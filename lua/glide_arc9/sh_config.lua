GlideArc9.NW_WEAPON_MODE = "GlideArc9.WeaponMode"
GlideArc9.NW_LEAN = "GlideArc9.Lean"
GlideArc9.NET_TOGGLE = "glide_arc9.toggle"
GlideArc9.NET_LEAN = "glide_arc9.lean"

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

local cvarLeanEnabled = CreateConVar( "glide_arc9_lean_enabled", "1", SERVER_FLAGS,
    "Let passengers in weapon mode lean out of their window (double-tap A or D).", 0, 1 )

local cvarLeanAimBack = CreateConVar( "glide_arc9_lean_aim_back", "150", SERVER_FLAGS,
    "While leaning out, how far back (degrees from forward) players can aim and fire on their side.", 90, 170 )

-- While leaning out, how far players can aim across the front of the vehicle
local LEAN_AIM_ACROSS = 30

CreateConVar( "glide_arc9_enclosed_boost", "0.7", SERVER_FLAGS,
    "Gunshots inside enclosed vehicles get an extra layer at this volume (0 turns it off).", 0, 1 )

CreateConVar( "glide_arc9_enclosed_dsp", "2", SERVER_FLAGS,
    "DSP preset (room echo) for gunshots inside enclosed vehicles. 0 turns it off; 2 is a small metal room.", 0, 140 )

CreateConVar( "glide_arc9_blocked_actions", "attack,attack_alt,switch_weapon,horn", SERVER_FLAGS,
    "Comma-separated Glide input actions that are ignored while a player is in weapon mode." )

local GetNW2Bool = FindMetaTable( "Entity" ).GetNW2Bool
local GetNW2Int = FindMetaTable( "Entity" ).GetNW2Int
local NW_WEAPON_MODE = GlideArc9.NW_WEAPON_MODE
local NW_LEAN = GlideArc9.NW_LEAN

function GlideArc9.GetAimArc()
    return cvarAimArc:GetFloat()
end

function GlideArc9.IsLeanEnabled()
    return cvarLeanEnabled:GetBool()
end

--- Seat-relative yaw range (min, max) a player leaning out of `side`
--- (1 = left, -1 = right) can aim in: forward and back on their side, and
--- a little across the front. Positive yaw is to the left.
function GlideArc9.GetLeanYawRange( side )
    local back = cvarLeanAimBack:GetFloat()

    if side > 0 then
        return -LEAN_AIM_ACROSS, back
    end

    return -back, LEAN_AIM_ACROSS
end

-- Seats closer to the vehicle's center line than this have no window side
local MIN_SEAT_SIDE_OFFSET = 4

--- Which side of the vehicle this player's seat is on: 1 = left, -1 = right,
--- 0 = middle (or not seated). Glide vehicles face +X, so left is +Y.
function GlideArc9.GetSeatSide( ply )
    local seat = ply:GetVehicle()
    if not IsValid( seat ) then return 0 end

    local y = seat:GetLocalPos()[2]
    if math.abs( y ) < MIN_SEAT_SIDE_OFFSET then return 0 end

    return y > 0 and 1 or -1
end

--- Which window this player is leaning out of: 1 = left, -1 = right, 0 = not leaning.
function GlideArc9.GetLeanSide( ply )
    return GetNW2Int( ply, NW_LEAN, 0 )
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
