-- v-phone | client/alerts.lua
--
-- **The doc-civilalerte side of the Alerts app.**
--
-- doc-civilalerte publishes everything its own iframe needed, and it publishes it on the
-- FRAMEWORK rather than on itself:
--
--     doc-civilalerte:server:getAlerts    a QB server callback -> { alerts, serverTime, myCid, isStaff }
--     doc-civilalerte:server:emit         a net event -> { category, title, message, durationMinutes }
--     doc-civilalerte:server:delete       a net event -> alertId
--
-- A server callback is registered on the framework and not on the resource, so **any client may
-- call one**, and a net event registered with `RegisterNetEvent` may be triggered by any client -
-- which is safe here because doc-civilalerte re-checks job, grade, duty, category, content and
-- ownership on the way in, exactly as it should. That is the whole integration: this file asks the
-- same questions its own app asked. **doc-civilalerte is not edited, patched, wrapped or replaced.**
--
-- It also BROADCASTS, to everybody:
--
--     doc-civilalerte:client:newAlert     a fresh alert, the full row
--     doc-civilalerte:client:alertDeleted an id that has been withdrawn
--
-- Both are listened for here, so the phone raises a banner the moment an alert goes out and the
-- app drops a withdrawn card without waiting to be reopened. Its own app could not do the first of
-- those: it kept an unread counter and found out what was in it later.
--
-- **What this file cannot answer is whether YOU may broadcast.** doc-civilalerte keeps that
-- decision to itself and publishes no way to ask, so the composer is offered from the mirrored
-- `Config.Alerts.emitters` list. Get the mirror wrong and the composer appears for somebody whose
-- alert is then refused by doc-civilalerte - annoying, and never dangerous, because the refusal is
-- its own and it is authoritative.

local function alertsOn()
    return (Config.Alerts or {}).enabled ~= false
end

