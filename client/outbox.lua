-- v-phone | client/outbox.lua
--
-- **Messages written where there is no signal, sent when there is.**
--
-- Before this, a text written in a dead spot was simply lost: the server refuses without bars,
-- the page said "no signal", and what somebody had typed was gone. Every real phone in the world
-- keeps that message and sends it when the bars come back, and this resource already models
-- signal, dead zones, masts and staff outages in detail - so a dead zone was a place where the
-- phone stopped working rather than a place where it behaved like a phone.
--
-- **The outbox belongs to the HANDSET, not to the network.** That is the whole design decision
-- and everything else follows from it:
--
--   * it lives on the client, because the server is the network and the network is what is
--     missing - a server-side queue would mean the server accepting a message it has just said
--     it cannot take;
--   * it is written to this player's own KVP, so it survives a reconnect or a crash the way an
--     unsent text survives turning a phone off and on;
--   * it flushes when the SIGNAL comes back, which the client is already told about;
--   * and it is never a silent lie: a queued message is drawn as queued, and the page is told
--     the moment it really goes.
--
-- What is deliberately NOT queued: anything that is not a message. A bank transfer, a taxi
-- callout or a lottery ticket bought in a tunnel and settled twenty minutes later would be a
-- worse surprise than being told it did not happen.

local KEY = 'vphone_outbox'

--- How many bars this phone has.
---
--- Its own copy, from the same event the status bar is drawn from. `power` in client/main.lua is
--- a file-local: client files share one Lua state but not each other's locals, and reaching for
--- it would have been nil at every call. Optimistic until the first push arrives - a send that
--- turns out to be impossible is queued by the answer, which is the safe direction.
local bars = 4
local Queue = {}          -- { { id, at, tries, payload = { number|group, body, kind, attachment } } }
local flushing = false
local seq = 0

--- A wall clock, on the client.
---
--- **The `os` library does not exist here.** It is server-side in this runtime, and reaching for
--- a time from a client file raises "attempt to index a nil value" - which is exactly what it
--- did, in two files, until a restart put it in the console.
---
--- `GetCloudTimeAsInt` is the client-side equivalent: a unix timestamp from the game itself. The
--- fallback keeps a number flowing if it ever answers nothing, because every caller here is
--- stamping a record rather than deciding anything, and a zero beats a crash.
local function clockNow()
    local t = GetCloudTimeAsInt and GetCloudTimeAsInt() or 0
    return math.floor(tonumber(t) or 0)
end

local function cfg()
    return (Config.Messages or {}).outbox or {}
end

local function on()
    return cfg().enabled ~= false
end

-- ══════════════════════════════════════════════════════════════
-- Where it is kept
-- ══════════════════════════════════════════════════════════════
-- KVP rather than memory. A player who writes a text in a tunnel and then crashes has still
-- written it, and losing it to the reconnect is the same failure this file exists to remove -
-- just later and more annoying.

local function save()
    local ok, encoded = pcall(json.encode, Queue)
    if ok and encoded then SetResourceKvp(KEY, encoded) end
end

local function load()
    local raw = GetResourceKvpString(KEY)
    if not raw or raw == '' then return end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        -- Unreadable rather than empty: something else wrote this key, or a version changed
        -- shape. Dropped rather than guessed at, because a half-understood queue would send
        -- half-understood messages.
        DeleteResourceKvp(KEY)
        return
    end
    Queue = decoded
    for _, item in ipairs(Queue) do
        seq = math.max(seq, math.floor(tonumber(item.id) or 0))
    end
end

--- What the page draws, for the thread it is looking at.
---
--- Sent as a whole list rather than as changes: it is at most a handful of items, and a list
--- the page can simply draw cannot drift out of step with this one.
local function push()
    SendNUIMessage({ action = 'outbox', items = Queue })
end

-- ══════════════════════════════════════════════════════════════
-- Putting one in
-- ══════════════════════════════════════════════════════════════

--- Is there any point trying right now?
---
--- `power.signal` is pushed by the server, so this is the same number the status bar is drawing.
--- Zero bars is the only state that queues: a flat battery means the phone is off and the page
--- is not open to write anything on, and every other refusal - rate limits, a number that does
--- not exist - is a real answer that queuing would only delay.
local function hasSignal()
    return bars > 0
end

local function queue(payload)
    if #Queue >= math.max(1, math.floor(tonumber(cfg().max) or 20)) then return nil, 'full' end

    seq = seq + 1
    Queue[#Queue + 1] = {
        id = seq,
        at = clockNow(),
        tries = 0,
        payload = payload,
    }
    save()
    push()
    return seq
end

-- ══════════════════════════════════════════════════════════════
-- Getting them out
-- ══════════════════════════════════════════════════════════════

