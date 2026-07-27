-- v-phone | client/repair.lua
--
-- **The doc-mechanicmdt side of the Repair app.**
--
-- doc-mechanicmdt publishes everything its own phone app used, and it publishes it on the
-- FRAMEWORK rather than on itself - six QB server callbacks, so any client may call one:
--
--     doc-mechanicmdt:server:getPublicGarages   -> { garages = { { job, name, logo, coords{x,y},
--                                                                 is_open, rating{moyenne,nb_votes} } } }
--     doc-mechanicmdt:server:getMyGarageRatings -> { mine = { [job] = { etoiles, commentaire } },
--                                                    eligible = { [job] = true } }
--     doc-mechanicmdt:server:rateGarage    { job, etoiles, commentaire }
--                                          -> false | { ok, nb_votes, moyenne }
--     doc-mechanicmdt:server:createCall    { job, message, name, phone, coords{x,y} }
--                                          -> false | { ok=false, closed=true }
--                                                   | { ok=false, already=true } | { ok=true, id }
--     doc-mechanicmdt:server:getMyCall     { job } -> nil | { id, status, handled_by }
--     doc-mechanicmdt:server:cancelMyCall  { job } -> true
--
-- And two more that only staff may use, which is what gives the app its other half - the queue,
-- on a phone, for a mechanic who is out on a job and nowhere near the tablet:
--
--     doc-mechanicmdt:server:getGarageCalls    -> { { id, client_name, client_phone, message,
--                                                     pos_x, pos_y, status, handled_by, created_at } }
--     doc-mechanicmdt:server:updateCallStatus  { id, action } -> boolean
--         action: accept | ongoing | onhold | done | refused
--
-- That is the whole integration: this file asks the same eight questions its own tablet and its
-- own iframe asked. **doc-mechanicmdt is not edited, patched, wrapped or replaced.** Every
-- permission - who may see a queue, who may review, whether a garage is open - stays its
-- decision, and it re-checks each one on the way in.
--
-- **The position is put in by the client, deliberately.** Its `createCall` reads `data.coords`
-- and its own app filled that in the same way, so this does too - and rounds it the same way it
-- did, because a callout is a place to drive to and not a survey marker.

local function repairOn()
    return (Config.Repair or {}).enabled ~= false
end

