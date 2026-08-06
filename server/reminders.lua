-- ══════════════════════════════════════════════════════════════
-- Reminders
-- ══════════════════════════════════════════════════════════════
-- A reminder that only exists in the page is a note with a tick box. What makes this an app is
-- that it goes off: at a time somebody chose, whether or not the phone is open, whether or not
-- they are still thinking about it.
--
-- **So the clock is here and not in the page.** A timer in a NUI page dies the moment the phone
-- is closed, and closing the phone is what a player does immediately after setting a reminder.
-- The server holds the due time, sweeps for what is ready, and pushes it to whoever is on.
--
-- The sweep is a single indexed query every half minute over rows that are due and not yet
-- announced. It does not scan players, and it does not scan the table.

-- Said out loud at boot. A file that is listed in the manifest but not actually loaded is
-- indistinguishable, from the phone, from one that loaded and answered badly - and the only
-- place that difference is visible is this console.
print('[v-phone] reminders: loaded')

local function num(v, d) return tonumber(v) or d or 0 end

local SWEEP_EVERY = 30000       -- ms between passes over what is due
local MAX_PER_PLAYER = 200      -- a list, not a queue
local MAX_TEXT = 120
local MAX_NOTE = 400

-- How often a repeating reminder comes back, in minutes. A closed list rather than a free
-- number: the page offers four choices, and a stored 1 would be a reminder that fires every
-- minute for ever on somebody else's server.
local REPEATS = {
    [0] = true,          -- once
    [1440] = true,       -- every day
    [10080] = true,      -- every week
    [43200] = true,      -- every thirty days
}

-- The lists a reminder can belong to. Named by key and drawn by the page, so a translation is
-- the page's business and the column stays short.
local LISTS = { personal = true, work = true, shopping = true, other = true }

CreateThread(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_reminders` (
        `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `citizenid` VARCHAR(64)  NOT NULL,
        `text`      VARCHAR(160) NOT NULL,
        `note`      VARCHAR(500) NOT NULL DEFAULT '',
        `list`      VARCHAR(16)  NOT NULL DEFAULT 'personal',
        -- NULL means "some day": a reminder with no date is still a reminder, and FruitOS has
        -- always allowed one. Only rows with a date are ever swept.
        `due`       DATETIME     NULL DEFAULT NULL,
        `repeat_mins` INT UNSIGNED NOT NULL DEFAULT 0,
        `flagged`   TINYINT(1)   NOT NULL DEFAULT 0,
        `done`      TINYINT(1)   NOT NULL DEFAULT 0,
        `notified`  TINYINT(1)   NOT NULL DEFAULT 0,
        `at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`),
        KEY `owner_idx` (`citizenid`, `done`, `due`),
        -- The sweep's index. It reads by (notified, done, due) and nothing else, so it never
        -- touches a row belonging to a reminder that has already gone off.
        KEY `due_idx` (`notified`, `done`, `due`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end)

--- One row, as the page wants it.
local function shape(r)
    return {
        id = r.id, text = r.text, note = r.note, list = r.list,
        due = r.due, repeatMins = r.repeat_mins,
        flagged = r.flagged == 1, done = r.done == 1,
    }
end

local function listOf(cid)
    local rows = MySQL.query.await([[
        SELECT id, text, note, list, due, repeat_mins, flagged, done
        FROM vphone_reminders WHERE citizenid = ?
        -- Undone first, then by when: something due in an hour matters more than something
        -- due next week, and something with no date at all comes last rather than first.
        ORDER BY done ASC, due IS NULL ASC, due ASC, id DESC
        LIMIT ?]], { cid, MAX_PER_PLAYER }) or {}
    local out = {}
    for i = 1, #rows do out[i] = shape(rows[i]) end
    return out
end

--- A due date from the page, as SQL or nil.
---
--- Taken as a millisecond epoch and turned into a date HERE. The page is in the player's own
--- browser with the player's own clock; a formatted string built there would carry whatever
--- timezone that machine is set to, and the server is the only clock the sweep can read.
local function dueSql(ms)
    local n = tonumber(ms)
    if not n or n <= 0 then return nil end
    -- A hundred years out is not a reminder, it is a way to leave a row nothing ever collects.
    local seconds = math.floor(n / 1000)
    local now = os.time()
    if seconds < now - 86400 * 365 or seconds > now + 86400 * 3650 then return nil end
    return os.date('%Y-%m-%d %H:%M:%S', seconds)
end

