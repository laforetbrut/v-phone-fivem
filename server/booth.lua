-- v-phone | server/booth.lua
--
-- **The payphone: credit, cards, and the call itself.**
--
-- A booth is not a device the phone owns. It is a prop on the street that a player walks
-- up to, so nothing here trusts the client for anything that matters:
--
--   * the coordinates of the box arrive from the client, and are ACCEPTED only after the
--     server has checked the player's own ped is standing next to them,
--   * the booth's number is then DERIVED from those coordinates here, never read from the
--     message, so a forged position buys a different booth rather than a chosen number,
--   * the card is removed through the inventory bridge and the credit is only granted if
--     the remove actually took something,
--   * talk time is billed by a server-side ticker, one second at a time, so a client that
--     stops reporting is a client that stops talking.
--
-- Credit lives in `vphone_kv` against the citizen id, the same place the phone keeps every
-- other per-character value. No new table, and it survives a reconnect the way a real
-- calling card would.

local BOOTH = Config.Booth or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return BOOTH.enabled == true end

--- Seconds of talk time one card is worth, and the ceiling a character may bank.
local function cardSeconds() return math.floor(num(BOOTH.card and BOOTH.card.seconds, 600)) end
local function maxCredit() return math.floor(num(BOOTH.card and BOOTH.card.maxCredit, 7200)) end
local function cardItem()
    local item = BOOTH.card and BOOTH.card.item
    if type(item) ~= 'string' or item == '' then return nil end
    return item
end

--- Free-call mode: no cost configured means no card, no credit, no meter.
local function isFree() return math.floor(num(BOOTH.costPerMinute, 60)) <= 0 end

local function log(src, message)
    if not BOOTH.log then return end
    local p = Core.GetPlayer(src)
    V.Info(('[v-phone] payphone: %s (%s) %s'):format(
        p and p.name or '?', p and p.citizenid or src, message))
    if Core.Log then Core.Log('payphone', message, nil, p and p.citizenid) end
end

-- ══════════════════════════════════════════════════════════════
-- Credit
-- ══════════════════════════════════════════════════════════════
-- Whole seconds, clamped on the way in and on the way out. A negative or absurd value in
-- the store - a hand-edited row, an older build - reads back as something sane rather than
-- as a call that never ends.

local KEY = 'boothCredit'

local function creditOf(cid)
    if not cid then return 0 end
    local raw = Bridge.KvGet(cid, KEY)
    return math.max(0, math.min(maxCredit(), math.floor(num(raw, 0))))
end

local function setCredit(cid, seconds)
    if not cid then return 0 end
    seconds = math.max(0, math.min(maxCredit(), math.floor(num(seconds, 0))))
    Bridge.KvSet(cid, KEY, seconds)
    return seconds
end

--- Push the meter to the box on screen. Called after every change so the page never shows
--- a balance the server has moved on from.
local function pushCredit(src, extra)
    local p = Core.GetPlayer(src)
    if not p then return end
    local payload = extra or {}
    payload.credit = creditOf(p.citizenid)
    payload.free = isFree()
    TriggerClientEvent('v-phone:client:boothCredit', src, payload)
end

-- ══════════════════════════════════════════════════════════════
-- Standing at the box
-- ══════════════════════════════════════════════════════════════
--- Is this player genuinely next to the booth they claim to be at?
---
--- The ped's coordinates come from the server's own copy of the world, never from the
--- message. The allowance on top of the configured radius is for the gap between the prop's
--- origin and where a player actually stands to use it.
local function atBooth(src, data)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local coords = GetEntityCoords(ped)
    if not coords then return nil end

    local x, y, z = num(data and data.x), num(data and data.y), num(data and data.z)
    if x == 0 and y == 0 and z == 0 then return nil end

    local reach = num(BOOTH.radius, 1.6) + num(BOOTH.reachTolerance, 2.5)
    if #(coords - vector3(x + 0.0, y + 0.0, z + 0.0)) > reach then return nil end

    -- The number is computed HERE, from the position the server just accepted.
    return { x = x, y = y, z = z, number = Booth.NumberAt(x, y, z), key = Booth.Key(x, y, z) }
end

