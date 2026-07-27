-- v-phone | server/charging.lua
--
-- **A public charger that takes money.**
--
-- The shape of it, in one paragraph: a player stands in a paid charger's zone, the phone asks
-- whether they want to pay, they accept or refuse, and one payment buys the whole stop. They
-- charge for as long as they like and pay again only if they LEAVE the zone and come back.
-- Nothing is metered - a meter that ticks while somebody is stood at a kiosk is a thing to
-- watch instead of a thing to forget about, and this is a phone, not a job.
--
-- Everything here is decided from the ped's real position on the server. The client is told
-- what is being offered and answers yes or no; it never says where it is standing, what a stop
-- costs, or whether it already paid. That is not paranoia about players so much as the same
-- rule the rest of this resource follows: the side that holds the money holds the truth.
--
-- Loaded BEFORE server/main.lua, whose `chargeRateAt` asks `PaidChargeOk` on every battery
-- tick - the same arrangement as server/outage.lua and `OutageCeiling`. Sessions are memory
-- only and deliberately so: a session is "this visit", and a visit does not survive a restart
-- any more than the player standing there does.

local function cfg()
    return Config.PaidCharging or {}
end

local function paidOn()
    return cfg().enabled ~= false
end

local function num(v, fallback)
    local n = tonumber(v)
    if not n then return fallback end
    return n
end

--- What a stop at this charger costs, or 0 for a free one.
---
--- A row's own `price` wins over the default, including a row that says `price = 0` on a
--- server whose default is a charge: a charger can be deliberately free.
local function priceOf(charger)
    if not paidOn() then return 0 end
    local price = charger and charger.price
    if price == nil then price = cfg().price end
    return math.max(0, math.floor(num(price, 0)))
end

--- Where the money goes. The charger's own account wins, so different sites can pay
--- different owners.
local function accountOf(charger)
    local account = charger and charger.account
    if account == nil or account == '' then account = cfg().account end
    return tostring(account or '')
end

-- ══════════════════════════════════════════════════════════════
-- Who is standing where
-- ══════════════════════════════════════════════════════════════

--- The charger a position is inside, or nil.
---
--- Same list and same radius rule as `chargeRateAt` in main.lua, on purpose: two different
--- answers to "am I at a charger" would show up as a phone that charges without paying or
--- asks for money at a kiosk it is not standing at.
local function chargerAt(coords)
    for _, c in ipairs(Config.Chargers or {}) do
        if c.enabled ~= false and c.enabled ~= 0 then
            if #(coords - vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0)) <= (c.radius or 3.0) then
                return c
            end
        end
    end
    return nil
end

local Session = {}    -- [source] = charger id they have paid for, for this visit
local Offer   = {}    -- [source] = { id = charger id, price, account, label, at = os.time() }
local Refused = {}    -- [source] = os.time() of the refusal, per charger id: [src] = { [id] = at }

--- Has this player paid for the charger they are standing at?
---
--- Read by `chargeRateAt` on every battery tick. A free charger answers true without anything
--- being stored, which is what keeps a server that never sets a price completely unaffected by
--- any of this.
function PaidChargeOk(src, charger)
    if priceOf(charger) <= 0 then return true end
    return Session[src] == charger.id
end

--- Is this charger a paid one at all? For the admin panel and the diagnostics.
function PaidChargerPrice(charger)
    return priceOf(charger)
end

--- Forget everything about a player. Called from main.lua's drop handler.
function PaidChargeDrop(src)
    Session[src], Offer[src], Refused[src] = nil, nil, nil
end

-- ══════════════════════════════════════════════════════════════
-- The offer
-- ══════════════════════════════════════════════════════════════

local function refusedRecently(src, id)
    local mine = Refused[src]
    local at = mine and mine[id]
    if not at then return false end
    return (os.time() - at) < math.max(0, num(cfg().refusedFor, 90))
end

local function offerAlive(src, id)
    local o = Offer[src]
    if not o or o.id ~= id then return false end
    return (os.time() - o.at) < math.max(5, num(cfg().offerSeconds, 45))
end

local function tellClient(src, payload)
    TriggerClientEvent('v-phone:client:chargeOffer', src, payload)
end

local function sendOffer(src, charger)
    local price = priceOf(charger)
    Offer[src] = {
        id = charger.id,
        price = price,
        account = accountOf(charger),
        label = tostring(charger.label or charger.id or ''),
        at = os.time(),
    }
    tellClient(src, {
        offer = true,
        id = charger.id,
        label = Offer[src].label,
        price = price,
        money = (cfg().money == 'bank') and 'bank' or 'cash',
        seconds = math.max(5, num(cfg().offerSeconds, 45)),
    })
end

