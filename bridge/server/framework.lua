-- v-phone | bridge/server/framework.lua
--
-- **One player object, whatever framework is underneath.**
--
-- The phone asks its `Core` for a player and then reads four things off it: a stable id,
-- a display name, a job, and a place to keep per-character preferences. Every framework
-- spells those differently. This file is where the spelling stops mattering.
--
-- Supported, detected in this order:
--
--     qb-core / qbx_core     PlayerData.citizenid, .charinfo, .job, .metadata
--     ox_core                player.charId, .firstName, .lastName, ox job groups
--     es_extended            xPlayer.identifier, .getName(), .job
--     standalone             the licence identifier, with everything else defaulted
--
-- Nothing below reaches into a framework's database. Phone preferences live in the
-- phone's own `vphone_kv` table (see kv.lua): a framework's metadata column is its own
-- business, and a phone that writes into it is a phone that breaks on the next update.

Bridge = Bridge or {}

local FRAMEWORKS = {
    { id = 'qb',   resources = { 'qbx_core', 'qb-core' } },
    { id = 'ox',   resources = { 'ox_core' } },
    { id = 'esx',  resources = { 'es_extended' } },
}

--- Which framework is running. `Config.Framework` may name one explicitly; `auto` looks.
local function detectFramework()
    local wanted = (Config.Framework or 'auto'):lower()
    if wanted ~= 'auto' then
        for _, f in ipairs(FRAMEWORKS) do
            if f.id == wanted then
                for _, res in ipairs(f.resources) do
                    if GetResourceState(res) == 'started' then return f.id, res end
                end
                print(('[v-phone] framework "%s" was named in the config but is not started'):format(wanted))
                return wanted, nil
            end
        end
        return 'standalone', nil
    end
    for _, f in ipairs(FRAMEWORKS) do
        for _, res in ipairs(f.resources) do
            if GetResourceState(res) == 'started' then return f.id, res end
        end
    end
    return 'standalone', nil
end

Bridge.framework, Bridge.frameworkResource = 'standalone', nil

-- The framework's own object, fetched once. qb hands out a shared table; ox and ESX are
-- reached through exports.
local QB, ESX

local function loadFramework()
    Bridge.framework, Bridge.frameworkResource = detectFramework()
    if Bridge.framework == 'qb' and Bridge.frameworkResource then
        -- Classic qb-core hands out a shared object. qbx_core deliberately does not:
        -- it exposes GetPlayer / CreateUseableItem / GetJobs as direct exports instead.
        -- `QB` stays nil on qbx, and every qb reader below goes through the helpers,
        -- which know both.
        local ok, core = pcall(function() return exports[Bridge.frameworkResource]:GetCoreObject() end)
        QB = ok and core or nil
    elseif Bridge.framework == 'esx' then
        local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
        ESX = ok and obj or nil
    end
    V.Info(('[v-phone] framework: %s%s'):format(Bridge.framework,
        Bridge.frameworkResource and (' (' .. Bridge.frameworkResource .. ')') or ''))
end

-- ══════════════════════════════════════════════════════════════
-- The player
-- ══════════════════════════════════════════════════════════════
-- Every reader below answers for whichever framework is loaded, and answers something
-- usable when none is. `citizenid` is the key everything in the phone hangs off, so it
-- is the one field that is never allowed to be nil: without a framework it falls back to
-- the player's licence, which is stable for as long as they own that account.

local function licenceOf(src)
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id and id:sub(1, 8) == 'license:' then return id:sub(9) end
    end
    return tostring(src)
end

--- Is qbx running rather than classic qb-core? They share a player SHAPE but not the
--- way you reach it.
local function isQbox() return Bridge.frameworkResource == 'qbx_core' end

--- A qb-style player object, from whichever qb variant is running. This is the ONE place
--- that knows qbx has no shared object, so nothing else has to.
function Bridge.QBGetPlayer(src)
    if isQbox() then
        local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        return ok and p or nil
    end
    return QB and QB.Functions.GetPlayer(src) or nil
end

--- The classic shared object, or nil on qbx. Callers that only need a player use
--- QBGetPlayer; this exists for the few that read QB.Shared or QB.Functions directly.
function Bridge.QBCore() return QB end