V.Callback('v-phone:reminders', function(src, resolve, data)
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local cid = p.citizenid
    local op = tostring((data and data.op) or 'list')

    if op == 'list' then
        resolve({ ok = true, items = listOf(cid) })
        return
    end

    if op == 'save' then
        local text = tostring((data and data.text) or ''):gsub('[%c]', ''):gsub('^%s+', ''):gsub('%s+$', '')
        text = text:sub(1, MAX_TEXT)
        if text == '' then resolve({ error = 'empty' }) return end

        local note = tostring((data and data.note) or ''):gsub('[%z\1-\9\11-\31\127]', ''):sub(1, MAX_NOTE)
        local list = tostring((data and data.list) or 'personal')
        if not LISTS[list] then list = 'personal' end
        local rep = math.floor(num(data and data.repeatMins, 0))
        if not REPEATS[rep] then rep = 0 end
        local due = dueSql(data and data.due)
        -- Something that comes back has to have a first time to come back from.
        if due == nil then rep = 0 end
        local flagged = (data and data.flagged) == true

        local id = math.floor(num(data and data.id, 0))
        if id > 0 then
            -- `notified` is reset on every edit: moving a reminder to a new time means it has
            -- to be able to go off again, and without this an edited one would sit there for
            -- ever having already been announced once.
            local n = MySQL.update.await([[UPDATE vphone_reminders
                SET text = ?, note = ?, list = ?, due = ?, repeat_mins = ?, flagged = ?,
                    notified = 0
                WHERE id = ? AND citizenid = ?]],
                { text, note, list, due, rep, flagged and 1 or 0, id, cid })
            if not n or n < 1 then resolve({ error = 'gone' }) return end
        else
            local total = MySQL.scalar.await(
                'SELECT COUNT(*) FROM vphone_reminders WHERE citizenid = ?', { cid }) or 0
            if total >= MAX_PER_PLAYER then resolve({ error = 'full' }) return end
            id = MySQL.insert.await([[INSERT INTO vphone_reminders
                (citizenid, text, note, list, due, repeat_mins, flagged)
                VALUES (?,?,?,?,?,?,?)]],
                { cid, text, note, list, due, rep, flagged and 1 or 0 })
        end
        resolve({ ok = true, id = id, items = listOf(cid) })
        return
    end

    if op == 'done' then
        local id = math.floor(num(data and data.id, 0))
        local want = (data and data.done) == true
        -- Ticking a repeating reminder does not finish it, it moves it on. That is what
        -- "every day" means, and a daily reminder you have to recreate every morning is one
        -- somebody stops using after two days.
        local row = MySQL.single.await(
            'SELECT due, repeat_mins FROM vphone_reminders WHERE id = ? AND citizenid = ?',
            { id, cid })
        if not row then resolve({ error = 'gone' }) return end

        if want and row.repeat_mins and row.repeat_mins > 0 then
            MySQL.update.await([[UPDATE vphone_reminders
                SET due = DATE_ADD(COALESCE(due, NOW()), INTERVAL ? MINUTE), notified = 0, done = 0
                WHERE id = ? AND citizenid = ?]], { row.repeat_mins, id, cid })
        else
            MySQL.update.await(
                'UPDATE vphone_reminders SET done = ? WHERE id = ? AND citizenid = ?',
                { want and 1 or 0, id, cid })
        end
        resolve({ ok = true, items = listOf(cid) })
        return
    end

    if op == 'del' then
        MySQL.update.await('DELETE FROM vphone_reminders WHERE id = ? AND citizenid = ?',
            { math.floor(num(data and data.id, 0)), cid })
        resolve({ ok = true, items = listOf(cid) })
        return
    end

    if op == 'clearDone' then
        MySQL.update.await('DELETE FROM vphone_reminders WHERE citizenid = ? AND done = 1', { cid })
        resolve({ ok = true, items = listOf(cid) })
        return
    end

    resolve({ error = 'x' })
end)

-- ── The clock ──────────────────────────────────────────────────

