-- v-phone | server/adminclean.lua
--
-- **Emptying an app, from the console.**
--
--     phoneclean                     the list of names it accepts, and nothing else
--     phoneclean bleeter             what WOULD go, counted table by table. Nothing is deleted.
--     phoneclean bleeter confirm     it goes.
--
-- **Nothing deletes on the first call, ever.** These commands destroy content players made and
-- there is no undo. A typo in a console must not cost six months of a server's social feed, so
-- the first call counts and prints, and only a second one with `confirm` acts. That is the
-- whole safety design and it is worth more than any amount of care in the wording.
--
-- Separate from `phoneadmin` on purpose. That command is for reading and nudging one player;
-- this one empties tables. Two different risks should not share a prefix, a help line, or an
-- accidental tab-completion.

local ADMIN = Config.Admin or {}

--- Same door as `phoneadmin`. Console always; in-game only with the ace.
local function allowed(src)
    if src == 0 then return true end
    return IsPlayerAceAllowed(src, ADMIN.ace or 'vphone.admin')
end

local function say(src, msg)
    if src == 0 then print('[v-phone] ' .. msg)
    else TriggerClientEvent('chat:addMessage', src, { args = { 'v-phone', msg } }) end
end

--- What each name empties.
---
--- Tables listed explicitly rather than discovered by prefix. `vphone_characters` and
--- `vphone_kv` hold the phone's identity and every player's settings; a cleanup that found
--- tables by pattern would eventually find those two, and the day it did there would be no
--- phones left. A list somebody has to extend is the correct trade here.
local TARGETS = {
    bleeter = { label = 'Bleeter (posts, comments, likes, reposts, saves, follows, tags)',
        tables = { 'vphone_social_posts', 'vphone_social_comments', 'vphone_social_likes',
                   'vphone_social_reposts', 'vphone_social_saves', 'vphone_social_follows',
                   'vphone_social_tags', 'vphone_social_notifs', 'vphone_social_stories',
                   'vphone_social_story_seen' },
        -- Accounts survive: a handle is somebody's identity, and deleting it silently frees
        -- their name for the next person to take. `phoneclean accounts` does that on purpose.
        note = 'accounts and handles are kept - use `phoneclean accounts` for those' },

    snapmatic = { label = 'Snapmatic', same = 'bleeter',
        note = 'Snapmatic and Bleeter share their tables; this cleans both' },

    accounts = { label = 'social accounts and handles (Bleeter and Snapmatic)',
        tables = { 'vphone_social_accounts' } },

    hush = { label = 'Hush (profiles, likes, matches)',
        tables = { 'vphone_hush_profiles', 'vphone_hush_likes' },
        -- Hush chat lives in the shared DM table under app='hush', so it is deleted by its
        -- own WHERE rather than by dropping a table other apps are using.
        extra = { { 'vphone_social_dm', "app = 'hush'" } } },

    dm = { label = 'social direct messages (Bleeter, Snapmatic and Hush)',
        tables = { 'vphone_social_dm', 'vphone_dm_hidden' } },

    onlyfruits = { label = 'OnlyFruits (creators, posts, subscriptions, unlocks)',
        tables = { 'vphone_fan_profiles', 'vphone_fan_posts', 'vphone_fan_subs',
                   'vphone_fan_follows', 'vphone_fan_unlocks', 'vphone_fan_tx' } },

    fruitee = { label = 'Fruitee fundraising pages and gifts',
        tables = { 'vphone_fund_pages', 'vphone_fund_gifts', 'vphone_fund_tx' } },

    messages = { label = 'text messages, groups and reactions',
        tables = { 'vphone_messages', 'vphone_groups', 'vphone_group_members',
                   'vphone_message_reactions', 'vphone_message_hidden' } },

    calls = { label = 'call history and voicemail',
        tables = { 'vphone_calls', 'vphone_voicemail' } },

    contacts = { label = 'every contact list', tables = { 'vphone_contacts' } },
    mail     = { label = 'Mail (messages, mailboxes and addresses)',
        tables = { 'vphone_mail', 'vphone_mail_box', 'vphone_mail_accounts' } },
    notes     = { label = 'Notes', tables = { 'vphone_notes' } },
    reminders = { label = 'Reminders', tables = { 'vphone_reminders' } },
    alerts    = { label = 'civil alerts', tables = { 'vphone_alerts' } },
    pins      = { label = 'map pins', tables = { 'vphone_pins' } },
    bank      = { label = 'bank statements and pending transfers',
        tables = { 'vphone_bank_tx', 'vphone_bank_pending', 'vphone_bankpro_log' } },
    lottery   = { label = 'lottery tickets and draws',
        tables = { 'vphone_lottery_tickets', 'vphone_lottery_sessions' } },
    zuber     = { label = 'Zuber orders', tables = { 'vphone_zuber_orders' } },
    repair    = { label = 'garage call-outs and reviews',
        tables = { 'vphone_repair_calls', 'vphone_repair_reviews', 'vphone_repair_served' } },
    export    = { label = 'export watchlists and alerts',
        tables = { 'vphone_export_watch', 'vphone_export_alerts' } },
    arcade    = { label = 'arcade scores and brawl stats',
        tables = { 'vphone_arcade_scores', 'vphone_brawl_stats' } },
    cipher    = { label = 'Cipher (profiles and encrypted messages)',
        tables = { 'vphone_cipher_profiles', 'vphone_cipher_messages', 'vphone_cipher_clears' } },
    reviews   = { label = 'FruitStore reviews', tables = { 'vphone_app_reviews' } },
    appdata   = { label = 'storage belonging to dropped-in apps', tables = { 'vphone_app_data' } },
}

