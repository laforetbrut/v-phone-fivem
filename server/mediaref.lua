-- v-phone | server/mediaref.lua
--
-- **Is anything still showing this photograph?**
--
-- The sweep in server/media.lua deletes an uploaded file when its time is up. Doing that
-- without asking this question is how a post keeps its caption and loses its picture, and it
-- is not hypothetical: with files expiring at thirty days and posts living sixty, the phone
-- has always been capable of it. Switching a server from a hosted CDN to its own bucket, where
-- the two clocks differ by months, turns "capable of" into "will".
--
-- So before a file goes, every place that can point at it is asked. Twenty of them, across six
-- tables and three keys of per-character storage.
--
-- **Three things make this harder than a list of columns, and each has cost somebody a bug.**
--
--  1. **The edit recipe rides in the URL's fragment.** `#vp=` carries the gallery's crop and
--     filter, and it is appended to the stored string - so `WHERE image = ?` answers "nobody is
--     using it" for every photograph a player has retouched. Every comparison here is
--     fragment-insensitive.
--
--  2. **Three references are not columns at all.** The gallery, the wallpaper and the card
--     photo live inside JSON in `vphone_kv`. Nothing that enumerates a schema can find them,
--     and they are the most visible things on the phone.
--
--  3. **Two columns exist only as `ALTER TABLE`.** `vphone_contacts.photo` and
--     `vphone_messages.attachment` appear in no `CREATE TABLE` in this resource, so a reader
--     looking for schemas misses them. The contact photo is worse than missed: after an AirDrop
--     it lives on somebody ELSE's row, so a per-owner cleanup would delete the face out of ten
--     other people's phone books.

Bridge = Bridge or {}

--- The URL without its edit recipe.
local function bare(url)
    return (tostring(url or ''):gsub('#.*$', ''))
end

--- Every SQL place a media URL can sit, as (table, column) pairs.
---
--- Written out rather than discovered, because two of them cannot be discovered: they were
--- added by `ALTER TABLE` and appear in no schema this resource declares. A list somebody has
--- to maintain is a liability; a list that silently misses two is a bug, so the list wins.
local COLUMNS = {
    { 'vphone_social_posts',    'image' },       -- Bleeter and Snapmatic, the cover
    { 'vphone_social_accounts', 'avatar' },
    { 'vphone_social_accounts', 'cover' },
    { 'vphone_social_stories',  'image' },
    { 'vphone_social_dm',       'image' },       -- social DMs and Hush chat share this table
    { 'vphone_hush_profiles',   'photo' },
    { 'vphone_hush_profiles',   'photo2' },
    { 'vphone_hush_profiles',   'photo3' },
    { 'vphone_fan_profiles',    'avatar' },      -- OnlyFruits
    { 'vphone_fan_profiles',    'cover' },
    { 'vphone_fan_posts',       'image' },
    { 'vphone_fund_pages',      'cover' },       -- Fruitee
    { 'vphone_fund_pages',      'avatar' },
    { 'vphone_mail',            'image' },       -- drafts count: a draft is still somebody's
    { 'vphone_messages',        'attachment' },  -- ALTER-only; also every GIF
    { 'vphone_contacts',        'photo' },       -- ALTER-only; may be on another person's row
}

--- The one column holding a JSON ARRAY of URLs rather than a single one.
---
--- `vphone_social_posts.images` is NULL on every legacy row and on every single-photo post, so
--- anybody testing with one photograph never sees this matter. The day it matters, photos two
--- to four vanish from a post whose cover still draws - which reads as a host glitch rather
--- than as a sweep that did not look here.
local JSON_ARRAYS = {
    { 'vphone_social_posts', 'images' },
}

--- Does a table exist? A server that never enabled Hush has no `vphone_hush_profiles`, and a
--- reference check that throws on a missing table would stop the sweep entirely - which fails
--- in the safe direction only by accident.
---
--- **Three answers, not two.** `true` and `false` are what the database said; `nil` is what it
--- says when it could not be asked at all, and that is not the same as "absent". The version
--- that collapsed the two deleted photographs: one transient error answered `false`, the answer
--- was remembered for the life of the resource, and every sweep afterwards skipped a table full
--- of live references without ever asking again. So a failure is never cached, and callers read
--- `nil` as "this table might hold a reference" rather than as "it does not".
local tableCache = {}

local function tableExists(name)
    if tableCache[name] ~= nil then return tableCache[name] end
    local ok, found = pcall(function()
        return MySQL.scalar.await([[SELECT 1 FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? LIMIT 1]], { name })
    end)
    if not ok then return nil end
    tableCache[name] = (found ~= nil)
    return tableCache[name]
end

