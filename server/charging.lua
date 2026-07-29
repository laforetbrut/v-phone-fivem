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

-- ══════════════════════════════════════════════════════════════
-- Plugged in
-- ══════════════════════════════════════════════════════════════
-- **Being somewhere that charges is not the same as charging.**
--
-- The phone used to fill up the moment a player sat in any car or walked into their own house,
-- which is not what a phone does: a car and a house are places with a cable in them, and the
-- cable has to be picked up. So a charging PLACE now offers a switch in FruitCharge, and the
-- battery moves when the player throws it.
--
-- Off by default in `Config.PlugIn`, and per source, because this is a change of habit for
-- everybody on a running server: an operator turns it on when they want it, and a server that
-- liked the old behaviour never notices this code exists.
--
-- Memory only, exactly like a paid session: being plugged in is "right now", and right now does
-- not survive a restart any more than the player standing there does.

local Plug = {}          -- [src] = { source = 'vehicle' | 'property' | 'charger' | 'external' }

local function plugCfg()
    return Config.PlugIn or {}
end

local function plugOn()
    return plugCfg().enabled == true
end

--- Does THIS source need the switch thrown?
---
--- Per source, because they are not the same promise. A car and a house are places a player
--- lives in for an hour and should not silently top up; a public charger is a thing you walk to
--- on purpose, and making that one opt-in as well is mostly a second tap. `external` is another
--- resource saying "this player is charging" - it already decided, and second-guessing it would
--- break the contract that export is for.
local function plugRequired(source)
    if not plugOn() or source == nil then return false end
    local sources = plugCfg().sources
    if type(sources) ~= 'table' then return false end
    return sources[source] == true
end

--- May the phone take charge from this source?
---
--- Also where UNPLUGGING happens. A player who gets out of the car has not pressed anything, and
--- without this the plug would still be set when they got back in - so the switch would need
--- throwing once per session rather than once per stop, which is the same automatic charging
--- wearing a button. `chargeRateAt` calls this with nil when there is nowhere to plug in, and
--- that call is what lets go.
function PlugOk(src, source)
    src = tonumber(src) or 0
    local p = Plug[src]
    if p and p.source ~= source and plugCfg().unplugOnLeave ~= false then
        -- **Getting out is unplugging.** Stepping out of the car or leaving the property stops
        -- the charge, and getting back in means opening FruitCharge again - which is the point:
        -- a cable that reconnects itself when you sit back down is not a cable.
        --
        -- Said out loud, because it happens while the phone is in a pocket. A player who is not
        -- told simply finds a flat battery later and has nothing to point at.
        Plug[src] = nil
        p = nil
        if plugCfg().notifyOnUnplug ~= false then
            TriggerClientEvent('v-phone:client:unplugged', src)
        end
    end
    if not plugRequired(source) then return true end

    -- **A flat phone plugs itself in.**
    --
    -- The switch lives in FruitCharge, and a phone at 0% does not open - so the one battery
    -- level that has to be recoverable was the one level that could not be. The player was
    -- standing on a charger holding a phone that refused to charge because the way to say
    -- "charge" was inside the thing that would not turn on.
    --
    -- Consent is for topping up a phone somebody is using. There is nothing to consent to when
    -- the handset is dead: plugging it in is the only thing anybody would ever want, and the
    -- switch reappears the moment there is enough charge to open the app and throw it.
    local self = exports[GetCurrentResourceName()]
    if (self:GetBattery(src) or 0) <= 0 then return true end

    return p ~= nil
end

--- Is the switch on, as the app needs to draw it?
function PlugState(src)
    src = tonumber(src) or 0
    local p = Plug[src]
    return p and p.source or nil
end

function PlugDrop(src)
    Plug[tonumber(src) or 0] = nil
end

--- Throw the switch.
---
--- Refused when there is nothing to plug into, from the SERVER's own reading of where the player
--- is - `ChargeSource` is written by the battery tick in server/main.lua from the ped's real
--- position. A client asking to charge in the middle of a field is asking for free battery.
V.Callback('v-phone:charge:plug', function(src, resolve, data)
    if not plugOn() then resolve({ error = 'off' }) return end

    local want = not (data and data.on == false)
    if not want then
        Plug[src] = nil
        resolve({ ok = true, on = false })
        return
    end

    local source = ChargeSource and ChargeSource[src] or nil
    if not source then resolve({ error = 'nowhere' }) return end
    if not plugRequired(source) then resolve({ ok = true, on = true, already = true }) return end

    Plug[src] = { source = source, at = os.time() }
    resolve({ ok = true, on = true, source = source })
end)

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

