-- v-phone | server/retention.lua
--
-- **How long the phone keeps things, in one place.**
--
-- A phone that never forgets is a database that only grows. Messages, call logs, social posts,
-- comments, direct messages, mail and bank lines all accumulate for as long as a server runs,
-- and none of them is worth keeping for ever: nobody scrolls to a text from four months ago.
--
-- Retention already existed here, but scattered and half-built:
--
--   * messages were pruned ONCE AT BOOT, so a server that stays up for a month never pruned;
--   * the call log was `INTERVAL 30 DAY` written into the code, with no way to change it;
--   * each feature kept its own key in its own config section, so "how long does this phone
--     keep things" had six answers in five files;
--   * and every one of them was a single unbounded `DELETE`.
--
-- That last point is the one that matters. `DELETE FROM vphone_messages WHERE at < ...` on a
-- table with a million rows takes a lock and holds it, and every other query on that table -
-- every player opening Messages - waits behind it. On a busy server the first prune after a
-- long uptime is the one that looks like a crash.
--
-- **So this deletes in batches**, a few hundred rows at a time, with a pause between them. It
-- takes longer in wall-clock and it never blocks anybody. A sweep that has to stop early
-- because it hit its cap simply carries on at the next pass; nothing is lost by being slow.
--
-- Order matters too. A row that only exists to point at another - a delivery in `mail_box`, a
-- hidden-message marker, a like - is removed BEFORE the thing it points at, and orphans are
-- swept afterwards. Deleting a parent first leaves keys pointing at nothing, which is how a
-- cleanup turns into a bug report about a thread that will not open.

local R = Config.Retention or {}

local function num(v, d) return tonumber(v) or d or 0 end

--- How long to keep one kind of thing.
---
--- The new key wins; when it is absent the OLD per-feature key is used, so a server that set
--- `Config.Messages.retentionDays = 90` two versions ago keeps ninety days without touching
--- anything. Superseding a setting is not a reason to silently change it.
local function keep(key, legacy)
    local v = R[key]
    if v == nil then v = legacy end
    return math.max(0, math.floor(num(v, 0)))
end

local function batchSize()
    return math.max(50, math.min(5000, math.floor(num(R.batchSize, 500))))
end

local function maxPerPass()
    return math.max(batchSize(), math.floor(num(R.maxPerPass, 20000)))
end

local function everyMinutes()
    return math.max(5, math.floor(num(R.everyMinutes, 60)))
end

-- ══════════════════════════════════════════════════════════════
-- The batched delete
-- ══════════════════════════════════════════════════════════════

