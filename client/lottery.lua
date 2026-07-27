-- v-phone | client/lottery.lua
--
-- **The doc-lottery side of the Lottery app.**
--
-- doc-lottery publishes everything its own phone app needed as **QB server callbacks**:
--
--     doc_lottery:server:phoneGetData     the session, the jackpot, the history, the tiers,
--                                         the player's own lines, and the buying rules
--     doc_lottery:server:phoneBuyTicket   { sessionId, numbers, paymentMethod } -> { success, message }
--
-- A server callback is registered on the framework and not on the resource, so **any client may
-- call one**. That is the whole integration: this file asks the same two questions its own iframe
-- asked. doc-lottery is not edited, patched, wrapped or replaced.
--
-- It also BROADCASTS its draw, which its own app ignored entirely: drawOpen, drawStartBalls,
-- drawBall, drawResult, drawClose, and drawSync for somebody arriving late (asked for with
-- `doc_lottery:server:requestDrawSync`). All six are listened for here, so the app follows the
-- draw live and the phone notifies whether or not it is open.
--
-- **Nothing takes focus.** doc-lottery keeps its own panel focus-free so a player can keep
-- driving through a draw; a phone that grabbed the cursor would undo that for them.

local function lotteryOn()
    return (Config.Lottery or {}).enabled ~= false
end

--- Is doc-lottery the provider?
local function docMode()
    if not lotteryOn() then return false end
    local want = tostring((Config.Lottery or {}).provider or 'auto'):lower()
    if want == 'config' then return false end
    return GetResourceState('doc-lottery') == 'started'
end

--- qb-core's shared object, fetched once and only if it is there.
---
--- Same reason as client/zuber.lua and client/taxi.lua: v-phone holds no framework object of its
--- own, and a QB server callback is only reachable through `QBCore.Functions.TriggerCallback`.
local QB, qbChecked = nil, false

local function qbCore()
    if qbChecked then return QB end
    qbChecked = true
    if GetResourceState('qb-core') ~= 'started' then return nil end
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    QB = ok and core or nil
    return QB
end

--- Ask one of doc-lottery's callbacks and answer the page.
---
--- Guarded twice, as every NUI callback in this resource is: a `pcall`, because an export that
--- moved would otherwise take this callback with it and leave the page waiting on a request that
--- can never be answered; and a timeout, because a callback that never fires is the same silence
--- seen from the page. Both end in an answer.
local function ask(name, payload, cb)
    local core = qbCore()
    if not core then cb({ error = 'noframework' }) return end

    local answered = false
    local function answer(res)
        if answered then return end
        answered = true
        cb(res)
    end

    local ok = pcall(function()
        core.Functions.TriggerCallback(name, function(res) answer(res) end, payload)
    end)
    if not ok then answer({ error = 'nodoc' }) return end
    SetTimeout(10000, function() answer({ error = 'timeout' }) end)
end

-- ══════════════════════════════════════════════════════════════
-- What the page asks for
-- ══════════════════════════════════════════════════════════════

RegisterNUICallback('lotteryDoc', function(data, cb)
    if not docMode() then cb({ error = 'notdoc' }) return end
    local op = tostring((data and data.op) or 'data')

    if op == 'data' then
        ask('doc_lottery:server:phoneGetData', nil, function(res)
            if type(res) ~= 'table' or res.ok ~= true then cb({ error = 'nodata' }) return end
            res.doc = true
            cb(res)
        end)
        return
    end

    -- **`paymentMethod`, and `sessionId` with it.** Its callback reads those names, and it checks
    -- the session id against the live one - a purchase for a session that has already been drawn
    -- is refused there, which is why the page sends back the id it was given rather than nothing.
    if op == 'buy' then
        local body = (type(data) == 'table' and type(data.buy) == 'table') and data.buy or {}
        ask('doc_lottery:server:phoneBuyTicket', {
            sessionId = body.sessionId,
            numbers = body.numbers,
            paymentMethod = body.account,
        }, function(res)
            if type(res) ~= 'table' then cb({ error = 'x' }) return end
            -- Its answer is `{ success, message }`, and the message is a finished sentence in the
            -- server's own language. Passed through untouched: rewriting it here would mean
            -- guessing which of a dozen refusals it was, and getting that wrong tells a player
            -- the wrong reason their money did not move.
            cb({ ok = res.success == true, message = res.message })
        end)
        return
    end

    cb({ error = 'x' })
end)

-- ══════════════════════════════════════════════════════════════
-- The draw, live
-- ══════════════════════════════════════════════════════════════
-- doc-lottery draws its own panel; this is the SECOND screen. The app follows the balls if it
-- happens to be open, and the phone notifies either way - which is what its own app could not do,
-- since it had no idea a draw was happening at all.

local live = nil     -- the mirrored sequence, so a render can happen long after the event

local function pushPage()
    SendNUIMessage({ action = 'lotteryLive', live = live })
end

local function notify(titleKey, bodyText)
    if not PhoneNotify then return end
    PhoneNotify({
        app = 'lottery', icon = 'lottery',
        title = (PhoneString and PhoneString(titleKey)) or 'Lottery',
        body = bodyText,
        hasItem = true,
    })
end