local Session  = {}   -- [source] = charger id they have paid for, for this visit
local Offer    = {}   -- [source] = { id = charger id, price, account, label, at = os.time() }
local Refused  = {}   -- [source] = { [charger id] = os.time() of the refusal }
local Prompted = {}   -- [source] = { [charger id] = os.time() of the "get the app" nudge }

-- ══════════════════════════════════════════════════════════════
-- The app, and a player's preferences
-- ══════════════════════════════════════════════════════════════
-- FruitCharge does the accepting now. It also carries an auto-accept, which is a standing
-- "yes" to a paid charger up to a price the player set - so a regular is not asked every day.

local function appId()
    return tostring(cfg().appId or 'charging')
end

--- Paid charging goes through the app; a free charger never needs it. Read on every offer so
--- an operator toggling `requireApp` takes effect on the next pass, not the next restart.
local function requiresApp()
    return paidOn() and cfg().requireApp ~= false
end

--- Does this player have FruitCharge installed? Through the export main.lua publishes, which is
--- the one answer to that question; a second copy here would be a second answer to disagree.
local function hasApp(src)
    if not requiresApp() then return true end
    local self = exports[GetCurrentResourceName()]
    local ok, has = pcall(function() return self:PhoneHasApp(src, appId()) end)
    return ok and has == true
end

--- A player's auto-accept preference, persisted on the character so it survives a relog.
local function prefsOf(src)
    local p = Core and Core.GetPlayer(src)
    local m = p and p.GetMetadata and p.GetMetadata('chargePrefs')
    if type(m) ~= 'table' then m = {} end
    return {
        autoAccept = m.autoAccept == true,
        autoMax = math.max(0, math.floor(num(m.autoMax, 0))),
    }
end

--- The hard ceiling on an auto-payment: the smaller of the player's own limit and the config
--- cap. Either being 0 means "no limit from that side"; if both are 0 there is no cap at all,
--- which is the player's own informed choice to make.
local function autoCeiling(src)
    local pr = prefsOf(src)
    local hard = math.max(0, math.floor(num(cfg().autoAcceptMax, 0)))
    local mine = pr.autoMax
    if hard <= 0 then return mine end          -- only the player's limit, if any
    if mine <= 0 then return hard end          -- only the config cap
    return math.min(hard, mine)
end

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
--- Forget everything about a player. Called from main.lua's drop handler.
function PaidChargeDrop(src)
    Session[src], Offer[src], Refused[src], Prompted[src] = nil, nil, nil, nil
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

local function promptedRecently(src, id)
    local mine = Prompted[src]
    local at = mine and mine[id]
    if not at then return false end
    return (os.time() - at) < math.max(0, num(cfg().appPromptFor, 120))
end

local function tellClient(src, payload)
    TriggerClientEvent('v-phone:client:chargeOffer', src, payload)
end

