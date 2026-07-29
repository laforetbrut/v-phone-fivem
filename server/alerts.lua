-- v-phone | server/alerts.lua
--
-- **Public alerts: what the authorities broadcast, and what every phone receives.**
--
-- Two providers, one app, and the page never learns which one answered.
--
--   * **doc-civilalerte**, when it is running. Its alerts, its table, its permissions, its
--     Discord relay. It publishes everything its own iframe used - `doc-civilalerte:server:getAlerts`
--     as a QB *server callback*, and `:server:emit` / `:server:delete` as net events - and a server
--     callback is registered on the framework rather than on the resource, so any client may call
--     one. That side is therefore driven from client/alerts.lua, and this file deliberately does
--     not touch it: nothing here reads or writes `doc_civilalerte_alerts`, calls into it, or
--     replaces any part of it.
--   * **`Config.Alerts`** otherwise, which is what makes the app worth installing on an ESX, ox or
--     standalone server: the phone's own table, its own permission check, its own broadcast.
--
-- Decided here in config mode and never by the page: whether this character may broadcast at all,
-- which category is legal, how long an alert stands, and who may take one down. The composer is
-- hidden from somebody who may not send, but that is only courtesy - the same check runs again on
-- the way in, so reaching the callback another way changes nothing.
--
-- **An alert is public and unsolicited**, which is exactly why the cooldown is not optional: it is
-- the only thing between one compromised account and every phone in the city buzzing on a loop.

local CFG = Config.Alerts or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

