local cvarHud = CreateClientConVar( "cl_glide_arc9_hud", "1", true, false,
    "Show a small indicator while in weapon mode.", 0, 1 )

language.Add( "glide_arc9.hud.weapon_mode", "WEAPON MODE" )
language.Add( "glide_arc9.hud.leaning_out", "WEAPON MODE - LEANING OUT" )
language.Add( "glide_arc9.hud.holster_hint", "Double-tap %s to holster" )
language.Add( "glide_arc9.hud.lean_hint", "Double-tap %s to holster, double-tap %s to lean out" )
language.Add( "glide_arc9.hud.out_of_arc", "CAN'T AIM THAT FAR" )

surface.CreateFont( "GlideArc9.Indicator", {
    font = "Roboto",
    size = ScreenScale( 7 ),
    weight = 600
} )

surface.CreateFont( "GlideArc9.Hint", {
    font = "Roboto",
    size = ScreenScale( 5 ),
    weight = 500
} )

local COLOR_TEXT = Color( 255, 255, 255, 230 )
local COLOR_HINT = Color( 200, 200, 200, 200 )
local COLOR_OUTLINE = Color( 0, 0, 0, 180 )
local COLOR_WARNING = Color( 255, 90, 70, 230 )

-- Below the crosshair, as a fraction of the screen height
local WARNING_OFFSET_Y = 0.04

local HINT_DURATION = 5

local titleText, leaningText, hintText, outOfArcText = "", "", "", ""
local hintUntil = 0

local function DrawIndicator()
    if not cvarHud:GetBool() then return end
    if hook.Run( "GlideArc9_CanDrawHUD" ) == false then return end

    local x, y = ScrW() * 0.5, ScrH() * 0.82

    -- Firing is blocked past the aim arc, say so next to the crosshair
    if not GlideArc9.IsAimInArc( LocalPlayer() ) then
        draw.SimpleTextOutlined( outOfArcText, "GlideArc9.Hint", x, ScrH() * ( 0.5 + WARNING_OFFSET_Y ), COLOR_WARNING,
            TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, COLOR_OUTLINE )
    end

    local title = GlideArc9.GetLeanSide( LocalPlayer() ) ~= 0 and leaningText or titleText
    local _, h = draw.SimpleTextOutlined( title, "GlideArc9.Indicator", x, y, COLOR_TEXT,
        TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, COLOR_OUTLINE )

    if RealTime() > hintUntil then return end

    draw.SimpleTextOutlined( hintText, "GlideArc9.Hint", x, y + h, COLOR_HINT,
        TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, COLOR_OUTLINE )
end

hook.Add( "GlideArc9_OnLocalWeaponModeChanged", "GlideArc9.HUD", function( inWeaponMode )
    if not inWeaponMode then
        hook.Remove( "HUDPaint", "GlideArc9.Indicator" )
        return
    end

    -- Build the strings once here, not every frame
    titleText = language.GetPhrase( "glide_arc9.hud.weapon_mode" )
    leaningText = language.GetPhrase( "glide_arc9.hud.leaning_out" )
    outOfArcText = language.GetPhrase( "glide_arc9.hud.out_of_arc" )
    local ply = LocalPlayer()
    local canLean = GlideArc9.IsLeanEnabled() and ply:GlideGetSeatIndex() > 1

    if canLean then
        local rightKey = string.upper( input.LookupBinding( "+moveright" ) or "D" )
        hintText = string.format( language.GetPhrase( "glide_arc9.hud.lean_hint" ), GlideArc9.GetToggleKeyName(), rightKey )
    else
        hintText = string.format( language.GetPhrase( "glide_arc9.hud.holster_hint" ), GlideArc9.GetToggleKeyName() )
    end
    hintUntil = RealTime() + HINT_DURATION

    hook.Add( "HUDPaint", "GlideArc9.Indicator", DrawIndicator )
end )