--- How many rows a target holds.
local function countOf(target)
    local total, per = 0, {}
    for _, tbl in ipairs(target.tables or {}) do
        local ok, n = pcall(function()
            return MySQL.scalar.await(('SELECT COUNT(*) FROM `%s`'):format(tbl))
        end)
        n = (ok and tonumber(n)) or 0
        if n > 0 then per[#per + 1] = ('%s %d'):format(tbl, n) end
        total = total + n
    end
    for _, e in ipairs(target.extra or {}) do
        local ok, n = pcall(function()
            return MySQL.scalar.await(('SELECT COUNT(*) FROM `%s` WHERE %s'):format(e[1], e[2]))
        end)
        n = (ok and tonumber(n)) or 0
        if n > 0 then per[#per + 1] = ('%s %d'):format(e[1] .. ' (' .. e[2] .. ')', n) end
        total = total + n
    end
    return total, per
end

local function wipe(target)
    local gone = 0
    for _, tbl in ipairs(target.tables or {}) do
        local ok = pcall(function() MySQL.query.await(('DELETE FROM `%s`'):format(tbl)) end)
        if ok then gone = gone + 1 end
    end
    for _, e in ipairs(target.extra or {}) do
        pcall(function()
            MySQL.query.await(('DELETE FROM `%s` WHERE %s'):format(e[1], e[2]))
        end)
    end
    return gone
end

--- Every uploaded file, gone from the host as well as from the phone.
---
--- Slower than a DELETE and deliberately so: each file is a request to the storage provider,
--- and dropping the rows without asking would leave every file on the operator's bill with
--- nothing left that knows its name.
local function wipeMedia(src)
    local rows = MySQL.query.await('SELECT id, url, media_id FROM vphone_media') or {}
    local removed, failed = 0, 0
    for _, r in ipairs(rows) do
        if Bridge.MediaForgetSettings then Bridge.MediaForgetSettings(r.url) end
        local ok = Bridge.MediaDeleteOne and Bridge.MediaDeleteOne(r.url, r.media_id)
        if ok == false then failed = failed + 1
        else
            MySQL.query.await('DELETE FROM vphone_media WHERE id = ?', { r.id })
            removed = removed + 1
        end
        if (removed + failed) % 25 == 0 then Wait(0) end
    end
    say(src, ('media: %d file(s) deleted, %d the host would not remove (rows kept so they can '
        .. 'be retried)'):format(removed, failed))
end

local function resolve(name)
    local t = TARGETS[name]
    if t and t.same then
        local base = TARGETS[t.same]
        return { label = t.label, note = t.note, tables = base.tables, extra = base.extra }
    end
    return t
end

RegisterCommand('phoneclean', function(src, args)
    if not allowed(src) then say(src, 'not allowed') return end
    local what = tostring(args[1] or ''):lower()
    local confirm = tostring(args[2] or ''):lower() == 'confirm'

    if what == '' then
        say(src, 'phoneclean <what> [confirm]   - nothing is deleted without `confirm`')
        local names = {}
        for k in pairs(TARGETS) do names[#names + 1] = k end
        table.sort(names)
        say(src, 'what: ' .. table.concat(names, ', ') .. ', media, all')
        return
    end

    -- ── Every uploaded photograph and clip ─────────────────────
    if what == 'media' then
        local n = MySQL.scalar.await('SELECT COUNT(*) FROM vphone_media') or 0
        if not confirm then
            say(src, ('media: %d uploaded file(s) would be deleted from the host AND from the '
                .. 'phone. Avatars, wallpapers and gallery tiles pointing at them are cleared '
                .. 'so nothing is left showing a hole. Run `phoneclean media confirm`.')
                :format(tonumber(n) or 0))
            return
        end
        say(src, ('media: deleting %d file(s)...'):format(tonumber(n) or 0))
        CreateThread(function() wipeMedia(src) end)
        return
    end

    -- ── Everything ─────────────────────────────────────────────
    if what == 'all' then
        local total = 0
        for _, name in pairs(TARGETS) do
            if not name.same then total = total + (select(1, countOf(name))) end
        end
        if not confirm then
            say(src, ('all: %d row(s) across every app would be deleted. Phones, numbers and '
                .. 'settings are KEPT; content is not. Uploaded files are NOT touched - run '
                .. '`phoneclean media confirm` separately. Run `phoneclean all confirm`.')
                :format(total))
            return
        end
        local n = 0
        for key, t in pairs(TARGETS) do
            if not t.same then n = n + wipe(resolve(key)) end
        end
        say(src, ('all: emptied %d table(s).'):format(n))
        Core.Log('admin', 'phoneclean all', nil, nil)
        return
    end

    local target = resolve(what)
    if not target then say(src, 'unknown: ' .. what) return end

    local total, per = countOf(target)
    if not confirm then
        say(src, ('%s: %d row(s) would be deleted.'):format(target.label, total))
        if #per > 0 then say(src, '  ' .. table.concat(per, ', ')) end
        if target.note then say(src, '  ' .. target.note) end
        say(src, ('  run `phoneclean %s confirm` to do it'):format(what))
        return
    end

    wipe(target)
    say(src, ('%s: %d row(s) deleted.'):format(target.label, total))
    Core.Log('admin', ('phoneclean %s (%d rows)'):format(what, total), nil, nil)
end, false)