--- Is doc-civilalerte the provider?
---
--- Asked per request rather than cached, so starting the resource mid-session works without
--- restarting the phone.
local function docMode()
    local want = tostring(CFG.provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-civilalerte' then return true end
    return GetResourceState('doc-civilalerte') == 'started'
end

-- ══════════════════════════════════════════════════════════════
-- The shapes the page is given
-- ══════════════════════════════════════════════════════════════

--- The categories, as the page needs them: a key, a name, a colour and an icon.
---
--- Sent rather than hard-coded in the page so an operator adding one only edits the config. The
--- label is a LOCALE KEY where the config uses one, resolved per player - a server that wants a
--- category the phone has never heard of just writes the finished text instead.
local function categories(src)
    local out = {}
    for _, c in ipairs(CFG.categories or {}) do
        local key = tostring(c.key or '')
        if key ~= '' then
            local label = tostring(c.label or key)
            out[#out + 1] = {
                key = key,
                -- `ph.` marks a phrase this resource ships; anything else is the operator's own
                -- words and is passed through untouched.
                label = label:sub(1, 3) == 'ph.' and LP(src, label) or label,
                color = tostring(c.color or '#94A3B8'),
                icon = tostring(c.icon or 'warning'),
            }
        end
    end
    return out
end

local function categoryFor(key)
    for _, c in ipairs(CFG.categories or {}) do
        if tostring(c.key) == tostring(key) then return c end
    end
    return nil
end

local function durations(src)
    local out = {}
    for _, d in ipairs(CFG.durations or {}) do
        local minutes = math.floor(num(d.minutes, 0))
        if minutes > 0 then
            local label = tostring(d.label or (minutes .. 'm'))
            out[#out + 1] = {
                minutes = minutes,
                label = label:sub(1, 3) == 'ph.' and LP(src, label) or label,
            }
        end
    end
    return out
end

--- A duration the operator actually offered.
---
--- An unknown value FALLS BACK rather than being refused: losing a written alert to a dropdown
--- that disagrees with the server is the worse of the two failures, and every value here is
--- bounded anyway.
local function durationMinutes(want)
    want = math.floor(num(want, 0))
    for _, d in ipairs(CFG.durations or {}) do
        if math.floor(num(d.minutes, 0)) == want then return want end
    end
    return math.max(1, math.floor(num(CFG.defaultDuration, 60)))
end

-- ══════════════════════════════════════════════════════════════
-- Who may broadcast
-- ══════════════════════════════════════════════════════════════

--- May this character send an alert, and under which authority?
---
--- Returns the emitter rule and the job, or nil and the reason. The reason is specific on purpose:
--- "you are off duty" and "your grade is too low" are two different problems and an officer who
--- cannot tell them apart will report the wrong one.
local function emitterFor(p)
    local job = p and p.job
    if type(job) ~= 'table' then return nil, 'nojob' end

    for _, e in ipairs(CFG.emitters or {}) do
        if tostring(e.job or '') == tostring(job.name or '') then
            if e.onDuty == true and job.onDuty == false then return nil, 'offduty' end
            if num(job.grade, 0) < num(e.grade, 0) then return nil, 'grade' end
            return e, job
        end
    end
    return nil, 'notauthority'
end

local function isStaff(src)
    local ace = tostring(CFG.staffAce or 'vphone.admin')
    return IsPlayerAceAllowed(src, ace) or IsPlayerAceAllowed(src, 'qbadmin.menu')
end

-- ══════════════════════════════════════════════════════════════
-- The table
-- ══════════════════════════════════════════════════════════════
-- Only in config mode. Under doc-civilalerte this file writes nothing at all, and creating a
-- table that will never hold a row would only be a second place to look when an alert goes
-- missing.

local ready = false

CreateThread(function()
    if not enabled() or docMode() then return end

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_alerts` (
        `id`           INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `category`     VARCHAR(32) NOT NULL,
        `title`        VARCHAR(120) NOT NULL,
        `message`      TEXT NOT NULL,
        `emitter_job`  VARCHAR(48) NOT NULL DEFAULT '',
        `emitter_label` VARCHAR(64) NOT NULL DEFAULT '',
        `emitter_name` VARCHAR(64) NOT NULL DEFAULT '',
        `emitter_cid`  VARCHAR(16) NOT NULL DEFAULT '',
        `created_at`   INT UNSIGNED NOT NULL,
        `expires_at`   INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        KEY `created_at` (`created_at`),
        KEY `expires_at` (`expires_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- Old alerts go on a timer rather than on read: an archive that is trimmed while somebody is
    -- reading it is an archive that loses the row under their finger.
    local days = math.floor(num(CFG.purgeAfterDays, 7))
    if days > 0 then
        MySQL.update.await('DELETE FROM vphone_alerts WHERE created_at < ?',
            { os.time() - (days * 86400) })
    end

    ready = true
end)

-- ══════════════════════════════════════════════════════════════
-- Reading
-- ══════════════════════════════════════════════════════════════

local function rowShape(r, now)
    return {
        id = math.floor(num(r.id, 0)),
        category = tostring(r.category or ''),
        title = tostring(r.title or ''),
        message = tostring(r.message or ''),
        job = tostring(r.emitter_job or ''),
        jobLabel = tostring(r.emitter_label or r.emitter_job or ''),
        author = tostring(r.emitter_name or ''),
        cid = tostring(r.emitter_cid or ''),
        at = math.floor(num(r.created_at, 0)),
        until_ = math.floor(num(r.expires_at, 0)),
        -- Worked out here rather than on the page, because the page has the PLAYER's clock and
        -- an alert that expires "in a minute" on one phone and "an hour ago" on the next is a
        -- broadcast nobody can act on.
        active = math.floor(num(r.expires_at, 0)) > now,
    }
end

--- Open the app: everything it draws, in one answer.
---
--- Deliberately one round trip. The app has three tabs over the same list, and asking again per
--- tab is how a phone gets the reload flash this resource spent an audit removing.
V.Callback('v-phone:alerts:open', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end

    -- doc-civilalerte answers this one itself, from client/alerts.lua, where its callback is
    -- reachable. What it cannot answer is whether THIS character may broadcast - it does not
    -- publish that - so the phone still says, from the mirrored list in the config.
    if docMode() then
        local p = Core.GetPlayer(src)
        local emitter = p and emitterFor(p) or nil
        resolve({
            ok = true, doc = true,
            canEmit = emitter ~= nil,
            categories = categories(src),
            durations = durations(src),
            maxTitle = math.floor(num(CFG.maxTitle, 60)),
            maxMessage = math.floor(num(CFG.maxMessage, 2000)),
        })
        return
    end

    if not ready then resolve({ error = 'wait' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local now = os.time()
    local rows = MySQL.query.await([[SELECT id, category, title, message, emitter_job,
            emitter_label, emitter_name, emitter_cid, created_at, expires_at
        FROM vphone_alerts ORDER BY created_at DESC LIMIT ?]],
        { math.max(1, math.floor(num(CFG.history, 50))) }) or {}

    local out = {}
    for i, r in ipairs(rows) do out[i] = rowShape(r, now) end

    local emitter = emitterFor(p)
    resolve({
        ok = true, doc = false,
        alerts = out,
        categories = categories(src),
        durations = durations(src),
        canEmit = emitter ~= nil,
        staff = isStaff(src),
        cid = p.citizenid,
        now = now,
        maxTitle = math.floor(num(CFG.maxTitle, 60)),
        maxMessage = math.floor(num(CFG.maxMessage, 2000)),
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Broadcasting
-- ══════════════════════════════════════════════════════════════

local lastEmit = {}      -- [citizenid] = os.time()

--- Bound a piece of written text.
---
--- Tags come out because the page renders a message as text and an operator should not have to
--- trust that: a stored `<img onerror>` would be a script running on every phone in the city,
--- which is the worst possible place to find one.
---
--- **What this guarantees, exactly:** no tag can be stored. The TEXT between two tags can -
--- `<script>steal()</script>` leaves `steal()` behind - and that is fine, because it is text by
--- then and the page escapes everything it draws. This is the second lock, not the first one.
---
--- Line breaks survive in the body, because a public notice with its paragraphs flattened is
--- unreadable, and go in the title, because a title is one line by definition.
local function clean(text, max, keepLines)
    text = tostring(text or ''):gsub('<[^>]*>', '')
    text = text:gsub('\r\n', '\n'):gsub('\r', '\n')
    if keepLines then
        text = text:gsub('[ \t]+', ' '):gsub('\n%s*\n%s*\n+', '\n\n'):gsub(' *\n *', '\n')
    else
        text = text:gsub('%s+', ' ')
    end
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    return text:sub(1, math.max(1, math.floor(num(max, 60))))
end

V.Callback('v-phone:alerts:emit', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if docMode() then resolve({ error = 'notconfig' }) return end
    if not ready then resolve({ error = 'wait' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    -- 1. May they, at all? Re-asked here even though the composer was only offered to somebody
    --    who passed: the page is not evidence of anything.
    local emitter, why = emitterFor(p)
    if not emitter then resolve({ error = why or 'notauthority' }) return end

    -- 2. Not again, not yet. Keyed on the CHARACTER rather than the connection, so reconnecting
    --    is not a way round it.
    local now = os.time()
    local cd = math.max(0, math.floor(num(CFG.cooldown, 30)))
    local last = lastEmit[p.citizenid]
    if last and (now - last) < cd then
        resolve({ error = 'cooldown', wait = cd - (now - last) })
        return
    end

    -- 3. A category that exists.
    local cat = categoryFor(data and data.category)
    if not cat then resolve({ error = 'category' }) return end

    -- 4. Something actually written. Checked AFTER cleaning, because a title of five tags is an
    --    empty title however long it looked in the box.
    local title = clean(data and data.title, CFG.maxTitle or 60, false)
    local message = clean(data and data.message, CFG.maxMessage or 2000, true)
    if title == '' or message == '' then resolve({ error = 'empty' }) return end

    local minutes = durationMinutes(data and data.minutes)
    local job = p.job or {}
    local name = tostring(p.name or ''):gsub('^%s+', ''):gsub('%s+$', '')

    local id = MySQL.insert.await([[INSERT INTO vphone_alerts
        (category, title, message, emitter_job, emitter_label, emitter_name, emitter_cid,
         created_at, expires_at)
        VALUES (?,?,?,?,?,?,?,?,?)]], {
        cat.key, title, message, tostring(job.name or ''), tostring(job.label or job.name or ''),
        name, p.citizenid, now, now + (minutes * 60),
    })
    if not id then resolve({ error = 'x' }) return end

    lastEmit[p.citizenid] = now

    local payload = {
        id = math.floor(id),
        category = cat.key,
        title = title,
        message = message,
        job = tostring(job.name or ''),
        jobLabel = tostring(job.label or job.name or ''),
        author = name,
        cid = p.citizenid,
        at = now,
        until_ = now + (minutes * 60),
        active = true,
    }

    -- **Everybody.** That is the whole point of the app: an alert is not a subscription, and a
    -- broadcast that only reaches people who happened to have the app open is a broadcast that
    -- did not happen. The phone decides what to do with it - banner, buzz, badge, or silence if
    -- the player muted the app.
    TriggerClientEvent('v-phone:client:alert', -1, payload)
    -- The home screen widget caches the newest standing alert. This is one of the two moments
    -- the answer can change, so it is one of the two places the cache is dropped.
    if AlertsWidgetStale then AlertsWidgetStale() end

    V.Log(('alerts: %s (%s) broadcast "%s" for %d minute(s)')
        :format(name, tostring(job.name or '?'), title, minutes))
    resolve({ ok = true, alert = payload })
end)

--- Take an alert down.
---
--- Whoever wrote it, and staff. The owner is read from the ROW rather than believed from the
--- page - a client that could name the author could name anybody's.
V.Callback('v-phone:alerts:delete', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if docMode() then resolve({ error = 'notconfig' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve({ error = 'args' }) return end

    local row = MySQL.single.await('SELECT emitter_cid FROM vphone_alerts WHERE id = ?', { id })
    if not row then resolve({ error = 'gone' }) return end

    local mine = CFG.allowAuthorDelete ~= false
        and tostring(row.emitter_cid or '') ~= ''
        and row.emitter_cid == p.citizenid
    if not mine and not isStaff(src) then resolve({ error = 'denied' }) return end

    MySQL.update.await('DELETE FROM vphone_alerts WHERE id = ?', { id })

    -- Withdrawn everywhere, not only for whoever pressed it: an alert that has been taken down
    -- is one that must stop being on people's phones.
    TriggerClientEvent('v-phone:client:alertGone', -1, id)
    if AlertsWidgetStale then AlertsWidgetStale() end

    V.Log(('alerts: %s withdrew alert #%d'):format(p.citizenid, id))
    resolve({ ok = true })
end)

-- The cooldown is per character and lives in memory. A character who has not sent anything in a
-- day is not worth remembering.
CreateThread(function()
    while true do
        Wait(600000)
        local cutoff = os.time() - 3600
        for cid, at in pairs(lastEmit) do
            if at < cutoff then lastEmit[cid] = nil end
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════

--- What is standing right now.
---
--- For a dispatch board, a news script or a sign in the world. Answers `nil` under
--- doc-civilalerte: the alerts are its rows, and a second function answering the same question
--- from a different table is how the two start disagreeing.
exports('GetAlerts', function()
    if not enabled() or docMode() or not ready then return nil end

    local now = os.time()
    local rows = MySQL.query.await([[SELECT id, category, title, message, emitter_job,
            emitter_label, emitter_name, emitter_cid, created_at, expires_at
        FROM vphone_alerts WHERE expires_at > ? ORDER BY created_at DESC]], { now }) or {}

    local out = {}
    for i, r in ipairs(rows) do out[i] = rowShape(r, now) end
    return out
end)

--- Broadcast one, from a script rather than from a phone.
---
--- For a weather system, a scripted disaster, or a console command of your own. **There is no
--- job check here on purpose**: a resource calling this is already server-side and already
--- trusted, and asking it to hold a citizen id to declare a flood would only mean inventing one.
--- The category and the duration are still whitelisted - they decide how the card is drawn, and
--- an unknown one would be an alert nobody can read properly.
exports('RaiseAlert', function(data)
    if not enabled() or docMode() or not ready then return nil, 'unavailable' end
    if type(data) ~= 'table' then return nil, 'args' end

    local cat = categoryFor(data.category)
    if not cat then return nil, 'category' end

    local title = clean(data.title, CFG.maxTitle or 60, false)
    local message = clean(data.message, CFG.maxMessage or 2000, true)
    if title == '' or message == '' then return nil, 'empty' end

    local now = os.time()
    local minutes = durationMinutes(data.minutes)
    local author = tostring(data.author or '')
    local jobLabel = tostring(data.authority or '')

    local id = MySQL.insert.await([[INSERT INTO vphone_alerts
        (category, title, message, emitter_job, emitter_label, emitter_name, emitter_cid,
         created_at, expires_at)
        VALUES (?,?,?,?,?,?,?,?,?)]], {
        cat.key, title, message, '', jobLabel, author, '', now, now + (minutes * 60),
    })
    if not id then return nil, 'x' end

    local payload = {
        id = math.floor(id), category = cat.key, title = title, message = message,
        job = '', jobLabel = jobLabel, author = author, cid = '',
        at = now, until_ = now + (minutes * 60), active = true,
    }
    TriggerClientEvent('v-phone:client:alert', -1, payload)
    -- The same cache drop the player path does. An alert raised by a script is standing over
    -- the city in exactly the same way, and the home screen widget was told about one and not
    -- the other - so a scripted alert stayed invisible on the strip until the cache expired
    -- by other means, which it does not.
    if AlertsWidgetStale then AlertsWidgetStale() end
    V.Log(('alerts: a script broadcast "%s" for %d minute(s)'):format(title, minutes))
    return payload
end)

-- ══════════════════════════════════════════════════════════════
-- The home screen widget
-- ══════════════════════════════════════════════════════════════
-- What is standing over the city right now, as one line.
--
-- **Cached, and invalidated by the two events that can change the answer** - a broadcast and a
-- withdrawal - rather than re-read per home paint. At steady state this tile costs nothing at
-- all: one query per server start, and one more each time an alert goes up or comes down.
local WNewest = nil       -- { at, row } or false for "asked, nothing standing"

function AlertsWidgetStale() WNewest = nil end

WidgetSource('alerts', 'alerts', function()
    -- Under doc-civilalerte the alerts are ITS rows. Reading our own table would answer
    -- confidently about a table nothing writes to, which is worse than not offering the tile.
    if not enabled() or docMode() or not ready then return { ok = false } end

    local now = os.time()
    -- A cached row can expire while it sits here, which is the one way the cache can be wrong
    -- without an event firing. Cheap to check, and it re-reads rather than showing a dead alert.
    if WNewest ~= nil and (WNewest == false or (WNewest.row and WNewest.row.expires_at > now)) then
        if WNewest == false then return { ok = true, n = 0 } end
    else
        local rows = MySQL.query.await([[SELECT id, category, title, emitter_label, expires_at
            FROM vphone_alerts WHERE expires_at > ? ORDER BY created_at DESC LIMIT 1]], { now })
        local row = rows and rows[1]
        if not row then
            WNewest = false
            return { ok = true, n = 0 }
        end
        local n = MySQL.scalar.await(
            'SELECT COUNT(*) FROM vphone_alerts WHERE expires_at > ?', { now }) or 1
        WNewest = { row = row, n = math.floor(tonumber(n) or 1) }
    end

    local r = WNewest.row
    return {
        ok = true,
        n = WNewest.n,
        category = tostring(r.category or ''),
        title = WidgetText(r.title, 56),
        -- The label, never `emitter_cid`. That column identifies the character who raised the
        -- alert and has no business on anybody else's home screen.
        emitter = WidgetText(r.emitter_label, 24),
        expiresAt = math.floor(tonumber(r.expires_at) or 0),
    }
end)
