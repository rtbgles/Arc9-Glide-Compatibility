local cvarDoubleTap = CreateClientConVar( "cl_glide_arc9_doubletap", "1", true, false,
    "Double-tap the duck key (CTRL) while in a Glide vehicle to toggle weapon mode.", 0, 1 )

local cvarDoubleTapWindow = CreateClientConVar( "cl_glide_arc9_doubletap_window", "0.3", true, false,
    "Maximum time (in seconds) between both taps of a double-tap.", 0.1, 1 )

language.Add( "glide_arc9.notify.no_weapon", "You have no weapon that can be used inside vehicles." )
language.Add( "glide_arc9.notify.seat_denied", "Weapons are not allowed on this seat." )

local IsValid = IsValid
local RealTime = RealTime
local LocalPlayer = LocalPlayer

function GlideArc9.RequestToggle()
    local ply = LocalPlayer()
    if not IsValid( ply ) then return end
    if not isfunction( ply.GlideGetVehicle ) or not IsValid( ply:GlideGetVehicle() ) then return end

    net.Start( GlideArc9.NET_TOGGLE )
    net.SendToServer()
end

concommand.Add( "glide_arc9_toggle", function()
    GlideArc9.RequestToggle()
end, nil, "Toggle weapon mode while seated in a Glide vehicle." )

----- Double-tap detection & state tracking (only while inside a Glide vehicle)

local wasDuckDown = false
local lastTapTime = 0
local wasInWeaponMode = false

local function ResetState()
    wasDuckDown = false
    lastTapTime = 0

    if wasInWeaponMode then
        wasInWeaponMode = false
        hook.Run( "GlideArc9_OnLocalWeaponModeChanged", false )
    end
end

local function CheckDoubleTap( ply )
    -- Same check Glide uses for its own CTRL camera toggle.
    local isDuckDown = ply:KeyDown( IN_DUCK ) and not vgui.CursorVisible()
    if isDuckDown == wasDuckDown then return end

    wasDuckDown = isDuckDown
    if not isDuckDown then return end

    local now = RealTime()

    if now - lastTapTime <= cvarDoubleTapWindow:GetFloat() then
        lastTapTime = 0
        GlideArc9.RequestToggle()
    else
        lastTapTime = now
    end
end

local function OnThink()
    local ply = LocalPlayer()
    if not IsValid( ply ) then return end

    local inWeaponMode = GlideArc9.IsInWeaponMode( ply )

    if inWeaponMode ~= wasInWeaponMode then
        wasInWeaponMode = inWeaponMode
        hook.Run( "GlideArc9_OnLocalWeaponModeChanged", inWeaponMode )
    end

    if cvarDoubleTap:GetBool() then
        CheckDoubleTap( ply )
    end
end

----- Weapon selection while in weapon mode

-- The default weapon selection is unreliable for players that entered a
-- vehicle without weapons, so handle slot/scroll binds ourselves while in
-- weapon mode. This also keeps the selection limited to allowed weapons.

local function GetSelectableWeapons( ply )
    local list = {}

    for _, weapon in ipairs( ply:GetWeapons() ) do
        if GlideArc9.IsWeaponAllowed( weapon ) then
            list[#list + 1] = weapon
        end
    end

    table.sort( list, function( a, b )
        local slotA, slotB = a:GetSlot(), b:GetSlot()
        if slotA ~= slotB then return slotA < slotB end

        return a:GetSlotPos() < b:GetSlotPos()
    end )

    return list
end

local function FindIndex( list, value )
    for i, v in ipairs( list ) do
        if v == value then return i end
    end

    return 0
end

local function CycleWeapon( ply, direction )
    local list = GetSelectableWeapons( ply )
    local count = #list
    if count == 0 then return end

    local index = FindIndex( list, ply:GetActiveWeapon() )
    local nextIndex = ( ( index - 1 + direction ) % count ) + 1

    input.SelectWeapon( list[nextIndex] )
end

local function SelectSlot( ply, slot )
    local inSlot = {}

    for _, weapon in ipairs( GetSelectableWeapons( ply ) ) do
        if weapon:GetSlot() == slot then
            inSlot[#inSlot + 1] = weapon
        end
    end

    local count = #inSlot
    if count == 0 then return end

    -- Pressing the same slot again cycles through the weapons in it
    local index = FindIndex( inSlot, ply:GetActiveWeapon() )

    input.SelectWeapon( inSlot[( index % count ) + 1] )
end

local function OnBindPress( ply, bind, pressed )
    if not pressed or not GlideArc9.IsInWeaponMode( ply ) then return end

    if bind == "invnext" then
        CycleWeapon( ply, 1 )
        return true
    end

    if bind == "invprev" then
        CycleWeapon( ply, -1 )
        return true
    end

    local slot = string.match( bind, "^slot(%d)$" )

    if slot then
        SelectSlot( ply, tonumber( slot ) - 1 )
        return true
    end
end

----- Glide hooks

hook.Add( "Glide_OnLocalEnterVehicle", "GlideArc9.StartTracking", function()
    ResetState()
    hook.Add( "Think", "GlideArc9.WeaponMode", OnThink )
    hook.Add( "PlayerBindPress", "GlideArc9.WeaponSelection", OnBindPress )
end )

hook.Add( "Glide_OnLocalExitVehicle", "GlideArc9.StopTracking", function()
    hook.Remove( "Think", "GlideArc9.WeaponMode" )
    hook.Remove( "PlayerBindPress", "GlideArc9.WeaponSelection" )
    ResetState()
end )
