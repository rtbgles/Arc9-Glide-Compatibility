--[[
    Aiming and shooting from inside a Glide vehicle, while in weapon mode.

    1. Aim direction
       Glide's camera sends the world-space aim direction through the
       usercmd view angles (its turrets and tank cannons rely on this).
       While seated, the engine's EyeAngles does not match that aim, and
       ARC9 aims and shoots with EyeAngles, so shots went off to the side.
       For players in weapon mode, EyeAngles/GetAimVector return the aim
       Glide sent instead. It is cached from the same usercmd on both
       realms, so prediction stays in sync.

    2. The vehicle's own body
       In enclosed vehicles the player's eyes are inside the vehicle's
       collision hull, so every trace from the gun hits the vehicle itself.
       ARC9 then thinks the gun is pressed against a wall (lowered, can't
       fire or aim down sights) and bullets hit your own car. We turn off
       ARC9's near-wall check and make bullets ignore the vehicle.
]]

local IsValid = IsValid
local HUGE = math.huge

-- Keyed by player. Weak keys so disconnected players are collected.
local aimAngles = setmetatable( {}, { __mode = "k" } )
local nearWallWeapons = setmetatable( {}, { __mode = "k" } )

----- Near-wall check

--- ARC9 only re-traces once `NearWallLastCheck` has passed, and returns
--- `NearWallCached` until then. Pushing it to infinity turns the check off.
local function SetNearWallDisabled( weapon, disabled )
    if disabled then
        weapon.NearWallLastCheck = HUGE
        weapon.NearWallCached = false
    else
        weapon.NearWallLastCheck = 0
    end
end

local function UpdateNearWall( ply, inWeaponMode )
    local weapon = inWeaponMode and ply:GetActiveWeapon() or nil

    if not IsValid( weapon ) or not weapon.ARC9 then
        weapon = nil
    end

    local patched = nearWallWeapons[ply]
    if patched == weapon then return end

    if IsValid( patched ) then
        SetNearWallDisabled( patched, false )
    end

    if weapon then
        SetNearWallDisabled( weapon, true )
    end

    nearWallWeapons[ply] = weapon
end

hook.Add( "SetupMove", "GlideArc9.Aim", function( ply, _, cmd )
    local inWeaponMode = GlideArc9.IsInWeaponMode( ply )

    aimAngles[ply] = inWeaponMode and cmd:GetViewAngles() or nil

    UpdateNearWall( ply, inWeaponMode )
end )

----- EyeAngles / GetAimVector

local PlayerMeta = FindMetaTable( "Player" )
local EntityMeta = FindMetaTable( "Entity" )

-- Keep the originals across Lua refreshes
GlideArc9.OriginalEyeAngles = GlideArc9.OriginalEyeAngles
    or rawget( PlayerMeta, "EyeAngles" )
    or EntityMeta.EyeAngles

GlideArc9.OriginalGetAimVector = GlideArc9.OriginalGetAimVector
    or rawget( PlayerMeta, "GetAimVector" )

local originalEyeAngles = GlideArc9.OriginalEyeAngles
local originalGetAimVector = GlideArc9.OriginalGetAimVector

function PlayerMeta:EyeAngles()
    local angles = aimAngles[self]

    if angles then
        -- Return a copy, callers (ARC9 included) modify it in place
        return Angle( angles[1], angles[2], angles[3] )
    end

    return originalEyeAngles( self )
end

function PlayerMeta:GetAimVector()
    local angles = aimAngles[self]

    if angles then
        return angles:Forward()
    end

    return originalGetAimVector( self )
end

----- Bullets

local function GetWeaponModeVehicle( ply )
    if not IsValid( ply ) or not ply:IsPlayer() then return end
    if not GlideArc9.IsInWeaponMode( ply ) then return end

    local vehicle = ply:GlideGetVehicle()
    if IsValid( vehicle ) then return vehicle end
end

-- Hitscan bullets. The shooter is always skipped by the engine, and ARC9
-- only sets the (non-solid) seat here, so we can replace it with the vehicle.
hook.Add( "EntityFireBullets", "GlideArc9.IgnoreOwnVehicle", function( entity, data )
    local vehicle = GetWeaponModeVehicle( entity )
    if not vehicle then return end

    data.IgnoreEntity = vehicle

    return true
end )

-- ARC9 physical bullets trace with their own filter table.
hook.Add( "ARC9_HookP_ModifyNewBullet", "GlideArc9.IgnoreOwnVehicle", function( weapon, bullet )
    local owner = weapon:GetOwner()
    local vehicle = GetWeaponModeVehicle( owner )
    if not vehicle or not istable( bullet.Filter ) then return end

    local filter = bullet.Filter
    filter[#filter + 1] = vehicle

    local seat = owner:GetVehicle()

    if IsValid( seat ) then
        filter[#filter + 1] = seat
    end
end )