--- Register a usable item across qb and qbx.
---
--- They do NOT agree on this, despite the shared shape. qbx_core exports
--- `CreateUseableItem`; classic qb-core does not - its full export list is SetMethod,
--- SetField, the job/gang/item-registry helpers, GetCoreVersion and ExploitBan, and nothing
--- else. `CreateUseableItem` lives only on the shared object there.
---
--- Reaching for the export first was silently wrong on qb-core: the call raised inside a
--- pcall, the pcall swallowed it, and the item was simply never registered. No error, no
--- log, just a power bank and a calling card that did nothing when used.
function Bridge.QBUsable(item, fn)
    if not Bridge.frameworkResource then return false end
    local handler = function(src) fn(src) end

    -- The shared object: classic qb-core's only route.
    local QBShared = Bridge.QBCore()
    if QBShared and QBShared.Functions and QBShared.Functions.CreateUseableItem then
        if pcall(QBShared.Functions.CreateUseableItem, item, handler) then return true end
    end

    -- qbx_core deliberately has no shared object and exports it instead.
    return pcall(function()
        exports[Bridge.frameworkResource]:CreateUseableItem(item, handler)
    end)
end

--- How many of an item a qb player carries, read from the player object itself.
---
--- Modern qb-core has NO `Functions.GetItemByName` and no `Functions.RemoveItem` - item
--- handling was moved out to qb-inventory, and `GetItemByName` does not appear anywhere in
--- the qb-core repository any more. Calling them raised "attempt to call a nil value".
--- `PlayerData.items` is the one thing every qb build still has.
---
--- Returns nil when there is genuinely no way to tell, which callers treat differently from
--- an answer of zero.
function Bridge.QBItemCount(src, item)
    local p = Bridge.QBGetPlayer(src)
    local items = p and p.PlayerData and p.PlayerData.items
    if type(items) ~= 'table' then return nil end

    local total, wanted = 0, tostring(item or ''):lower()
    for _, row in pairs(items) do
        if type(row) == 'table' and tostring(row.name or ''):lower() == wanted then
            -- Forks disagree on the field name; both are accepted rather than betting on one.
            total = total + (tonumber(row.amount) or tonumber(row.count) or 0)
        end
    end
    return total
end

local function qbPlayer(src) return Bridge.QBGetPlayer(src) end

local function oxPlayer(src)
    local ok, player = pcall(function() return exports.ox_core:GetPlayer(src) end)
    return ok and player or nil
end

local function esxPlayer(src) return ESX and ESX.GetPlayerFromId(src) or nil end

--- A phone player: the same fields upstream's v-core hands out.
---
---     citizenid   stable per character
---     name        what other players see
---     job         { name, label, grade, gradeLabel, onDuty, boss }
---     source      the server id, when they are online
---     GetMetadata / SetMetadata   per-character storage, in the phone's own table
local function wrap(src, citizenid, name, job)
    if not citizenid then return nil end
    local p = {
        source = src,
        citizenid = citizenid,
        name = name or ('Citizen ' .. tostring(citizenid):sub(1, 6)),
        job = job or { name = 'unemployed', label = 'Unemployed', grade = 0, gradeLabel = '', onDuty = true, boss = false },
    }
    p.lang = GetConvar('phone_locale', LOCALE_FALLBACK or 'fr')
    function p.GetMetadata(key) return Bridge.KvGet(citizenid, key) end
    function p.SetMetadata(key, value) return Bridge.KvSet(citizenid, key, value) end

    --- The same write, WAITED ON.
    ---
    --- `SetMetadata` fires the query and returns, which is right for anything the cache can
    --- answer for until the next tick. It is wrong for something a player would notice losing:
    --- an un-awaited query dies in the queue if the process tears down first, which is exactly
    --- how a photo taken a few seconds before a restart was gone afterwards. The player saw it
    --- in their gallery - the cache had it - and the row never landed.
    function p.SetMetadataSync(key, value) return Bridge.KvSetSync(citizenid, key, value) end
    return p
end

local function jobFromQb(data)
    if not data then return nil end
    return {
        name = data.name or 'unemployed',
        label = data.label or data.name or 'Unemployed',
        grade = (data.grade and (data.grade.level or data.grade)) or 0,
        gradeLabel = (data.grade and data.grade.name) or '',
        onDuty = data.onduty ~= false,
        boss = (data.isboss == true) or (data.grade and data.grade.isboss == true) or false,
        -- What qb is actually paying this character. Kept because it is authoritative: the
        -- shared job table says what the grade is worth in general, this says what THIS
        -- character receives, and a script that granted a rise changed only this one.
        pay = tonumber(data.payment),
    }
