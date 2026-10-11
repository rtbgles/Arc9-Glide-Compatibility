util.AddNetworkString( GlideArc9.NET_TOGGLE )

local IsValid = IsValid

local NW_WEAPON_MODE = GlideArc9.NW_WEAPON_MODE
local TOGGLE_COOLDOWN = 0.3

local ICON_DENIED = "materials/icon16/cancel.png"
local SOUND_DENIED = "glide/ui/radar_alert.wav"

----- Glide input actions to ignore while in weapon mode

local blockedActions = {}

local function ParseBlockedActions( value )
    table.Empty( blockedActions )

    for _, action in ipairs( string.Explode( ",", value ) ) do
        action = string.Trim( action )

        if action ~= "" then
            blockedActions[action] = true
        end
    end
end

ParseBlockedActions( GetConVar( "glide_arc9_blocked_actions" ):GetString() )

cvars.AddChangeCallback( "glide_arc9_blocked_actions", function( _, _, newValue )
    ParseBlockedActions( newValue )
end, "GlideArc9.ParseBlockedActions" )

----- Helpers

local function Notify( ply, text, icon, sound )
    if not Glide or not isfunction( Glide.SendNotification ) then return end

    Glide.SendNotification( ply, {
        text = text,
        icon = icon,
        sound = sound,
        immediate = true
    } )
end

--- Returns the Glide vehicle and seat index this player is sitting on, if any.
local function GetGlideSeat( ply )
    if not isfunction( ply.GlideGetVehicle ) then return end

    local vehicle = ply:GlideGetVehicle()
    if not IsValid( vehicle ) then return end

    return vehicle, ply:GlideGetSeatIndex()
end

local function GetOwnedAllowedWeapon( ply, class )
    if not class then return end

    local weapon = ply:GetWeapon( class )
    if not GlideArc9.IsWeaponAllowed( weapon ) then return end

    return weapon
end

--- Pick which weapon to draw: the one last used in weapon mode, then the one
--- held before entering the vehicle, then the first allowed weapon we can find.
local function FindWeaponToEquip( ply )
    local weapon = GetOwnedAllowedWeapon( ply, ply.GlideArc9LastClass )
        or GetOwnedAllowedWeapon( ply, ply.GlideLastWeaponClass )

    if weapon then return weapon end

    for _, candidate in ipairs( ply:GetWeapons() ) do
        if GlideArc9.IsWeaponAllowed( candidate ) then
            return candidate
        end
    end
end

--- Release blocked inputs that might have been held down when weapon mode
--- started, so the vehicle does not keep firing/honking on its own.
local function ReleaseBlockedInputs( vehicle, seatIndex )
    if not isfunction( vehicle.GetInputBool ) or not isfunction( vehicle.SetInputBool ) then return end

    local aliases = Glide.ACTION_ALIASES or {}

    for action in pairs( blockedActions ) do
        action = aliases[action] or action

        if vehicle:GetInputBool( seatIndex, action ) then
            vehicle:SetInputBool( seatIndex, action, false )
        end
    end
end

----- Weapon mode state

--- Leave weapon mode. When `holster` is true the active weapon is put away
--- and the vehicle's original weapon permission is restored. Pass false when
--- the player is leaving the vehicle, so they keep holding their weapon.
function GlideArc9.DisableWeaponMode( ply, holster )
    if not GlideArc9.IsInWeaponMode( ply ) then return end

    ply:SetNW2Bool( NW_WEAPON_MODE, false )

    local weapon = ply:GetActiveWeapon()

    if IsValid( weapon ) then
        ply.GlideArc9LastClass = weapon:GetClass()
    end

    if holster then
        if IsValid( weapon ) then
            ply.GlideLastWeaponClass = weapon:GetClass()
            ply:SetActiveWeapon( NULL )
        end

        ply:SetAllowWeaponsInVehicle( ply.GlideArc9PrevAllowWeapons == true )
    end

    ply.GlideArc9PrevAllowWeapons = nil

    hook.Run( "GlideArc9_OnWeaponModeChanged", ply, false )
end

--- Try to enter weapon mode. Returns true on success.
function GlideArc9.EnableWeaponMode( ply )
    if GlideArc9.IsInWeaponMode( ply ) then return true end
    if not GlideArc9.IsEnabled() or not ply:Alive() then return false end

    local vehicle, seatIndex = GetGlideSeat( ply )
    if not vehicle then return false end

    if not GlideArc9.IsSeatAllowed( seatIndex ) then
        Notify( ply, "#glide_arc9.notify.seat_denied", ICON_DENIED, SOUND_DENIED )
        return false
    end

    if hook.Run( "GlideArc9_CanEnterWeaponMode", ply, vehicle, seatIndex ) == false then
        return false
    end

    local weapon = FindWeaponToEquip( ply )

    if not weapon then
        Notify( ply, "#glide_arc9.notify.no_weapon", ICON_DENIED, SOUND_DENIED )
        return false
    end

    ply.GlideArc9PrevAllowWeapons = ply:GetAllowWeaponsInVehicle()
    ply:SetAllowWeaponsInVehicle( true )
    ply:SetNW2Bool( NW_WEAPON_MODE, true )

    ReleaseBlockedInputs( vehicle, seatIndex )

    local class = weapon:GetClass()

    ply.GlideLastWeaponClass = class
    ply:SelectWeapon( class )

    hook.Run( "GlideArc9_OnWeaponModeChanged", ply, true )

    return true
end

function GlideArc9.ToggleWeaponMode( ply )
    if GlideArc9.IsInWeaponMode( ply ) then
        GlideArc9.DisableWeaponMode( ply, true )
        return
    end

    GlideArc9.EnableWeaponMode( ply )
end

----- Networking

net.Receive( GlideArc9.NET_TOGGLE, function( _, ply )
    if not IsValid( ply ) then return end

    local now = RealTime()
    if ( ply.GlideArc9NextToggle or 0 ) > now then return end

    ply.GlideArc9NextToggle = now + TOGGLE_COOLDOWN

    GlideArc9.ToggleWeaponMode( ply )
end )

----- Glide integration

-- Stop Glide from using the same buttons as the weapon (fire, reload, etc.)
-- Only presses are blocked, so releases always reach the vehicle.
hook.Add( "Glide_CanPlayerVehicleInput", "GlideArc9.BlockVehicleInputs", function( ply, _, action, pressed )
    if pressed and blockedActions[action] and GlideArc9.IsInWeaponMode( ply ) then
        return false
    end
end )

-- Leaving the seat (exiting, switching seats, dying) ends weapon mode.
-- Glide handles holstering/restoring weapons when the player gets out.
hook.Add( "PlayerLeaveVehicle", "GlideArc9.Cleanup", function( ply )
    GlideArc9.DisableWeaponMode( ply, false )
end )

hook.Add( "PlayerDeath", "GlideArc9.Cleanup", function( ply )
    GlideArc9.DisableWeaponMode( ply, false )
end )

hook.Add( "PlayerSpawn", "GlideArc9.Cleanup", function( ply )
    GlideArc9.DisableWeaponMode( ply, false )
    ply.GlideArc9LastClass = nil
end )

-- Kick everyone out of weapon mode if the feature gets turned off.
cvars.AddChangeCallback( "glide_arc9_enabled", function( _, _, newValue )
    if tobool( newValue ) then return end

    for _, ply in player.Iterator() do
        GlideArc9.DisableWeaponMode( ply, true )
    end
end, "GlideArc9.DisableAll" )