--- Is this URL still shown anywhere?
---
--- Answers the place that holds it, or nil when nothing does. The place is returned rather than
--- a bare boolean so the sweep can say WHY it is keeping a file, which is the difference
--- between a log somebody can act on and one they switch off.
function Bridge.MediaReferencedBy(url)
    local plain = bare(url)
    if plain == '' then return nil end
    -- The stored value is either exactly the URL, or the URL plus a `#vp=` recipe. `LIKE` with
    -- the fragment marker rather than `LIKE '%url%'`: a bare wildcard would also match a
    -- LONGER url that merely starts the same way, and answer "still used" for a file nobody
    -- has - which fails safe but never lets anything expire.
    local like = plain .. '#%'

    for _, pair in ipairs(COLUMNS) do
        local tbl, col = pair[1], pair[2]
        local exists = tableExists(tbl)
        -- Not knowing whether the table is there is not the same as it not being there. The
        -- only honest answer is the same one a failed reference query gives: keep the file.
        if exists == nil then return tbl .. ' (schema query failed)' end
        if exists then
            local ok, hit = pcall(function()
                return MySQL.scalar.await(
                    ('SELECT 1 FROM `%s` WHERE `%s` = ? OR `%s` LIKE ? LIMIT 1')
                        :format(tbl, col, col), { plain, like })
            end)
            -- **A failed query is not an answer.** Swallowing it read as "nothing is using
            -- this" and deleted live media - on a transient error, or on the boot where a
            -- column is added and the query runs before the ALTER. Keeping the file costs
            -- storage; deleting it wrongly costs the photograph.
            if not ok then return tbl .. '.' .. col .. ' (query failed)' end
            if hit then return tbl .. '.' .. col end
        end
    end

    for _, pair in ipairs(JSON_ARRAYS) do
        local tbl, col = pair[1], pair[2]
        local exists = tableExists(tbl)
        if exists == nil then return tbl .. ' (schema query failed)' end
        if exists then
            -- A JSON array of quoted strings, so the URL is searched WITH its quotes. Without
            -- them `%url%` matches a longer URL that begins the same way.
            local ok, hit = pcall(function()
                return MySQL.scalar.await(
                    ('SELECT 1 FROM `%s` WHERE `%s` LIKE ? OR `%s` LIKE ? LIMIT 1')
                        :format(tbl, col, col),
                    { '%"' .. plain .. '"%', '%"' .. plain .. '#%' })
            end)
            if not ok then return tbl .. '.' .. col .. ' (query failed)' end
            if hit then return tbl .. '.' .. col end
        end
    end

    -- ── The three that are not columns ─────────────────────────
    -- The gallery, the wallpaper and the card photo live inside JSON blobs in the per-character
    -- store. There is no column to name and no index to use, so this is one LIKE over the value
    -- - which is why it runs LAST, after every cheap check has had its chance.
    local kvExists = tableExists('vphone_kv')
    if kvExists == nil then
        print('[v-phone] media: could not tell whether vphone_kv exists - keeping the file.')
        return 'vphone_kv (schema query failed)'
    end
    if kvExists then
        -- `key` and `value`, which is what bridge/server/kv.lua:116-121 declares. The first
        -- version of this asked for `k` and `v`; the pcall below swallowed the SQL error, so
        -- the check answered "not referenced" every single time and the gallery protected
        -- nothing. A guard that turns a wrong query into a confident wrong answer is worse
        -- than no guard, which is why the failure is now told apart from the miss.
        local ok, hit = pcall(function()
            return MySQL.scalar.await([[SELECT `key` FROM vphone_kv
                WHERE `key` IN ('photos', 'phone') AND `value` LIKE ? LIMIT 1]],
                { '%' .. plain .. '%' })
        end)
        if not ok then
            -- The query itself failed. Nothing can be concluded, and concluding "unreferenced"
            -- deletes somebody's gallery - so this answers "in use" and says why. A file kept
            -- too long costs storage; a file deleted wrongly costs the photograph.
            print('[v-phone] media: the gallery reference check failed - keeping the file. '
                  .. 'Check the vphone_kv table.')
            return 'vphone_kv (query failed)'
        end
        if hit then return 'vphone_kv.' .. tostring(hit) end
    end

    return nil
end

--- Take this URL out of the places that are the player's own settings.
---
--- Called when a file really is going. A post keeps its history whatever happens to its
--- picture, but a wallpaper, an avatar or a gallery tile pointing at nothing is not history -
--- it is a setting that no longer works, and leaving it is what turns an expired file into a
--- black screen or a hole where a face was.
---
--- Deliberately narrow: only the places that have a DESIGNED fallback to drop back to. The
--- gallery drops the tile, the wallpaper returns to the shipped gradient, an avatar returns to
--- the letter. Nothing rewrites a post, a message or a mail - those are records.
function Bridge.MediaForgetSettings(url)
    local plain = bare(url)
    if plain == '' then return 0 end
    local cleaned = 0

    -- Avatars and covers: emptied, so the letter placeholder that every one of these screens
    -- already draws takes over.
    for _, pair in ipairs({
        { 'vphone_social_accounts', 'avatar' },
        { 'vphone_social_accounts', 'cover' },
        { 'vphone_fan_profiles',    'avatar' },
        { 'vphone_fan_profiles',    'cover' },
        { 'vphone_fund_pages',      'cover' },
        { 'vphone_fund_pages',      'avatar' },
        { 'vphone_hush_profiles',   'photo' },
        { 'vphone_hush_profiles',   'photo2' },
        { 'vphone_hush_profiles',   'photo3' },
        { 'vphone_contacts',        'photo' },
    }) do
        local tbl, col = pair[1], pair[2]
        -- Attempted unless the table is KNOWN to be absent. An unknown answer tries anyway: if
        -- the table is there the setting is cleared, and if it is not the pcall below absorbs
        -- the error - where skipping would leave a wallpaper or an avatar pointing at a file
        -- that has just been deleted.
        if tableExists(tbl) ~= false then
            local ok, res = pcall(function()
                return MySQL.update.await(
                    ('UPDATE `%s` SET `%s` = %s WHERE `%s` = ? OR `%s` LIKE ?')
                        :format(tbl, col, "''", col, col),
                    { plain, plain .. '#%' })
            end)
            if ok and tonumber(res) then cleaned = cleaned + tonumber(res) end
        end
    end

    return cleaned
end
