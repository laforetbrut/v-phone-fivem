-- v-phone | server/reviews.lua
--
-- **Ratings and reviews for the FruitStore.**
--
-- What was here before was a hash of the app's own id: `4.5 + (seed % 5) / 10` stars and
-- `120 + seed * 37 % 4800` ratings, computed on the page, identical on every server for ever.
-- It looked like data and answered no question - two apps a player had strong opinions about
-- scored 4.7 and 4.9 because of how their names happened to hash.
--
-- These are real. One review per character per app, editable, and the average is what the store
-- shows on the card and on the page.
--
-- **You may only review an app you have.** Not a moral position: a rating is a claim about
-- using something, and a store where anybody can score anything is a store whose scores mean
-- nothing. The check is the same one the install path uses - the app is in your list - so an
-- app removed after being reviewed keeps its review, which is right: you did use it.
--
-- The reviewer is named, never identified. The display name comes from the character sheet and
-- the citizen id never leaves the server, so a review says who thought it in the fiction without
-- handing the page a key to anything.

local CFG = (Config.Store or {}).reviews or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end
local function maxLength() return math.max(20, math.min(1000, math.floor(num(CFG.maxLength, 300)))) end
local function needsApp() return CFG.requireInstalled ~= false end

-- ══════════════════════════════════════════════════════════════
-- The table
-- ══════════════════════════════════════════════════════════════
CreateThread(function()
    if not enabled() then return end
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_app_reviews` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `app_id`    VARCHAR(48) NOT NULL,
        `citizenid` VARCHAR(64) NOT NULL,
        `stars`     TINYINT UNSIGNED NOT NULL DEFAULT 5,
        `body`      VARCHAR(1000) NOT NULL DEFAULT '',
        `at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        -- One per person per app. Reviewing again EDITS, which is what the unique key turns an
        -- insert into - rather than a second opinion from the same person moving the average.
        UNIQUE KEY `one_each` (`app_id`, `citizenid`),
        KEY `app_id` (`app_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

-- ══════════════════════════════════════════════════════════════
-- The averages
-- ══════════════════════════════════════════════════════════════
-- Every store listing wants a rating, and the store is opened often. One grouped query for all
-- of them, cached for a few seconds, rather than a query per app per open: with thirty apps
-- that is the difference between one read and thirty on every tap of the store icon.
--
-- The cache is short deliberately. A review somebody just left should show up while they are
-- still looking at the screen; a rating that takes a minute to move reads as a lost review.

local ratings = { at = 0, by = {} }
local CACHE_MS = 5000

local function allRatings()
    local now = GetGameTimer and GetGameTimer() or 0
    if ratings.at > 0 and now - ratings.at < CACHE_MS then return ratings.by end

    local by = {}
    for _, r in ipairs(MySQL.query.await([[
        SELECT app_id, COUNT(*) AS n, AVG(stars) AS avg_stars
        FROM vphone_app_reviews GROUP BY app_id]]) or {}) do
        by[r.app_id] = {
            count = math.floor(num(r.n, 0)),
            -- One decimal, the way a store shows it. Rounded rather than truncated: 4.25 is
            -- closer to 4.3 than to 4.2, and truncating would quietly bias every score down.
            average = math.floor(num(r.avg_stars, 0) * 10 + 0.5) / 10,
        }
    end
    ratings = { at = now, by = by }
    return by
end

--- The rating for one app, for the store listing. Nil when nobody has reviewed it.
---
--- Published rather than local: `storeApps` in server/main.lua attaches it to every row, and it
--- is defined in this file because this file owns the table. Load order is safe - the store is
--- built when somebody opens it, long after every file has run.
function PhoneAppRating(id)
    if not enabled() then return nil end
    local ok, by = pcall(allRatings)
    if not ok then return nil end
    return by[tostring(id or '')]
end

--- Anything that writes a review clears the cache, so the number moves at once for the person
--- who moved it.
local function forget() ratings = { at = 0, by = {} } end

-- ══════════════════════════════════════════════════════════════
-- Reading
-- ══════════════════════════════════════════════════════════════

--- What a reviewer is called.
---
--- The character's own name, and never their citizen id. A store review is signed in the
--- fiction: "Mara O." is who said it, and nothing about that lets the page ask anything else
--- about them.
local function reviewerName(cid)
    local row = MySQL.single.await(
        'SELECT firstname, lastname FROM vphone_characters WHERE citizenid = ?', { cid })
    if not row then return '?' end
    local first = tostring(row.firstname or ''):gsub('%s+', '')
    local last = tostring(row.lastname or ''):gsub('%s+', '')
    if first == '' and last == '' then return '?' end
    if last == '' then return first end
    return first .. ' ' .. last:sub(1, 1) .. '.'
end

V.Callback('v-phone:store:reviews', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local app = tostring((data and data.app) or ''):sub(1, 48)
    if app == '' then resolve({ error = 'args' }) return end

    local rows = MySQL.query.await([[
        SELECT citizenid, stars, body, UNIX_TIMESTAMP(at) AS ts
        FROM vphone_app_reviews WHERE app_id = ?
        ORDER BY (citizenid = ?) DESC, id DESC LIMIT 40]], { app, p.citizenid }) or {}

    -- The distribution, so the page can draw the five bars a store draws. Counted from the
    -- whole table rather than from the forty rows above, or the bars would describe the page
    -- rather than the app.
    local spread = { 0, 0, 0, 0, 0 }
    for _, r in ipairs(MySQL.query.await(
        'SELECT stars, COUNT(*) AS n FROM vphone_app_reviews WHERE app_id = ? GROUP BY stars',
        { app }) or {}) do
        local star = math.floor(num(r.stars, 0))
        if star >= 1 and star <= 5 then spread[star] = math.floor(num(r.n, 0)) end
    end

    local out, mine = {}, nil
    for _, r in ipairs(rows) do
        local isMine = r.citizenid == p.citizenid
        local row = {
            name = isMine and nil or reviewerName(r.citizenid),
            stars = math.floor(num(r.stars, 0)),
            body = r.body,
            ts = math.floor(num(r.ts, 0)),
            mine = isMine or nil,
        }
        if isMine then mine = row end
        out[#out + 1] = row
    end

    local agg = PhoneAppRating(app) or { count = 0, average = 0 }
    resolve({
        ok = true,
        average = agg.average, count = agg.count, spread = spread,
        reviews = out, mine = mine,
        -- Whether the button to write one should be there at all. The server checks it again
        -- when a review arrives; this only keeps the page from offering what it will refuse.
        canReview = (not needsApp()) or (PhoneHasApp and PhoneHasApp(src, app)) or false,
        maxLength = maxLength(),
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Writing
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:store:review', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local app = tostring((data and data.app) or ''):sub(1, 48)
    if app == '' then resolve({ error = 'args' }) return end

    -- A rating is a claim about having used something.
    if needsApp() and PhoneHasApp and not PhoneHasApp(src, app) then
        resolve({ error = 'notinstalled' }) return
    end

    local stars = math.floor(num(data and data.stars, 0))
    if stars < 1 or stars > 5 then resolve({ error = 'stars' }) return end

    local body = tostring((data and data.body) or '')
        :gsub('[%c]', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
        :sub(1, maxLength())

    -- The unique key turns the second write into an edit, so there is one statement for both
    -- "leave a review" and "change my review" and no read-then-write between them.
    MySQL.query.await([[
        INSERT INTO vphone_app_reviews (app_id, citizenid, stars, body)
        VALUES (?,?,?,?)
        ON DUPLICATE KEY UPDATE stars = VALUES(stars), body = VALUES(body), at = CURRENT_TIMESTAMP]],
        { app, p.citizenid, stars, body })

    forget()
    resolve({ ok = true })
end)

V.Callback('v-phone:store:reviewDelete', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local app = tostring((data and data.app) or ''):sub(1, 48)
    if app == '' then resolve({ error = 'args' }) return end

    -- Yours, decided by the statement rather than by a read before it.
    local n = MySQL.update.await(
        'DELETE FROM vphone_app_reviews WHERE app_id = ? AND citizenid = ?',
        { app, p.citizenid }) or 0
    forget()
    resolve({ ok = n > 0, error = n > 0 and nil or 'gone' })
end)

-- ══════════════════════════════════════════════════════════════
-- For an operator
-- ══════════════════════════════════════════════════════════════

--- Take a review off, whoever wrote it. For a staff member dealing with something that should
--- not be on the store page.
---
---     exports['v-phone']:RemoveAppReview('bleeter', citizenid)
exports('RemoveAppReview', function(app, citizenid)
    app = tostring(app or '')
    citizenid = tostring(citizenid or '')
    if app == '' or citizenid == '' then return false end
    local n = MySQL.update.await(
        'DELETE FROM vphone_app_reviews WHERE app_id = ? AND citizenid = ?',
        { app, citizenid }) or 0
    forget()
    return n > 0
end)

--- What an app scores, for a script that wants it outside the phone.
---
---     local r = exports['v-phone']:GetAppRating('bleeter')   --> { average = 4.3, count = 12 }
exports('GetAppRating', function(app)
    return PhoneAppRating(app) or { average = 0, count = 0 }
end)
