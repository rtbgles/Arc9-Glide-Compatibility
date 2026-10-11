--[[
    Glide drives the camera while the player is in a vehicle. These tweaks
    make it play nicely with ARC9 while in weapon mode:

    - Switch to first person when weapon mode starts (so sights work),
      then restore the previous view when it ends.
    - Let the weapon adjust the first person view (ADS zoom, recoil kick).
    - Apply the weapon's mouse sensitivity multiplier (slower aim in sights).
]]

local cvarFirstPerson = CreateClientConVar( "cl_glide_arc9_firstperson", "1", true, false,
    "Switch to first person while in weapon mode.", 0, 1 )

local cvarWeaponView = CreateClientConVar( "cl_glide_arc9_weapon_view", "1", true, false,
    "Let the held weapon adjust the camera (ADS zoom, recoil) while in weapon mode.", 0, 1 )

local IsValid = IsValid
local LocalPlayer = LocalPlayer

local function GetCamera()
    return Glide and Glide.Camera
end

--- Returns the held weapon when the view should be handed over to it.
local function GetViewWeapon( camera )
    if not camera.isInFirstPerson then return end
    if not cvarWeaponView:GetBool() then return end

    local ply = LocalPlayer()
    if not GlideArc9.IsInWeaponMode( ply ) then return end

    local weapon = ply:GetActiveWeapon()
    if not IsValid( weapon ) then return end

    return weapon, ply
end

function GlideArc9.CameraCalcView( camera, view )
    if not view then return view end

    local weapon, ply = GetViewWeapon( camera )
    if not weapon or not isfunction( weapon.CalcView ) then return view end

    local ok, origin, angles, fov = pcall( weapon.CalcView, weapon, ply, view.origin, view.angles, view.fov )
    if not ok then return view end

    view.origin = origin or view.origin
    view.angles = angles or view.angles
    view.fov = fov or view.fov

    return view
end

function GlideArc9.CameraMouseSensitivity( camera )
    local weapon = GetViewWeapon( camera )
    if not weapon or not isfunction( weapon.AdjustMouseSensitivity ) then return 1 end

    local ok, mult = pcall( weapon.AdjustMouseSensitivity, weapon )
    if not ok or not isnumber( mult ) or mult <= 0 then return 1 end

    return mult
end

--- Wrap a few of Glide's camera functions. Glide's hooks look these up on
--- the Camera table every call, so wrapping them is enough. The wrappers call
--- through GlideArc9 so a Lua refresh picks up new logic without re-wrapping.
local function WrapCamera()
    local camera = GetCamera()
    if not camera or camera.GlideArc9Wrapped then return end
    if not isfunction( camera.CalcView ) or not isfunction( camera.InputMouseApply ) then return end

    camera.GlideArc9Wrapped = true

    local originalCalcView = camera.CalcView
    local originalInputMouseApply = camera.InputMouseApply

    function camera:CalcView( ... )
        return GlideArc9.CameraCalcView( self, originalCalcView( self, ... ) )
    end

    function camera:InputMouseApply( cmd, x, y, ... )
        local mult = GlideArc9.CameraMouseSensitivity( self )

        return originalInputMouseApply( self, cmd, x * mult, y * mult, ... )
    end
end

----- First person while in weapon mode

local savedFirstPerson

local function SetFirstPerson( camera, enable )
    if not isfunction( camera.SetFirstPerson ) then return end

    if IsValid( camera.vehicle ) then
        camera:SetFirstPerson( enable )
    else
        camera.isInFirstPerson = enable
    end
end

hook.Add( "GlideArc9_OnLocalWeaponModeChanged", "GlideArc9.Camera", function( inWeaponMode )
    local camera = GetCamera()
    if not camera then return end

    if inWeaponMode then
        if not cvarFirstPerson:GetBool() then return end

        savedFirstPerson = camera.isInFirstPerson == true
        SetFirstPerson( camera, true )

        return
    end

    if savedFirstPerson == nil then return end

    SetFirstPerson( camera, savedFirstPerson )
    savedFirstPerson = nil
end )

hook.Add( "Glide_OnLocalEnterVehicle", "GlideArc9.WrapCamera", function()
    savedFirstPerson = nil
    WrapCamera()
end )

-- Glide remembers the last camera view between vehicles,
-- so put back the one the player had before weapon mode.
hook.Add( "Glide_OnLocalExitVehicle", "GlideArc9.RestoreCamera", function()
    local camera = GetCamera()

    if camera and savedFirstPerson ~= nil then
        camera.isInFirstPerson = savedFirstPerson
    end

    savedFirstPerson = nil
end )
