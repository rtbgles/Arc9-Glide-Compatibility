--[[
    Third person animations while in weapon mode.

    Glide picks a seated animation per seat (steering wheel for car
    drivers, handlebars for bikes) and only switches to a "holding a gun"
    pose for passengers on plain seats. Its hooks also skip the engine's
    aim pose, so the gun never pointed where the player was aiming.

    While in weapon mode, for every seat:
    - use the seated pose that matches the weapon's hold type
    - point the arms and head at the player's aim
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

local function UpdateWeaponModeAim( ply )
    if not GetWeaponModeWeapon( ply ) then return end

    local aim = GlideArc9.GetAimAngles( ply )
    if not aim then return end

    local seat = ply:GetVehicle()
    if not IsValid( seat ) then return end

    local localAim = seat:WorldToLocalAngles( aim )
    local yaw = NormalizeAngle( localAim[2] - SEAT_FORWARD_YAW )
    local pitch = NormalizeAngle( localAim[1] )

    ply:SetPoseParameter( "aim_yaw", yaw )
    ply:SetPoseParameter( "aim_pitch", pitch )
    ply:SetPoseParameter( "head_yaw", yaw )
    ply:SetPoseParameter( "head_pitch", pitch )

    if CLIENT then
        ply:InvalidateBoneCache()
    end
end

----- Wrapping Glide's animation hooks

GlideArc9.WrappedHooks = GlideArc9.WrappedHooks or {}

local function WrapGlideHook( event, id, makeWrapper )
    local hooks = hook.GetTable()[event]
    local original = hooks and hooks[id]
    local key = event .. "/" .. id

    -- Missing (Glide not installed / renamed), or already wrapped
    if not isfunction( original ) or original == GlideArc9.WrappedHooks[key] then return end

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