-- ══════════════════════════════════════════════════════════════
-- Opening the box
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:booth:open', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local booth = atBooth(src, data)
    if not booth then resolve({ error = 'notatbooth' }) return end

    resolve({
        ok = true,
        number = booth.number,
        -- The operator's name for the plate at the top of the panel.
        brand = tostring(BOOTH.brand or 'Badger'),
        credit = creditOf(p.citizenid),
        free = isFree(),
        -- The page needs these to draw the meter and to grey out what it cannot do.
        costPerMinute = math.floor(num(BOOTH.costPerMinute, 60)),
        minimumSeconds = math.floor(num(BOOTH.minimumSeconds, 30)),
        hasCard = cardItem() ~= nil and Bridge.ItemCount(src, cardItem()) > 0 or false,
        cardItem = cardItem(),
        cardSeconds = cardSeconds(),
        freeNumbers = BOOTH.freeNumbers or {},
        maxDialLength = math.floor(num(BOOTH.maxDialLength, 20)),
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Feeding a card in
-- ══════════════════════════════════════════════════════════════
-- The order matters. The item is taken FIRST and the credit granted only if the inventory
-- confirms something left it. Doing it the other way round would pay out on a failed
-- remove, which on a busy inventory script is not a theoretical concern.
local function redeemCard(src, silent)
    local p = Core.GetPlayer(src)
    if not p then return nil, 'noplayer' end
    if isFree() then return nil, 'nocost' end

    local item = cardItem()
    if not item then return nil, 'nocard' end

    local before = creditOf(p.citizenid)
    if before >= maxCredit() then return nil, 'creditfull' end

    if Bridge.ItemCount(src, item) <= 0 then return nil, 'nocarditem' end
    if not Bridge.RemoveItem(src, item, 1) then return nil, 'nocarditem' end

    local after = setCredit(p.citizenid, before + cardSeconds())
    log(src, ('redeemed a card: %ds -> %ds'):format(before, after))
    if not silent then pushCredit(src) end
    return { credit = after, added = after - before }, nil
end

V.Callback('v-phone:booth:card', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    -- Cards go in at the box, not from a menu somewhere else.
    if not atBooth(src, data) then resolve({ error = 'notatbooth' }) return end

    local result, err = redeemCard(src)
    if not result then resolve({ error = err }) return end
    resolve({ ok = true, credit = result.credit, added = result.added })
end)

-- Using the card from the inventory, away from any box, tops the character up just the
-- same. This goes through the `v-inventory` shim, so it registers correctly on
-- ox_inventory, the qb family, Quasar and ESX without knowing which is running.
CreateThread(function()
    if not enabled() or isFree() then return end
    local item = cardItem()
    if not item then return end

    -- Same wait as the power bank's registration: the inventory shim publishes its provider
    -- on a thread, and registering against it before it exists registers against nothing.
    while GetResourceState('v-inventory') ~= 'started' do Wait(200) end
    Wait(1500)

    V.Use('v-inventory').RegisterUsableItem(item, function(src)
        local result, err = redeemCard(src, true)
        if not result then
            V.Notify(src, LP(src, 'ph.booth_card_' .. tostring(err or 'failed')), 'error')
            return
        end
        pushCredit(src)
        V.Notify(src, LP(src, 'ph.booth_card_loaded', math.floor(result.added / 60)), 'success')
    end)
end)

-- ══════════════════════════════════════════════════════════════
-- The call
-- ══════════════════════════════════════════════════════════════
-- One ticker per booth call, started when the call connects and stopped when it ends. It
-- is the only thing that spends credit, and it spends it a second at a time against the
-- LIVE call record, so a call that ended for any other reason simply stops being billed.

-- [src] = the call id the running ticker is billing. Keyed by CALL rather than by a plain
-- flag: a boolean would still read as "already metering" for the first second after a call
-- ended, and the next call placed inside that second would never be billed at all.
local Metering = {}

-- [src] = os.time() when this player's last booth call ended. Only used when
-- `Config.Booth.cooldownSeconds` is set.
local Cooldown = {}

local function startMeter(src, cid, callId)
    if Metering[src] == callId then return end
    Metering[src] = callId

    CreateThread(function()
        -- Whole seconds of credit per second of call. `costPerMinute` is seconds spent per
        -- minute talked, so 60 is real time and 120 is double rate.
        local rate = math.floor(num(BOOTH.costPerMinute, 60)) / 60.0
        local owed = 0.0

        while Metering[src] == callId do
            Wait(1000)

            local call, id = BoothCallOf(src)
            if not call or id ~= callId then break end
            -- Only a connected call is billed. Ringing is free, the way it should be.
            if call.state == 'active' then
                owed = owed + rate
                if owed >= 1.0 then
                    local spend = math.floor(owed)
                    owed = owed - spend
                    local left = creditOf(cid)
                    if left <= 0 then
                        log(src, 'call cut: out of credit')
                        BoothEndCall(src, 'nocredit')
                        break
                    end
                    setCredit(cid, left - spend)
                    pushCredit(src, { inCall = true })
                end
            end

            -- Still at the box? The client drops the call when the player walks off, but
            -- the server checks too rather than trusting it to. Skipped, rather than
            -- crashed on, if the call somehow carries no box: billing a call is worth more
            -- than leashing it.
            if call.boothX then
                local ped = GetPlayerPed(src)
                local coords = ped and ped ~= 0 and GetEntityCoords(ped)
                if not coords or #(coords - vector3(call.boothX, call.boothY, call.boothZ))
                    > num(BOOTH.leashDistance, 3.5) + 2.0 then
                    log(src, 'call cut: walked away from the box')
                    BoothEndCall(src, 'boothleft')
                    break
                end
            end
        end

        -- Only stand down if this thread is still the one on duty. A newer call may already
        -- have claimed the slot, and clearing it here would silence that call's meter.
        if Metering[src] == callId then Metering[src] = nil end
    end)
end

--- Stamp the cooldown when the call ENDS, not when it starts, so a long conversation does not
--- earn a free immediate redial. Only runs at all when the option is on.
local function watchForCooldown(src, callId)
    if math.floor(num(BOOTH.cooldownSeconds, 0)) <= 0 then return end
    CreateThread(function()
        while true do
            Wait(1000)
            local call, id = BoothCallOf(src)
            if not call or id ~= callId then break end
        end
        Cooldown[src] = os.time()
    end)
end

V.Callback('v-phone:booth:call', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local booth = atBooth(src, data)
    if not booth then resolve({ error = 'notatbooth' }) return end

    local to = tostring((data and data.number) or ''):gsub('%s', '')
    if to == '' then resolve({ error = 'nonumber' }) return end
    if #to > math.floor(num(BOOTH.maxDialLength, 20)) then resolve({ error = 'nonumber' }) return end

    -- Anti-spam. Counted from when the LAST call ended, so a long conversation does not earn
    -- somebody a free immediate redial. Off by default.
    local wait = math.floor(num(BOOTH.cooldownSeconds, 0))
    if wait > 0 then
        local last = Cooldown[src]
        if last and os.time() - last < wait then
            resolve({ error = 'cooldown', seconds = wait - (os.time() - last) })
            return
        end
    end

    -- Paying for it. An emergency number is free and needs no card; everything else needs
    -- enough credit on the character to be worth connecting.
    local free = isFree() or Booth.IsFreeNumber(to)
    if not free then
        local have = creditOf(p.citizenid)
        local need = math.floor(num(BOOTH.minimumSeconds, 30))
        if have <= 0 then resolve({ error = 'nocredit' }) return end
        if have < need then resolve({ error = 'lowcredit', credit = have, need = need }) return end
    end

    local id, err = BoothCall(src, booth.number, to)
    if not id then resolve({ error = err }) return end

    -- Where the box is, kept on the call so the ticker can tell when the player leaves it.
    local call = BoothCallOf(src)
    if call then
        call.boothX, call.boothY, call.boothZ = booth.x + 0.0, booth.y + 0.0, booth.z + 0.0
    end

    log(src, ('called %s from the box at %s (%s)'):format(to, booth.key, booth.number))
    if not free then startMeter(src, p.citizenid, id) end
    watchForCooldown(src, id)

    resolve({ ok = true, id = id, number = booth.number, to = to, free = free,
              credit = creditOf(p.citizenid) })
end)

V.Callback('v-phone:booth:hangup', function(src, resolve)
    -- The ticker notices the call is gone on its next pass and stands itself down, so the
    -- slot is left alone here: clearing it would race a meter that may already belong to a
    -- newer call.
    BoothEndCall(src, 'hangup')
    resolve({ ok = true })
end)

--- The meter, on demand. The page asks once when it opens; everything after that is pushed.
V.Callback('v-phone:booth:credit', function(src, resolve)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    resolve({ ok = true, credit = creditOf(p.citizenid), free = isFree(),
              hasCard = cardItem() ~= nil and Bridge.ItemCount(src, cardItem()) > 0 or false })
end)

AddEventHandler('playerDropped', function()
    Metering[source] = nil
    Cooldown[source] = nil
end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════
-- A shop that sells talk time, an admin command, a reward for a job. Documented in API.md.

--- Read a character's talk time, in seconds.
exports('GetBoothCredit', function(src)
    local p = Core.GetPlayer(src)
    return p and creditOf(p.citizenid) or 0
end)

--- Give (or take, with a negative) talk time. Returns the new balance.
exports('AddBoothCredit', function(src, seconds)
    local p = Core.GetPlayer(src)
    if not p then return 0 end
    local after = setCredit(p.citizenid, creditOf(p.citizenid) + math.floor(num(seconds, 0)))
    pushCredit(src)
    return after
end)

--- The number of the booth standing at these coordinates, for a dispatch or a script that
--- wants to name the box a call came from.
exports('BoothNumberAt', function(x, y, z) return Booth.NumberAt(x, y, z) end)

--- Is this number a payphone's? The same test the call and SMS paths use.
exports('IsBoothNumber', function(number) return Booth.IsNumber(number) end)