--- Is doc-mechanicmdt the provider?
local function docMode()
    if not repairOn() then return false end
    local want = tostring((Config.Repair or {}).provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-mechanicmdt' then return true end
    return GetResourceState('doc-mechanicmdt') == 'started'
end

--- qb-core's shared object, fetched once and only if it is there.
---
--- Same reason as client/lottery.lua, client/alerts.lua and client/taxi.lua: v-phone holds no
--- framework object of its own, and a QB server callback is only reachable through
--- `QBCore.Functions.TriggerCallback`.
local QB, qbChecked = nil, false

local function qbCore()
    if qbChecked then return QB end
    qbChecked = true
    if GetResourceState('qb-core') ~= 'started' then return nil end
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    QB = ok and core or nil
    return QB
end

--- Ask one of its callbacks and answer the page.
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

--- Where the phone is, rounded the way its own app rounded it.
local function here()
    local c = GetEntityCoords(PlayerPedId())
    return { x = math.ceil(c.x * 100) / 100, y = math.ceil(c.y * 100) / 100 }, c
end

-- ══════════════════════════════════════════════════════════════
-- What the page asks for
-- ══════════════════════════════════════════════════════════════

RegisterNUICallback('repairOpen', function(_, cb)
    V.Request('v-phone:repair:open', function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('repairCall', function(data, cb)
    V.Request('v-phone:repair:call', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('repairCancel', function(data, cb)
    V.Request('v-phone:repair:cancel', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('repairQueue', function(_, cb)
    V.Request('v-phone:repair:queue', function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('repairHandle', function(data, cb)
    V.Request('v-phone:repair:handle', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('repairReview', function(data, cb)
    V.Request('v-phone:repair:review', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('repairReviews', function(data, cb)
    V.Request('v-phone:repair:reviews', function(res) cb(res or { error = 'x' }) end, data or {})
end)

--- Both providers' "get me somebody on the phone", which is the phone's own question either way.
RegisterNUICallback('repairNumber', function(data, cb)
    local which = tostring((data and data.of) or 'garage')
    local event = (which == 'client') and 'v-phone:repair:clientNumber'
                                       or 'v-phone:repair:garageNumber'
    V.Request(event, function(res) cb(res or { error = 'x' }) end, data or {})
end)

--- A route to a garage, or to a customer who is waiting.
---
--- The phone's own waypoint rather than doc-mechanicmdt's `phoneSetGPS`, because that callback
--- belongs to its resource and is only reachable from its own iframe. The native is the same
--- one it calls.
RegisterNUICallback('repairRoute', function(data, cb)
    local x, y = tonumber(data and data.x), tonumber(data and data.y)
    if not x or not y or (x == 0.0 and y == 0.0) then cb({ error = 'nowhere' }) return end
    SetNewWaypoint(x + 0.0, y + 0.0)
    cb({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Everything that only exists under doc-mechanicmdt
-- ══════════════════════════════════════════════════════════════

RegisterNUICallback('repairDoc', function(data, cb)
    if not docMode() then cb({ error = 'notdoc' }) return end
    local op = tostring((data and data.op) or 'garages')

    -- The garages, their state, their score, and what this player has already written about
    -- them - two of its callbacks, merged into the shape the page already draws so that neither
    -- provider is visible from up there.
    if op == 'garages' then
        ask('doc-mechanicmdt:server:getPublicGarages', nil, function(res)
            if type(res) ~= 'table' or type(res.garages) ~= 'table' then
                cb({ error = 'nodata' })
                return
            end
            local _, coords = here()

            ask('doc-mechanicmdt:server:getMyGarageRatings', nil, function(mine)
                mine = type(mine) == 'table' and mine or {}
                local written = type(mine.mine) == 'table' and mine.mine or {}
                local eligible = type(mine.eligible) == 'table' and mine.eligible or {}

                local out = {}
                for _, g in ipairs(res.garages) do
                    local job = tostring(g.job or '')
                    local c = type(g.coords) == 'table' and g.coords or {}
                    local x, y = tonumber(c.x), tonumber(c.y)
                    local rating = type(g.rating) == 'table' and g.rating or {}
                    local rev = written[job]
                    out[#out + 1] = {
                        job = job,
                        label = tostring(g.name or job),
                        x = x, y = y,
                        -- A garage it places at the origin is one it does not consider open to
                        -- the public - its own config says so in a comment - so the distance is
                        -- left out rather than measured to the middle of the ocean.
                        distance = (x and y and not (x == 0.0 and y == 0.0))
                            and math.floor(#(coords - vector3(x + 0.0, y + 0.0, coords.z))) or nil,
                        open = g.is_open == true,
                        votes = math.floor(tonumber(rating.nb_votes) or 0),
                        average = math.floor((tonumber(rating.moyenne) or 0) * 10 + 0.5) / 10,
                        -- Its eligibility rule is an INVOICE from that garage, which is stricter
                        -- than a completed callout and is the right rule: it is their business.
                        canReview = eligible[job] == true,
                        myReview = rev and {
                            stars = math.floor(tonumber(rev.etoiles) or 0),
                            comment = tostring(rev.commentaire or ''),
                        } or nil,
                    }
                end
                cb({ ok = true, doc = true, garages = out })
            end)
        end)
        return
    end

    -- The state of my callout at one garage. Asked per garage because that is the shape of its
    -- callback: it is keyed on the job, and it has no "all of mine" answer.
    if op == 'mycall' then
        ask('doc-mechanicmdt:server:getMyCall', { job = tostring((data and data.job) or '') },
            function(res)
                if type(res) ~= 'table' then cb({ ok = true, call = nil }) return end
                cb({ ok = true, call = {
                    id = math.floor(tonumber(res.id) or 0),
                    status = tostring(res.status or 'pending'),
                    by = tostring(res.handled_by or ''),
                } })
            end)
        return
    end

    if op == 'create' then
        local body = (type(data) == 'table' and type(data.call) == 'table') and data.call or {}
        local pos = here()
        ask('doc-mechanicmdt:server:createCall', {
            job = tostring(body.job or ''),
            message = tostring(body.message or ''),
            -- Its column names, not ours: `phone`, and it is a free-text field the player may
            -- edit or clear. That field IS how a garage rings back, which is why the app fills
            -- it with the real number rather than leaving it blank.
            name = tostring(body.name or ''),
            phone = tostring(body.number or ''),
            coords = pos,
        }, function(res)
            if type(res) ~= 'table' then cb({ error = 'refused' }) return end
            if res.ok == true then cb({ ok = true, id = res.id }) return end
            -- Its two named refusals, passed through as themselves: "the garage is shut" and
            -- "you already have one open there" are different things to be told.
            if res.closed then cb({ error = 'closed' }) return end
            if res.already then cb({ error = 'already' }) return end
            cb({ error = 'refused' })
        end)
        return
    end

    if op == 'cancel' then
        ask('doc-mechanicmdt:server:cancelMyCall', { job = tostring((data and data.job) or '') },
            function(res) cb({ ok = res ~= false }) end)
        return
    end

    if op == 'rate' then
        local body = (type(data) == 'table' and type(data.review) == 'table') and data.review or {}
        ask('doc-mechanicmdt:server:rateGarage', {
            job = tostring(body.job or ''),
            etoiles = tonumber(body.stars),
            commentaire = tostring(body.comment or ''),
        }, function(res)
            if type(res) == 'table' and res.ok then
                cb({ ok = true,
                     votes = math.floor(tonumber(res.nb_votes) or 0),
                     average = math.floor((tonumber(res.moyenne) or 0) * 10 + 0.5) / 10 })
                return
            end
            -- It refuses with a bare `false` and raises its own notification saying why - "you
            -- must have been a customer here". Passed through as a refusal rather than dressed
            -- up: inventing a reason here would mean guessing which of its checks failed.
            cb({ error = 'refused' })
        end)
        return
    end

    -- ── the mechanic's side ────────────────────────────────────
    if op == 'queue' then
        ask('doc-mechanicmdt:server:getGarageCalls', nil, function(res)
            if type(res) ~= 'table' then cb({ error = 'notstaff' }) return end
            local out = {}
            for _, r in ipairs(res) do
                out[#out + 1] = {
                    id = math.floor(tonumber(r.id) or 0),
                    name = tostring(r.client_name or ''),
                    number = tostring(r.client_phone or ''),
                    message = tostring(r.message or ''),
                    x = tonumber(r.pos_x) or 0.0,
                    y = tonumber(r.pos_y) or 0.0,
                    status = tostring(r.status or 'pending'),
                    by = tostring(r.handled_by or ''),
                }
            end
            cb({ ok = true, calls = out })
        end)
        return
    end

    if op == 'handle' then
        -- Its verbs, which are not quite the phone's: it takes `accept` where the status it
        -- writes is `accepted`. Translated here rather than teaching the page two vocabularies.
        local ACTION = { accepted = 'accept', ongoing = 'ongoing', onhold = 'onhold',
                         done = 'done', refused = 'refused' }
        local action = ACTION[tostring((data and data.action) or '')]
        local id = tonumber(data and data.id)
        if not action or not id then cb({ error = 'args' }) return end
        ask('doc-mechanicmdt:server:updateCallStatus', { id = id, action = action },
            function(res) cb(res == true and { ok = true } or { error = 'refused' }) end)
        return
    end

    cb({ error = 'x' })
end)

-- ══════════════════════════════════════════════════════════════
-- Arriving
-- ══════════════════════════════════════════════════════════════

--- A callout has come in, on a mechanic's phone.
---
--- Config provider only. doc-mechanicmdt raises its own notification through the framework and
--- plays its own alert sound to every on-duty employee, so a second banner here would be the
--- same message twice - and the phone is not the authority on its queue.
RegisterNetEvent('v-phone:client:repairCall', function(d)
    if type(d) ~= 'table' or not PhoneNotify then return end
    PhoneNotify({
        app = 'repair', icon = 'repair',
        title = (PhoneString and PhoneString('ph.repair_new_call')) or 'Callout',
        body = tostring(d.name or '') ..
            ((d.message or '') ~= '' and (' - ' .. tostring(d.message)) or ''),
        hasItem = true,
    })
    SendNUIMessage({ action = 'repairQueue' })
end)

--- My callout moved. Config provider only, for the same reason.
RegisterNetEvent('v-phone:client:repairStatus', function(d)
    if type(d) ~= 'table' then return end
    -- The page updates whether or not it is open: an app that has to be reopened to notice is
    -- an app that shows a stale status the moment somebody comes back to it.
    SendNUIMessage({ action = 'repairStatus', update = d })
    if not PhoneNotify then return end
    PhoneNotify({
        app = 'repair', icon = 'repair',
        title = tostring(d.label or ''),
        body = (PhoneString and PhoneString('ph.repair_s_' .. tostring(d.status or ''))) or '',
        hasItem = true,
    })
end)
