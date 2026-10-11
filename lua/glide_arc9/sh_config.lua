GlideArc9.NW_WEAPON_MODE = "GlideArc9.WeaponMode"
GlideArc9.NET_TOGGLE = "glide_arc9.toggle"

local SERVER_FLAGS = { FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY }

local cvarEnabled = CreateConVar( "glide_arc9_enabled", "1", SERVER_FLAGS,
    "Allow players to toggle weapon mode while seated in Glide vehicles.", 0, 1 )

local cvarAllowDriver = CreateConVar( "glide_arc9_allow_driver", "1", SERVER_FLAGS,
    "Allow the driver/pilot of a Glide vehicle to use weapon mode.", 0, 1 )

local cvarAllowPassengers = CreateConVar( "glide_arc9_allow_passengers", "1", SERVER_FLAGS,
    "Allow passengers of a Glide vehicle to use weapon mode.", 0, 1 )

local cvarArc9Only = CreateConVar( "glide_arc9_arc9_only", "1", SERVER_FLAGS,
    "Only allow ARC9 weapons to be used while in weapon mode.", 0, 1 )

local cvarAimArc = CreateConVar( "glide_arc9_aim_arc", "110", SERVER_FLAGS,
    "How far (degrees, left or right of the seat's forward) players can aim and fire in weapon mode.", 30, 180 )

CreateConVar( "glide_arc9_blocked_actions", "attack,attack_alt,switch_weapon,horn", SERVER_FLAGS,
    "Comma-separated Glide input actions that are ignored while a player is in weapon mode." )

local GetNW2Bool = FindMetaTable( "Entity" ).GetNW2Bool
local NW_WEAPON_MODE = GlideArc9.NW_WEAPON_MODE

function GlideArc9.GetAimArc()
    return cvarAimArc:GetFloat()
end

function GlideArc9.IsEnabled()
    return cvarEnabled:GetBool()
end

--- Is this player currently in weapon mode inside a Glide vehicle?
function GlideArc9.IsInWeaponMode( ply )
    return GetNW2Bool( ply, NW_WEAPON_MODE, false )
end

--- Can this weapon be held while in weapon mode?
function GlideArc9.IsWeaponAllowed( weapon )
    if not IsValid( weapon ) then return false end
    if not cvarArc9Only:GetBool() then return true end

    return weapon.ARC9 == true
end

--- Is this seat allowed to use weapon mode? Seat 1 is the driver/pilot.
function GlideArc9.IsSeatAllowed( seatIndex )
    if seatIndex == 1 then
        return cvarAllowDriver:GetBool()
    end

    return seatIndex > 1 and cvarAllowPassengers:GetBool()
end

-- While in weapon mode, block switching to weapons that are not allowed.
-- This runs on both realms so prediction stays in sync.
hook.Add( "PlayerSwitchWeapon", "GlideArc9.RestrictWeapons", function( ply, _, newWeapon )
    if not GlideArc9.IsInWeaponMode( ply ) then return end
    if not IsValid( newWeapon ) then return end

    if not GlideArc9.IsWeaponAllowed( newWeapon ) then
        return true
    end

    if SERVER then
        -- Glide restores this weapon class when the player leaves the vehicle,
        -- so they keep holding the gun they were using.
        ply.GlideLastWeaponClass = newWeapon:GetClass()
    end
end )
