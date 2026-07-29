-- v-phone | server/music.lua
--
-- **Music that other people can hear.**
--
-- The Music app has three outputs and they are not the same problem:
--
--   headphones  only you hear it. Entirely a client matter - xsound's client `PlayUrl` plays
--               into the local player's ears and nobody else's - so it never reaches here.
--   phone       the speaker. Everybody near you hears it, which means the sound has to exist
--               on every one of their clients, which means the SERVER has to start it.
--   vehicle     the same, positioned on the car instead of on the player.
--
-- So this file exists for exactly one reason: a positioned sound has to be broadcast, and a
-- broadcast is the server's to make. xsound's server exports take a target of -1 for
-- everybody, and from then on the sound is a named object every client holds.
--
-- **And it has to follow.** A positioned sound stays where it was started. A player who walks
-- away from their own phone music, or drives off with the radio on, would leave the sound
-- standing in the street - so while one is playing its position is pushed on a ticker. That
-- ticker is the whole difference between this working and this technically working.

local Playing = {}   -- [source] = { name, mode, entity }
local TICK_MS = 400  -- fast enough that a car does not outrun its own radio

local function soundName(src) return ('vphone_%d'):format(src) end

local function xsound()
    return GetResourceState('xsound') == 'started' and exports.xsound or nil
end

--- Where the sound should be right now.
---
--- The vehicle when there is one and the player is still in it - a player who gets out mid
--- track leaves the radio in the car, which is what a car radio does - otherwise the ped.
local function positionOf(src, record)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    if record.mode == 'vehicle' then
        local veh = GetVehiclePedIsIn(ped, false)
        if veh and veh ~= 0 then return GetEntityCoords(veh) end
    end
    return GetEntityCoords(ped)
end

local function stopFor(src, silent)
    local record = Playing[src]
    Playing[src] = nil
    if not record then return false end
    local x = xsound()
    if x and not silent then pcall(function() x:Destroy(-1, record.name) end) end
    return true
end

--- One ticker for everybody, started only when something is playing.
---
--- A thread per sound would be a thread per player on a busy server, all doing the same
--- thing at the same interval; one loop that ends when the last sound stops costs nothing
--- when nobody is listening, which is most of the time.
local ticking = false
local function ensureTicker()
    if ticking then return end
    ticking = true
    CreateThread(function()
        while next(Playing) ~= nil do
            local x = xsound()
            if not x then break end
            for src, record in pairs(Playing) do
                local at = positionOf(src, record)
                if at then
                    pcall(function() x:Position(-1, record.name, at) end)
                else
                    -- The player is gone from the world. Their sound goes with them rather
                    -- than being left playing at their last known position.
                    stopFor(src)
                end
            end
            Wait(TICK_MS)
        end
        ticking = false
    end)
end

--- Start a positioned sound for everybody, or replace the one this player already has.
---
--- `url` is NOT validated here for host: `Config.Music.hosts` is the operator's allowlist and
--- the app checks it before a track is ever added to a library. What matters at this layer is
--- that the value is a string of sane length going into another resource's export.
local function play(src, url, volume, mode, distance)
    local x = xsound()
    if not x then return { error = 'nodeck' } end

    url = tostring(url or '')
    if url == '' or #url > 500 then return { error = 'nourl' } end
    volume = math.max(0.0, math.min(1.0, tonumber(volume) or 0.5))
    mode = (mode == 'vehicle') and 'vehicle' or 'phone'
    -- A phone speaker is a phone speaker. The ceiling stops a player broadcasting across a
    -- district, which is the obvious abuse and the reason this is not simply whatever the
    -- page asked for.
    local M = Config.Music or {}
    local maxRange = math.max(2.0, math.min(60.0, tonumber(M.speakerRange) or 12.0))
    distance = math.max(2.0, math.min(maxRange, tonumber(distance) or maxRange))

    -- Replace rather than layer: one phone, one sound. Without this, skipping tracks leaves
    -- every previous one playing.
    stopFor(src)

    local name = soundName(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return { error = 'x' } end
    local record = { name = name, mode = mode }
    local at = positionOf(src, record)
    if not at then return { error = 'x' } end

    local ok = pcall(function()
        x:PlayUrlPos(-1, name, url, volume, at, false)
        x:Distance(-1, name, distance)
    end)
    if not ok then return { error = 'nodeck' } end

    Playing[src] = record
    ensureTicker()
    return { ok = true, driven = true, deck = 'xsound' }
end

V.Callback('v-phone:music:play', function(src, resolve, data)
    -- `PhoneRequiresItem`, not `requireItem`: the second is a file-local in server/main.lua
    -- and was nil here, so `not requireItem` was always true and this check never ran.
    if PhoneRequiresItem(src) then
        resolve(play(src, data and data.url, data and data.volume,
                     data and data.mode, data and data.distance))
        return
    end
    resolve({ error = 'nophone' })
end)

V.Callback('v-phone:music:stop', function(src, resolve)
    resolve({ ok = stopFor(src) })
end)

--- Pause or resume the sound this player owns.
---
--- Not "stop and start again": a stream restarted from the beginning is not a pause, and on a
--- twenty-minute mix that difference is the whole feature. xsound keeps the sound object and
--- its position, so Pause/Resume land where the track was.
V.Callback('v-phone:music:pause', function(src, resolve, data)
    local record = Playing[src]
    local x = xsound()
    if not record or not x then resolve({ error = 'nothing' }) return end
    local resume = data and data.resume == true
    local ok = pcall(function()
        if resume then x:Resume(-1, record.name) else x:Pause(-1, record.name) end
    end)
    if not ok then resolve({ error = 'nodeck' }) return end
    record.paused = not resume
    resolve({ ok = true, paused = record.paused })
end)

V.Callback('v-phone:music:volume', function(src, resolve, data)
    local record = Playing[src]
    local x = xsound()
    if not record or not x then resolve({ error = 'nothing' }) return end
    local volume = math.max(0.0, math.min(1.0, tonumber(data and data.volume) or 0.5))
    pcall(function() x:setVolume(-1, record.name, volume) end)
    resolve({ ok = true })
end)

-- A sound belongs to a player, so it ends when they do. Without this the track plays on at
-- the spot they disconnected, and nothing is left that knows how to stop it.
AddEventHandler('playerDropped', function() stopFor(source) end)

-- And on the way down, so a restart does not leave a street full of music with no owner.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for src in pairs(Playing) do stopFor(src) end
end)

exports('PauseMusic', function(src, resume)
    local record = Playing[tonumber(src) or 0]
    local x = xsound()
    if not record or not x then return false end
    pcall(function()
        if resume then x:Resume(-1, record.name) else x:Pause(-1, record.name) end
    end)
    record.paused = not resume
    return true
end)

exports('StopMusic', function(src) return stopFor(tonumber(src) or 0) end)
exports('IsPlayingMusic', function(src) return Playing[tonumber(src) or 0] ~= nil end)