--- One shape for both `drawOpen` and `drawSync`, because they carry the same thing: `drawSync` is
--- the same state with the countdown recomputed for somebody who arrived late.
local function beginLive(d, announce)
    if type(d) ~= 'table' then return end
    live = {
        jackpot = tonumber(d.jackpot) or 0,
        numberCount = tonumber(d.numberCount) or 5,
        countdown = tonumber(d.countdown),
        started = d.ballsStarted == true,
        revealed = d.revealed or {},
        result = d.result,
        mine = d.myNumbers or {},
    }
    pushPage()
    if announce and (Config.Lottery or {}).announce ~= false then
        notify('ph.lottery_draw_soon',
               (PhoneString and PhoneString('ph.lottery_draw_soon_body')) or nil)
    end
end

RegisterNetEvent('doc_lottery:client:drawOpen', function(d)
    if not docMode() then return end
    beginLive(d, true)
end)

RegisterNetEvent('doc_lottery:client:drawSync', function(d)
    if not docMode() then return end
    -- No notification: this is a resync, and telling somebody a draw is starting when it started
    -- four minutes ago is worse than saying nothing.
    beginLive(d, false)
end)

RegisterNetEvent('doc_lottery:client:drawStartBalls', function()
    if not docMode() or not live then return end
    live.started = true
    live.countdown = nil
    pushPage()
end)

RegisterNetEvent('doc_lottery:client:drawBall', function(n)
    if not docMode() or not live then return end
    local number = tonumber(n)
    if not number then return end
    live.revealed[#live.revealed + 1] = number
    pushPage()
end)

RegisterNetEvent('doc_lottery:client:drawResult', function(payload)
    if not docMode() or not live then return end
    live.result = payload
    pushPage()

    -- doc-lottery's public result is deliberately ANONYMOUS - counts per tier, never a name - and
    -- its title and detail are already written. Passed through as the notification body rather
    -- than recomposed, so the phone says exactly what its panel says.
    if (Config.Lottery or {}).announce ~= false and type(payload) == 'table' then
        notify('ph.lottery_result', tostring(payload.title or ''))
    end
end)

RegisterNetEvent('doc_lottery:client:drawClose', function()
    if not docMode() then return end
    live = nil
    pushPage()
end)

--- Where the draw is, for an app opened in the middle of one.
---
--- Two answers, in order of trust: the state mirrored from the broadcasts, and - if there is none
--- because this client connected mid-draw - a request for doc-lottery's own resync. Its answer
--- arrives as `drawSync`, which lands on the handler above.
RegisterNUICallback('lotteryLive', function(_, cb)
    if not docMode() then cb({ ok = true, live = false }) return end
    if not live then
        pcall(function() TriggerServerEvent('doc_lottery:server:requestDrawSync') end)
        cb({ ok = true, live = false, asked = true })
        return
    end
    cb({ ok = true, live = true, state = live })
end)

-- ══════════════════════════════════════════════════════════════
-- The config provider's relays
-- ══════════════════════════════════════════════════════════════
-- Thin: every decision is in server/lottery.lua.

RegisterNUICallback('lotteryOpen', function(_, cb)
    V.Request('v-phone:lottery:open', function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('lotteryBuy', function(data, cb)
    V.Request('v-phone:lottery:buy', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('lotteryLiveOwn', function(_, cb)
    V.Request('v-phone:lottery:live', function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('lotteryAdmin', function(data, cb)
    V.Request('v-phone:lottery:admin', function(res) cb(res or { error = 'x' }) end, data or {})
end)

--- The config provider's own draw, mirrored into the same shape the page already draws.
---
--- One page renderer for both providers, which is the point: the app cannot look like two
--- different apps depending on which resource a server happens to run.
RegisterNetEvent('v-phone:client:lotteryDraw', function(d)
    if type(d) ~= 'table' then return end
    local kind = tostring(d.kind or '')

    if kind == 'open' then
        live = {
            jackpot = tonumber(d.jackpot) or 0,
            numberCount = tonumber(d.numberCount) or 5,
            countdown = tonumber(d.countdown),
            started = false,
            revealed = {},
            result = nil,
            mine = d.mine or {},
        }
        pushPage()
        if (Config.Lottery or {}).announce ~= false then
            notify('ph.lottery_draw_soon',
                   (PhoneString and PhoneString('ph.lottery_draw_soon_body')) or nil)
        end
        return
    end

    if not live then return end

    if kind == 'start' then
        live.started = true
        live.countdown = nil
    elseif kind == 'ball' then
        local n = tonumber(d.number)
        if n then live.revealed[#live.revealed + 1] = n end
    elseif kind == 'result' then
        live.result = d.result
        if (Config.Lottery or {}).announce ~= false then
            notify('ph.lottery_result', nil)
        end
    elseif kind == 'close' then
        live = nil
    end
    pushPage()
end)

--- What YOUR ticket did. Private, and only ever sent to the holder.
RegisterNetEvent('v-phone:client:lotteryResult', function(d)
    if type(d) ~= 'table' then return end
    SendNUIMessage({ action = 'lotteryMine', result = d })
    local reward = tonumber(d.reward) or 0
    -- A loss is worth a notification too. "Did I win?" is the whole reason somebody bought a
    -- ticket, and silence is not an answer to it - it just reads as the app being broken.
    notify(reward > 0 and 'ph.lottery_you_won' or 'ph.lottery_you_lost', nil)
end)
