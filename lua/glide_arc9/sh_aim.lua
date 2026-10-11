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

-- Seat-local yaw that faces forward on Glide seats
local SEAT_FORWARD_YAW = 90

local NormalizeAngle = math.NormalizeAngle

--- Aim yaw/pitch relative to the seat's forward direction (positive yaw
--- is to the left), or nil if unknown.
function GlideArc9.GetSeatAimAngles( ply )
    local aim = aimAngles[ply]
    if not aim then return end

    local seat = ply:GetVehicle()
    if not IsValid( seat ) then return end

    local localAim = seat:WorldToLocalAngles( aim )

    return NormalizeAngle( localAim[2] - SEAT_FORWARD_YAW ), NormalizeAngle( localAim[1] )
end

----- Aim limits

-- Up/down limits (degrees, relative to the vehicle, negative is up)
local SEATED_PITCH_UP = -50
local SEATED_PITCH_DOWN = 40
local LEAN_PITCH_UP = -70
local LEAN_PITCH_DOWN = 60

-- While leaning out, shots must clear the player's own vehicle this far out
local LEAN_BLOCK_CHECK_DISTANCE = 150

-- Seat-local angles a Glide seat's occupant faces
local SEAT_FORWARD = Angle( 0, SEAT_FORWARD_YAW, 0 )

--- Aim relative to the vehicle: yaw from the direction the player faces
--- (positive is to the left) and pitch (negative is up). Also returns the
--- facing yaw (vehicle-local) and the vehicle. Unlike the seat's frame,
--- this doesn't change when the seat tilts while leaning out.
function GlideArc9.GetVehicleAimAngles( ply )
    local aim = aimAngles[ply]
    if not aim then return end

    local seat = ply:GetVehicle()
    local vehicle = ply:GlideGetVehicle()
    if not IsValid( seat ) or not IsValid( vehicle ) then return end

    local facingYaw = vehicle:WorldToLocalAngles( seat:LocalToWorldAngles( SEAT_FORWARD ) )[2]
    local localAim = vehicle:WorldToLocalAngles( aim )

    return NormalizeAngle( localAim[2] - facingYaw ), NormalizeAngle( localAim[1] ), facingYaw, vehicle
end

--- How far the player can aim (relative to the vehicle, see above):
--- minYaw, maxYaw, minPitch, maxPitch.
function GlideArc9.GetAimLimits( ply )
    local side = GlideArc9.GetLeanSide( ply )

    if side ~= 0 then
        local minYaw, maxYaw = GlideArc9.GetLeanYawRange( side )

        return minYaw, maxYaw, LEAN_PITCH_UP, LEAN_PITCH_DOWN
    end

    local arc = GlideArc9.GetAimArc()

    return -arc, arc, SEATED_PITCH_UP, SEATED_PITCH_DOWN
end

local function HitOnlyVehicle( vehicle )
    return function( ent )
        return ent == vehicle
    end
end

--- Leaning out: would shots go into the player's own vehicle (down through
--- the roof, the bonnet, back into the car)? Only checked when the eyes are
--- outside the vehicle's bounds, a trace starting inside it would always hit.
local function IsAimIntoOwnVehicle( ply, vehicle )
    local eyes = ply:EyePos()
    local localEyes = vehicle:WorldToLocal( eyes )

    if localEyes:WithinAABox( vehicle:OBBMins(), vehicle:OBBMaxs() ) then return false end

    local tr = util.TraceLine( {
        start = eyes,
        endpos = eyes + aimAngles[ply]:Forward() * LEAN_BLOCK_CHECK_DISTANCE,
        filter = HitOnlyVehicle( vehicle ),
        ignoreworld = true,
        mask = MASK_SHOT
    } )

    return tr.Hit
end

--- Is the player aiming somewhere their gun can physically point?
function GlideArc9.IsAimInArc( ply )
    local yaw, pitch, _, vehicle = GlideArc9.GetVehicleAimAngles( ply )
    if not yaw then return true end

    local minYaw, maxYaw, minPitch, maxPitch = GlideArc9.GetAimLimits( ply )

    if yaw < minYaw or yaw > maxYaw or pitch < minPitch or pitch > maxPitch then
        return false
    end

    if GlideArc9.GetLeanSide( ply ) ~= 0 and IsAimIntoOwnVehicle( ply, vehicle ) then
        return false
    end

    return true
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
        UpdateNearWall( ply, inWeaponMode )

        if not inWeaponMode then
            aimAngles[ply] = nil
            return
        end

        -- Glide puts the distance to its aim point in the up-move while its
        -- camera is active. Zero means it isn't (the player is looking through
        -- a GMod camera, for example) and the view angles are just the seat's,
        -- so keep aiming where the player last aimed.
        if cmd:GetUpMove() == 0 and aimAngles[ply] then return end

        local angles = cmd:GetViewAngles()

        aimAngles[ply] = angles
        NetworkAim( ply, angles )
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
                -- Keep the last aim while Glide's camera is off (see the server side)
                aimAngles[ply] = inWeaponMode and ( GetCameraAim() or aimAngles[ply] ) or nil
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

----- Firing arc

-- The gun's pose stops at the aim arc (see sh_anims.lua). Block shots past
-- it, so bullets never leave in a direction the gun isn't visibly pointing
-- (like out the back of the car while the rifle points out the side).
-- Runs on both realms, so prediction agrees.
hook.Add( "ARC9_HookP_BlockFire", "GlideArc9.AimArc", function( weapon )
    local owner = weapon:GetOwner()
    if not IsValid( owner ) or not owner:IsPlayer() then return end
    if not GlideArc9.IsInWeaponMode( owner ) then return end

    if not GlideArc9.IsAimInArc( owner ) then
        return true
    end
end )

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

    print( string.format( "[GlideArc9 %s v" .. GlideArc9.VERSION .. "] %s | aim %s | eyes %s | engine eyes %s | bullet %s -> %s | vehicle %s | seat %s | src->aimpos %s",
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
