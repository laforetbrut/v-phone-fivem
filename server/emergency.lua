-- v-phone | server/emergency.lua
--
-- **911: alerting the emergency services from the phone.**
--
-- These are alerts, not calls. A player picks a service and a reason; the people working that
-- service get it on their own phones with a position they can navigate to. If they want to
-- speak to the caller they ring the number back, which is why the number travels with the
-- alert unless the caller asked to stay anonymous.
--
-- Everything that matters is decided here:
--
--   * **where the caller is** comes from their ped on this server, never from the page. An
--     alert whose position the client could name is a way to send a service across the map.
--   * **who receives it** is worked out from the job the framework reports, per service, with
--     the duty and grade rules from the config. The page is told nothing about who else is on
--     the queue until it asks and qualifies.
--   * **who may accept or close one** is checked again on every action. A responder who goes
--     off duty mid-alert cannot keep working it.
--
-- Alerts live in memory, like outages and paid charging stops, and that is deliberate: an
-- alert is about right now. A server that restarts has no shift to hand over.

local CFG = Config.Emergency or {}

local function num(v, d) return tonumber(v) or d or 0 end

local function enabled()
    return CFG.enabled ~= false
end

-- ══════════════════════════════════════════════════════════════
-- Reading the config
-- ══════════════════════════════════════════════════════════════
-- Every setting can be written once at the top and overridden per service, and these two are
-- the only things that know that. Written once, because a rule that is applied in six places
-- is a rule that will one day be applied in five.

--- One setting: the service's own value if it named one, otherwise the global, otherwise `d`.
local function opt(service, key, d)
    if type(service) == 'table' and service[key] ~= nil then return service[key] end
    if CFG[key] ~= nil then return CFG[key] end
    return d
end

--- One block of settings, merged KEY BY KEY rather than replaced. A service that names
--- `blip = { colour = 5 }` means "the usual blip, in red" - not "a blip with nothing else set",
--- which is what a plain override would have given it, and it would have looked like a bug in
--- the blip code rather than in the config.
local function block(service, key)
    local out = {}
    local base = type(CFG[key]) == 'table' and CFG[key] or {}
    for k, v in pairs(base) do out[k] = v end
    local own = type(service) == 'table' and type(service[key]) == 'table' and service[key] or nil
    if own then for k, v in pairs(own) do out[k] = v end end
    return out
end

-- ══════════════════════════════════════════════════════════════
-- The services
-- ══════════════════════════════════════════════════════════════

