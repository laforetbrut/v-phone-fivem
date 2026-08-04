-- v-phone | bridge/server/migrate.lua
--
-- **One prefix, and a migration that will never touch a table that is not ours.**
--
-- Every table this resource creates begins with `vphone_`, so it can never collide with
-- a table another script owns. A server that ran an earlier build has the same data under
-- the old `phone_`, `social_` and `hush_` names; this renames those in place at boot.
--
-- The danger the rename has to avoid is obvious: another resource might already own a
-- table called `phone_contacts` or `social_posts` that has nothing to do with us. Renaming
-- it would break that script and lose no data of ours because there was none.
--
-- So a table is renamed only when ALL of these hold:
--
--  1. the OLD name exists, and the NEW name does not,
--  2. the old name is one this resource is known to create,
--  3. **its columns match our schema** - every column our earliest build put in that
--     table is present in the one on disk.
--
-- Point 3 is what makes it safe. A foreign `phone_contacts` shaped
-- `(id, owner, label, digits)` does not contain our `citizenid, name, number, favourite`,
-- so it fails the check, is left untouched, and a fresh `vphone_contacts` is created
-- beside it. The phone works; the other script keeps its table.
--
-- `Config.MigrateLegacyTables` controls the whole thing:
--   'auto'  (default) rename only tables whose columns match ours, warn about the rest
--   true              trust the names, rename without the column check (not recommended)
--   false             never migrate; always start fresh under the new names

Bridge = Bridge or {}

-- ══════════════════════════════════════════════════════════════
-- Widening the character-id columns
-- ══════════════════════════════════════════════════════════════
-- **A citizen id is not sixteen characters, and on two frameworks it never was.**
--
--   qb / qbx     a generated id, eight characters
--   ox           the numeric charId
--   ESX          `player.identifier` - `license:` plus forty hex, or `charN:` before that
--   standalone   the bare licence hex, forty characters
--
-- The bridge's own two tables always knew: `vphone_kv` and `vphone_characters` are VARCHAR(64).
-- Every feature table declared VARCHAR(16). So on ESX and standalone the phone opened, kept the
-- wallpaper and the passcode, and then saved nothing: on a server in MySQL's default strict
-- mode every insert raised "Data too long", and on one without it the id was cut to 16 on the
-- way in while every read used the full one, so nothing matched again.
--
-- The CREATE statements are fixed, which repairs a new install. This repairs an old one.
local ID_COLUMNS = { 'citizenid', 'from_cid', 'to_cid', 'other_cid', 'owner_cid' }

--- Widen every character-id column in a `vphone_` table that is narrower than 64.
---
--- Idempotent: it asks `information_schema` what is actually there, so a second run finds
--- nothing to do. Nullability and the default are read and written back, because MODIFY
--- replaces the whole definition and a column that loses its NOT NULL is a different column.
function Bridge.WidenIdColumns()
    local placeholders = {}
    for _ = 1, #ID_COLUMNS do placeholders[#placeholders + 1] = '?' end

    local rows = MySQL.query.await(([[
        SELECT TABLE_NAME, COLUMN_NAME, IS_NULLABLE, COLUMN_DEFAULT
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME LIKE 'vphone!_%%' ESCAPE '!'
          AND COLUMN_NAME IN (%s)
          AND DATA_TYPE = 'varchar'
          AND CHARACTER_MAXIMUM_LENGTH < 64
    ]]):format(table.concat(placeholders, ',')), ID_COLUMNS) or {}

    if #rows == 0 then return 0 end

    local done = 0
    for _, r in ipairs(rows) do
        -- Rebuilt rather than guessed: MODIFY replaces the definition outright, so a column
        -- that came back without its NOT NULL would start accepting rows it used to refuse.
        local nullable = tostring(r.IS_NULLABLE or 'NO') == 'YES'
        local def = 'VARCHAR(64) ' .. (nullable and 'NULL' or 'NOT NULL')
        if r.COLUMN_DEFAULT ~= nil then
            def = def .. " DEFAULT " .. ("'%s'"):format(tostring(r.COLUMN_DEFAULT):gsub("'", "''"))
        elseif nullable then
            def = def .. ' DEFAULT NULL'
        end

        -- Table and column names come from information_schema, not from anything a player can
        -- reach, so back-quoting them is enough; there is nothing here to parameterise.
        local ok = pcall(MySQL.query.await, ('ALTER TABLE `%s` MODIFY COLUMN `%s` %s')
            :format(r.TABLE_NAME, r.COLUMN_NAME, def))
        if ok then
            done = done + 1
        else
            print(('[v-phone] could not widen %s.%s - widen it by hand if this server runs ESX '
                   .. 'or standalone'):format(r.TABLE_NAME, r.COLUMN_NAME))
        end
    end

    if done > 0 then
        print(('[v-phone] widened %d character-id column(s) to 64 characters. ESX and '
               .. 'standalone identifiers do not fit in 16.'):format(done))
    end
    return done
end


