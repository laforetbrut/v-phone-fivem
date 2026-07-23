-- v-phone | bridge/server/migrate.lua
--
-- **One prefix, and a safe way to reach it.**
--
-- Every table this resource creates begins with `vphone_`, so it can never collide with
-- a table another script owns. A server that ran an earlier build has the same data
-- under the old `phone_`, `social_` and `hush_` names; this renames those in place at
-- boot, once, so nobody loses a message or a contact to the change.
--
-- The rename is conditional on three things, all of which must hold, so it can never
-- touch a table that is not ours:
--
--  1. the OLD name exists,
--  2. the NEW name does not,
--  3. the old name is one this resource is known to have created.
--
-- A server that never ran an old build has none of the old tables and the whole pass is
-- a handful of catalogue reads that find nothing.

Bridge = Bridge or {}

-- Every table this resource owns, without its prefix. The migration renames `phone_X`,
-- `social_X` and `hush_X` to `vphone_...`, and nothing else in the schema is touched.
local OWNED = {
    -- phone_X  ->  vphone_X
    phone = {
        'app_data', 'calls', 'characters', 'cipher_clears', 'cipher_messages',
        'cipher_profiles', 'contacts', 'group_members', 'groups', 'kv',
        'mail', 'mail_accounts', 'mail_box', 'messages', 'notes', 'voicemail',
    },
    -- social_X  ->  vphone_social_X
    social = {
        'accounts', 'comments', 'dm', 'follows', 'likes',
        'posts', 'reposts', 'stories', 'story_seen',
    },
    -- hush_X  ->  vphone_hush_X
    hush = { 'likes', 'profiles' },
}

local function tableExists(name)
    return MySQL.scalar.await([[SELECT 1 FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? LIMIT 1]], { name }) ~= nil
end

--- Rename `old` to `new` only if `old` is there and `new` is not. The names come from
--- the constant table above, never from a caller, so the identifier interpolation is
--- safe: there is no user input anywhere near this query.
local function renameIfNeeded(old, new)
    if not tableExists(old) then return false end
    if tableExists(new) then
        -- Both exist: an earlier partial migration, or a server that manually made the
        -- new one. Leave both alone rather than risk merging two tables into one.
        print(('[v-phone] migration: %s and %s both exist, leaving them untouched'):format(old, new))
        return false
    end
    MySQL.query.await(('RENAME TABLE `%s` TO `%s`'):format(old, new))
    return true
end

--- Run once at boot, before any table is created. Returns how many it renamed, so the
--- one log line is truthful about whether anything happened.
function Bridge.MigrateTables()
    local moved = 0
    for prefix, names in pairs(OWNED) do
        for _, base in ipairs(names) do
            local old = prefix .. '_' .. base
            -- phone_ -> vphone_ ; social_/hush_ keep their word and gain the vphone_ prefix.
            local new = (prefix == 'phone') and ('vphone_' .. base)
                or ('vphone_' .. prefix .. '_' .. base)
            if renameIfNeeded(old, new) then moved = moved + 1 end
        end
    end
    if moved > 0 then
        print(('[v-phone] migrated %d table(s) to the vphone_ prefix'):format(moved))
    end
    return moved
end
