--[[
    While in weapon mode the client sends seat-local aim angles (see
    cl_camera.lua), so the player's eye angles follow Glide's camera and
    ARC9 can aim. Glide's own SetupMove hook still reads those angles as
    world angles, which would break mouse steering, turrets and tank cannons.

    We cache the correct world aim here and make Glide's aim getters return
    it while the player is in weapon mode. Using our own fields means it does
    not matter whether this hook runs before or after Glide's.
]]

local IsValid = IsValid

hook.Add( "SetupMove", "GlideArc9.CacheAim", function( ply, _, cmd )
    if not GlideArc9.IsInWeaponMode( ply ) then return end

    local seat = ply:GetVehicle()
    if not IsValid( seat ) then return end

    local angles = seat:LocalToWorldAngles( cmd:GetViewAngles() )

    ply.GlideArc9AimAngles = angles
    ply.GlideArc9AimPos = ply:EyePos() + angles:Forward() * cmd:GetUpMove()
end )

local function WrapAimGetter( PlayerMeta, name, field )
    local marker = "GlideArc9Wrapped_" .. name
    local original = PlayerMeta[name]

    -- Skip if missing, or already wrapped (Glide refreshing replaces it)
    if not isfunction( original ) or original == PlayerMeta[marker] then return end

    local function wrapper( self, ... )
        local value = self[field]

        if value and GlideArc9.IsInWeaponMode( self ) then
            return value
        end

        return original( self, ... )
    end

    PlayerMeta[marker] = wrapper
    PlayerMeta[name] = wrapper
end

local function WrapAimGetters()
    local PlayerMeta = FindMetaTable( "Player" )

    WrapAimGetter( PlayerMeta, "GlideGetAimAngles", "GlideArc9AimAngles" )
    WrapAimGetter( PlayerMeta, "GlideGetCameraAngles", "GlideArc9AimAngles" )
    WrapAimGetter( PlayerMeta, "GlideGetAimPos", "GlideArc9AimPos" )
end

-- Glide defines these when it loads, which may be after this file.
hook.Add( "InitPostEntity", "GlideArc9.WrapAimGetters", WrapAimGetters )
WrapAimGetters()

hook.Add( "GlideArc9_OnWeaponModeChanged", "GlideArc9.ClearAim", function( ply, isEnabled )
    if isEnabled then return end

    ply.GlideArc9AimAngles = nil
    ply.GlideArc9AimPos = nil
end )