-- The columns our earliest build created in each table. Later versions only ever ADD
-- columns (through ALTER), so these are present in every version of our own tables, and
-- absent from anything that merely shares a name. Generated from the CREATE statements.
local SIGNATURE = {
    phone = {
        app_data        = { 'citizenid', 'app', 'k', 'v' },
        calls           = { 'id', 'citizenid', 'other_num', 'direction', 'answered' },
        characters      = { 'citizenid', 'firstname', 'lastname', 'dob', 'phone' },
        cipher_clears   = { 'citizenid', 'other_cid', 'before_id' },
        cipher_messages = { 'id', 'from_cid', 'to_cid', 'envelope', 'burn', 'expires_at' },
        cipher_profiles = { 'citizenid', 'handle', 'public_key', 'fingerprint' },
        contacts        = { 'id', 'citizenid', 'name', 'number', 'favourite' },
        group_members   = { 'group_id', 'citizenid' },
        groups          = { 'id', 'name', 'owner_cid' },
        kv              = { 'citizenid', 'key', 'value' },
        mail            = { 'id', 'from_addr', 'to_addr', 'subject', 'body' },
        mail_accounts   = { 'citizenid', 'address' },
        mail_box        = { 'id', 'mail_id', 'address', 'folder', 'seen', 'saved' },
        messages        = { 'id', 'from_cid', 'to_cid', 'body', 'seen' },
        notes           = { 'id', 'citizenid', 'title', 'body' },
        voicemail       = { 'id', 'citizenid', 'from_num', 'body', 'seen' },
    },
    social = {
        accounts   = { 'citizenid', 'app', 'handle', 'displayname', 'password', 'verified' },
        comments   = { 'id', 'post_id', 'citizenid', 'body' },
        dm         = { 'id', 'app', 'from_cid', 'to_cid', 'body', 'image', 'seen' },
        follows    = { 'app', 'from_cid', 'to_cid' },
        likes      = { 'post_id', 'citizenid' },
        posts      = { 'id', 'citizenid', 'kind', 'body', 'image' },
        reposts    = { 'post_id', 'citizenid' },
        stories    = { 'id', 'app', 'citizenid', 'image', 'body' },
        story_seen = { 'story_id', 'citizenid' },
    },
    hush = {
        likes    = { 'from_cid', 'to_cid', 'liked' },
        profiles = { 'citizenid', 'bio', 'photo', 'active' },
    },
}

local function tableExists(name)
    return MySQL.scalar.await([[SELECT 1 FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? LIMIT 1]], { name }) ~= nil
end

--- The columns of a table on disk, as a lookup.
local function columnsOf(name)
    local rows = MySQL.query.await([[SELECT COLUMN_NAME AS c FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?]], { name }) or {}
    local set = {}
    for _, r in ipairs(rows) do set[tostring(r.c):lower()] = true end
    return set
end

--- Does the table on disk contain every column our schema expects? A foreign table that
--- shares the name will not, which is the whole point.
local function matchesSignature(name, expected)
    local present = columnsOf(name)
    for _, col in ipairs(expected) do
        if not present[col:lower()] then return false end
    end
    return true
end

--- Rename `old` to `new`, but only when it is safe. `expected` is the column signature
--- of our own table; `mode` is the config value. Returns 'moved', 'skip-foreign',
--- 'skip-both' or nil (nothing there).
local function migrateOne(old, new, expected, mode)
    if not tableExists(old) then return nil end
    if tableExists(new) then
        -- Both exist: an earlier partial migration, or a server that made the new one by
        -- hand. Merging two tables is never safe to guess, so leave both.
        print(('[v-phone] migration: %s and %s both exist, leaving both untouched'):format(old, new))
        return 'skip-both'
    end

    -- The column check is the safety. `true` skips it on the operator's own head.
    if mode ~= true and not matchesSignature(old, expected) then
        print(('[v-phone] migration: `%s` exists but its columns are not ours - NOT touched. '
            .. 'A fresh `%s` will be created beside it.'):format(old, new))
        return 'skip-foreign'
    end

    MySQL.query.await(('RENAME TABLE `%s` TO `%s`'):format(old, new))
    return 'moved'
end

--- Run once at boot, before any table is created.
function Bridge.MigrateTables()
    -- Off unless something explicitly opts in: a fresh database should never be rewritten
    -- on first boot, and a missing setting means "do nothing", not "guess".
    --
    -- A convar wins over the config, so an operator upgrading a live server can turn the
    -- migration on for one boot without editing a file:
    --     set phone_migrate auto     # then remove it once the migration has run
    local mode = Config.MigrateLegacyTables
    local convar = GetConvar('phone_migrate', '')
    if convar == 'auto' then mode = 'auto'
    elseif convar == 'true' then mode = true
    elseif convar == 'false' then mode = false end

    if mode == nil or mode == false then return 0 end

    local moved, foreign = 0, 0
    for prefix, tables in pairs(SIGNATURE) do
        for base, expected in pairs(tables) do
            local old = prefix .. '_' .. base
            local new = (prefix == 'phone') and ('vphone_' .. base)
                or ('vphone_' .. prefix .. '_' .. base)
            local result = migrateOne(old, new, expected, mode)
            if result == 'moved' then moved = moved + 1
            elseif result == 'skip-foreign' then foreign = foreign + 1 end
        end
    end

    if moved > 0 then
        print(('[v-phone] migrated %d table(s) to the vphone_ prefix'):format(moved))
    end
    if foreign > 0 then
        print(('[v-phone] %d legacy-named table(s) were NOT ours and were left alone'):format(foreign))
    end
    return moved
end
