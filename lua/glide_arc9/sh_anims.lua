--[[
    Third person animations while in weapon mode.

    Glide picks a seated animation per seat (steering wheel for car
    drivers, handlebars for bikes) and only switches to a "holding a gun"
    pose for passengers on plain seats. Its hooks also skip the engine's
    aim pose, so the gun never pointed where the player was aiming.

    While in weapon mode, for every seat:
    - use the seated pose that matches the weapon's hold type
    - point the arms and head at the player's aim (pose parameters), then
      measure where the gun really points and turn the spine until it's
      on target (clientside, any model, seated or leaning out)
    - skip Glide's hand/arm bone poses

    Glide's hooks are wrapped in place (same hook identifiers), so it does
    not matter which addon's hook would have run first.
]]

local IsValid = IsValid

local ACT_HL2MP_SIT = 1970

local HOLDTYPE_SEQUENCES = {
    ["pistol"] = "sit_pistol",
    ["revolver"] = "sit_pistol",
    ["smg"] = "sit_smg1",
    ["ar2"] = "sit_ar2",
    ["shotgun"] = "sit_shotgun",
    ["rpg"] = "sit_rpg",
    ["crossbow"] = "sit_crossbow",
    ["grenade"] = "sit_grenade",
    ["melee"] = "sit_melee",
    ["melee2"] = "sit_melee2",
    ["knife"] = "sit_knife",
    ["fist"] = "sit_fist",
    ["duel"] = "sit_duel",
    ["physgun"] = "sit_physgun",
    ["slam"] = "sit_slam",
    ["camera"] = "sit_camera",
    ["passive"] = "sit_passive",
    ["magic"] = "sit_magic"
}

local FALLBACK_SEQUENCE = "sit_ar2"

local function GetWeaponModeWeapon( ply )
    if not GlideArc9.IsInWeaponMode( ply ) then return end

    local weapon = ply:GetActiveWeapon()
    if IsValid( weapon ) then return weapon end
end

local function GetSitSequence( ply, weapon )
    local name = HOLDTYPE_SEQUENCES[weapon:GetHoldType()] or FALLBACK_SEQUENCE
    local seq = ply:LookupSequence( name )

    if seq == -1 then
        seq = ply:LookupSequence( FALLBACK_SEQUENCE )
    end

    return seq
end

local function CalcWeaponModeActivity( ply )
    local weapon = GetWeaponModeWeapon( ply )
    if not weapon then return end

    local seq = GetSitSequence( ply, weapon )
    if seq == -1 then return end

    local plyTbl = ply:GetTable()
    plyTbl.CalcIdeal = ACT_HL2MP_SIT
    plyTbl.CalcSeqOverride = seq

    return ACT_HL2MP_SIT, seq
end

----- Aim pose

local Clamp = math.Clamp

-- Each of these can only turn so far (aim_yaw stops around the A-pillar
-- when looking out a side window). Whatever one can't cover is passed on to
-- the next, so the torso twists to make up the rest. Missing ones are skipped.
local YAW_POSE_PARAMS = { "aim_yaw", "spine_yaw", "body_yaw" }
local TWIST_POSE_PARAMS = { "spine_yaw", "body_yaw" }

-- [model] = { [poseName] = { min, max } or false }
local poseRanges = {}

local cvarDebug = GetConVar( "glide_arc9_debug" )
local DEBUG_INTERVAL = 1
local nextDebugPrint = 0

local function GetPoseRange( ply, name )
    local model = ply:GetModel()
    local ranges = poseRanges[model]

    if not ranges then
        ranges = {}
        poseRanges[model] = ranges
    end

    local range = ranges[name]

    if range == nil then
        local id = ply:LookupPoseParameter( name )

        if id < 0 then
            range = false
        else
            local min, max = ply:GetPoseParameterRange( id )
            range = { min, max }
        end

        ranges[name] = range
    end

    return range
end

--- Set a pose parameter within its range. Returns the value actually used.
local function SetClampedPose( ply, name, value )
    local range = GetPoseRange( ply, name )
    if not range then return 0 end

    value = Clamp( value, range[1], range[2] )
    ply:SetPoseParameter( name, value )

    return value
end

local function ResetTwist( ply )
    for _, name in ipairs( TWIST_POSE_PARAMS ) do
        SetClampedPose( ply, name, 0 )
    end
end

----- Closed-loop aim (clientside, for every player in weapon mode)

--[[
    The pose parameters above get the gun roughly toward the aim, but how
    far they really turn it depends on the player model, the seated
    animation and the seat's tilt (leaning out). So every frame the gun's
    actual direction is measured and the spine is rotated a little toward
    the aim. Whatever the pose got wrong is corrected, on any model.

    The spine bones are what turns: the arms, head and gun hang off them,
    the legs don't. Each bone can only turn so far, which is the body's
    physical limit; past it the gun stays at the edge.
]]