--- The services an operator configured, with anything that is not one dropped.
---
--- **Every entry is checked for being a table.** `serviceById` and `waitFor` both read `s.id`
--- straight off whatever the list holds, and indexing a number in Lua is a hard error rather
--- than nil - which is what "attempt to index a number value" means when it comes out of this
--- file. One stray value in `Config.Emergency.services` took the whole 911 screen down with a
--- message naming a line nowhere near the config that caused it.
---
--- Dropped rather than repaired: an entry that is not a table has no id, no label and no
--- reasons, so there is nothing to call and nothing a guess would improve.
local function services()
    if type(CFG.services) ~= 'table' then return {} end
    local out = {}
    for _, s in ipairs(CFG.services) do
        if type(s) == 'table' and s.id ~= nil then out[#out + 1] = s end
    end
    return out
end

local function serviceById(id)
    id = tostring(id or '')
    for _, s in ipairs(services()) do
        if tostring(s.id) == id then return s end
    end
    return nil
end

--- Does this character work for this service, right now?
---
--- One function, used both to decide who an alert is sent to and to decide whether somebody
--- may act on one. Two answers to that question would eventually disagree, and the way it
--- would show is a responder who can see an alert they cannot accept.
local function serves(p, service)
    if not p or not service then return false end
    local job = p.job
    if type(job) ~= 'table' then return false end

    local held = false
    for _, name in ipairs(service.jobs or {}) do
        if tostring(name):lower() == tostring(job.name):lower() then held = true break end
    end
    if not held then return false end

    -- `Bridge.OnDuty` rather than the field: ESX and ox have no duty of their own, and a server
    -- that tracks it with esx_service answers through the hook there. See bridge/server/framework.
    if service.onDutyOnly ~= false and Bridge and Bridge.OnDuty
        and not Bridge.OnDuty(p.source, p) then
        return false
    end
    if num(job.grade, 0) < num(service.minGrade, 0) then return false end
    return true
end

--- Every connected player who serves this service.
local function respondersFor(service)
    local out = {}
    for _, raw in ipairs(GetPlayers()) do
        local src = tonumber(raw)
        local p = src and Core.GetPlayer(src)
        if p and serves(p, service) then out[#out + 1] = src end
    end
    return out
end

-- ══════════════════════════════════════════════════════════════
-- The queue
-- ══════════════════════════════════════════════════════════════

local Alerts = {}       -- [id] = alert
local Order = {}        -- ids, newest last
local nextId = 0
-- [citizenid][serviceId] = os.time(). Per service, because the cooldown is per service: a
-- fire brigade paced at ninety seconds and a police line paced at five minutes are two
-- numbers in the config, and one shared timer would quietly apply the longer of them to both.
local LastSent = {}

--- Seconds this character still has to wait before alerting this service.
local function waitFor(cid, service)
    local last = (LastSent[cid] or {})[service.id]
    if not last then return 0 end
    return math.max(0, math.floor(num(opt(service, 'cooldown', 90), 90)) - (os.time() - last))
end

local function expireSeconds(service)
    return math.max(60, math.floor(num(opt(service, 'expireMinutes', 20), 20) * 60))
end

--- Live means: still open, and not older than the expiry. An alert that ages out is not
--- deleted - a service should be able to see what they missed - it just leaves the top.
local function isLive(a)
    if not a or a.state ~= 'open' then return false end
    return (os.time() - a.at) < expireSeconds(serviceById(a.service))
end

--- Trim the oldest closed alerts. Live ones are never dropped, however many there are: a
--- busy night is exactly when a queue must not start forgetting.
local function trim()
    local keep = math.max(5, math.floor(num(CFG.history, 30)))
    local closed = {}
    for _, id in ipairs(Order) do
        local a = Alerts[id]
        if a and not isLive(a) then closed[#closed + 1] = id end
    end
    while #closed > keep do
        local id = table.remove(closed, 1)
        Alerts[id] = nil
        for i, other in ipairs(Order) do
            if other == id then table.remove(Order, i) break end
        end
    end
end

--- How many of their own alerts this character has open right now. Below `isLive`, which it
--- calls: a local used above the line that declares it is a nil global, and this file is where
--- that has already cost the phone a release.
local function openCount(cid)
    local n = 0
    for _, id in ipairs(Order) do
        local a = Alerts[id]
        if a and a.callerCid == cid and isLive(a) then n = n + 1 end
    end
    return n
end

--- What a responder is shown. The caller's identity is stripped here rather than in the page,
--- because a page that receives a name has the name whatever it chooses to draw.
local function alertFor(a, forResponder)
    local out = {
        id = a.id,
        service = a.service,
        reason = a.reason,
        detail = a.detail,
        at = a.at,
        state = a.state,
        anonymous = a.anonymous,
        street = a.street,
        takenBy = a.takenByName,
        source = a.source,
    }
    if forResponder then
        if not a.anonymous then
            out.caller = a.callerName
            out.number = a.callerNumber
        elseif opt(serviceById(a.service), 'anonymousCallback', false) == true then
            -- The operator decided an anonymous caller can still be rung back. The NAME is
            -- still withheld, which is the part that is not recoverable from a number anyway.
            out.number = a.callerNumber
        end
    end
    return out
end

--- The blip an alert should be wearing, or nil if this server does not draw them. Worked out
--- here rather than on the client for the ordinary reason: the client is told what to draw and
--- never what the rules were.
local function blipFor(a, service, state)
    local b = block(service, 'blip')
    if b.enabled == false then return nil end
    return {
        sprite = math.floor(num(b.sprite, 280)),
        colour = math.floor(num(b.colour, 1)),
        scale = num(b.scale, 0.9),
        alpha = math.floor(num(b.alpha, 255)),
        -- What flashes is what nobody has answered yet. A map where every blip flashes is a
        -- map where flashing means nothing.
        flash = b.flash ~= false and (state or a.state) == 'open',
        seconds = math.floor(num(b.seconds, 300)),
        radius = num(b.radius, 0),
        route = b.route == true,
        label = a.reason,
    }
end

--- The alerts one service can see: live ones first, then a short tail of what has been dealt
--- with. Every live alert is shown, however many - a busy night must not hide open calls - but
--- the "dealt with" list is capped, because a service wants recent history, not the whole shift.
local function queueFor(serviceId)
    local live, past = {}, {}
    local pastCap = math.max(0, math.floor(num(CFG.dispatchHistory, 10)))
    for i = #Order, 1, -1 do
        local a = Alerts[Order[i]]
        if a and a.service == serviceId then
            if isLive(a) then
                live[#live + 1] = alertFor(a, true)
            elseif #past < pastCap then
                past[#past + 1] = alertFor(a, true)
            end
        end
    end
    return live, past
end

-- ══════════════════════════════════════════════════════════════
-- Raising one
-- ══════════════════════════════════════════════════════════════

--- The heart of it. Everything else is a way of calling this.
---
--- `coords` is optional: an alert raised by another script is about wherever that script says
--- it happened, and one raised from a phone is about where the caller's ped is. What is never
--- accepted is a position from the PAGE.
local function raise(o)
    local service = serviceById(o.service)
    if not service then return nil, 'noservice' end

    nextId = nextId + 1
    local id = nextId
    local a = {
        id = id,
        service = service.id,
        reason = tostring(o.reason or ''):gsub('[%c]', ''):sub(1, 80),
        detail = tostring(o.detail or ''):gsub('[%c]', ''):sub(1, math.max(0, math.floor(num(CFG.maxText, 200)))),
        at = os.time(),
        state = 'open',
        anonymous = o.anonymous == true,
        coords = o.coords,
        street = o.street,
        callerName = o.callerName,
        callerNumber = o.callerNumber,
        callerCid = o.callerCid,
        source = o.source,
    }
    Alerts[id] = a
    Order[#Order + 1] = id
    trim()

    -- The map pin every responder gets without pressing anything. The coordinates travel with
    -- it, which is a deliberate exception to the rule that they stay here: the recipients are
    -- already filtered to people working that service, and each of them could ask for the same
    -- coordinates with "Take me there" a second later. What it buys is a service that sees an
    -- emergency on the map instead of one that has to be reading its phone to notice.
    --
    -- Turn `blip.auto` off and the position stays on the server until somebody asks.
    local pin = nil
    local b = block(service, 'blip')
    if a.coords and b.enabled ~= false and b.auto ~= false then
        pin = blipFor(a, service)
        pin.x, pin.y, pin.z = a.coords.x + 0.0, a.coords.y + 0.0, (a.coords.z or 0.0) + 0.0
    end

    -- Everybody working that service, and nobody else.
    local sent = 0
    for _, src in ipairs(respondersFor(service)) do
        TriggerClientEvent('v-phone:client:911', src, {
            alert = alertFor(a, true),
            service = { id = service.id, label = service.label, tint = service.tint,
                        icon = service.icon },
            sound = opt(service, 'sound', true) ~= false,
            file = tostring(opt(service, 'alertSound', 'alert911')),
            volume = num(opt(service, 'alertVolume', 0.85), 0.85),
            vibrate = opt(service, 'vibrate', true) ~= false,
            peek = opt(service, 'peek', true) ~= false,
            pin = pin,
        })
        sent = sent + 1
    end

    Core.Log('911', ('%s alert #%d: %s%s'):format(service.id, id, a.reason,
        sent == 0 and ' (nobody on duty)' or (' -> %d responder(s)'):format(sent)))
    return id, sent
end

-- ══════════════════════════════════════════════════════════════
-- What the app asks for
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:911:open', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    -- The services a caller may pick, with their reasons. Sent every time rather than cached
    -- on the page: an operator editing the config and restarting should not need every player
    -- to reload their phone.
    local out = {}
    local soonest = nil
    for _, s in ipairs(services()) do
        local wait = waitFor(p.citizenid, s)
        if wait > 0 and (soonest == nil or wait < soonest) then soonest = wait end
        out[#out + 1] = {
            id = s.id, label = s.label, icon = s.icon, tint = s.tint,
            reasons = s.reasons or {},
            -- Whether THIS player answers for it, which is what decides if the queue is
            -- drawn at all.
            responder = serves(p, s),
            -- Per service, because the cooldown is. A caller who has just alerted the police
            -- can still call an ambulance, and the app has to show that rather than a single
            -- greyed-out list.
            wait = wait > 0 and wait or nil,
            anonymous = opt(s, 'anonymous', true) ~= false,
            allowOther = opt(s, 'allowOther', true) ~= false,
            maxText = math.floor(num(opt(s, 'maxText', 200), 200)),
        }
    end

    -- Their own recent alerts, so a caller can see whether anybody picked it up. Capped small:
    -- the useful thing is "was my last shout answered", not a diary of every call.
    local mine = {}
    local mineCap = math.max(0, math.floor(num(CFG.callerHistory, 3)))
    for i = #Order, 1, -1 do
        local a = Alerts[Order[i]]
        if a and a.callerCid == p.citizenid then
            mine[#mine + 1] = alertFor(a, false)
            if #mine >= mineCap then break end
        end
    end

    -- And the queues they answer for.
    local queues = {}
    for _, s in ipairs(services()) do
        if serves(p, s) then
            local live, past = queueFor(s.id)
            local d = block(s, 'dispatch')
            queues[#queues + 1] = { id = s.id, label = s.label, tint = s.tint, icon = s.icon,
                                    live = live,
                                    past = d.showPast ~= false and past or {} }
        end
    end

    resolve({
        ok = true,
        services = out,
        mine = mine,
        queues = queues,
        -- The global defaults, for a page drawing something before it knows which service is
        -- being called. Each service row above carries its own, and those win.
        anonymous = CFG.anonymous ~= false,
        allowOther = CFG.allowOther ~= false,
        maxText = math.floor(num(CFG.maxText, 200)),
        cooldown = soonest,
    })
end)

V.Callback('v-phone:911:send', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local service = serviceById(data and data.service)
    if not service then resolve({ error = 'noservice' }) return end

    -- A phone is needed. Signal and battery are not, unless the operator says so - the one
    -- call that has to work is the one made from a tunnel by somebody nearly out of charge.
    --
    -- Through the exports rather than the functions themselves: the item check, the signal
    -- and the battery all live as locals in server/main.lua, and a second copy of any of them
    -- here is a second answer waiting to disagree with the first.
    local self = exports[GetCurrentResourceName()]
    if CFG.requireItem ~= false and not self:PhoneUsable(src) then
        -- `PhoneUsable` is item AND charge. When the operator has not asked for the battery to
        -- matter, a flat phone must still be able to call - so a failure here is only final
        -- if the battery is not the reason.
        if CFG.requireBattery == true or self:GetBattery(src) > 0 then
            resolve({ error = 'nophone' })
            return
        end
    end
    if CFG.requireSignal == true and not self:HasSignal(src) then
        resolve({ error = 'nosignal' })
        return
    end
    if CFG.requireBattery == true and self:GetBattery(src) <= 0 then
        resolve({ error = 'nobattery' })
        return
    end

    local wait = waitFor(p.citizenid, service)
    if wait > 0 then
        resolve({ error = 'cooldown', wait = wait })
        return
    end

    -- The cooldown paces somebody in a panic; this stops one character owning the board. Both
    -- are needed: ten alerts ninety seconds apart is still ten alerts.
    local cap = math.floor(num(opt(service, 'maxOpenPerPlayer', 3), 3))
    if cap > 0 and openCount(p.citizenid) >= cap then
        resolve({ error = 'toomany' })
        return
    end

    -- The position of the phone's OWNER. Staff holding somebody's phone and raising an alert
    -- for them must send help to that player, not to the staff member's own body.
    local ped = GetPlayerPed(PhoneActingSource and PhoneActingSource(src) or src)
    if not ped or ped == 0 then resolve({ error = 'x' }) return end
    local coords = GetEntityCoords(ped)

    local anonymous = (opt(service, 'anonymous', true) ~= false)
        and (data and data.anonymous == true) or false
    local id, sent = raise({
        service = service.id,
        reason = data and data.reason,
        detail = (opt(service, 'allowOther', true) ~= false) and (data and data.detail) or nil,
        coords = coords,
        anonymous = anonymous,
        callerName = p.name,
        callerNumber = exports[GetCurrentResourceName()]:GetNumber(p.citizenid),
        callerCid = p.citizenid,
        source = 'phone',
    })
    if not id then resolve({ error = sent or 'x' }) return end

    LastSent[p.citizenid] = LastSent[p.citizenid] or {}
    LastSent[p.citizenid][service.id] = os.time()
    -- `sent` is told to the caller on purpose. "Nobody is on duty" is information somebody in
    -- trouble should have, rather than waiting beside a silent phone for a service that has
    -- nobody working it.
    resolve({ ok = true, id = id, responders = sent })
end)

-- ══════════════════════════════════════════════════════════════
-- Telling everybody what happened to an alert
-- ══════════════════════════════════════════════════════════════

--- The service's maps, once an alert stops being unanswered. Three settings decide it and they
--- are worth reading together: `clearOnTaken` wipes it for everyone, `onlyTaker` keeps it just
--- for whoever is driving there, and neither leaves it up for the whole service - unflashing,
--- because it is no longer waiting for somebody to go.
local function syncBlips(a, service, taker)
    local b = block(service, 'blip')
    if b.enabled == false or b.auto == false or not a.coords then return end

    local closed = a.state == 'closed'
    local wipeAll = closed and (b.clearOnClosed ~= false) or (not closed and b.clearOnTaken == true)

    local pin = nil
    if not wipeAll then
        pin = blipFor(a, service)
        pin.x, pin.y, pin.z = a.coords.x + 0.0, a.coords.y + 0.0, (a.coords.z or 0.0) + 0.0
        -- A route to an alert somebody else is handling is a route nobody asked for.
        pin.route = pin.route and (taker ~= nil) or false
    end

    for _, src in ipairs(respondersFor(service)) do
        local mine = taker ~= nil and src == taker
        local keep = pin and (b.onlyTaker ~= true or mine)
        TriggerClientEvent('v-phone:client:911blip', src,
            keep and { id = a.id, pin = pin, route = pin.route and mine or false }
                 or { id = a.id, clear = true })
    end
end

--- The caller, who has been waiting. Somebody who shouted for help and heard nothing back
--- cannot tell "on their way" from "nobody is coming", and will shout again - which is how a
--- queue fills up with the same emergency four times.
local function tellCaller(a, service, state, byName)
    if not a.callerCid then return end
    local n = block(service, 'notifyCaller')
    if state == 'taken' and n.taken == false then return end
    if state == 'closed' and n.closed == false then return end

    local caller = Core.GetPlayerByCitizenId(a.callerCid)
    if not caller or not caller.source then return end

    TriggerClientEvent('v-phone:client:911status', caller.source, {
        id = a.id,
        state = state,
        service = { id = service.id, label = service.label, icon = service.icon,
                    tint = service.tint },
        -- Naming the responder is a choice: "somebody is on their way" is the same promise
        -- without telling a stranger which officer to look out for.
        by = n.name ~= false and byName or nil,
        sound = n.sound ~= false,
        vibrate = n.vibrate ~= false,
    })
end

--- Accept an alert. First one to press it owns it, and the rest of the service is told.
V.Callback('v-phone:911:take', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local a = Alerts[math.floor(num(data and data.id, 0))]
    if not a then resolve({ error = 'gone' }) return end
    local service = serviceById(a.service)
    if not serves(p, service) then resolve({ error = 'notyours' }) return end

    local d = block(service, 'dispatch')
    if a.state == 'closed' then resolve({ error = 'gone' }) return end
    if a.state ~= 'open' and d.takeOver ~= true then
        resolve({ error = 'taken', takenBy = a.takenByName })
        return
    end

    a.state = 'taken'
    a.takenBy = p.citizenid
    a.takenByName = p.name
    a.takenAt = os.time()

    if d.notifyService ~= false then
        for _, other in ipairs(respondersFor(service)) do
            TriggerClientEvent('v-phone:client:911update', other,
                { id = a.id, state = a.state, takenBy = a.takenByName })
        end
    else
        TriggerClientEvent('v-phone:client:911update', src,
            { id = a.id, state = a.state, takenBy = a.takenByName })
    end

    syncBlips(a, service, src)
    tellCaller(a, service, 'taken', p.name)
    resolve({ ok = true })
end)

--- Close one. By default anybody serving the service may, not only whoever accepted it: a
--- responder who logs off mid-shift would otherwise leave an alert nobody can clear.
V.Callback('v-phone:911:close', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local a = Alerts[math.floor(num(data and data.id, 0))]
    if not a then resolve({ error = 'gone' }) return end
    local service = serviceById(a.service)
    if not serves(p, service) then resolve({ error = 'notyours' }) return end

    local d = block(service, 'dispatch')
    if d.closeAnyone == false and a.takenBy and a.takenBy ~= p.citizenid then
        resolve({ error = 'nottaker' })
        return
    end

    a.state = 'closed'
    a.closedBy = p.name
    if d.notifyService ~= false then
        for _, other in ipairs(respondersFor(service)) do
            TriggerClientEvent('v-phone:client:911update', other,
                { id = a.id, state = 'closed', takenBy = p.name })
        end
    else
        TriggerClientEvent('v-phone:client:911update', src,
            { id = a.id, state = 'closed', takenBy = p.name })
    end

    syncBlips(a, service, nil)
    tellCaller(a, service, 'closed', p.name)
    resolve({ ok = true })
end)

--- Where it happened. The coordinates never travel with the alert itself - only a responder
--- who asks, and qualifies, is given them, and the client turns them into a waypoint.
V.Callback('v-phone:911:locate', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local a = Alerts[math.floor(num(data and data.id, 0))]
    if not a or not a.coords then resolve({ error = 'gone' }) return end
    if not serves(p, serviceById(a.service)) then resolve({ error = 'notyours' }) return end

    local service = serviceById(a.service)
    local b = block(service, 'blip')
    TriggerClientEvent('v-phone:client:911locate', src, {
        id = a.id,
        x = a.coords.x + 0.0, y = a.coords.y + 0.0, z = a.coords.z + 0.0,
        label = a.reason,
        -- The waypoint is the point of the button. It is separate from the automatic blip and
        -- always the exact spot, radius or no radius: a responder pressed a button that says
        -- "take me there", which is not the same as a service being shown an area to search.
        waypoint = b.waypointOnLocate ~= false,
        route = b.route == true,
        blip = blipFor(a, service),
    })
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- For other scripts
-- ══════════════════════════════════════════════════════════════
-- A till under robbery, a fire that started itself, a player who went down with nobody
-- around. See API.md.

--- Raise an alert from anywhere.
---
---     exports['v-phone']:CreateAlert({
---         service = 'police',
---         reason  = 'Store robbery',
---         detail  = '24/7 on Route 68',
---         coords  = vector3(1959.0, 3740.0, 32.3),   -- or `source = playerId`
---     })
---
--- Returns the alert id and how many responders it reached, or false and a reason. The count
--- is worth acting on: a script that raises an alert nobody received may want to do something
--- else as well.
exports('CreateAlert', function(o)
    if not enabled() then return false, 'off' end
    if type(o) ~= 'table' then return false, 'args' end

    local coords = o.coords
    local callerName, callerNumber, callerCid = o.callerName, o.callerNumber, nil

    -- A player id is the friendlier way to say "where this happened and who it is about".
    local src = tonumber(o.source)
    if src then
        local p = Core.GetPlayer(src)
        -- The position of the phone's OWNER. Staff holding somebody's phone and raising an alert
    -- for them must send help to that player, not to the staff member's own body.
    local ped = GetPlayerPed(PhoneActingSource and PhoneActingSource(src) or src)
        if not coords and ped and ped ~= 0 then coords = GetEntityCoords(ped) end
        if p then
            callerCid = p.citizenid
            callerName = callerName or p.name
            callerNumber = callerNumber
                or exports[GetCurrentResourceName()]:GetNumber(p.citizenid)
        end
    end

    if coords and type(coords) == 'table' and coords.x == nil then
        -- A plain { x, y, z } array, which is what json.decode gives a caller that came over
        -- the wire. Accepted rather than refused: the shape is unambiguous.
        coords = { x = num(coords[1], 0), y = num(coords[2], 0), z = num(coords[3], 0) }
    end

    local id, sent = raise({
        service = o.service,
        reason = o.reason,
        detail = o.detail,
        coords = coords,
        anonymous = o.anonymous == true,
        callerName = callerName,
        callerNumber = callerNumber,
        callerCid = callerCid,
        source = tostring(o.from or 'script'),
    })
    if not id then return false, sent end
    return id, sent
end)

--- Read a service's live queue, for a dispatch board or an MDT of your own.
exports('GetAlerts', function(serviceId)
    local live = queueFor(tostring(serviceId or ''))
    return live
end)

--- Close one from outside - a script that resolved whatever raised it.
---
--- The same path a responder's Close button takes, deliberately: the blips come off the maps
--- and the caller is told. A script that resolves an emergency silently leaves everybody who
--- was told about it still believing in it.
local function closeAlert(id, by)
    local a = Alerts[math.floor(num(id, 0))]
    if not a or a.state == 'closed' then return false end
    a.state = 'closed'
    a.closedBy = by
    local service = serviceById(a.service)
    for _, other in ipairs(respondersFor(service)) do
        TriggerClientEvent('v-phone:client:911update', other,
            { id = a.id, state = 'closed', takenBy = by })
    end
    syncBlips(a, service, nil)
    tellCaller(a, service, 'closed', by)
    return true
end

exports('CloseAlert', function(id) return closeAlert(id, nil) end)

-- ══════════════════════════════════════════════════════════════
-- Housekeeping
-- ══════════════════════════════════════════════════════════════
-- Only runs at all if some service asked for it, and it checks the config each pass rather
-- than at start-up so `restart v-phone` is enough to change your mind.
CreateThread(function()
    while true do
        Wait(30000)
        if enabled() then
            for _, id in ipairs(Order) do
                local a = Alerts[id]
                if a and a.state == 'taken' and a.takenAt then
                    local mins = num(opt(serviceById(a.service), 'autoCloseMinutes', 0), 0)
                    if mins > 0 and (os.time() - a.takenAt) >= mins * 60 then
                        closeAlert(a.id, a.takenByName)
                    end
                end
            end
        end
    end
end)

--- Which services exist, for a script that wants to offer them somewhere else.
exports('GetEmergencyServices', function()
    local out = {}
    for _, s in ipairs(services()) do
        out[#out + 1] = { id = s.id, label = s.label, jobs = s.jobs }
    end
    return out
end)

AddEventHandler('playerDropped', function()
    -- Nothing to clean: the cooldown is keyed on the character, not the session, so it
    -- survives a reconnect on purpose. Alerts belong to the queue rather than to a player.
end)