--- Send what is waiting, oldest first.
---
--- One at a time and in order, because a conversation sent out of order is worse than one sent
--- late. `flushing` is the guard: the signal push and the retry tick can both arrive while a
--- send is still in flight, and two flushes would send everything twice.
local function flush()
    if flushing or not on() or #Queue == 0 or not hasSignal() then return end
    flushing = true

    local item = Queue[1]
    V.Request('v-phone:send', function(res)
        if type(res) == 'table' and res.ok then
            table.remove(Queue, 1)
            save()
            push()
            -- The page is told what actually went, so a queued bubble becomes a real one with
            -- the server's own copy of the text rather than the client's guess at it.
            SendNUIMessage({ action = 'outboxSent', id = item.id, message = res })
            flushing = false
            -- Straight on to the next: they are already written and the signal is back.
            flush()
            return
        end

        flushing = false
        item.tries = (tonumber(item.tries) or 0) + 1

        -- A refusal that is not about the signal is a real answer. Retrying it forever would
        -- be the phone insisting on something the server has already decided - a number that
        -- does not exist does not start existing.
        local err = type(res) == 'table' and tostring(res.error or '') or 'x'
        local keep = (err == 'nosignal' or err == 'rate' or err == 'x')
            and item.tries < math.max(1, math.floor(tonumber(cfg().tries) or 6))

        if not keep then
            table.remove(Queue, 1)
            save()
            push()
            SendNUIMessage({ action = 'outboxFailed', id = item.id, error = err })
            if PhoneNotify then
                PhoneNotify({
                    app = 'messages', icon = 'messages',
                    title = (PhoneString and PhoneString('ph.outbox_failed_title')) or '',
                    body = (PhoneString and PhoneString('ph.outbox_failed')) or '',
                    hasItem = true,
                })
            end
        else
            save()
        end
    end, item.payload)
end

--- The signal came back.
---
--- Driven by the power push rather than by a poll: the client is already told the moment the
--- bars change, and a tick that asks every few seconds would be asking a question it is already
--- being answered.
RegisterNetEvent('v-phone:client:power', function(p)
    if type(p) == 'table' then bars = math.floor(tonumber(p.signal) or 4) end
    if on() and hasSignal() and #Queue > 0 then
        -- A short wait, because the same push that says "you have bars" is the one that arrives
        -- as somebody walks out of a tunnel, and the server's own view of their position is a
        -- fraction behind. Sending into the edge of the dead zone is how a flush fails and
        -- burns a retry for nothing.
        SetTimeout(1500, flush)
    end
end)

-- A safety net, and nothing more. The push above is what normally flushes; this catches the
-- case where a player logs in already holding a queue and no signal change ever arrives
-- because they were somewhere with bars the whole time.
CreateThread(function()
    load()
    Wait(8000)
    push()
    while true do
        Wait(30000)
        if on() and #Queue > 0 then flush() end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- What the page asks for
-- ══════════════════════════════════════════════════════════════

--- Sending a message, with the outbox in the way.
---
--- **This replaces the plain relay.** The page still posts `send` and still gets one answer; what
--- changed is that "no signal" is no longer the end of the story. Written as a wrapper rather
--- than as a change to the page, so every place that sends a message - the thread, the composer,
--- the SDK, an app - gets the outbox without knowing it exists.
RegisterNUICallback('send', function(data, cb)
    data = type(data) == 'table' and data or {}

    -- With bars, nothing changes at all: straight to the server, same answer, same speed.
    if not on() or hasSignal() then
        V.Request('v-phone:send', function(res)
            -- Refused for want of a signal even though the bars said otherwise - the server's
            -- measurement is the authority and it is a moment ahead of the status bar. Queued
            -- rather than lost, which is the whole point of the file.
            if type(res) == 'table' and res.error == 'nosignal' and on() then
                local id, why = queue(data)
                cb(id and { ok = true, queued = true, id = id } or { error = why or 'x' })
                return
            end
            cb(res or { error = 'x' })
        end, data)
        return
    end

    local id, why = queue(data)
    cb(id and { ok = true, queued = true, id = id } or { error = why or 'full' })
end)

--- The outbox, for the page to draw. Asked when the Messages app opens.
RegisterNUICallback('outbox', function(_, cb)
    cb({ ok = true, items = Queue, enabled = on() })
end)

--- Give up on one, or on all of them.
---
--- Somebody who wrote a text an hour ago in a tunnel may well not want it going out now, and a
--- queue with no way to empty it is a queue that sends something embarrassing eventually.
RegisterNUICallback('outboxDrop', function(data, cb)
    local id = math.floor(tonumber(data and data.id) or 0)

    if id <= 0 then
        Queue = {}
        save()
        push()
        cb({ ok = true, cleared = true })
        return
    end

    for i, item in ipairs(Queue) do
        if math.floor(tonumber(item.id) or 0) == id then
            table.remove(Queue, i)
            save()
            push()
            cb({ ok = true })
            return
        end
    end
    cb({ error = 'gone' })
end)

--- `/phonedebug outbox` - what is waiting, and why it has not gone.
V.Sub('phonedebug', 'outbox', 'what is waiting to be sent, and why', function()
    print(('[v-phone] outbox: %s'):format(on() and 'on' or 'off'))
    print(('[v-phone] signal: %d bar(s)'):format(bars))
    print(('[v-phone] waiting: %d'):format(#Queue))
    for i, item in ipairs(Queue) do
        local p = item.payload or {}
        print(('  %d. to %s - "%s" (%d try/tries)'):format(
            i,
            tostring(p.group and ('group ' .. tostring(p.group)) or p.number or '?'),
            tostring(p.body or ''):sub(1, 40),
            math.floor(tonumber(item.tries) or 0)))
    end
end)