local CORRECTION_BONES = {
    "ValveBiped.Bip01_Spine",
    "ValveBiped.Bip01_Spine1",
    "ValveBiped.Bip01_Spine2",
    "ValveBiped.Bip01_Spine4"
}

-- How quickly the gun closes in on the aim (per second)
local CORRECTION_RATE = 14

-- How quickly the spine drifts back to rest, so no odd twist builds up
local RELAX_RATE = 0.25

-- Most a single frame may turn the gun (degrees)
local MAX_STEP = 20

-- Most each spine bone may turn away from the animation (degrees)
local MAX_BONE_CORRECTION = 35

-- Errors smaller than this are left alone (degrees)
local DEADBAND = 0.5

-- [model] = { boneId, ... }
local correctionBoneIds = {}

local function GetCorrectionBones( ply )
    local model = ply:GetModel()
    local ids = correctionBoneIds[model]
    if ids then return ids end

    ids = {}

    for _, name in ipairs( CORRECTION_BONES ) do
        local id = ply:LookupBone( name )

        if id then
            ids[#ids + 1] = id
        end
    end

    correctionBoneIds[model] = ids

    return ids
end

local function ResetCorrection( ply )
    for _, id in ipairs( GetCorrectionBones( ply ) ) do
        ply:ManipulateBoneAngles( id, angle_zero, false )
    end
end

--- How many degrees of rotation an Angle represents.
local function GetRotationAmount( ang )
    -- Trace of the rotation matrix; Right() is the -Y axis in Source
    local trace = ang:Forward()[1] - ang:Right()[2] + ang:Up()[3]

    return math.deg( math.acos( Clamp( ( trace - 1 ) * 0.5, -1, 1 ) ) )
end

--- Where the gun's barrel points. ARC9 draws the weapon with its own model,
--- facing down the barrel.
local function GetGunDirection( weapon )
    if not isfunction( weapon.GetWM ) then return end

    local wm = weapon:GetWM()
    if not IsValid( wm ) then return end

    return wm:GetAngles():Forward()
end

--- The aim, kept within the limits (sh_aim.lua), so the gun stops at the edge.
local function GetTargetDirection( ply )
    local yaw, pitch, facingYaw, vehicle = GlideArc9.GetVehicleAimAngles( ply )
    if not yaw then return end

    local minYaw, maxYaw, minPitch, maxPitch = GlideArc9.GetAimLimits( ply )
    local ang = Angle( Clamp( pitch, minPitch, maxPitch ), facingYaw + Clamp( yaw, minYaw, maxYaw ), 0 )

    return vehicle:LocalToWorldAngles( ang ):Forward()
end

local function ApplyAimCorrection( ply, weapon )
    local ids = GetCorrectionBones( ply )
    local count = #ids
    if count == 0 then return end

    local target = GetTargetDirection( ply )
    local gun = GetGunDirection( weapon )
    if not target or not gun then return end

    local dt = FrameTime()
    local relax = 1 - math.exp( -RELAX_RATE * dt )

    -- The rotation that would turn the gun onto the target
    local axis = gun:Cross( target )
    local sinError = axis:Length()
    local errorAngle = math.deg( math.atan2( sinError, gun:Dot( target ) ) )
    local step = 0

    if errorAngle > DEADBAND and sinError > 1e-4 then
        axis:Div( sinError )
        step = math.min( errorAngle * ( 1 - math.exp( -CORRECTION_RATE * dt ) ), MAX_STEP ) / count
    end

    ply:GetTable().GlideArc9AimError = errorAngle

    for _, id in ipairs( ids ) do
        local manip = LerpAngle( relax, ply:GetManipulateBoneAngles( id ), angle_zero )
        local matrix = step > 0 and ply:GetBoneMatrix( id )

        if matrix then
            -- The world axis in this bone's frame, then in the frame the
            -- manipulation is applied in: turning the bone by `step` around
            -- the world axis, on top of its current manipulation.
            local boneAxis = WorldToLocal( axis, angle_zero, vector_origin, matrix:GetAngles() )
            local manipAxis = LocalToWorld( boneAxis, angle_zero, vector_origin, manip )
            manipAxis:Normalize()

            local turned = Angle( manip )
            turned:RotateAroundAxis( manipAxis, step )

            if GetRotationAmount( turned ) <= MAX_BONE_CORRECTION then
                manip = turned
            end
        end

        ply:ManipulateBoneAngles( id, manip, false )
    end
end

local function UpdateWeaponModeAim( ply )
    local plyTbl = ply:GetTable()

    if not GetWeaponModeWeapon( ply ) then
        -- Put the torso back once after leaving weapon mode
        if plyTbl.GlideArc9Twisted then
            plyTbl.GlideArc9Twisted = nil
            plyTbl.GlideArc9AimError = nil
            ResetTwist( ply )

            if CLIENT then
                ResetCorrection( ply )
            end
        end

        return
    end

    local yaw, pitch = GlideArc9.GetSeatAimAngles( ply )
    if not yaw then return end

    -- Rough pose toward the aim, kept within the limits (the closed loop
    -- above fixes up the rest clientside)
    local minYaw, maxYaw, minPitch, maxPitch = GlideArc9.GetAimLimits( ply )
    local remaining = Clamp( yaw, minYaw, maxYaw )
    local applied = {}

    for i, name in ipairs( YAW_POSE_PARAMS ) do
        local value = SetClampedPose( ply, name, remaining )
        remaining = remaining - value
        applied[i] = value
    end

    plyTbl.GlideArc9Twisted = true

    local aimPitch = SetClampedPose( ply, "aim_pitch", Clamp( pitch, minPitch, maxPitch ) )

    -- The head rides on the spine like the arms do, so look the same way
    SetClampedPose( ply, "head_yaw", applied[1] )
    SetClampedPose( ply, "head_pitch", aimPitch )

    if CLIENT then
        ply:InvalidateBoneCache()
    end

    if cvarDebug and cvarDebug:GetBool() and CLIENT and ply == LocalPlayer() and RealTime() > nextDebugPrint then
        nextDebugPrint = RealTime() + DEBUG_INTERVAL

        local parts = {}

        for i, name in ipairs( YAW_POSE_PARAMS ) do
            local range = GetPoseRange( ply, name )

            parts[i] = range and string.format( "%s %.1f [%.0f..%.0f]", name, applied[i], range[1], range[2] )
                or ( name .. " missing" )
        end

        print( string.format( "[GlideArc9 CL v" .. GlideArc9.VERSION .. "] pose | seat yaw %.1f pitch %.1f | %s | spine bones %d | gun off by %.1f deg",
            yaw, pitch, table.concat( parts, " | " ), #GetCorrectionBones( ply ), plyTbl.GlideArc9AimError or -1 ) )
    end
end

----- Wrapping Glide's animation hooks

GlideArc9.WrappedHooks = GlideArc9.WrappedHooks or {}

local function WrapGlideHook( event, id, makeWrapper )
    local hooks = hook.GetTable()[event]
    local original = hooks and hooks[id]
    local key = event .. "/" .. id

    if not isfunction( original ) then
        -- Glide is loaded but this hook isn't there: probably renamed in a newer Glide
        if Glide and not GlideArc9.WrappedHooks[key] then
            print( "[Glide x ARC9] Could not find Glide's " .. key .. " hook; weapon poses in vehicles may not work." )
        end

        return
    end

    -- Already wrapped
    if original == GlideArc9.WrappedHooks[key] then return end

    local wrapper = makeWrapper( original )

    GlideArc9.WrappedHooks[key] = wrapper
    hook.Add( event, id, wrapper )
end

local function WrapGlideHooks()
    WrapGlideHook( "CalcMainActivity", "Glide.OverridePlayerActivity", function( original )
        return function( ply, velocity )
            local ideal, seq = original( ply, velocity )
            local weaponIdeal, weaponSeq = CalcWeaponModeActivity( ply )

            if weaponIdeal then
                return weaponIdeal, weaponSeq
            end

            return ideal, seq
        end
    end )

    WrapGlideHook( "UpdateAnimation", "Glide.OverridePlayerAnim", function( original )
        return function( ply, velocity, maxSeqGroundSpeed )
            local result = original( ply, velocity, maxSeqGroundSpeed )
            UpdateWeaponModeAim( ply )

            return result
        end
    end )

    if not CLIENT then return end

    WrapGlideHook( "PrePlayerDraw", "Glide.ManipulatePlayerBones", function( original )
        return function( ply, flags )
            if GetWeaponModeWeapon( ply ) then
                if Glide and Glide.ResetBoneManipulations then
                    Glide.ResetBoneManipulations( ply )
                end

                ApplyAimCorrection( ply, GetWeaponModeWeapon( ply ) )

                return
            end

            return original( ply, flags )
        end
    end )
end

-- Glide adds its hooks when it loads, which may be after this file.
hook.Add( "InitPostEntity", "GlideArc9.WrapAnimHooks", WrapGlideHooks )
WrapGlideHooks()