--- Take the money and open the stop. The single money path, called by the accept button and
--- by auto-accept alike: two copies of "charge the player and credit the owner" is two places
--- for the reversal to be forgotten. Returns a result table; never resolves anything itself.
local function doPay(src, charger)
    local price = priceOf(charger)
    if price <= 0 then
        -- Free by the time they said yes: nothing to take, and it charges anyway.
        Session[src] = charger.id
        return { ok = true, free = true, id = charger.id, label = charger.label or charger.id }
    end

    if Session[src] == charger.id then
        return { ok = true, already = true, id = charger.id, label = charger.label or charger.id }
    end

    local purse = (cfg().money == 'bank') and 'bank' or 'cash'
    if not Bridge.RemoveMoney(src, price, purse, 'v-phone: charging') then
        return { error = 'nomoney', price = price }
    end

    -- Paid. The session opens whatever the operator's banking script says next: the player's
    -- money is gone, so refusing to charge the phone would be taking it for nothing.
    Session[src] = charger.id
    Offer[src] = nil
    -- A "no" they have since paid past means nothing. Left in place it would suppress the
    -- offer at this charger on their next visit, which is the visit they have to pay for.
    Refused[src] = nil

    local account = accountOf(charger)
    if account ~= '' then
        local landed = Bridge.AddSociety and Bridge.AddSociety(account, price,
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

    return { ok = true, price = price, label = charger.label or charger.id, id = charger.id }
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
                        -- And a refusal - and a store nudge - is forgotten on the way out.
                        --
                        -- Otherwise a player who said no by accident has no way to change their
                        -- mind: the offer is the only route to paying, and it would not come
                        -- back for the whole cooldown. Walking out and back in is a deliberate
                        -- act, and it reads as asking again - which is exactly what it now is.
                        Refused[src], Prompted[src] = nil, nil
                    elseif Session[src] == charger.id then
                        -- Paid, charging, nothing to say.
                    elseif not offerAlive(src, charger.id)
                        and not refusedRecently(src, charger.id)
                        -- **`batteryOf` is NOT a global**, whatever the comment that used to
                        -- sit here said. It is `local batteryOf` at server/main.lua:35,
                        -- assigned further down - so from this file the name was always nil,
                        -- `batteryOf and ... or 0` was always 0, and `0 < skipAbove` was always
                        -- true. The skip this line exists for never skipped anybody, and the
                        -- guard that was supposed to make it safe is what hid that.
                        and PhoneBattery(src) < skipAbove then
                        -- A nearly-full phone is not a customer, and asking anyway is noise.
                        if not hasApp(src) then
                            -- No app, so nothing to accept an offer WITH: point them at the
                            -- store instead, and not more than once every appPromptFor seconds.
                            if not promptedRecently(src, charger.id) then
                                Prompted[src] = Prompted[src] or {}
                                Prompted[src][charger.id] = os.time()
                                tellClient(src, {
                                    needApp = true,
                                    id = charger.id,
                                    label = tostring(charger.label or charger.id or ''),
                                    price = price,
                                    app = appId(),
                                })
                            end
                        else
                            local pr = prefsOf(src)
                            local cap = autoCeiling(src)
                            if cfg().autoAccept ~= false and pr.autoAccept
                                and (cap <= 0 or price <= cap) then
                                -- A standing yes. Pay silently and tell the phone it happened,
                                -- so the player sees a charge rather than is asked for one.
                                local res = doPay(src, charger)
                                tellClient(src, res.ok
                                    and { auto = true, id = charger.id, price = price,
                                          label = tostring(charger.label or charger.id or '') }
                                    or { autofail = true, error = res.error or 'x',
                                         price = price })
                            else
                                sendOffer(src, charger)
                            end
                        end
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

    -- Paid chargers need the app; the button cannot be pressed without it, but a hand-made
    -- request can, so the gate is here too.
    if priceOf(charger) > 0 and not hasApp(src) then resolve({ error = 'needapp' }) return end

    resolve(doPay(src, charger))
end)

--- Pay for a stop without the screen: `/chargephone`.
---
--- **The one command a dead phone needs.** A paid charger is accepted from FruitCharge, and a
--- phone at 0% does not open - so the player stood on the charger with no way to say yes,
--- holding the one thing that could have said it. Money must still be consented to, which is
--- why this is a command and not an automatic payment.
---
--- Everything is re-read here exactly as the button's path re-reads it: which charger they are
--- standing at, what it costs, and whether they hold the app. `doPay` is the single money path
--- and this does not become a second one.
RegisterCommand('chargephone', function(src)
    src = tonumber(src) or 0
    if src <= 0 then return end

    local function say(msg)
        TriggerClientEvent('chat:addMessage', src, { args = { 'iFruit', msg } })
    end

    if not paidOn() then say(LP(src, 'ph.charge_cmd_off')) return end

    local ped = GetPlayerPed(src)
    local charger = (ped and ped ~= 0) and chargerAt(GetEntityCoords(ped)) or nil
    if not charger then say(LP(src, 'ph.charge_cmd_nowhere')) return end

    if Session[src] == charger.id then say(LP(src, 'ph.charge_cmd_already')) return end
    if priceOf(charger) > 0 and not hasApp(src) then say(LP(src, 'ph.charge_cmd_needapp')) return end

    local res = doPay(src, charger)
    if res and res.ok then
        say(LP(src, 'ph.charge_cmd_paid'):gsub('{price}', tostring(priceOf(charger))))
    else
        say(LP(src, 'ph.err_' .. tostring((res and res.error) or 'x')))
    end
end, false)

