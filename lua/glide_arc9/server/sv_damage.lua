--[[
    Weapons fired from inside a Glide vehicle should never damage that
    vehicle (body, wheels or any other part parented to it). Shots from
    anyone outside the vehicle still damage it as usual.

    Glide's own damage is left alone: crashes use DMG_CRUSH with the vehicle
    as the inflictor, and burning uses DMG_GENERIC (it can carry the last
    attacker's weapon as inflictor, so it must not be confused with a shot).
]]

local cvarProtect = CreateConVar( "glide_arc9_protect_own_vehicle", "1", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
    "Weapons fired from inside a Glide vehicle do not damage that vehicle.", 0, 1 )

local IsValid = IsValid

local DMG_GENERIC = 0
local DMG_CRUSH = 1

-- Wheels, turrets and rotors are parented to the vehicle,
-- sometimes through another part.
local MAX_PARENT_DEPTH = 3

local function GetGlideVehicle( ent )
    for _ = 1, MAX_PARENT_DEPTH do
        if not IsValid( ent ) then return end
        if ent.IsGlideVehicle then return ent end

        ent = ent:GetParent()
    end
end

--- Did this damage come from the attacker's own weapon (hitscan, melee or
--- a projectile it fired), as opposed to one of Glide's vehicle weapons?
local function IsFromPlayerWeapon( attacker, inflictor )
    if not IsValid( inflictor ) or inflictor == attacker then return true end

    if inflictor:IsWeapon() then
        return inflictor:GetOwner() == attacker
    end

    if inflictor.IsGlideVehicle or string.StartsWith( inflictor:GetClass(), "glide_" ) then
        return false
    end

    return inflictor:GetOwner() == attacker
end

hook.Add( "EntityTakeDamage", "GlideArc9.ProtectOwnVehicle", function( target, dmginfo )
    if not cvarProtect:GetBool() then return end

    local attacker = dmginfo:GetAttacker()
    if not IsValid( attacker ) or not attacker:IsPlayer() then return end

    local vehicle = GetGlideVehicle( target )
    if not vehicle then return end

    -- Only players sitting in this same vehicle
    if not isfunction( attacker.GlideGetVehicle ) or attacker:GlideGetVehicle() ~= vehicle then return end

    local damageType = dmginfo:GetDamageType()
    if damageType == DMG_GENERIC or dmginfo:IsDamageType( DMG_CRUSH ) then return end

    if IsFromPlayerWeapon( attacker, dmginfo:GetInflictor() ) then
        return true
    end
end )
