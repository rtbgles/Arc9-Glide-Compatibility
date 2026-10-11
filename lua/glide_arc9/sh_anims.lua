--[[
    Third person animations while in weapon mode.

    Glide picks a seated animation per seat (steering wheel for car
    drivers, handlebars for bikes) and only switches to a "holding a gun"
    pose for passengers on plain seats. Its hooks also skip the engine's
    aim pose, so the gun never pointed where the player was aiming.

    While in weapon mode, for every seat:
    - use the seated pose that matches the weapon's hold type
    - point the arms and head at the player's aim, twisting the torso
      when the arms alone can't turn far enough
    - skip Glide's hand/arm bone poses

    Glide's hooks are wrapped in place (same hook identifiers), so it does
    not matter which addon's hook would have run first.
]]

local IsValid = IsValid
local NormalizeAngle = math.NormalizeAngle

local ACT_HL2MP_SIT = 1970

-- Seat-local yaw that faces forward on Glide seats
local SEAT_FORWARD_YAW = 90

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

-- Nobody can aim straight behind them from a car seat. Past this the gun
-- stays at the limit on that side instead of twisting the torso further.
local MAX_TOTAL_YAW = 110

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

local function UpdateWeaponModeAim( ply )
    local plyTbl = ply:GetTable()

    if not GetWeaponModeWeapon( ply ) then
        -- Put the torso back once after leaving weapon mode
        if plyTbl.GlideArc9Twisted then
            plyTbl.GlideArc9Twisted = nil
            ResetTwist( ply )
        end

        return
    end

    local aim = GlideArc9.GetAimAngles( ply )
    if not aim then return end

    local seat = ply:GetVehicle()
    if not IsValid( seat ) then return end

    local localAim = seat:WorldToLocalAngles( aim )
    local yaw = NormalizeAngle( localAim[2] - SEAT_FORWARD_YAW )
    local pitch = NormalizeAngle( localAim[1] )

    local remaining = Clamp( yaw, -MAX_TOTAL_YAW, MAX_TOTAL_YAW )
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

        print( string.format( "[GlideArc9 CL v" .. GlideArc9.VERSION .. "] pose | target yaw %.1f pitch %.1f | %s | head %.1f",
            yaw, pitch, table.concat( parts, " | " ), yaw - twist ) )
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

                return
            end

            return original( ply, flags )
        end
    end )
end

-- Glide adds its hooks when it loads, which may be after this file.
hook.Add( "InitPostEntity", "GlideArc9.WrapAnimHooks", WrapGlideHooks )
WrapGlideHooks()