-- One thread for everybody. A handful of distance checks per player every few seconds, which
-- is the same order of work as the battery tick this sits next to.
CreateThread(function()
    while true do
        Wait(math.max(1, num(cfg().checkSeconds, 4)) * 1000)
        if paidOn() and Core then
            local skipAbove = num(cfg().skipAbove, 95)
            for _, raw in ipairs(GetPlayers()) do
                local src = tonumber(raw)
                local ped = src and GetPlayerPed(src)
                if ped and ped ~= 0 then
                    local charger = chargerAt(GetEntityCoords(ped))
                    local price = charger and priceOf(charger) or 0

                    if not charger or price <= 0 then
                        -- Out of every paid zone. The session ends here, which is the whole
                        -- rule of the feature: leaving is what makes the next stop cost again.
                        if Session[src] or Offer[src] then
                            Session[src], Offer[src] = nil, nil
                            tellClient(src, { clear = true })
                        end
                        -- And a refusal is forgotten on the way out.
                        --
                        -- Otherwise a player who said no by accident has no way to change their
                        -- mind: the offer is the only route to paying, and it would not come
                        -- back for the whole cooldown. Walking out and back in is a deliberate
                        -- act, and it reads as asking again - which is exactly what it now is.
                        Refused[src] = nil
                    elseif Session[src] == charger.id then
                        -- Paid, charging, nothing to say.
                    elseif not offerAlive(src, charger.id)
                        and not refusedRecently(src, charger.id)
                        -- `batteryOf` lives in main.lua, which loads after this file. It is a
                        -- global and this thread only ever runs long after both are loaded, but
                        -- the guard costs nothing and the failure mode would be an error every
                        -- four seconds for every player on the server.
                        and (batteryOf and batteryOf(src) or 0) < skipAbove then
                        -- A nearly-full phone is not a customer, and asking anyway is noise.
                        sendOffer(src, charger)
                    end
                end
            end
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Accepting, and refusing
-- ══════════════════════════════════════════════════════════════
-- The page sends nothing but "yes" or "no". Which charger, what it costs and whether the
-- player is still standing there are all read again here.

V.Callback('v-phone:charge:pay', function(src, resolve)
    if not paidOn() then resolve({ error = 'off' }) return end

    local ped = GetPlayerPed(src)
    local charger = (ped and ped ~= 0) and chargerAt(GetEntityCoords(ped)) or nil
    if not charger then resolve({ error = 'notatcharger' }) return end

    local price = priceOf(charger)
    if price <= 0 then
        -- Free by the time they said yes: nothing to take, and it charges anyway.
        Session[src] = charger.id
        resolve({ ok = true, free = true })
        return
    end

    if Session[src] == charger.id then resolve({ ok = true, already = true }) return end

    local purse = (cfg().money == 'bank') and 'bank' or 'cash'
    if not Bridge.RemoveMoney(src, price, purse) then
        resolve({ error = 'nomoney', price = price })
        return
    end

    -- Paid. The session opens whatever the operator's banking script says next: the player's
    -- money is gone, so refusing to charge the phone would be taking it for nothing.
    Session[src] = charger.id
    Offer[src] = nil
    -- A "no" they have since paid past means nothing. Left in place it would suppress the
    -- offer at this charger on their next visit, which is the visit they have to pay for.
    Refused[src] = nil

    local account = accountOf(charger)
    local landed = false
    if account ~= '' then
        landed = Bridge.AddSociety and Bridge.AddSociety(account, price,
            ('v-phone: charging at %s'):format(charger.label or charger.id)) or false
        if not landed then
            -- Printed unconditionally, unlike the audit line below: an operator who set an
            -- account name and never sees the money is looking at a misconfiguration, and a
            -- silent one of those is worse than a line in the console.
            V.Log(('paid charging: could not credit "%s" with %d - check the account exists')
                :format(account, price))
        end
    end

    if cfg().log == true then
        -- Off by default. It is the only paper trail a charge leaves, and it is also a line
        -- per customer per stop, which on a busy server is a lot of console for something an
        -- operator either wants deliberately or not at all.
        V.Log(('paid charging: %s paid %d at %s'):format(tostring(src), price,
            tostring(charger.label or charger.id)))
    end

    -- The battery tick will notice the session on its next pass; this just makes the phone
    -- show it now rather than in twenty seconds.
    resolve({ ok = true, price = price, label = charger.label or charger.id })
end)

V.Callback('v-phone:charge:decline', function(src, resolve)
    local o = Offer[src]
    if o then
        Refused[src] = Refused[src] or {}
        Refused[src][o.id] = os.time()
        Offer[src] = nil
    end
    resolve({ ok = true })
end)

--- Staff: open a stop for somebody without taking their money, or close one.
---
--- The admin panel's "charge their phone" already exists; this is the other half of it for a
--- server that runs paid chargers - an officer with a warrant, a mechanic doing a favour.
exports('SetChargePaid', function(src, on, chargerId)
    src = tonumber(src)
    if not src then return false end
    if on == false then
        Session[src] = nil
        TriggerClientEvent('v-phone:client:chargeOffer', src, { clear = true })
        return true
    end
    local id = chargerId
    if not id then
        local ped = GetPlayerPed(src)
        local charger = (ped and ped ~= 0) and chargerAt(GetEntityCoords(ped)) or nil
        id = charger and charger.id
    end
    if not id then return false end
    Session[src] = id
    return true
end)

--- The server half of `/phonecharge`. Printed into the player's own console, next to what the
--- client just printed, so the two halves of "why is it charging" are read together.
RegisterNetEvent('v-phone:charge:why', function()
    local src = source
    local reason = ChargeReason and ChargeReason[src] or nil
    local lease = ExternalChargeUntil and ExternalChargeUntil[src]
    TriggerClientEvent('chat:addMessage', src, { args = { 'iFruit', ('charging because: %s')
        :format(tostring(reason or 'nothing - it is not charging')) } })
    if lease then
        TriggerClientEvent('chat:addMessage', src, { args = { 'iFruit',
            ('an external script claimed it; that claim expires in %ds'):format(
                math.max(0, lease - os.time())) } })
    end
    if Session[src] then
        TriggerClientEvent('chat:addMessage', src, { args = { 'iFruit',
            ('paid stop open at %s'):format(tostring(Session[src])) } })
    end
end)

--- What the phone knows about this player's stop. For /phoneadmin and the diagnostics.
exports('GetChargeSession', function(src)
    src = tonumber(src)
    if not src then return nil end
    return { charger = Session[src], offered = Offer[src] and Offer[src].id or nil }
end)
