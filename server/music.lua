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

-- **How often a sound's position is pushed, and why there are two numbers.**
--
-- `x:Position()` MOVES a sound; it does not animate it there. So the interval is exactly how far
-- the sound is allowed to fall behind before it catches up in one jump - and at 100 km/h a car
-- covers eleven metres in four hundred milliseconds. That is not a radio in a car, it is a radio
-- being teleported down the street every four hundred milliseconds, which is what it sounded
-- like.
--
-- A sound on a PED does not have that problem: somebody walking covers a metre and a half in the
-- same time, and nobody can hear a metre and a half. So the loop runs at the fast rate only
-- while something is riding a vehicle, and drops back the moment nothing is.
local TICK_FOOT = 400
local TICK_DRIVE = 100

local function soundName(src) return ('vphone_%d'):format(src) end

local function xsound()
    return GetResourceState('xsound') == 'started' and exports.xsound or nil
end

--- Where the sound should be right now.
---
--- The vehicle when there is one and the player is still in it - a player who gets out mid
--- track leaves the radio in the car, which is what a car radio does - otherwise the ped.
--- Where the sound should be right now, and whether it is riding a vehicle.
---
--- The second answer decides how fast the ticker runs. It is returned from here rather than
--- asked for separately because this function already made the `GetVehiclePedIsIn` call, and a
--- second one could answer differently in the gap.
local function positionOf(src, record)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    if record.mode == 'vehicle' then
        local veh = GetVehiclePedIsIn(ped, false)
        if veh and veh ~= 0 then return GetEntityCoords(veh), true end
    end
    return GetEntityCoords(ped), false
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
            -- Set while the positions are being read, from the same `GetVehiclePedIsIn` answer
            -- `positionOf` uses - so it costs nothing extra and cannot disagree with it.
            local moving = false
            for src, record in pairs(Playing) do
                local at, inVehicle = positionOf(src, record)
                if at then
                    if inVehicle then moving = true end
                    pcall(function() x:Position(-1, record.name, at) end)
                else
                    -- The player is gone from the world. Their sound goes with them rather
                    -- than being left playing at their last known position.
                    stopFor(src)
                end
            end
            Wait(moving and TICK_DRIVE or TICK_FOOT)
        end
        ticking = false
    end)
end

--- May this URL be streamed on this server?
---
--- `Config.Music.hosts` is the operator's allowlist and it was checked ON THE PAGE only. A page
--- is a browser: the check it performs is a courtesy to the player, never a control on the
--- request. And the request here is broadcast to EVERY client - `PlayUrlPos(-1, ...)` - so an
--- unchecked URL is every player on the server fetching whatever the sender chose.
---
--- An empty list still means "any host". That is what the config documents ("An empty list
--- allows any host, which is the permissive setting") and a server relying on it must not stop
--- working because of a security fix.
---
--- Subdomain-safe: `youtube.com` in the list allows `music.youtube.com` but not
--- `notyoutube.com`, which is the same rule the wallpaper and picture gates use.
local function urlAllowed(url)
    local M = Config.Music or {}
    local hosts = M.hosts
    if type(hosts) ~= 'table' or #hosts == 0 then return true end

    local host = tostring(url or ''):match('^https?://([^/?#]+)')
    if not host then return false end
    host = host:lower():gsub(':%d+$', '')
    for _, allowed in ipairs(hosts) do
        allowed = tostring(allowed or ''):lower()
        if allowed ~= '' and (host == allowed or host:sub(-(#allowed + 1)) == '.' .. allowed) then
            return true
        end
    end
    return false
end

--- Start a positioned sound for everybody, or replace the one this player already has.
local function play(src, url, volume, mode, distance)
    local x = xsound()
    if not x then return { error = 'nodeck' } end

    url = tostring(url or '')
    if url == '' or #url > 500 then return { error = 'nourl' } end
    -- **Here, not on the page.** See `urlAllowed` above: this value is about to be handed to
    -- every client on the server.
    if not urlAllowed(url) then return { error = 'badhost' } end
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