-- ══════════════════════════════════════════════════════════════
-- The FruitCharge app
-- ══════════════════════════════════════════════════════════════
-- Locate the chargers, see the one you are standing at, and set the auto-accept. Coordinates
-- DO travel here, unlike a 911 alert's: a public charger is a fixed, published place, and the
-- point of the app is to be taken to one.

V.Callback('v-phone:charging:app', function(src, resolve)
    if not paidOn() and #(Config.Chargers or {}) == 0 then resolve({ error = 'off' }) return end

    local ped = GetPlayerPed(src)
    local here = (ped and ped ~= 0) and GetEntityCoords(ped) or nil
    local atNow = here and chargerAt(here) or nil

    local list = {}
    for _, c in ipairs(Config.Chargers or {}) do
        if c.enabled ~= false and c.enabled ~= 0 then
            local price = priceOf(c)
            local dist = here and #(here - vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0)) or nil
            list[#list + 1] = {
                id = c.id,
                label = tostring(c.label or c.id or ''),
                x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0,
                price = price,          -- 0 is a free charger
                distance = dist and math.floor(dist) or nil,
                here = atNow ~= nil and atNow.id == c.id,
            }
        end
    end
    -- Nearest first when we know where they are, so the one they are most likely to want is at
    -- the top; by name otherwise, so the order is at least stable.
    table.sort(list, function(a, b)
        if a.distance and b.distance then return a.distance < b.distance end
        if a.distance then return true end
        if b.distance then return false end
        return a.label < b.label
    end)

    local pr = prefsOf(src)
    resolve({
        ok = true,
        chargers = list,
        session = Session[src] or nil,          -- the charger they have already paid for
        offer = Offer[src] and { id = Offer[src].id, label = Offer[src].label,
                                 price = Offer[src].price } or nil,
        atCharger = atNow and { id = atNow.id, label = tostring(atNow.label or atNow.id or ''),
                                price = priceOf(atNow) } or nil,
        money = (cfg().money == 'bank') and 'bank' or 'cash',
        prefs = { autoAccept = pr.autoAccept, autoMax = pr.autoMax },
        autoAcceptOn = cfg().autoAccept ~= false,   -- whether the option is offered at all
        autoMaxCap = math.max(0, math.floor(num(cfg().autoAcceptMax, 0))),
        -- The switch. `source` is what is here, `needs` is whether it has to be thrown, and `on`
        -- is whether it has been - three separate facts, because "in a car with the phone
        -- unplugged" and "nowhere near a socket" look identical if you only send one boolean.
        plug = plugOn() and {
            source = ChargeSource and ChargeSource[src] or nil,
            needs = plugRequired(ChargeSource and ChargeSource[src] or nil),
            on = PlugState(src) ~= nil,
        } or nil,
    })
end)

V.Callback('v-phone:charging:prefs', function(src, resolve, data)
    local p = Core and Core.GetPlayer(src)
    if not p or not p.SetMetadata then resolve({ error = 'x' }) return end

    local autoAccept = (cfg().autoAccept ~= false) and (data and data.autoAccept == true) or false
    local autoMax = math.max(0, math.floor(num(data and data.autoMax, 0)))
    -- Kept no higher than the config's hard cap: a player cannot raise their own ceiling above
    -- what the operator allows, only lower it.
    local hard = math.max(0, math.floor(num(cfg().autoAcceptMax, 0)))
    if hard > 0 and (autoMax == 0 or autoMax > hard) then autoMax = hard end

    -- Waited on: an auto-accept ceiling is a decision about money, and it has to survive a
    -- restart or the next paid charger asks again.
    p.SetMetadataSync('chargePrefs', { autoAccept = autoAccept, autoMax = autoMax })
    resolve({ ok = true, autoAccept = autoAccept, autoMax = autoMax })
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