end

function Bridge.GetPlayer(src)
    src = tonumber(src)
    if not src then return nil end

    if Bridge.framework == 'qb' then
        local player = qbPlayer(src)
        if not player then return nil end
        local data = player.PlayerData
        local info = data.charinfo or {}
        return wrap(src, data.citizenid,
            ((info.firstname or '') .. ' ' .. (info.lastname or '')):gsub('^%s+', ''),
            jobFromQb(data.job))

    elseif Bridge.framework == 'ox' then
        local player = oxPlayer(src)
        if not player then return nil end
        -- ox hands the player object across the export boundary as DATA: the fields
        -- survive, the methods do not. Anything that needs a method goes back through
        -- `CallPlayer`, which is what that export is for.
        local ok, groups = pcall(function()
            return exports.ox_core:CallPlayer(src, 'getGroups')
        end)
        groups = (ok and type(groups) == 'table') and groups or {}
        local jobName, jobGrade = 'unemployed', 0
        -- **`pairs` has no order.** ox has no single "job", so one group has to be chosen, and
        -- the first version took whichever one `pairs` happened to hand over first and broke.
        -- For a character in two non-permission groups that is a job which changes between two
        -- opens of the same app with nothing having happened - and it is invisible in testing,
        -- because a character in one group is stable and that is what anybody tests with.
        --
        -- The highest grade wins, which is also the more useful answer: somebody who is a
        -- sergeant of police and a hand at the garage reads as police. The name breaks a tie,
        -- so two groups at the same grade still pick the same one every time.
        --
        -- `picked` rather than testing jobName against 'unemployed': a server is allowed to
        -- have a group actually NAMED unemployed, and comparing against the sentinel would
        -- then let every later group overwrite it however low its grade.
        local picked = false
        for group, grade in pairs(groups) do
            if not Config.Compat.ignoredGroups[group] then
                local g = tonumber(grade) or 0
                if not picked or g > jobGrade or (g == jobGrade and group < jobName) then
                    jobName, jobGrade, picked = group, g, true
                end
            end
        end
        -- The names ox already has. `ox_groups.label` and `ox_group_grades.label` are read by
        -- the Jobs catalogue and were never read here, so the one job a player sees on their
        -- own card was the only one shown as a raw key and a bare number.
        local named = (Bridge.OxGroupLabels and Bridge.OxGroupLabels() or {})[jobName] or {}
        return wrap(src, tostring(player.charId),
            ((player.firstName or '') .. ' ' .. (player.lastName or '')):gsub('^%s+', ''),
            { name = jobName, label = named.label or jobName, grade = jobGrade,
              gradeLabel = (named.grades or {})[jobGrade] or tostring(jobGrade),
              -- ox_core has no boss flag either; a group's own grade list decides, and the
              -- operator names the grade that counts as one. Nil means "do not guess", and
              -- Bank Pro's `minGrade` is the route on such a server.
              boss = (Config.Compat.bossGrade ~= nil)
                     and (jobGrade >= tonumber(Config.Compat.bossGrade)) or false,
              onDuty = true })

    elseif Bridge.framework == 'esx' then
        local player = esxPlayer(src)
        if not player then return nil end
        local job = player.getJob and player.getJob() or {}
        return wrap(src, player.identifier, player.getName and player.getName() or nil,
            { name = job.name or 'unemployed', label = job.label or job.name or 'Unemployed',
              grade = job.grade or 0, gradeLabel = job.grade_label or '',
              -- ESX puts the grade's wage on the job object it hands over, so the card needs
              -- no second lookup to be right.
              pay = tonumber(job.grade_salary),
              -- **A boss on ESX is the grade NAMED `boss`.** ESX has no `isboss` flag - that is
              -- qb's - and esx_society decides who may open a society account by the grade name.
              -- This used to answer `false` unconditionally, which meant `requireBoss` locked
              -- every ESX player out of Bank Pro and looked like the app refusing to work.
              boss = tostring(job.grade_name or ''):lower() == 'boss',
              -- ESX has no duty concept of its own, so everybody holding the job is on it. A
              -- server running esx_service points `Config.Compat.hooks.onDuty` at the real
              -- answer; see the hook below.
              onDuty = true })
    end

    -- Standalone: the phone still works, it simply has no job and no character name.
    return wrap(src, licenceOf(src), GetPlayerName(src), nil)
