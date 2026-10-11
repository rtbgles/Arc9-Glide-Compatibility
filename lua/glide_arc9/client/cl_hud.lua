local cvarHud = CreateClientConVar( "cl_glide_arc9_hud", "1", true, false,
    "Show a small indicator while in weapon mode.", 0, 1 )

language.Add( "glide_arc9.hud.weapon_mode", "WEAPON MODE" )
language.Add( "glide_arc9.hud.holster_hint", "Double-tap %s to holster" )

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

local HINT_DURATION = 5

local titleText, hintText = "", ""
local hintUntil = 0

local function GetDuckKeyName()
    local key = input.LookupBinding( "+duck" )

    return key and string.upper( key ) or "+duck"
end

local function DrawIndicator()
    if not cvarHud:GetBool() then return end
    if hook.Run( "GlideArc9_CanDrawHUD" ) == false then return end

    local x, y = ScrW() * 0.5, ScrH() * 0.82
    local _, h = draw.SimpleTextOutlined( titleText, "GlideArc9.Indicator", x, y, COLOR_TEXT,
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
    hintText = string.format( language.GetPhrase( "glide_arc9.hud.holster_hint" ), GetDuckKeyName() )
    hintUntil = RealTime() + HINT_DURATION

    hook.Add( "HUDPaint", "GlideArc9.Indicator", DrawIndicator )
end )
