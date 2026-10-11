local cvarDoubleTap = CreateClientConVar( "cl_glide_arc9_doubletap", "1", true, false,
    "Double-tap the toggle key (C by default) while in a Glide vehicle to toggle weapon mode.", 0, 1 )

local cvarDoubleTapWindow = CreateClientConVar( "cl_glide_arc9_doubletap_window", "0.3", true, false,
    "Maximum time (in seconds) between both taps of a double-tap.", 0.1, 1 )

local cvarToggleKey = CreateClientConVar( "cl_glide_arc9_toggle_key", "c", true, false,
    "Key to double-tap while in a Glide vehicle to toggle weapon mode (a key name, like c or g)." )

language.Add( "glide_arc9.notify.no_weapon", "You have no weapon that can be used inside vehicles." )
language.Add( "glide_arc9.notify.seat_denied", "Weapons are not allowed on this seat." )

local IsValid = IsValid
local RealTime = RealTime
local LocalPlayer = LocalPlayer

function GlideArc9.RequestToggle()
    local ply = LocalPlayer()
    if not IsValid( ply ) then return end
    if not isfunction( ply.GlideGetVehicle ) or not IsValid( ply:GlideGetVehicle() ) then return end

    net.Start( GlideArc9.NET_TOGGLE )
    net.SendToServer()
end

concommand.Add( "glide_arc9_toggle", function()
    GlideArc9.RequestToggle()
end, nil, "Toggle weapon mode while seated in a Glide vehicle." )

----- Double-tap detection & state tracking (only while inside a Glide vehicle)

--[[
    The toggle key (C) normally does something already: the context menu, or
    ARC9's customize menu / peeking while an ARC9 weapon is out. To keep a
    double-tap from flashing those open, a press is held back for the
    double-tap window while seated:
    - a second press in time toggles weapon mode, and the first is dropped
    - otherwise the held-back press is given to the game as normal, a little
      late (as a tap if the key was already released, or as a hold)
    ARC9 peeking polls the key directly, so it keeps working while aiming.
]]

local HELD_TAP_TIMER = "GlideArc9.HeldTap"

-- How long a replayed short tap is held down, so the game sees it
local TAP_REPLAY_DURATION = 0.1

local wasInWeaponMode = false

local heldTap -- { time, bind, passed }
local swallowNextRelease = false

-- Fallback for an unbound toggle key, which never reaches PlayerBindPress
local wasKeyDown = false
local lastPolledTap = 0

function GlideArc9.GetToggleKey()
    local code = input.GetKeyCode( cvarToggleKey:GetString() )

    if not code or code <= 0 then
        code = KEY_C
    end

    return code
end

function GlideArc9.GetToggleKeyName()
    return string.upper( language.GetPhrase( input.GetKeyName( GlideArc9.GetToggleKey() ) or "C" ) )
end

local function IsTypingOrInMenu( ply )
    return ply:IsTyping() or gui.IsGameUIVisible() or IsValid( vgui.GetKeyboardFocus() )
end

--- Should a press of this button be handled by the double-tap logic?
function GlideArc9.ShouldInterceptToggleKey( code )
    if not cvarDoubleTap:GetBool() or code ~= GlideArc9.GetToggleKey() then return false end

    local ply = LocalPlayer()
    if not IsValid( ply ) or IsTypingOrInMenu( ply ) then return false end

    return isfunction( ply.GlideGetVehicle ) and IsValid( ply:GlideGetVehicle() )
end

local function HasARC9Weapon( ply )
    local weapon = ply:GetActiveWeapon()

    return IsValid( weapon ) and weapon.ARC9 == true
end

--- Give a held-back bind to the game. ARC9 handles its own binds in a
--- PlayerBindPress hook, which is called directly; anything else runs as
--- a console command, like the engine would.
local function RunBind( bind, pressed )
    local ply = LocalPlayer()
    if not IsValid( ply ) then return end

    local arc9Binds = GlideArc9.ARC9BindsOriginal

    if arc9Binds and HasARC9Weapon( ply ) and arc9Binds( ply, bind, pressed, GlideArc9.GetToggleKey() ) then
        return
    end

    if pressed then
        ply:ConCommand( bind )

    elseif string.sub( bind, 1, 1 ) == "+" then
        ply:ConCommand( "-" .. string.sub( bind, 2 ) )
    end