--- Delete up to `maxPerPass` rows, a batch at a time, yielding between batches.
---
--- Returns how many went. The `Wait` is the entire point: without it this is the same locking
--- delete it replaces, just written in a loop.
local function sweep(sql, params, label)
    local size, cap = batchSize(), maxPerPass()
    local gone, guard = 0, 0

    while gone < cap do
        -- One extra guard against a query that always reports rows but never removes any -
        -- a broken clause would otherwise spin this thread for ever.
        guard = guard + 1
        if guard > 200 then break end

        local args = {}
        for i, v in ipairs(params) do args[i] = v end
        args[#args + 1] = math.min(size, cap - gone)

        local ok, n = pcall(function()
            return MySQL.update.await(sql .. ' LIMIT ?', args)
        end)
        if not ok then
            print(('[v-phone] retention: %s failed (%s)'):format(label, tostring(n)))
            return gone
        end

        n = math.floor(num(n, 0))
        gone = gone + n
        if n < size then break end

        -- Breathe. Another query gets a turn, which is the difference between housekeeping
        -- and an outage.
        Wait(200)
    end

    return gone
end

-- ══════════════════════════════════════════════════════════════
-- What gets swept
-- ══════════════════════════════════════════════════════════════
-- Each entry is one table and the age past which its rows stop being worth keeping. `legacy`
-- names the key this used to live under, so an existing config still decides.

local function plan()
    local M = Config.Messages or {}
    local SOC = Config.Social or {}
    local BANK = Config.Bank or {}
    local ALERTS = Config.Alerts or {}

    return {
        -- Conversation. The big one on any server that has been up a while.
        { table = 'vphone_messages',        days = keep('messages', M.retentionDays or 30),
          label = 'message' },
        -- Who rang whom. History, not an archive.
        { table = 'vphone_calls',           days = keep('calls', 30), label = 'call' },
        { table = 'vphone_voicemail',       days = keep('voicemail', 30), label = 'voicemail' },

        -- The social apps.
        { table = 'vphone_social_posts',    days = keep('socialPosts', (SOC.keep or {}).posts or 30),
          label = 'post' },
        { table = 'vphone_social_comments', days = keep('socialComments', (SOC.keep or {}).comments or 30),
          label = 'comment' },
        { table = 'vphone_social_dm',       days = keep('socialMessages', (SOC.keep or {}).messages or 30),
          label = 'social message' },
        -- Stories are measured in hours because a day is their whole life.
        { table = 'vphone_social_stories',  days = keep('socialStories', (SOC.keep or {}).stories or 1),
          label = 'story', hours = true },
        { table = 'vphone_social_notifs',   days = keep('socialNotifs', 14), label = 'notification' },

        -- Mail: the delivery rows go first, then the letters nobody holds any more. A saved
        -- letter is kept whatever its age, because saving it is somebody saying so.
        --
        -- Its own statement, because a delivery row carries no date: how old a copy is, is how
        -- old the letter is. The generated form would have filtered on `at`, which is not a
        -- column in this table at all - it would have thrown once an hour, printed, moved on,
        -- and never pruned a single row.
        { table = 'vphone_mail_box',        days = keep('mail', 30), label = 'mail delivery',
          needs = { 'vphone_mail' },
          sql = [[DELETE FROM vphone_mail_box
                  WHERE saved = 0 AND EXISTS (
                      SELECT 1 FROM vphone_mail m
                      WHERE m.id = vphone_mail_box.mail_id
                        AND m.`at` < DATE_SUB(NOW(), INTERVAL ? DAY))]] },

        { table = 'vphone_bank_tx',         days = keep('bank', BANK.retentionDays or 60),
          label = 'bank line' },
        { table = 'vphone_alerts',          days = keep('alerts', ALERTS.purgeAfterDays or 7),
          label = 'alert', column = 'FROM_UNIXTIME(created_at)' },
        { table = 'vphone_app_reviews',     days = keep('reviews', 0), label = 'review' },

        -- Fruitee. Only the GIFT LOG ages out: a page is somebody's fundraiser and a balance
        -- somebody can still withdraw, so neither is housekeeping's to remove. Default 0,
        -- which keeps the gifts too - the money history of a donation page is the last thing
        -- an operator wants swept by accident.
        { table = 'vphone_fund_gifts',      days = keep('fundGifts', 0), label = 'gift' },
    }
end

-- Rows that only point at something else. Swept AFTER their parents, because until the parent
-- is gone they are not orphans - they are the reason it still works.
--
-- **Every one of these is a single-table DELETE, and that is not a style choice.** The obvious
-- way to write them is `DELETE h FROM x h LEFT JOIN y ... WHERE y.id IS NULL`, and that is how
-- they were written first. MySQL and MariaDB both refuse `LIMIT` on a multi-table DELETE, and
-- the batching this whole file is built on appends a LIMIT to every statement - so all six
-- were a parse error on every pass. The sweep caught it, printed, and moved on, which is the
-- worst possible shape for a bug: an orphan sweep that runs for ever and removes nothing.
--
-- The real database was asked, rather than reasoned with. `NOT EXISTS` reads the same, takes a
-- LIMIT, and is safe here because the subquery never names the table being deleted from.
local ORPHANS = {
    { sql = [[DELETE FROM vphone_message_hidden
              WHERE NOT EXISTS (SELECT 1 FROM vphone_messages m
                                WHERE m.id = vphone_message_hidden.message_id)]],
      table = 'vphone_message_hidden', label = 'hidden marker', needs = { 'vphone_messages' } },
    { sql = [[DELETE FROM vphone_message_reactions
              WHERE NOT EXISTS (SELECT 1 FROM vphone_messages m
                                WHERE m.id = vphone_message_reactions.message_id)]],
      table = 'vphone_message_reactions', label = 'reaction', needs = { 'vphone_messages' } },
    { sql = [[DELETE FROM vphone_mail_box
              WHERE NOT EXISTS (SELECT 1 FROM vphone_mail m
                                WHERE m.id = vphone_mail_box.mail_id)]],
      table = 'vphone_mail_box', label = 'mail delivery', needs = { 'vphone_mail' } },
    { sql = [[DELETE FROM vphone_mail
              WHERE NOT EXISTS (SELECT 1 FROM vphone_mail_box b
                                WHERE b.mail_id = vphone_mail.id)]],
      table = 'vphone_mail', label = 'undelivered letter', needs = { 'vphone_mail_box' } },
    { sql = [[DELETE FROM vphone_social_likes
              WHERE NOT EXISTS (SELECT 1 FROM vphone_social_posts p
                                WHERE p.id = vphone_social_likes.post_id)]],
      table = 'vphone_social_likes', label = 'like', needs = { 'vphone_social_posts' } },
    { sql = [[DELETE FROM vphone_social_comments
              WHERE NOT EXISTS (SELECT 1 FROM vphone_social_posts p
                                WHERE p.id = vphone_social_comments.post_id)]],
      table = 'vphone_social_comments', label = 'orphan comment', needs = { 'vphone_social_posts' } },
    { sql = [[DELETE FROM vphone_fund_gifts
              WHERE NOT EXISTS (SELECT 1 FROM vphone_fund_pages p
                                WHERE p.id = vphone_fund_gifts.page_id)]],
      table = 'vphone_fund_gifts', label = 'orphan gift', needs = { 'vphone_fund_pages' } },
    { sql = [[DELETE FROM vphone_fan_unlocks
              WHERE NOT EXISTS (SELECT 1 FROM vphone_fan_posts p
                                WHERE p.id = vphone_fan_unlocks.post_id)]],
      table = 'vphone_fan_unlocks', label = 'unlock', needs = { 'vphone_fan_posts' } },
}

--- Does this table exist? A server on an older schema, or with a module switched off, has not
--- got all of them - and a sweep must not fill the console with errors about tables the phone
--- never created.
---
--- Answered once per name per boot. `information_schema` is not free, and asking the same
--- twelve questions every hour for the life of the server is a cost with no answer attached.
local seen = {}
local function exists(name)
    if seen[name] ~= nil then return seen[name] end
    local ok, n = pcall(function()
        return MySQL.scalar.await([[SELECT 1 FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? LIMIT 1]], { name })
    end)
    seen[name] = ok and n ~= nil
    return seen[name]
end

--- Everything a job touches, not just the table it is named after: a statement that joins two
--- tables needs both, and running it with one missing throws exactly the error `exists` is
--- here to avoid.
local function ready(job)
    if not exists(job.table) then return false end
    for _, name in ipairs(job.needs or {}) do
        if not exists(name) then return false end
    end
    return true
end

-- ══════════════════════════════════════════════════════════════
-- One pass
-- ══════════════════════════════════════════════════════════════
local running = false

--- Sweep everything once. `loud` prints a line per table that gave up rows.
function PhoneRetentionSweep(loud)
    if R.enabled == false then return 0 end
    -- Two passes at once would fight over the same rows and double the lock pressure this
    -- whole file exists to avoid.
    if running then return 0 end
    running = true

    local total = 0
    for _, job in ipairs(plan()) do
        if job.days > 0 and ready(job) then
            local column = job.column or '`at`'
            local unit = job.hours and 'HOUR' or 'DAY'
            local age = job.hours and math.max(1, math.floor(job.days * 24)) or job.days
            local n = sweep(
                job.sql or ('DELETE FROM `%s` WHERE %s < DATE_SUB(NOW(), INTERVAL ? %s) %s')
                    :format(job.table, column, unit, job.extra or ''),
                { age }, job.table)
            total = total + n
            if loud and n > 0 then
                print(('[v-phone] retention: %d %s(s) older than %d %s')
                    :format(n, job.label, job.days, job.hours and 'day(s) of stories' or 'day(s)'))
            end
            Wait(100)
        end
    end

    -- And the rows whose reason for existing has just gone.
    if R.orphans ~= false then
        for _, job in ipairs(ORPHANS) do
          if ready(job) then
            local ok, n = pcall(function()
                return MySQL.update.await(job.sql .. ' LIMIT ' .. batchSize())
            end)
            if ok then
                n = math.floor(num(n, 0))
                total = total + n
                if loud and n > 0 then
                    print(('[v-phone] retention: %d orphaned %s(s)'):format(n, job.label))
                end
            else
                print(('[v-phone] retention: orphan %s failed (%s)')
                    :format(job.label, tostring(n)))
            end
            Wait(50)
          end
        end
    end

    running = false
    return total
end

-- ══════════════════════════════════════════════════════════════
-- When
-- ══════════════════════════════════════════════════════════════
CreateThread(function()
    if R.enabled == false then return end

    -- Not at boot. A server starting up has a hundred things to do and a prune is none of
    -- them; five minutes in, everybody who was going to connect has connected.
    Wait(math.max(30, math.floor(num(R.firstRunSeconds, 300))) * 1000)

    while true do
        local ok, n = pcall(PhoneRetentionSweep, true)
        if not ok then print('[v-phone] retention: sweep failed (' .. tostring(n) .. ')') end
        Wait(everyMinutes() * 60 * 1000)
    end
end)

--- Run it now, for an operator who does not want to wait for the timer.
---
---     exports['v-phone']:RunRetention()
exports('RunRetention', function()
    local removed = 0
    local done = false
    CreateThread(function()
        removed = PhoneRetentionSweep(true) or 0
        done = true
    end)
    -- The export answers once the sweep has finished, because "how many did it remove" is the
    -- only useful thing to return and it is not known before then.
    local waited = 0
    while not done and waited < 60000 do Wait(100) waited = waited + 100 end
    return removed
end)