end

--- **Is this character clocked on?**
---
--- qb answers it itself. ESX and ox have no duty concept, so the bridge reports everybody holding
--- the job as on duty - which is the safe direction: the cost of getting it wrong that way is a
--- taxi driver who is called out when they did not want to be, and the cost of the other way is
--- an app that never works at all on those frameworks.
---
--- A server that DOES track duty - esx_service, a boolean on the player, a table of its own -
--- points `Config.Compat.hooks.onDuty` at the real answer and every app that asks about duty
--- follows: the taxi queue, 911's responders, Bank Pro.
---
---     onDuty = function(src, job) return exports['esx_service']:IsInService(src, job) end
---
--- Returning nil from the hook means "no opinion", and the framework's own answer stands.
function Bridge.OnDuty(src, p)
    local job = p and p.job
    if type(job) ~= 'table' then return false end

    local hook = Config.Compat.hooks and Config.Compat.hooks.onDuty
    if hook then
        local ok, answer = pcall(hook, src, job)
        if ok and answer ~= nil then return answer == true end
    end
    return job.onDuty ~= false
end

--- The same player, addressed by citizen id. Used when the phone has to reach somebody
--- it only knows by the id stored on a message or a match.
function Bridge.GetPlayerByCitizenId(cid)
    cid = tostring(cid or '')
    if cid == '' then return nil end
    for _, src in ipairs(GetPlayers()) do
        local p = Bridge.GetPlayer(tonumber(src))
        if p and p.citizenid == cid then return p end
    end
    return nil
end

--- Offline-safe: the phone often needs a name for somebody who is not connected.
function Bridge.NameOfCitizen(cid)
    local online = Bridge.GetPlayerByCitizenId(cid)
    if online then return online.name end
    return Bridge.CharacterName(cid)
end

-- ══════════════════════════════════════════════════════════════
-- Notifications
-- ══════════════════════════════════════════════════════════════
-- Every framework has one, and a server that has bought a notification script wants that
-- one instead. `Config.Compat.notify` picks; `auto` uses the framework's.
function Bridge.Notify(src, message, kind)
    kind = kind or 'inform'
    local mode = (Config.Compat.notify or 'auto'):lower()

    if mode == 'auto' then
        if GetResourceState('ox_lib') == 'started' then mode = 'ox_lib'
        elseif Bridge.framework == 'qb' then mode = 'qb'
        elseif Bridge.framework == 'esx' then mode = 'esx'
        else mode = 'chat' end
    end

    if mode == 'ox_lib' then
        TriggerClientEvent('ox_lib:notify', src, { title = 'iFruit', description = message, type = kind })
    elseif mode == 'qb' then
        TriggerClientEvent('QBCore:Notify', src, message, kind == 'error' and 'error' or 'primary')
    elseif mode == 'esx' then
        TriggerClientEvent('esx:showNotification', src, message)
    elseif mode == 'custom' then
        TriggerClientEvent(Config.Compat.notifyEvent, src, message, kind)
    else
        TriggerClientEvent('chat:addMessage', src, { args = { 'iFruit', message } })
    end
end

-- ══════════════════════════════════════════════════════════════
-- Core, as the phone expects it
-- ══════════════════════════════════════════════════════════════
Core = {
    GetPlayer = function(src) return Bridge.GetPlayer(src) end,
    GetPlayerByCitizenId = function(cid) return Bridge.GetPlayerByCitizenId(cid) end,
    -- Upstream's core carries a notifier and server/main.lua calls it. It was missing here,
    -- so every `Core.Notify` reached a nil field: the power bank raised an error instead of
    -- telling the player it had charged their phone. Same destination as V.Notify.
    Notify = function(src, message, kind) return Bridge.Notify(src, message, kind) end,
    Log = function(category, message, _, cid)
        if not Config.Compat.log then return end
        print(('[v-phone] %s: %s%s'):format(category, message, cid and (' (' .. cid .. ')') or ''))
    end,
}

CreateThread(function()
    -- Give a named framework a moment to start; `auto` finds whatever is up by then.
    for _ = 1, 100 do
        local id = detectFramework()
        if id ~= 'standalone' then break end
        Wait(100)
    end
    loadFramework()
    V.MarkReady()
end)
