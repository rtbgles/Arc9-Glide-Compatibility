--[[
    Leaning out of the window (passengers in weapon mode, double-tap the
    move key toward their window: A on the left, D on the right).

    The passenger's seat is moved: slid toward the door, raised a little and
    tilted toward the window. The seat keeps facing forward, so the legs
    stay in the footwell and only the upper body turns to aim (sh_anims.lua).
    The player is attached to the seat, so their eyes, the bullets' origin
    and their hit boxes really are out of the window, which is exactly what
    other players see. The seat goes back to where Glide put it when the lean
    ends, the player leaves, dies or holsters.
]]

util.AddNetworkString( GlideArc9.NET_LEAN )

local IsValid = IsValid
local Clamp = math.Clamp
local Approach = math.Approach
local NormalizeAngle = math.NormalizeAngle

local NW_LEAN = GlideArc9.NW_LEAN

-- Seconds to lean fully out, or back in
local LEAN_TIME = 0.35

-- Degrees the passenger tilts toward the window
local LEAN_TILT = 30

-- Units the seat moves up, so the shoulders clear the window sill
local LEAN_RAISE = 14

-- The seat stops this far inside the vehicle's side, so the hips stay
-- tucked in and the tilt puts the shoulders out of the window
local LEAN_INSET = 12

-- Most the seat may move sideways (wide vehicles, mirrors in the bounds)
local MAX_LEAN_SIDEWAYS = 18

-- Only seats facing within this many degrees of forward can lean
local MAX_FACING_ERROR = 30

-- Glide seats face forward with this local yaw
local SEAT_FORWARD_LOCAL_YAW = 270

-- Room check: a box from the middle of the vehicle to the leaned out head
local ROOM_CHECK_INTERVAL = 0.2
local ROOM_HULL_MAX = Vector( 6, 6, 6 )
local ROOM_HULL_MIN = -ROOM_HULL_MAX
local HEAD_HEIGHT = 30
local HEAD_OUT = 16

local TOGGLE_COOLDOWN = 0.4

local ICON_DENIED = "materials/icon16/cancel.png"
local SOUND_DENIED = "glide/ui/radar_alert.wav"

-- [ply] = state
local leans = {}

local function Notify( ply, text )
    if not Glide or not isfunction( Glide.SendNotification ) then return end

    Glide.SendNotification( ply, {
        text = text,
        icon = ICON_DENIED,
        sound = SOUND_DENIED,
        immediate = true
    } )
end

--- Can this player lean out right now? Returns { vehicle, seat, basePos,
--- baseAng, side }, or nil and a notification phrase (nil when not worth saying).
local function GetLeanSetup( ply )
    if not GlideArc9.IsLeanEnabled() then return nil, "#glide_arc9.notify.lean_disabled" end
    if not GlideArc9.IsInWeaponMode( ply ) then return nil, "#glide_arc9.notify.lean_no_weapon" end

    local vehicle = ply:GlideGetVehicle()
    if not IsValid( vehicle ) then return end

    local seat = ply:GetVehicle()
    if not IsValid( seat ) then return end

    if ply:GlideGetSeatIndex() < 2 then return nil, "#glide_arc9.notify.lean_passengers_only" end

    if vehicle.VehicleType == Glide.VEHICLE_TYPE.MOTORCYCLE then return nil, "#glide_arc9.notify.lean_seat" end

    local basePos = seat:GetLocalPos()
    local baseAng = seat:GetLocalAngles()

    local side = GlideArc9.GetSeatSide( ply )
    if side == 0 then return nil, "#glide_arc9.notify.lean_seat" end

    if math.abs( NormalizeAngle( baseAng[2] - SEAT_FORWARD_LOCAL_YAW ) ) > MAX_FACING_ERROR then
        return nil, "#glide_arc9.notify.lean_seat"
    end

    return { vehicle = vehicle, seat = seat, basePos = basePos, baseAng = baseAng, side = side }
end

local function GetLeanedPos( vehicle, basePos, side )
    local edge = side > 0 and vehicle:OBBMaxs()[2] or -vehicle:OBBMins()[2]
    local sideways = Clamp( edge - math.abs( basePos[2] ) - LEAN_INSET, 0, MAX_LEAN_SIDEWAYS )

    return basePos + Vector( 0, side * sideways, LEAN_RAISE )
end

local function RoomTraceFilter( vehicle )
    return function( ent )
        if ent == vehicle or ent:GetParent() == vehicle then return false end
        if ent:IsPlayer() and ent:GlideGetVehicle() == vehicle then return false end

        return true
    end
end

local function HasRoom( state )
    local vehicle = state.vehicle
    local basePos = state.basePos
    local side = state.side

    local tr = util.TraceHull( {
        start = vehicle:LocalToWorld( Vector( basePos[1], 0, basePos[3] + HEAD_HEIGHT ) ),
        endpos = vehicle:LocalToWorld( state.leanedPos + Vector( 0, side * HEAD_OUT, HEAD_HEIGHT ) ),
        mins = ROOM_HULL_MIN,
        maxs = ROOM_HULL_MAX,
        mask = MASK_PLAYERSOLID,
        filter = RoomTraceFilter( vehicle )
    } )

    return not tr.Hit
end

local function SetLeanSide( ply, side )
    ply:SetNW2Int( NW_LEAN, side )
end

--- Put the seat back exactly where Glide had it and forget the lean.
local function EndLean( ply )
    local state = leans[ply]
    if not state then return end

    leans[ply] = nil

    if IsValid( state.seat ) then
        state.seat:SetLocalPos( state.basePos )
        state.seat:SetLocalAngles( state.baseAng )
    end

    if IsValid( ply ) then
        SetLeanSide( ply, 0 )
    end
