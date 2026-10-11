--[[
    Glide x ARC9 Compatibility

    Lets players draw and fire their ARC9 weapons while seated in a Glide
    vehicle. Double-tap the duck key (CTRL by default) to toggle weapon mode.

    Glide and ARC9 are only referenced lazily (inside hooks and functions),
    so the order in which addons are loaded does not matter.
]]

GlideArc9 = GlideArc9 or {}

AddCSLuaFile( "glide_arc9/sh_config.lua" )
AddCSLuaFile( "glide_arc9/sh_aim.lua" )
AddCSLuaFile( "glide_arc9/sh_anims.lua" )
AddCSLuaFile( "glide_arc9/client/cl_weapon_mode.lua" )
AddCSLuaFile( "glide_arc9/client/cl_camera.lua" )
AddCSLuaFile( "glide_arc9/client/cl_hud.lua" )

include( "glide_arc9/sh_config.lua" )
include( "glide_arc9/sh_aim.lua" )
include( "glide_arc9/sh_anims.lua" )

if SERVER then
    include( "glide_arc9/server/sv_weapon_mode.lua" )
    include( "glide_arc9/server/sv_damage.lua" )
end

if CLIENT then
    include( "glide_arc9/client/cl_weapon_mode.lua" )
    include( "glide_arc9/client/cl_camera.lua" )
    include( "glide_arc9/client/cl_hud.lua" )
end
