--[[
    Third person animations while in weapon mode.

    Glide picks a seated animation per seat (steering wheel for car
    drivers, handlebars for bikes) and only switches to a "holding a gun"
    pose for passengers on plain seats. Its hooks also skip the engine's
    aim pose, so the gun never pointed where the player was aiming.

    While in weapon mode, for every seat:
    - use the seated pose that matches the weapon's hold type
    - point the arms and head at the player's aim, twisting the torso
      (pose parameters, or spine bones on models without them) when the
      arms alone can't turn far enough
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

----- Spine bone twist (for player models without spine_yaw/body_yaw)

-- Whatever the pose parameters can't cover is spread over these bones.
-- The arms and head hang off them, so twisting them turns the gun.
local TWIST_BONES = {
    "ValveBiped.Bip01_Spine",
    "ValveBiped.Bip01_Spine1",
    "ValveBiped.Bip01_Spine2",
    "ValveBiped.Bip01_Spine4"
}

-- Most the spine bones may twist in total, either way. Leaning out of a
-- window the hips stay put, so the upper body has to turn further.
local MAX_BONE_TWIST = 75
local MAX_BONE_TWIST_LEANING = 110

-- [model] = { boneId, ... }
local twistBoneIds = {}

local function GetTwistBones( ply )
    local model = ply:GetModel()
    local ids = twistBoneIds[model]
    if ids then return ids end

    ids = {}

    for _, name in ipairs( TWIST_BONES ) do
        local id = ply:LookupBone( name )

        if id then
            ids[#ids + 1] = id
        end
    end

    twistBoneIds[model] = ids

    return ids
end

local function ResetBoneTwist( ply )
    for _, id in ipairs( GetTwistBones( ply ) ) do
        ply:ManipulateBoneAngles( id, angle_zero, false )
    end
end

--- Twist the spine around the seat's up axis: the way the body leans (the
--- seat tilts toward the window while leaning out), and the frame the aim
--- is measured in. Twisting a tilted body around the vehicle's up axis
--- would tip it forward/back instead. Bone axes differ between models, so
--- the axis is worked out from each bone's current orientation.
--- Rotating about that axis leaves it unchanged, so reading the already
--- twisted bones every frame does not feed back into the result.
local function ApplyBoneTwist( ply, amount )
    local ids = GetTwistBones( ply )
    local count = #ids
    if count == 0 then return end

    local seat = ply:GetVehicle()
    if not IsValid( seat ) then return end

    local up = seat:GetUp()
    local perBone = amount / count

    for _, id in ipairs( ids ) do
        local matrix = ply:GetBoneMatrix( id )

        if matrix then
            local localAxis = WorldToLocal( up, angle_zero, vector_origin, matrix:GetAngles() )
            localAxis:Normalize()

            local ang = Angle()

            ang:RotateAroundAxis( localAxis, perBone )
            ply:ManipulateBoneAngles( id, ang, false )
        end
    end
end

local function UpdateWeaponModeAim( ply )
    local plyTbl = ply:GetTable()

    if not GetWeaponModeWeapon( ply ) then
        -- Put the torso back once after leaving weapon mode
        if plyTbl.GlideArc9Twisted then
            plyTbl.GlideArc9Twisted = nil
            plyTbl.GlideArc9BoneTwist = nil
            ResetTwist( ply )

            if CLIENT then
                ResetBoneTwist( ply )
            end
        end

        return
    end

    local yaw, pitch = GlideArc9.GetSeatAimAngles( ply )
    if not yaw then return end

    -- Nobody can aim straight behind them from a car seat. Past the aim
    -- range the gun stays at the limit (and firing is blocked, sh_aim.lua).
    local isLeaning = GlideArc9.GetLeanSide( ply ) ~= 0
    local minYaw, maxYaw = GlideArc9.GetAimYawRange( ply )
    local remaining = Clamp( yaw, minYaw, maxYaw )
    local twist = 0
    local applied = {}

    for i, name in ipairs( YAW_POSE_PARAMS ) do
        local value = SetClampedPose( ply, name, remaining )
        remaining = remaining - value
        applied[i] = value

        if i > 1 then
            twist = twist + value
        end
    end

    -- Whatever is still left goes to the spine bones (drawn clientside)
    local boneTwist = 0

    if CLIENT and #GetTwistBones( ply ) > 0 then
        local maxTwist = isLeaning and MAX_BONE_TWIST_LEANING or MAX_BONE_TWIST
        boneTwist = Clamp( remaining, -maxTwist, maxTwist )
        twist = twist + boneTwist
    end

    plyTbl.GlideArc9BoneTwist = boneTwist
    plyTbl.GlideArc9Twisted = true

    -- The head turns with the torso, so it only needs what the twist didn't cover
    SetClampedPose( ply, "head_yaw", yaw - twist )
    SetClampedPose( ply, "aim_pitch", pitch )
    SetClampedPose( ply, "head_pitch", pitch )

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

        print( string.format( "[GlideArc9 CL v" .. GlideArc9.VERSION .. "] pose | target yaw %.1f pitch %.1f | %s | spine bones %.1f (%d) | head %.1f",
            yaw, pitch, table.concat( parts, " | " ), boneTwist, #GetTwistBones( ply ), yaw - twist ) )
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

                ApplyBoneTwist( ply, ply:GetTable().GlideArc9BoneTwist or 0 )

                return
            end

            return original( ply, flags )
        end
    end )
end

-- Glide adds its hooks when it loads, which may be after this file.
hook.Add( "InitPostEntity", "GlideArc9.WrapAnimHooks", WrapGlideHooks )
WrapGlideHooks()