end

local function ReplayHeldTap()
    local tap = heldTap
    if not tap then return end

    RunBind( tap.bind, true )

    if input.IsKeyDown( GlideArc9.GetToggleKey() ) then
        -- Still held down, release it when the key comes up
        tap.passed = true
        return
    end

    -- Already let go: replay it as a short tap
    heldTap = nil

    timer.Simple( TAP_REPLAY_DURATION, function()
        RunBind( tap.bind, false )
    end )
end

local function DropHeldTap()
    timer.Remove( HELD_TAP_TIMER )

    if heldTap and heldTap.passed then
        RunBind( heldTap.bind, false )
    end

    heldTap = nil
    swallowNextRelease = false
end

--- PlayerBindPress handler for the toggle key. Returns true to block the bind.
local function OnToggleKeyBind( bind, pressed, code )
    if not GlideArc9.ShouldInterceptToggleKey( code ) then return end

    if pressed then
        local now = RealTime()

        if heldTap and not heldTap.passed and now - heldTap.time <= cvarDoubleTapWindow:GetFloat() then
            -- Second tap: toggle, and the first tap never happened
            timer.Remove( HELD_TAP_TIMER )
            heldTap = nil
            swallowNextRelease = true

            GlideArc9.RequestToggle()

            return true
        end

        DropHeldTap()

        heldTap = { time = now, bind = bind, passed = false }
        timer.Create( HELD_TAP_TIMER, cvarDoubleTapWindow:GetFloat(), 1, ReplayHeldTap )

        return true
    end

    if swallowNextRelease then
        swallowNextRelease = false
        return true
    end

    if not heldTap then return end

    -- Not replayed yet: the timer will replay it as a tap
    if heldTap.passed then
        RunBind( heldTap.bind, false )
        heldTap = nil
    end

    return true
end

--- Unbound toggle key: nothing to hold back, just watch the key.
local function PollUnboundToggleKey( ply )
    local code = GlideArc9.GetToggleKey()
    local binding = input.LookupKeyBinding( code )

    if binding and binding ~= "" then
        wasKeyDown = false
        return
    end

    local isDown = input.IsKeyDown( code ) and not IsTypingOrInMenu( ply )
    if isDown == wasKeyDown then return end

    wasKeyDown = isDown
    if not isDown then return end

    local now = RealTime()

    if now - lastPolledTap <= cvarDoubleTapWindow:GetFloat() then
        lastPolledTap = 0
        GlideArc9.RequestToggle()
    else
        lastPolledTap = now
    end
end

local function ResetState()
    DropHeldTap()
    wasKeyDown = false
    lastPolledTap = 0

    if wasInWeaponMode then
        wasInWeaponMode = false
        hook.Run( "GlideArc9_OnLocalWeaponModeChanged", false )
    end
end

local function OnThink()
    local ply = LocalPlayer()
    if not IsValid( ply ) then return end

    local inWeaponMode = GlideArc9.IsInWeaponMode( ply )

    if inWeaponMode ~= wasInWeaponMode then
        wasInWeaponMode = inWeaponMode
        hook.Run( "GlideArc9_OnLocalWeaponModeChanged", inWeaponMode )
    end

    -- Release a replayed hold if the key came up without us seeing it
    -- (for example, a menu took keyboard focus in the meantime)
    if heldTap and heldTap.passed and not input.IsKeyDown( GlideArc9.GetToggleKey() ) then
        RunBind( heldTap.bind, false )
        heldTap = nil
    end

    if cvarDoubleTap:GetBool() then
        PollUnboundToggleKey( ply )
    end
end

----- Let the toggle key reach us before ARC9's bind hook

-- ARC9 blocks the context menu key while one of its weapons is out. Wrap
-- its hook (same identifier) so it skips the toggle key while seated; held
-- back presses are handed to the original when they are replayed.
local ARC9_BINDS_HOOK = "ARC9_Binds"

