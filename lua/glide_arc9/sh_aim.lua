--[[
    Aiming and shooting from inside a Glide vehicle, while in weapon mode.

    1. Aim direction
       Glide's camera sends the world-space aim direction through the
       usercmd view angles (its turrets and tank cannons rely on this).
       While seated, the engine's EyeAngles does not match that aim, and
       ARC9 aims and shoots with EyeAngles, so shots went off to the side.
       For players in weapon mode, EyeAngles/GetAimVector return that aim
       instead:
       - server: read from the usercmd, exactly what Glide sent
       - local client: read from Glide's camera, the value Glide puts in
         the usercmd (SetupMove is not reliable clientside in vehicles)
       - other clients: networked from the server, used for animations

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

----- Aim caching

local NW_AIM = "GlideArc9.Aim"

-- Only network the aim to other clients when it changes this much (degrees)
local AIM_NETWORK_THRESHOLD = 1

--- The world-space aim of a player in weapon mode, or nil.
function GlideArc9.GetAimAngles( ply )
    return aimAngles[ply]
end

if SERVER then
    local AngleDifference = math.AngleDifference
    local Abs = math.abs

    local networkedAim = setmetatable( {}, { __mode = "k" } )

    local function NetworkAim( ply, angles )
        local last = networkedAim[ply]

        if last
            and Abs( AngleDifference( last[1], angles[1] ) ) < AIM_NETWORK_THRESHOLD
            and Abs( AngleDifference( last[2], angles[2] ) ) < AIM_NETWORK_THRESHOLD
        then
            return
        end

        networkedAim[ply] = angles
        ply:SetNW2Angle( NW_AIM, angles )
    end

    hook.Add( "SetupMove", "GlideArc9.Aim", function( ply, _, cmd )
        local inWeaponMode = GlideArc9.IsInWeaponMode( ply )
        local angles = inWeaponMode and cmd:GetViewAngles() or nil

        aimAngles[ply] = angles
        UpdateNearWall( ply, inWeaponMode )

        if angles then
            NetworkAim( ply, angles )
        end
    end )
end

if CLIENT then
    local LocalPlayer = LocalPlayer

    local function GetCameraAim()
        local camera = Glide and Glide.Camera
        if not camera or not camera.isActive then return end

        return camera.lastAimPosAnglesFromEyes
    end

    hook.Add( "Think", "GlideArc9.Aim", function()
        local localPly = LocalPlayer()

        for _, ply in player.Iterator() do
            local inWeaponMode = GlideArc9.IsInWeaponMode( ply )

            if ply == localPly then
                aimAngles[ply] = inWeaponMode and GetCameraAim() or nil
                UpdateNearWall( ply, inWeaponMode )
            else
                aimAngles[ply] = inWeaponMode and ply:GetNW2Angle( NW_AIM, nil ) or nil
            end
        end
    end )
end

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

local cvarDebug = CreateConVar( "glide_arc9_debug", "0", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Print aim/bullet directions to the console when firing in weapon mode.", 0, 1 )

local DEBUG_INTERVAL = 0.25
local nextDebugPrint = 0

local function DebugShot( ply, kind, direction )
    if not cvarDebug:GetBool() then return end

    local now = RealTime()
    if now < nextDebugPrint then return end

    nextDebugPrint = now + DEBUG_INTERVAL

    print( string.format( "[GlideArc9 %s] %s | aim %s | engine eyes %s | bullet %s",
        SERVER and "SV" or "CL", kind, tostring( aimAngles[ply] ),
        tostring( originalEyeAngles( ply ) ), tostring( direction:Angle() ) ) )
end

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

    if data.Dir then
        DebugShot( entity, "hitscan", data.Dir )
    end

    return true
end )

-- ARC9 physical bullets trace with their own filter table.
hook.Add( "ARC9_HookP_ModifyNewBullet", "GlideArc9.IgnoreOwnVehicle", function( weapon, bullet )
    local owner = weapon:GetOwner()
    local vehicle = GetWeaponModeVehicle( owner )
    if not vehicle or not istable( bullet.Filter ) then return end

    local filter = bullet.Filter
    filter[#filter + 1] = vehicle

    if isvector( bullet.Vel ) then
        DebugShot( owner, "physbullet", bullet.Vel )
    end

    local seat = owner:GetVehicle()

    if IsValid( seat ) then
        filter[#filter + 1] = seat
    end
end )
