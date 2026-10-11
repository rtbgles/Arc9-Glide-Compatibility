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
         the usercmd (SetupMove may not run clientside in vehicles)
       - other clients: networked from the server, used for animations
       As a safety net, every shot leaving the gun is also re-aimed at the
       point Glide's camera is looking at (the same point Glide's turrets
       use), keeping the shot's spread/recoil offset.

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

local WorldToLocal = WorldToLocal
local LocalToWorld = LocalToWorld

-- Only shots leaving the gun get re-aimed. ARC9 also fires short bullets
-- from where a physical bullet hits something, those must be left alone.
local MAX_MUZZLE_DISTANCE_SQR = 48 * 48

-- Ignore aim points closer than this to the muzzle
local MIN_AIM_DISTANCE_SQR = 16 * 16

local DEBUG_INTERVAL = 0.25
local nextDebugPrint = 0

local DEBUG_LINE_LENGTH = 3000
local DEBUG_LINE_LIFETIME = 3
local DEBUG_COLOR_SHOT = SERVER and Color( 255, 60, 60 ) or Color( 60, 140, 255 )
local DEBUG_COLOR_AIM = Color( 60, 255, 60 )

local function GetWeaponModeVehicle( ply )
    if not IsValid( ply ) or not ply:IsPlayer() then return end
    if not GlideArc9.IsInWeaponMode( ply ) then return end

    local vehicle = ply:GlideGetVehicle()
    if IsValid( vehicle ) then return vehicle end
end

--- The point Glide's camera is aiming at: the same data Glide's own
--- turrets use, on the server (from the usercmd) and the local client.
local function GetAimPos( ply )
    local aimPos

    if SERVER then
        aimPos = isfunction( ply.GlideGetAimPos ) and ply:GlideGetAimPos()

    elseif ply == LocalPlayer() then
        local camera = Glide and Glide.Camera
        aimPos = camera and camera.isActive and camera.lastAimPos
    end

    if not isvector( aimPos ) or aimPos:IsZero() then return end

    return aimPos
end

--- With glide_arc9_debug 1: print the shot's angles, and (with developer 1)
--- draw the shot's path (red = server, blue = client) and Glide's aim point
--- (green cross).
local function DebugShot( ply, kind, src, before, after )
    if not cvarDebug:GetBool() then return end

    local final = after or before
    local aimPos = GetAimPos( ply )

    debugoverlay.Line( src, src + final:GetNormalized() * DEBUG_LINE_LENGTH, DEBUG_LINE_LIFETIME, DEBUG_COLOR_SHOT, true )

    if aimPos then
        debugoverlay.Cross( aimPos, 16, DEBUG_LINE_LIFETIME, DEBUG_COLOR_AIM, true )
    end

    local now = RealTime()
    if now < nextDebugPrint then return end

    nextDebugPrint = now + DEBUG_INTERVAL

    local vehicle = GetWeaponModeVehicle( ply )
    local seat = ply:GetVehicle()

    print( string.format( "[GlideArc9 %s] %s | aim %s | eyes %s | engine eyes %s | bullet %s -> %s | vehicle %s | seat %s | src->aimpos %s",
        SERVER and "SV" or "CL", kind, tostring( aimAngles[ply] ), tostring( ply:EyeAngles() ),
        tostring( originalEyeAngles( ply ) ), tostring( before:Angle() ),
        after and tostring( after:Angle() ) or "unchanged",
        IsValid( vehicle ) and tostring( vehicle:GetAngles() ) or "none",
        IsValid( seat ) and tostring( seat:GetAngles() ) or "none",
        aimPos and tostring( ( aimPos - src ):Angle() ) or "none" ) )
end

--- Re-aim a shot leaving the gun at `src` so it goes to Glide's aim point.
--- The shot's offset from the eye angles (spread, recoil, sway) is kept.
--- Returns the new direction, or nil to leave the shot alone.
local function CorrectShotDirection( ply, src, dir )
    if src:DistToSqr( ply:EyePos() ) > MAX_MUZZLE_DISTANCE_SQR then return end

    local aimPos = GetAimPos( ply )
    if not aimPos then return end

    local toAim = aimPos - src
    if toAim:LengthSqr() < MIN_AIM_DISTANCE_SQR then return end

    local localDir = WorldToLocal( dir, angle_zero, vector_origin, ply:EyeAngles() )
    local newDir = LocalToWorld( localDir, angle_zero, vector_origin, toAim:Angle() )

    return newDir
end

-- Hitscan bullets. The shooter is always skipped by the engine, and ARC9
-- only sets the (non-solid) seat here, so we can replace it with the vehicle.
hook.Add( "EntityFireBullets", "GlideArc9.InVehicleShots", function( entity, data )
    local vehicle = GetWeaponModeVehicle( entity )
    if not vehicle then return end

    data.IgnoreEntity = vehicle

    if isvector( data.Src ) and isvector( data.Dir ) then
        local newDir = CorrectShotDirection( entity, data.Src, data.Dir )

        DebugShot( entity, "hitscan", data.Src, data.Dir, newDir )

        if newDir then
            data.Dir = newDir
        end
    end

    return true
end )

-- ARC9 physical bullets trace with their own filter table.
hook.Add( "ARC9_HookP_ModifyNewBullet", "GlideArc9.InVehicleShots", function( weapon, bullet )
    local owner = weapon:GetOwner()
    local vehicle = GetWeaponModeVehicle( owner )
    if not vehicle then return end

    if istable( bullet.Filter ) then
        local filter = bullet.Filter
        filter[#filter + 1] = vehicle

        local seat = owner:GetVehicle()

        if IsValid( seat ) then
            filter[#filter + 1] = seat
        end
    end

    local vel = bullet.Vel
    if not isvector( bullet.Pos ) or not isvector( vel ) then return end

    local speed = vel:Length()
    if speed == 0 then return end

    local newDir = CorrectShotDirection( owner, bullet.Pos, vel / speed )

    DebugShot( owner, "physbullet", bullet.Pos, vel, newDir )

    if newDir then
        bullet.Vel = newDir * speed
    end
end )