--- Is doc-civilalerte the provider?
local function docMode()
    if not alertsOn() then return false end
    local want = tostring((Config.Alerts or {}).provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-civilalerte' then return true end
    return GetResourceState('doc-civilalerte') == 'started'
end

--- qb-core's shared object, fetched once and only if it is there.
---
--- Same reason as client/lottery.lua, client/zuber.lua and client/taxi.lua: v-phone holds no
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

--- Ask doc-civilalerte's callback and answer the page.
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
-- Shape
-- ══════════════════════════════════════════════════════════════

--- One of doc-civilalerte's rows, in the shape the page already draws.
---
--- Its column names are its own - `emitter_name`, `created_at`, `expires_at` - and translating
--- here rather than teaching the page two vocabularies is what keeps the app from having to know
--- which provider answered.
local function shape(r, now)
    if type(r) ~= 'table' then return nil end
    local expires = math.floor(tonumber(r.expires_at) or 0)
    return {
        id = math.floor(tonumber(r.id) or 0),
        category = tostring(r.category or ''),
        title = tostring(r.title or ''),
        message = tostring(r.message or ''),
        job = tostring(r.emitter_job or ''),
        jobLabel = tostring(r.emitter_job_label or r.emitter_job or ''),
        author = tostring(r.emitter_name or ''),
        cid = tostring(r.emitter_cid or ''),
        at = math.floor(tonumber(r.created_at) or 0),
        until_ = expires,
        -- Against the SERVER's clock, which is why `serverTime` is asked for and passed down: a
        -- player's own clock decides nothing about whether a public warning is still standing.
        active = expires > now,
    }
end

-- ══════════════════════════════════════════════════════════════
-- What the page asks for
-- ══════════════════════════════════════════════════════════════

RegisterNUICallback('alertsOpen', function(_, cb)
    V.Request('v-phone:alerts:open', function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('alertsEmit', function(data, cb)
    -- Config mode. doc-civilalerte's own emit is a net event and goes below.
    V.Request('v-phone:alerts:emit', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('alertsDelete', function(data, cb)
    V.Request('v-phone:alerts:delete', function(res) cb(res or { error = 'x' }) end, data or {})
end)

--- Everything that only exists when doc-civilalerte is the provider.
RegisterNUICallback('alertsDoc', function(data, cb)
    if not docMode() then cb({ error = 'notdoc' }) return end
    local op = tostring((data and data.op) or 'list')

    if op == 'list' then
        ask('doc-civilalerte:server:getAlerts', nil, function(res)
            if type(res) ~= 'table' then cb({ error = 'nodata' }) return end
            local now = math.floor(tonumber(res.serverTime) or os.time())
            local out = {}
            for _, r in ipairs(res.alerts or {}) do
                local one = shape(r, now)
                if one then out[#out + 1] = one end
            end
            cb({
                ok = true, doc = true, alerts = out, now = now,
                -- Its answers, not ours: it decides who may delete what, and the app shows the
                -- button on exactly the alerts it would accept.
                cid = tostring(res.myCid or ''),
                staff = res.isStaff == true,
            })
        end)
        return
    end

    -- **A net event, not a callback**, so there is nothing to wait for and nothing to time out.
    -- doc-civilalerte answers with its own framework notification either way - "alerte diffusee"
    -- or the reason it was refused - which is why nothing here invents a second one. Its refusals
    -- are written in the server's own language and are the operator's words, not ours.
    if op == 'emit' then
        local body = (type(data) == 'table' and type(data.emit) == 'table') and data.emit or {}
        TriggerServerEvent('doc-civilalerte:server:emit', {
            category = tostring(body.category or ''),
            title = tostring(body.title or ''),
            message = tostring(body.message or ''),
            durationMinutes = tonumber(body.minutes),
        })
        cb({ ok = true, sent = true })
        return
    end

    if op == 'delete' then
        local id = tonumber(data and data.id)
        if not id then cb({ error = 'args' }) return end
        TriggerServerEvent('doc-civilalerte:server:delete', id)
        cb({ ok = true, sent = true })
        return
    end

    cb({ error = 'x' })
end)

-- ══════════════════════════════════════════════════════════════
-- Arriving
-- ══════════════════════════════════════════════════════════════

--- Raise one alert on this phone.
---
--- The banner behaves like every other notification here: a peek when the phone is pocketed, a
--- banner and a buzz when it is open, and silence when the app is muted or DND is on. That last
--- one matters more than it sounds - a broadcast a player cannot silence is not a phone, it is an
--- alarm clock - and it is why this goes through `PhoneNotify` rather than drawing its own.
local function raise(alert)
    if type(alert) ~= 'table' then return end
    if not alertsOn() then return end

    -- The page gets it whether or not it is looking: an open app adds the card without a refetch,
    -- and a closed one has it ready when it opens.
    SendNUIMessage({ action = 'alert', alert = alert })

    if (Config.Alerts or {}).notify == false then return end
    if not PhoneNotify then return end

    -- The category's own name, so the banner says "Road" or "Wanted" rather than "Alert" seven
    -- times. Unknown keys keep the generic title rather than printing a raw key at somebody.
    local title = (PhoneString and PhoneString('app.alerts')) or 'Alerts'
    for _, c in ipairs((Config.Alerts or {}).categories or {}) do
        if tostring(c.key) == tostring(alert.category) then
            local label = tostring(c.label or '')
            title = (label:sub(1, 3) == 'ph.' and PhoneString and PhoneString(label)) or label or title
            break
        end
    end

    PhoneNotify({
        app = 'alerts', icon = 'alerts',
        title = title,
        body = tostring(alert.title or ''),
        hasItem = true,
    })

    if (Config.Alerts or {}).vibrate ~= false then
        -- The game's own alert tone. A public warning that arrives silently while the phone is in
        -- a pocket is a warning nobody acted on.
        PlaySoundFrontend(-1, 'Text_Arrive_Tone', 'Phone_SoundSet_Default', true)
    end
end

-- The phone's own broadcast, in config mode.
RegisterNetEvent('v-phone:client:alert', function(alert) raise(alert) end)

RegisterNetEvent('v-phone:client:alertGone', function(id)
    SendNUIMessage({ action = 'alertGone', id = tonumber(id) })
end)

-- doc-civilalerte's broadcast, which reaches every client whether or not it has this app.
--
-- Its row arrives with its own column names and no server clock, so `active` is decided from this
-- client's - acceptable here and nowhere else: an alert this event carries was created a moment
-- ago by definition, so "is it still standing" has exactly one answer.
RegisterNetEvent('doc-civilalerte:client:newAlert', function(alert)
    if not docMode() then return end
    raise(shape(alert, os.time()))
end)

RegisterNetEvent('doc-civilalerte:client:alertDeleted', function(id)
    if not docMode() then return end
    SendNUIMessage({ action = 'alertGone', id = tonumber(id) })
end)
