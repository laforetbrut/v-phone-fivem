-- v-phone | server/downloads.lua
--
-- **An app takes time to download, and a bad signal makes it take longer.**
--
-- Ten seconds on four bars, a minute on one. Before this an app appeared the instant it was
-- tapped, which made the store the one part of the phone where the network did not exist - and
-- this resource models signal, dead zones, masts and outages everywhere else.
--
-- **Server-driven, and that is the whole design.**
--
--   * it keeps running with the phone in a pocket, which is what a download does;
--   * a client cannot skip it, because the app is granted here and only when the time is up;
--   * and the RATE follows the signal each second, so walking out of a tunnel visibly speeds it
--     up instead of the phone having decided the whole duration at the start.
--
-- Progress is a fraction, not a countdown: at four bars a second buys a tenth of the app, at one
-- bar a sixtieth. Somebody who starts underground and drives into town finishes early, which is
-- both what a real phone does and the more forgiving behaviour.
--
-- Nothing is charged here. The money is taken by the install callback in server/main.lua before
-- a download is ever started - paying for something and then watching it fail on the signal
-- would be the worst version of this feature.

local CFG = (Config.Store or {}).download or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

--- How long a full download takes at this many bars, in seconds.
---
--- Read per tick rather than once at the start: that is what makes the signal matter while it is
--- running rather than only at the moment somebody pressed the button.
local function secondsAt(bars)
    bars = math.max(0, math.min(4, math.floor(tonumber(bars) or 4)))
    local at = CFG.secondsAtBars
    if type(at) ~= 'table' then at = { [4] = 10, [3] = 15, [2] = 30, [1] = 60 } end
    return math.max(1, math.floor(num(at[bars], num(CFG.seconds, 10))))
end

-- [citizenid] = { [appId] = { progress = 0..1, src, update = bool } }
local Active = {}

--- What this character is downloading, for the store to draw.
function DownloadsOf(cid)
    local out = {}
    for id, d in pairs(Active[cid] or {}) do
        -- Rounded the same way the tick rounds it. Two places reporting the same download at
        -- 99% and 100% is a store row and a home screen tile disagreeing about the same app.
        out[id] = { progress = math.floor(d.progress * 100 + 0.5), update = d.update == true }
    end
    return out
end

function DownloadBusy(cid, id)
    return (Active[cid] or {})[id] ~= nil
end

--- Start one.
---
--- `grant` is what actually installs the app, handed in by the caller rather than reached for:
--- the install rules - required, optional, already owned, paid for - all live in server/main.lua
--- and there is no reason for a second copy of them to exist here.
function DownloadStart(src, cid, id, isUpdate, grant)
    if not enabled() then
        grant()
        return { ok = true, installed = true }
    end
    if DownloadBusy(cid, id) then return { error = 'downloading' } end

    Active[cid] = Active[cid] or {}
    Active[cid][id] = { progress = 0.0, src = src, update = isUpdate == true, grant = grant }

    TriggerClientEvent('v-phone:client:download', src, {
        app = id, progress = 0, update = isUpdate == true,
    })
    return { ok = true, downloading = true, seconds = secondsAt(GetSignalOf and GetSignalOf(src) or 4) }
end

--- Give up on one. The app is not installed and nothing is refunded here - what was paid for is
--- remembered against the character, so starting again later costs nothing.
function DownloadCancel(cid, id)
    local mine = Active[cid]
    if not mine or not mine[id] then return false end
    local src = mine[id].src
    mine[id] = nil
    if src then
        TriggerClientEvent('v-phone:client:download', src, { app = id, cancelled = true })
    end
    return true
end

--- One tick a second for everybody downloading.
---
--- One thread rather than one per download: a busy server is a handful of downloads, and a
--- thread each is a thread each to leak.
CreateThread(function()
    while true do
        Wait(1000)
        if enabled() then
            for cid, apps in pairs(Active) do
                for id, d in pairs(apps) do
                    local src = d.src

                    -- Gone. The download goes with them: it is a phone fetching something, and
                    -- the phone left.
                    if not src or GetPlayerName(src) == nil then
                        apps[id] = nil
                    else
                        local bars = GetSignalOf and GetSignalOf(src) or 4

                        -- No service is no download. Held rather than failed, because a player
                        -- walking through a tunnel expects to come out the other side and find
                        -- it still going - which is what a real phone does.
                        if bars > 0 then
                            d.progress = math.min(1.0, d.progress + (1.0 / secondsAt(bars)))
                        end

                        TriggerClientEvent('v-phone:client:download', src, {
                            app = id,
                            -- Rounded, not truncated. Ten additions of a tenth land on
                            -- 0.9999999999999999, and `floor` turns the last second of every
                            -- download into "99%" - which reads as a download that stalled on
                            -- the finish line.
                            progress = math.floor(d.progress * 100 + 0.5),
                            stalled = bars <= 0,
                            update = d.update,
                        })

                        -- **Not `>= 1.0`.** Binary floating point cannot hold a tenth, so ten
                        -- ticks of `1/10` sum to slightly UNDER one and an eleventh second was
                        -- needed to finish a ten-second download. At one bar it was sixty-one.
                        -- The epsilon is smaller than any real tick can be and larger than the
                        -- error a few hundred additions can accumulate.
                        if d.progress >= 0.9999 then
                            apps[id] = nil
                            local ok = pcall(d.grant)
                            TriggerClientEvent('v-phone:client:download', src, {
                                app = id, progress = 100, done = true,
                                failed = not ok, update = d.update,
                            })
                        end
                    end
                end
                if next(apps) == nil then Active[cid] = nil end
            end
        end
    end
end)

--- A player who left is not downloading anything.
AddEventHandler('playerDropped', function()
    local p = Core.GetPlayerReal and Core.GetPlayerReal(source) or Core.GetPlayer(source)
    if p and p.citizenid then Active[p.citizenid] = nil end
end)

--- Stop waiting for one.
V.Callback('v-phone:download:cancel', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local id = tostring((data and data.app) or '')
    resolve({ ok = DownloadCancel(p.citizenid, id) })
end)
