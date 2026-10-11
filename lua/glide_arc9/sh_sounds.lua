--[[
    Gunshots inside an enclosed vehicle are deafening. While a player in
    weapon mode fires from inside one (not leaning out), the people in that
    vehicle hear the shot with a small-room echo and an extra layer of the
    same shot on top (a sound can't play louder than full volume, so it's
    played twice). People outside hear the shot as usual.

    - The shooter's own shots are predicted on their client, so the client
      changes those.
    - The other occupants hear the server's copy, so the server plays the
      extra layer to just them.
    - In singleplayer everything comes from the server.

    Enclosed means what Glide itself muffles in first person (cars, not
    motorcycles, ATVs or turret seats). That check only exists clientside,
    so the server goes by vehicle type, with a per-vehicle override:
    set ENT.GlideArc9Enclosed = true/false on a vehicle class.
]]

local IsValid = IsValid

local cvarBoost = GetConVar( "glide_arc9_enclosed_boost" )
local cvarDsp = GetConVar( "glide_arc9_enclosed_dsp" )

local SINGLEPLAYER = game.SinglePlayer()

-- Overlapping channel, so rapid fire doesn't cut the extra layer off
local BOOST_CHANNEL = CHAN_STATIC

--- Is this player inside an enclosed vehicle (and not leaning out of it)?
function GlideArc9.IsInEnclosedVehicle( ply )
    if GlideArc9.GetLeanSide( ply ) ~= 0 then return false end

    local vehicle = ply:GlideGetVehicle()
    if not IsValid( vehicle ) then return false end

    if vehicle.GlideArc9Enclosed ~= nil then
        return vehicle.GlideArc9Enclosed == true
    end

    if CLIENT and isfunction( vehicle.AllowFirstPersonMuffledSound ) then
        return vehicle:AllowFirstPersonMuffledSound( ply:GlideGetSeatIndex() ) == true
    end

    return vehicle.VehicleType == Glide.VEHICLE_TYPE.CAR
end

--- ARC9's channels for the gunshot itself (and its layer), indoor or not.
--- Built on first use, ARC9 may load after this file.
local shotChannels

local function IsShotChannel( channel )
    if not shotChannels then
        if not ARC9 or not ARC9.CHAN_WEAPON then return false end

        shotChannels = {
            [ARC9.CHAN_WEAPON] = true,
            [ARC9.CHAN_LAYER + 4] = true,
            [ARC9.CHAN_INDOOR] = true,
            [ARC9.CHAN_INDOOR + 7] = true
        }
    end

    return shotChannels[channel] == true
end

local function GetPitch( pitch )
    if istable( pitch ) then
        return math.random( pitch[1], pitch[2] )
    end

    return pitch or 100
end

--- A sound script's own volume and channel override what EmitSound is
--- given, so the extra layer could end up on the shot's channel and cut it
--- off. Play the wave file behind the script instead.
local function GetSoundFile( name )
    local props = sound.GetProperties( name )
    if not props then return name end

    local wave = props.sound

    if istable( wave ) then
        wave = wave[math.random( #wave )]
    end

    return isstring( wave ) and wave or name
end

local function PlayExtraLayer( weapon, soundtab, dsp, filter )
    local boost = cvarBoost:GetFloat()
    if boost <= 0 then return end

    weapon:EmitSound( GetSoundFile( soundtab.sound ), soundtab.level or 75, GetPitch( soundtab.pitch ),
        boost * ( soundtab.volume or 1 ), BOOST_CHANNEL, 0, dsp, filter )
end

--- ARC9 reuses the same sound tables for every shot, so changes go on a copy.
local function CopySoundTab( soundtab )
    local copy = {}

    for k, v in pairs( soundtab ) do
        copy[k] = v
    end

    return copy
end

--- Everyone else riding in the shooter's vehicle.
local function GetOtherOccupants( shooter, vehicle )
    local filter

    for _, ply in player.Iterator() do
        if ply ~= shooter and ply:GlideGetVehicle() == vehicle then
            filter = filter or RecipientFilter()
            filter:AddPlayer( ply )
        end
    end

    return filter
end

hook.Add( "ARC9_HookP_TranslateSound", "GlideArc9.EnclosedShots", function( weapon, soundtab )
    if not istable( soundtab ) or not isstring( soundtab.sound ) or soundtab.sound == "" then return end
    if not IsShotChannel( soundtab.channel ) then return end

    local owner = weapon:GetOwner()
    if not IsValid( owner ) or not owner:IsPlayer() or not GlideArc9.IsInWeaponMode( owner ) then return end
    if not GlideArc9.IsInEnclosedVehicle( owner ) then return end

    local dsp = cvarDsp:GetInt()

    -- The shooter's own copy: predicted clientside, or the server's in
    -- singleplayer (EmitSound skips repeated predictions by itself)
    if CLIENT or SINGLEPLAYER then
        PlayExtraLayer( weapon, soundtab, dsp )

        if dsp <= 0 then return end

        local echoed = CopySoundTab( soundtab )
        echoed.dsp = dsp

        return echoed
    end

    -- Multiplayer server: the other occupants hear this copy. People outside
    -- hear it too, so it stays as it is and the occupants get the echo and
    -- the extra layer on their own.
    local filter = GetOtherOccupants( owner, owner:GlideGetVehicle() )

    if filter then
        PlayExtraLayer( weapon, soundtab, dsp, filter )
    end
end )
