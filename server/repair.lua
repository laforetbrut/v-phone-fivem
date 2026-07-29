-- v-phone | server/repair.lua
--
-- **Repair: reaching a mechanic from the side of the road.**
--
-- Two providers, one app, and the page never learns which one answered.
--
--   * **doc-mechanicmdt**, when it is running. Its garages, its opening states, its ratings, its
--     invoice rule and its callout queue. It publishes everything its own phone app used as QB
--     *server callbacks* - `getPublicGarages`, `getMyGarageRatings`, `rateGarage`, `createCall`,
--     `getMyCall`, `cancelMyCall` - and a server callback is registered on the framework rather
--     than on the resource, so any client may call one. That side is driven from
--     client/repair.lua, and this file does not touch it: nothing here writes a `doc_mechanic_*`
--     table or replaces any part of it.
--   * **`Config.Repair.garages`** otherwise, which is what makes the app worth installing on an
--     ESX, ox or standalone server: the phone's own garages, callouts and reviews.
--
-- What this file adds on TOP of doc-mechanicmdt, because its own app had no way to do either:
--
--   * **ringing a garage** - it has no phone numbers, so the phone finds a mechanic who is
--     actually on duty there and rings them;
--   * **ringing the client back** - the callout row names their citizen id, so the pairing can
--     be PROVEN before a number is handed over. That is a stronger guarantee than the taxi app
--     manages, and it is why this one is not merely gated on the job.
--
-- Decided here and never by the page in config mode: which garage exists, whether it is taking
-- callouts, who counts as staff, and whether somebody may review at all.

local CFG = Config.Repair or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