--- Everything that has come due and has not been announced.
---
--- Marked as announced BEFORE anything is sent. A player who is offline still has their
--- reminder marked: it is in the list with its date behind them, which is what a missed
--- reminder looks like on a real phone. Announcing it when they log in two days later would
--- be worse than not announcing it at all.
local function sweep()
    local rows = MySQL.query.await([[
        SELECT id, citizenid, text, list, due, repeat_mins
        FROM vphone_reminders
        WHERE notified = 0 AND done = 0 AND due IS NOT NULL AND due <= NOW()
        ORDER BY due ASC LIMIT 100]]) or {}
    if #rows == 0 then return end

    local ids = {}
    for i = 1, #rows do ids[i] = rows[i].id end
    local marks = ('?,'):rep(#ids):sub(1, -2)
    MySQL.update.await(
        'UPDATE vphone_reminders SET notified = 1 WHERE id IN (' .. marks .. ')', ids)

    for _, r in ipairs(rows) do
        local p = Core.GetPlayerByCitizenId and Core.GetPlayerByCitizenId(r.citizenid)
        local target = p and p.source
        if target then
            TriggerClientEvent('v-phone:client:banner', target, {
                app = 'reminders', icon = 'reminders',
                -- `LP` translates for ONE player, in the language that player carries. `L` on
                -- the server would answer in the server's own language and hand a French
                -- player an English word.
                title = LP and LP(target, 'ph.reminder_due') or 'Reminder',
                body = r.text,
                -- See server/main.lua: `requireItem` is a file-local and was nil here,
                -- so this always said yes.
                hasItem = PhoneRequiresItem(target),
            })
        end
    end
end

CreateThread(function()
    -- One pass at boot after the table exists, then on the clock. Wrapped so a database that is
    -- briefly unavailable stops one sweep rather than the thread.
    Wait(8000)
    while true do
        pcall(sweep)
        Wait(SWEEP_EVERY)
    end
end)

-- ══════════════════════════════════════════════════════════════
-- The home screen widget
-- ══════════════════════════════════════════════════════════════
-- The next thing due, and how many are due at all. Two narrow reads, both served entirely by
-- `owner_idx (citizenid, done, due)` with no filesort and no temporary table.
--
-- **Not `op = 'list'`.** That returns every open reminder the character has, each carrying its
-- 500-character `note` column, to draw one line on a tile. The columns below are the four the
-- tile actually shows.
WidgetSource('reminders', 'reminders', function(src, p)
    local cid = p.citizenid
    local next1 = MySQL.query.await([[SELECT id, text, list, due, flagged
        FROM vphone_reminders
        WHERE citizenid = ? AND done = 0 AND due IS NOT NULL
        ORDER BY due ASC LIMIT 1]], { cid })
    local row = next1 and next1[1]

    -- Everything already past its time and not ticked off. This is the number a player wants
    -- at a glance; the one below it is "and some day, these".
    local overdue = MySQL.scalar.await([[SELECT COUNT(*) FROM vphone_reminders
        WHERE citizenid = ? AND done = 0 AND due IS NOT NULL AND due <= ?]],
        { cid, os.date('%Y-%m-%d %H:%M:%S') }) or 0
    local someday = MySQL.scalar.await([[SELECT COUNT(*) FROM vphone_reminders
        WHERE citizenid = ? AND done = 0 AND due IS NULL]], { cid }) or 0

    local out = { ok = true, due = math.floor(tonumber(overdue) or 0),
                  someday = math.floor(tonumber(someday) or 0) }
    if row then
        out.text = WidgetText(row.text, 48)
        out.list = tostring(row.list or 'personal')
        out.flagged = (tonumber(row.flagged) or 0) == 1 or nil
        -- Seconds since the epoch, so the page can say "in 20 minutes" without a second round
        -- trip and without needing the server's timezone.
        local y, mo, d, h, mi, s = tostring(row.due):match('(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)')
        if y then
            out.dueAt = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                                  hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
        end
    end
    return out
end)

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════

--- Put a reminder on somebody's phone.
---
--- Returns the row id, or `false` and a reason. It goes off through the sweep above, so it
--- survives a restart and arrives whether or not the app is open - which is the whole reason a
--- shop should use this rather than its own timer.
---
--- Bounded by the same caps a player's own reminder is: `MAX_PER_PLAYER`, `MAX_TEXT`, `MAX_NOTE`.
--- A script that can set two hundred and one reminders on somebody is a script that can fill
--- their phone.
function PhoneAddReminder(citizenid, atEpoch, text, note)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return false, 'nocid' end

    text = tostring(text or ''):gsub('[%c]', ' '):gsub('%s+', ' ')
    text = text:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, MAX_TEXT)
    if text == '' then return false, 'empty' end

    note = tostring(note or ''):gsub('[%z\1-\9\11-\31\127]', ''):sub(1, MAX_NOTE)

    local held = tonumber(MySQL.scalar.await(
        'SELECT COUNT(*) FROM vphone_reminders WHERE citizenid = ?', { citizenid })) or 0
    if held >= MAX_PER_PLAYER then return false, 'full' end

    -- A date in the far past or the far future is a caller with a millisecond timestamp or a
    -- broken clock, and either would sit in the sweep for ever.
    local when = math.floor(tonumber(atEpoch) or 0)
    local now = os.time()
    local due = nil
    if when > 0 then
        if when < now - 86400 or when > now + 86400 * 3650 then return false, 'baddate' end
        due = os.date('%Y-%m-%d %H:%M:%S', when)
    end

    local id = MySQL.insert.await([[INSERT INTO vphone_reminders
        (citizenid, text, note, list, due) VALUES (?,?,?,?,?)]],
        { citizenid, text, note, 'personal', due })
    return id or false
end