end

local function StartLeaningIn( ply, state )
    state.leaningOut = false
    SetLeanSide( ply, 0 )
end

local function UpdateLean( ply, state, dt )
    local target = state.leaningOut and 1 or 0
    state.fraction = Approach( state.fraction, target, dt / LEAN_TIME )

    if state.fraction <= 0 and not state.leaningOut then
        EndLean( ply )
        return
    end

    local f = state.fraction
    local eased = f * f * ( 3 - 2 * f )

    local ang = Angle( state.baseAng )
    ang:RotateAroundAxis( state.tiltAxis, LEAN_TILT * eased )

    state.seat:SetLocalPos( LerpVector( eased, state.basePos, state.leanedPos ) )
    state.seat:SetLocalAngles( ang )
end

----- Toggling

local function StartLean( ply )
    local state = leans[ply]

    -- Already leaning back in: just go back out
    if state then
        state.leaningOut = true
        SetLeanSide( ply, state.side )
        return
    end

    local setup, reason = GetLeanSetup( ply )

    if not setup then
        if reason then Notify( ply, reason ) end
        return
    end

    local side = setup.side

    state = {
        vehicle = setup.vehicle,
        seat = setup.seat,
        side = side,
        basePos = setup.basePos,
        baseAng = setup.baseAng,
        leanedPos = GetLeanedPos( setup.vehicle, setup.basePos, side ),

        -- Tilting around ( up x outward ) moves the head toward the window
        tiltAxis = Vector( -side, 0, 0 ),

        fraction = 0,
        leaningOut = true,
        nextRoomCheck = 0
    }

    if not HasRoom( state ) then
        Notify( ply, "#glide_arc9.notify.lean_blocked" )
        return
    end

    leans[ply] = state
    SetLeanSide( ply, side )
end

function GlideArc9.ToggleLean( ply )
    local state = leans[ply]

    if state and state.leaningOut then
        StartLeaningIn( ply, state )
    else
        StartLean( ply )
    end
end

net.Receive( GlideArc9.NET_LEAN, function( _, ply )
    if not IsValid( ply ) then return end

    local now = RealTime()
    if ( ply.GlideArc9NextLean or 0 ) > now then return end

    ply.GlideArc9NextLean = now + TOGGLE_COOLDOWN

    GlideArc9.ToggleLean( ply )
end )

----- Per-tick update

hook.Add( "Think", "GlideArc9.Lean", function()
    if next( leans ) == nil then return end

    local dt = FrameTime()
    local now = CurTime()

    for ply, state in pairs( leans ) do
        if not IsValid( ply ) or not IsValid( state.seat ) or not IsValid( state.vehicle ) or ply:GetVehicle() ~= state.seat then
            EndLean( ply )

        else
            if state.leaningOut and not GlideArc9.IsInWeaponMode( ply ) then
                StartLeaningIn( ply, state )
            end

            -- Pull back in when something gets in the way (walls, other cars)
            if state.leaningOut and now > state.nextRoomCheck then
                state.nextRoomCheck = now + ROOM_CHECK_INTERVAL

                if not HasRoom( state ) then
                    StartLeaningIn( ply, state )
                end
            end

            UpdateLean( ply, state, dt )
        end
    end
end )

-- Glide exits the player using its own exit positions, so snapping the
-- seat back here is enough.
hook.Add( "PlayerLeaveVehicle", "GlideArc9.Lean", EndLean )
hook.Add( "PlayerDeath", "GlideArc9.Lean", EndLean )
hook.Add( "PlayerDisconnected", "GlideArc9.Lean", EndLean )

hook.Add( "GlideArc9_OnWeaponModeChanged", "GlideArc9.Lean", function( ply, isEnabled )
    local state = leans[ply]

    if state and not isEnabled then
        StartLeaningIn( ply, state )
    end
end )

----- Explosions

-- Glide zeroes blast damage for anyone inside a vehicle. Someone leaning out
-- of the window isn't sheltered by it, so give them their blast damage back.
-- Glide's hook is wrapped in place, so the order hooks run in doesn't matter.
local GLIDE_DAMAGE_HOOK = "Glide.OverrideDamage"

GlideArc9.WrappedHooks = GlideArc9.WrappedHooks or {}

local function WrapGlideDamageHook()
    local hooks = hook.GetTable()["EntityTakeDamage"]
    local original = hooks and hooks[GLIDE_DAMAGE_HOOK]
    local key = "EntityTakeDamage/" .. GLIDE_DAMAGE_HOOK

    if not isfunction( original ) then
        if Glide and not GlideArc9.WrappedHooks[key] then
            print( "[Glide x ARC9] Could not find Glide's " .. key .. " hook; leaning players stay safe from explosions." )
        end

        return
    end

    if original == GlideArc9.WrappedHooks[key] then return end

    local function wrapper( target, dmginfo )
        local isLeaningPlayer = IsValid( target ) and target:IsPlayer() and GlideArc9.GetLeanSide( target ) ~= 0
        local damage = dmginfo:GetDamage()

        local result = original( target, dmginfo )

        if isLeaningPlayer and dmginfo:IsDamageType( DMG_BLAST ) then
            dmginfo:SetDamage( damage )
        end

        return result
    end

    GlideArc9.WrappedHooks[key] = wrapper

    -- Glide adds this one with HOOK_HIGH (nil, and ignored, without hook priorities)
    hook.Add( "EntityTakeDamage", GLIDE_DAMAGE_HOOK, wrapper, HOOK_HIGH )
end

hook.Add( "InitPostEntity", "GlideArc9.WrapDamageHook", WrapGlideDamageHook )
WrapGlideDamageHook()