--- Is doc-mechanicmdt the provider?
---
--- Asked per request rather than cached, so starting the resource mid-session works without
--- restarting the phone.
local function docMode()
    local want = tostring(CFG.provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-mechanicmdt' then return true end
    return GetResourceState('doc-mechanicmdt') == 'started'
end

-- ══════════════════════════════════════════════════════════════
-- Who is a mechanic
-- ══════════════════════════════════════════════════════════════

--- The jobs that count as staff, as a set.
---
--- In config mode this is derived from the garages themselves - a garage IS a job, so listing
--- them twice is one list to forget to update. `jobs` adds to it, for a server whose staff jobs
--- and garages do not line up one to one, and it is the ONLY source under doc-mechanicmdt, where
--- the garages are not ours to read.
local function staffJobs()
    local out = {}
    if not docMode() then
        for _, g in ipairs(CFG.garages or {}) do
            local job = tostring(g.job or '')
            if job ~= '' then out[job] = true end
        end
    end
    for _, job in ipairs(CFG.jobs or {}) do
        job = tostring(job or '')
        if job ~= '' then out[job] = true end
    end
    return out
end

--- Does this character work at a garage, and may they work the queue?
---
--- Returns the job name, or nil and the reason. The reason is specific because "you are off
--- duty" and "your grade is too low" are different problems and somebody who cannot tell them
--- apart reports the wrong one.
local function staffOf(p)
    local job = p and p.job
    if type(job) ~= 'table' then return nil, 'nojob' end
    if not staffJobs()[tostring(job.name or '')] then return nil, 'notstaff' end
    if CFG.requireDuty ~= false and job.onDuty == false then return nil, 'offduty' end
    if num(job.grade, 0) < num(CFG.minGrade, 0) then return nil, 'grade' end
    return tostring(job.name)
end

--- Everybody on duty at one garage, as sources. Used to decide who a call to the garage rings.
local function onDutyAt(job)
    local out = {}
    for _, raw in ipairs(GetPlayers()) do
        local src = tonumber(raw)
        local other = src and Core.GetPlayer(src)
        local ojob = other and other.job
        if type(ojob) == 'table' and tostring(ojob.name) == job then
            if CFG.requireDuty == false or ojob.onDuty ~= false then
                out[#out + 1] = other
            end
        end
    end
    return out
end

-- ══════════════════════════════════════════════════════════════
-- The tables
-- ══════════════════════════════════════════════════════════════
-- Only in config mode. Under doc-mechanicmdt this file stores nothing at all, and creating
-- tables that will never hold a row would only be a second place to look when a callout goes
-- missing.

local ready = false

CreateThread(function()
    if not enabled() or docMode() then return end

    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_repair_calls` (
        `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `job`        VARCHAR(48) NOT NULL,
        `citizenid`  VARCHAR(16) NOT NULL,
        `name`       VARCHAR(64) NOT NULL DEFAULT '',
        `number`     VARCHAR(24) NOT NULL DEFAULT '',
        `message`    VARCHAR(320) NOT NULL DEFAULT '',
        `x`          FLOAT NOT NULL DEFAULT 0,
        `y`          FLOAT NOT NULL DEFAULT 0,
        `status`     VARCHAR(16) NOT NULL DEFAULT 'pending',
        `handled_by` VARCHAR(64) NOT NULL DEFAULT '',
        `created_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        KEY `job` (`job`),
        KEY `citizenid` (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- One review per person per garage, which is what the primary key says: reviewing again
    -- edits what you wrote rather than stacking a second opinion on the same visit.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_repair_reviews` (
        `job`        VARCHAR(48) NOT NULL,
        `citizenid`  VARCHAR(16) NOT NULL,
        `stars`      TINYINT UNSIGNED NOT NULL DEFAULT 5,
        `comment`    VARCHAR(320) NOT NULL DEFAULT '',
        `name`       VARCHAR(64) NOT NULL DEFAULT '',
        `at`         INT UNSIGNED NOT NULL,
        PRIMARY KEY (`job`, `citizenid`),
        KEY `job_at` (`job`, `at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    -- Somebody who has been served here, which is what earns the right to review. Written when
    -- a callout is completed, and kept after the callout row itself is gone.
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_repair_served` (
        `job`       VARCHAR(48) NOT NULL,
        `citizenid` VARCHAR(16) NOT NULL,
        `at`        INT UNSIGNED NOT NULL,
        PRIMARY KEY (`job`, `citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])

    ready = true
end)

-- ══════════════════════════════════════════════════════════════
-- Shapes
-- ══════════════════════════════════════════════════════════════

local function clean(text, max)
    text = tostring(text or ''):gsub('<[^>]*>', '')
    text = text:gsub('[\r\n\t]+', ' '):gsub('%s+', ' ')
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    return text:sub(1, math.max(1, math.floor(num(max, 60))))
end

local function garageFor(job)
    for _, g in ipairs(CFG.garages or {}) do
        if tostring(g.job or '') == tostring(job) then return g end
    end
    return nil
end

--- A garage's score, from its own reviews.
---
--- Counted rather than kept in a column: a running total is a number that drifts the first time
--- a row is deleted by hand, and this table is small enough that the sum is free.
local function ratingOf(job)
    local row = MySQL.single.await(
        'SELECT COUNT(*) AS votes, AVG(stars) AS avg FROM vphone_repair_reviews WHERE job = ?',
        { job })
    local votes = math.floor(num(row and row.votes, 0))
    return {
        votes = votes,
        average = votes > 0 and (math.floor(num(row and row.avg, 0) * 10 + 0.5) / 10) or 0,
    }
end

--- Is this garage taking callouts?
---
--- In config mode, `open` on the row AND somebody on duty. The second half is the part worth
--- stating: a garage nobody is working at cannot answer a callout, and letting a player raise
--- one into an empty building is the app taking a request it knows will not be read.
local function isOpen(g)
    if g.open == false then return false end
    if CFG.requireDuty == false then return true end
    return #onDutyAt(tostring(g.job)) > 0
end

-- ══════════════════════════════════════════════════════════════
-- Opening the app
-- ══════════════════════════════════════════════════════════════

--- Everything the app draws, in one answer.
---
--- One round trip on purpose. The app has three or four tabs over the same data, and asking
--- again per tab is how a phone gets the reload flash this resource spent an audit removing.
V.Callback('v-phone:repair:open', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local job, why = staffOf(p)

    -- doc-mechanicmdt answers the garages, the ratings and the callout itself from
    -- client/repair.lua, where its callbacks are reachable. What it does not publish is whether
    -- THIS character is staff, so the phone still says - from the mirrored list in the config.
    if docMode() then
        resolve({
            ok = true, doc = true,
            staff = job or false,
            staffWhy = job and nil or why,
            callGarage = CFG.callGarage ~= false,
            callClient = CFG.callClient ~= false,
            maxMessage = math.floor(num(CFG.maxMessage, 300)),
            maxReview = math.floor(num(CFG.maxReview, 300)),
            refresh = math.floor(num(CFG.refreshSeconds, 15)),
            me = {
                name = tostring(p.name or ''),
                number = CFG.prefillNumber == false and ''
                    or tostring(Bridge.Numbers.Get and Bridge.Numbers.Get(p.citizenid) or ''),
            },
        })
        return
    end

    if not ready then resolve({ error = 'wait' }) return end

    local ped = GetPlayerPed(PhoneActingSource and PhoneActingSource(src) or src)
    local here = (ped and ped ~= 0) and GetEntityCoords(ped) or nil

    local mine = MySQL.query.await([[SELECT id, job, status, handled_by, message, created_at
        FROM vphone_repair_calls WHERE citizenid = ?]], { p.citizenid }) or {}
    local byJob = {}
    for _, r in ipairs(mine) do
        byJob[r.job] = {
            id = math.floor(num(r.id, 0)),
            status = tostring(r.status or 'pending'),
            by = tostring(r.handled_by or ''),
            message = tostring(r.message or ''),
            at = math.floor(num(r.created_at, 0)),
        }
    end

    local reviews = MySQL.query.await(
        'SELECT job, stars, comment FROM vphone_repair_reviews WHERE citizenid = ?',
        { p.citizenid }) or {}
    local written = {}
    for _, r in ipairs(reviews) do
        written[r.job] = { stars = math.floor(num(r.stars, 0)), comment = tostring(r.comment or '') }
    end

    local served = {}
    for _, r in ipairs(MySQL.query.await(
        'SELECT job FROM vphone_repair_served WHERE citizenid = ?', { p.citizenid }) or {}) do
        served[r.job] = true
    end

    -- Every garage's rating in one grouped read, rather than `ratingOf` once per garage inside
    -- the loop. `ratingOf` STAYS: the review-submit path below calls it for a single job, where
    -- one read is the right shape.
    --
    -- The rounding is copied character for character. `math.floor(x * 10 + 0.5) / 10` and any
    -- other way of getting to one decimal disagree at the halfway point, and a 4.25 that
    -- redraws as 4.3 where it showed 4.2 is a visible change on the garage card.
    local ratings = {}
    for _, r in ipairs(MySQL.query.await(
        'SELECT job, COUNT(*) AS votes, AVG(stars) AS avg FROM vphone_repair_reviews GROUP BY job') or {}) do
        local votes = math.floor(num(r.votes, 0))
        ratings[tostring(r.job)] = {
            votes = votes,
            average = votes > 0 and (math.floor(num(r.avg, 0) * 10 + 0.5) / 10) or 0,
        }
    end

    local garages = {}
    for _, g in ipairs(CFG.garages or {}) do
        local gjob = tostring(g.job or '')
        if gjob ~= '' then
            local c = g.coords
            -- A garage with no reviews is absent from the GROUP BY, and the fallback below is
            -- the same zero `ratingOf` returned for it.
            local rating = ratings[gjob] or { votes = 0, average = 0 }
            garages[#garages + 1] = {
                job = gjob,
                label = tostring(g.label or gjob),
                x = c and (c.x + 0.0) or nil,
                y = c and (c.y + 0.0) or nil,
                open = isOpen(g),
                -- Nobody on duty is a different thing from closed, and a customer deserves the
                -- difference: one is "come back tomorrow", the other is "try in a minute".
                staffOn = #onDutyAt(gjob),
                distance = (here and c) and math.floor(#(here - vector3(c.x + 0.0, c.y + 0.0, c.z + 0.0))) or nil,
                votes = rating.votes,
                average = rating.average,
                call = byJob[gjob],
                myReview = written[gjob],
                canReview = CFG.requireCustomer == false or served[gjob] == true,
            }
        end
    end

    table.sort(garages, function(a, b)
        if a.distance and b.distance then return a.distance < b.distance end
        if a.distance then return true end
        if b.distance then return false end
        return a.label < b.label
    end)

    resolve({
        ok = true, doc = false,
        garages = garages,
        staff = job or false,
        staffWhy = job and nil or why,
        callGarage = CFG.callGarage ~= false,
        callClient = CFG.callClient ~= false,
        ratings = CFG.ratings ~= false,
        maxMessage = math.floor(num(CFG.maxMessage, 300)),
        maxReview = math.floor(num(CFG.maxReview, 300)),
        refresh = math.floor(num(CFG.refreshSeconds, 15)),
        me = {
            name = CFG.prefillName == false and '' or tostring(p.name or ''),
            number = CFG.prefillNumber == false and ''
                or tostring(Bridge.Numbers.Get and Bridge.Numbers.Get(p.citizenid) or ''),
        },
    })
end)

--- One garage's written reviews.
---
--- Asked separately because it is the only thing on the page that is per-garage and long, and
--- loading every garage's reviews to draw a list of garages is a query nobody reads.
V.Callback('v-phone:repair:reviews', function(src, resolve, data)
    if not enabled() or docMode() then resolve({ error = 'notconfig' }) return end
    if not ready then resolve({ error = 'wait' }) return end

    local job = tostring((data and data.job) or '')
    if job == '' then resolve({ error = 'args' }) return end

    local rows = MySQL.query.await([[SELECT stars, comment, name, at FROM vphone_repair_reviews
        WHERE job = ? AND comment <> '' ORDER BY at DESC LIMIT ?]],
        { job, math.max(1, math.floor(num(CFG.reviewsShown, 20))) }) or {}

    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {
            stars = math.floor(num(r.stars, 0)),
            comment = tostring(r.comment or ''),
            -- A name, never a citizen id: a review is signed by a person, and the id behind
            -- them is nobody else's business.
            name = tostring(r.name or ''),
            at = math.floor(num(r.at, 0)),
        }
    end
    resolve({ ok = true, reviews = out })
end)

-- ══════════════════════════════════════════════════════════════
-- Asking for a callout
-- ══════════════════════════════════════════════════════════════

local lastCall = {}      -- [citizenid] = os.time()

V.Callback('v-phone:repair:call', function(src, resolve, data)
    if not enabled() or docMode() then resolve({ error = 'notconfig' }) return end
    if not ready then resolve({ error = 'wait' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local job = tostring((data and data.job) or '')
    local g = garageFor(job)
    if not g then resolve({ error = 'nogarage' }) return end
    if not isOpen(g) then resolve({ error = 'closed' }) return end

    -- One live callout per garage per person, and a floor between two of them. The first stops
    -- the same person filling one garage's queue; the second stops them filling every garage's.
    local existing = MySQL.scalar.await(
        'SELECT id FROM vphone_repair_calls WHERE citizenid = ? AND job = ? LIMIT 1',
        { p.citizenid, job })
    if existing then resolve({ error = 'already' }) return end

    local now = os.time()
    local wait = math.max(0, math.floor(num(CFG.cooldown, 60)))
    local last = lastCall[p.citizenid]
    if last and (now - last) < wait then
        resolve({ error = 'cooldown', wait = wait - (now - last) })
        return
    end

    -- **Where they actually are**, from the ped, never from the page. A position a client sends
    -- is a position a client can invent, and the whole point of asking from a phone is that the
    -- mechanic is told where to drive.
    local ped = GetPlayerPed(PhoneActingSource and PhoneActingSource(src) or src)
    local here = (ped and ped ~= 0) and GetEntityCoords(ped) or vector3(0.0, 0.0, 0.0)

    local name = clean(data and data.name, 64)
    if name == '' then name = tostring(p.name or '') end
    local number = clean(data and data.number, 24)
    local message = clean(data and data.message, CFG.maxMessage or 300)

    local id = MySQL.insert.await([[INSERT INTO vphone_repair_calls
        (job, citizenid, name, number, message, x, y, status, created_at)
        VALUES (?,?,?,?,?,?,?,?,?)]],
        { job, p.citizenid, name, number, message,
          CFG.shareLocation == false and 0.0 or here.x,
          CFG.shareLocation == false and 0.0 or here.y, 'pending', now })
    if not id then resolve({ error = 'x' }) return end

    lastCall[p.citizenid] = now

    -- Every mechanic on duty there, on their phone. This is the half doc-mechanicmdt does with
    -- a tablet and a notification: a mechanic out on a job has the tablet nowhere near them.
    for _, mech in ipairs(onDutyAt(job)) do
        if mech.source then
            TriggerClientEvent('v-phone:client:repairCall', mech.source, {
                id = math.floor(id), name = name, message = message,
                label = tostring(g.label or job),
            })
        end
    end

    V.Log(('repair: %s asked %s for a callout'):format(p.citizenid, job))
    resolve({ ok = true, id = math.floor(id) })
end)

V.Callback('v-phone:repair:cancel', function(src, resolve, data)
    if not enabled() or docMode() then resolve({ error = 'notconfig' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local job = tostring((data and data.job) or '')
    if job == '' then resolve({ error = 'args' }) return end

    -- Keyed on the CHARACTER as well as the garage, so this can only ever cancel your own.
    local n = MySQL.update.await(
        'DELETE FROM vphone_repair_calls WHERE citizenid = ? AND job = ?', { p.citizenid, job })
    resolve({ ok = true, removed = math.floor(num(n, 0)) })
end)

-- ══════════════════════════════════════════════════════════════
-- The other side of it
-- ══════════════════════════════════════════════════════════════

--- The queue at the garage this character works at.
V.Callback('v-phone:repair:queue', function(src, resolve)
    if not enabled() or docMode() then resolve({ error = 'notconfig' }) return end
    if not ready then resolve({ error = 'wait' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local job, why = staffOf(p)
    if not job then resolve({ error = why or 'notstaff' }) return end

    local rows = MySQL.query.await([[SELECT id, name, number, message, x, y, status, handled_by,
            created_at FROM vphone_repair_calls WHERE job = ? ORDER BY created_at ASC]],
        { job }) or {}

    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {
            id = math.floor(num(r.id, 0)),
            name = tostring(r.name or ''),
            -- The number the CUSTOMER put on the request, which is how they expect to be rung
            -- back. Not looked up behind their back: if they cleared the field, there is
            -- nothing here and the mechanic has to go and find them.
            number = tostring(r.number or ''),
            message = tostring(r.message or ''),
            x = num(r.x, 0), y = num(r.y, 0),
            status = tostring(r.status or 'pending'),
            by = tostring(r.handled_by or ''),
            at = math.floor(num(r.created_at, 0)),
        }
    end
    resolve({ ok = true, job = job, calls = out })
end)

--- Take a job, put it on hold, finish it, or turn it down.
V.Callback('v-phone:repair:handle', function(src, resolve, data)
    if not enabled() or docMode() then resolve({ error = 'notconfig' }) return end
    if not ready then resolve({ error = 'wait' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local job, why = staffOf(p)
    if not job then resolve({ error = why or 'notstaff' }) return end

    local id = math.floor(num(data and data.id, 0))
    local action = tostring((data and data.action) or '')
    if id <= 0 then resolve({ error = 'args' }) return end

    -- **The callout must belong to THIS garage.** Read before anything is written, and matched
    -- on the job as well as the id: without it, a mechanic at one garage could work another
    -- garage's queue by guessing a number.
    local row = MySQL.single.await(
        'SELECT id, job, citizenid, name FROM vphone_repair_calls WHERE id = ? AND job = ?',
        { id, job })
    if not row then resolve({ error = 'gone' }) return end

    local me = tostring(p.name or '')
    local target = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(row.citizenid)
    local g = garageFor(job)
    local label = tostring((g and g.label) or job)

    if action == 'done' or action == 'refused' then
        MySQL.update.await('DELETE FROM vphone_repair_calls WHERE id = ?', { id })
        -- Finishing a job is what earns the customer the right to review it. A refusal does
        -- not: being turned away is not being served.
        if action == 'done' then
            MySQL.query.await([[INSERT INTO vphone_repair_served (job, citizenid, at)
                VALUES (?,?,?) ON DUPLICATE KEY UPDATE at = VALUES(at)]],
                { job, row.citizenid, os.time() })
        end
        if target and target.source then
            TriggerClientEvent('v-phone:client:repairStatus', target.source, {
                job = job, label = label, status = action, by = me,
            })
        end
        V.Log(('repair: %s marked callout #%d as %s'):format(p.citizenid, id, action))
        resolve({ ok = true })
        return
    end

    local allowed = { accepted = true, ongoing = true, onhold = true }
    if not allowed[action] then resolve({ error = 'args' }) return end

    MySQL.update.await('UPDATE vphone_repair_calls SET status = ?, handled_by = ? WHERE id = ?',
        { action, me, id })

    if target and target.source then
        TriggerClientEvent('v-phone:client:repairStatus', target.source, {
            job = job, label = label, status = action, by = me,
        })
    end
    resolve({ ok = true })
end)

-- ══════════════════════════════════════════════════════════════
-- Reviews
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:repair:review', function(src, resolve, data)
    if not enabled() or docMode() then resolve({ error = 'notconfig' }) return end
    if CFG.ratings == false then resolve({ error = 'off' }) return end
    if not ready then resolve({ error = 'wait' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local job = tostring((data and data.job) or '')
    if not garageFor(job) then resolve({ error = 'nogarage' }) return end

    local stars = math.floor(num(data and data.stars, 0))
    if stars < 1 or stars > 5 then resolve({ error = 'stars' }) return end

    -- Somebody who was never a customer has nothing to review. Checked here rather than only
    -- hidden in the page, which is where a review-bombing script would come in.
    if CFG.requireCustomer ~= false then
        local served = MySQL.scalar.await(
            'SELECT 1 FROM vphone_repair_served WHERE job = ? AND citizenid = ?',
            { job, p.citizenid })
        if not served then resolve({ error = 'notcustomer' }) return end
    end

    MySQL.query.await([[INSERT INTO vphone_repair_reviews (job, citizenid, stars, comment, name, at)
        VALUES (?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE stars = VALUES(stars), comment = VALUES(comment), at = VALUES(at)]],
        { job, p.citizenid, stars, clean(data and data.comment, CFG.maxReview or 300),
          tostring(p.name or ''), os.time() })

    local rating = ratingOf(job)
    resolve({ ok = true, votes = rating.votes, average = rating.average })
end)

-- ══════════════════════════════════════════════════════════════
-- Ringing
-- ══════════════════════════════════════════════════════════════
-- The two things doc-mechanicmdt's own app could not do, and they work the same under both
-- providers because neither depends on where the callout is stored.

--- Get me a mechanic at this garage, on the phone.
---
--- A garage is not a person and has no number, so this picks somebody who is actually on duty
--- there and hands back THEIR number. Nothing is dialled here: the page places the call the
--- same way it places every other one, so the whole call system - signal, voicemail, do not
--- disturb, the call log - behaves exactly as it always does.
V.Callback('v-phone:repair:garageNumber', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if CFG.callGarage == false then resolve({ error = 'off' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local job = tostring((data and data.job) or '')
    if job == '' or not staffJobs()[job] then resolve({ error = 'nogarage' }) return end

    local on = onDutyAt(job)
    if #on == 0 then resolve({ error = 'nobody' }) return end

    -- The first with a number rather than a random one: the list is in join order, which is
    -- stable, and a customer ringing twice reaching the same mechanic is the behaviour a
    -- garage's landline would have.
    for _, mech in ipairs(on) do
        local number = Bridge.Numbers.Get and Bridge.Numbers.Get(mech.citizenid) or nil
        if number and number ~= '' then
            resolve({ ok = true, number = number, name = tostring(mech.name or '') })
            return
        end
    end
    resolve({ error = 'nonumber' })
end)

--- Get me the person who asked for this callout, on the phone.
---
--- **The pairing is PROVEN, not assumed.** The callout row names the client's citizen id, so
--- this can check that the caller is staff at the garage the callout was raised with before it
--- hands over anything - which is a stronger guarantee than the taxi app can offer, where the
--- pairing lives in another resource's memory.
---
--- Under doc-mechanicmdt the row is read from ITS table. Reading is not writing: nothing is
--- changed, nothing is replaced, and the alternative is asking the mechanic to type a number
--- they can see on their own tablet - which is a worse app for no extra safety.
V.Callback('v-phone:repair:clientNumber', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if CFG.callClient == false then resolve({ error = 'off' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local job, why = staffOf(p)
    if not job then resolve({ error = why or 'notstaff' }) return end

    local id = math.floor(num(data and data.id, 0))
    if id <= 0 then resolve({ error = 'args' }) return end

    local cid
    if docMode() then
        local row = MySQL.single.await(
            'SELECT citizenid FROM doc_mechanic_calls WHERE id = ? AND job = ?', { id, job })
        cid = row and row.citizenid or nil
    else
        local row = MySQL.single.await(
            'SELECT citizenid FROM vphone_repair_calls WHERE id = ? AND job = ?', { id, job })
        cid = row and row.citizenid or nil
    end
    if not cid then resolve({ error = 'gone' }) return end

    local number = Bridge.Numbers.Get and Bridge.Numbers.Get(cid) or nil
    if not number or number == '' then resolve({ error = 'nonumber' }) return end

    V.Log(('repair: %s looked up the number of their callout #%d'):format(p.citizenid, id))
    resolve({
        ok = true, number = number,
        name = tostring(Bridge.NameOfCitizen and Bridge.NameOfCitizen(cid) or ''),
    })
end)

-- The cooldown is per character and lives in memory. Somebody who has not called anybody out in
-- an hour is not worth remembering.
CreateThread(function()
    while true do
        Wait(600000)
        local cutoff = os.time() - 3600
        for cid, at in pairs(lastCall) do
            if at < cutoff then lastCall[cid] = nil end
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════

--- The callouts waiting at a garage, for a dispatch board or a sign in the world.
---
--- nil under doc-mechanicmdt: the callouts are its rows, and a second function answering the
--- same question from a different table is how two answers start disagreeing.
exports('GetRepairCalls', function(job)
    if not enabled() or docMode() or not ready then return nil end
    job = tostring(job or '')
    local rows = job ~= ''
        and MySQL.query.await([[SELECT id, name, message, x, y, status, handled_by, created_at
            FROM vphone_repair_calls WHERE job = ? ORDER BY created_at ASC]], { job })
        or MySQL.query.await([[SELECT id, job, name, message, x, y, status, handled_by, created_at
            FROM vphone_repair_calls ORDER BY created_at ASC]])
    return rows or {}
end)