local function WrapARC9Binds()
    local hooks = hook.GetTable()["PlayerBindPress"]
    local original = hooks and hooks[ARC9_BINDS_HOOK]

    if not isfunction( original ) then
        if ARC9 and not GlideArc9.ARC9BindsOriginal then
            print( "[Glide x ARC9] Could not find ARC9's PlayerBindPress/" .. ARC9_BINDS_HOOK
                .. " hook; double-tapping the toggle key may open ARC9's menu." )
        end

        return
    end

    if original == GlideArc9.ARC9BindsWrapper then return end

    local function wrapper( ply, bind, pressed, code )
        if GlideArc9.ShouldInterceptToggleKey( code ) then return end

        return original( ply, bind, pressed, code )
    end

    GlideArc9.ARC9BindsOriginal = original
    GlideArc9.ARC9BindsWrapper = wrapper
    hook.Add( "PlayerBindPress", ARC9_BINDS_HOOK, wrapper )
end

hook.Add( "InitPostEntity", "GlideArc9.WrapARC9Binds", WrapARC9Binds )
WrapARC9Binds()

----- Weapon selection while in weapon mode

-- The default weapon selection is unreliable for players that entered a
-- vehicle without weapons, so handle slot/scroll binds ourselves while in
-- weapon mode. This also keeps the selection limited to allowed weapons.

local function GetSelectableWeapons( ply )
    local list = {}

    for _, weapon in ipairs( ply:GetWeapons() ) do
        if GlideArc9.IsWeaponAllowed( weapon ) then
            list[#list + 1] = weapon
        end
    end

    table.sort( list, function( a, b )
        local slotA, slotB = a:GetSlot(), b:GetSlot()
        if slotA ~= slotB then return slotA < slotB end

        return a:GetSlotPos() < b:GetSlotPos()
    end )

    return list
end

local function FindIndex( list, value )
    for i, v in ipairs( list ) do
        if v == value then return i end
    end

    return 0
end

local function CycleWeapon( ply, direction )
    local list = GetSelectableWeapons( ply )
    local count = #list
    if count == 0 then return end

    local index = FindIndex( list, ply:GetActiveWeapon() )
    local nextIndex = ( ( index - 1 + direction ) % count ) + 1

    input.SelectWeapon( list[nextIndex] )
end

local function SelectSlot( ply, slot )
    local inSlot = {}

    for _, weapon in ipairs( GetSelectableWeapons( ply ) ) do
        if weapon:GetSlot() == slot then
            inSlot[#inSlot + 1] = weapon
        end
    end

    local count = #inSlot
    if count == 0 then return end

    -- Pressing the same slot again cycles through the weapons in it
    local index = FindIndex( inSlot, ply:GetActiveWeapon() )

    input.SelectWeapon( inSlot[( index % count ) + 1] )
end

local function OnBindPress( ply, bind, pressed, code )
    local blocked = OnToggleKeyBind( bind, pressed, code )
    if blocked ~= nil then return blocked end

    if not pressed or not GlideArc9.IsInWeaponMode( ply ) then return end

    if bind == "invnext" then
        CycleWeapon( ply, 1 )
        return true
    end

    if bind == "invprev" then
        CycleWeapon( ply, -1 )
        return true
    end

    local slot = string.match( bind, "^slot(%d)$" )

    if slot then
        SelectSlot( ply, tonumber( slot ) - 1 )
        return true
    end
end

----- Glide hooks

hook.Add( "Glide_OnLocalEnterVehicle", "GlideArc9.StartTracking", function()
    ResetState()
    hook.Add( "Think", "GlideArc9.WeaponMode", OnThink )
    hook.Add( "PlayerBindPress", "GlideArc9.WeaponSelection", OnBindPress )
end )

hook.Add( "Glide_OnLocalExitVehicle", "GlideArc9.StopTracking", function()
    hook.Remove( "Think", "GlideArc9.WeaponMode" )
    hook.Remove( "PlayerBindPress", "GlideArc9.WeaponSelection" )
    ResetState()
end )
