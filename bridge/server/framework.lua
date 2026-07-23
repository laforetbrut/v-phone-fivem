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
    print(('[v-phone] framework: %s%s'):format(Bridge.framework,
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

--- Register a usable item across qb and qbx. Both export CreateUseableItem directly, so
--- neither needs the shared object.
function Bridge.QBUsable(item, fn)
    if not Bridge.frameworkResource then return false end
    local ok = pcall(function()
        exports[Bridge.frameworkResource]:CreateUseableItem(item, function(src) fn(src) end)
    end)
    return ok
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
    p.lang = GetConvar('phone_locale', 'en')
    function p.GetMetadata(key) return Bridge.KvGet(citizenid, key) end
    function p.SetMetadata(key, value) return Bridge.KvSet(citizenid, key, value) end
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
        for group, grade in pairs(groups) do
            -- ox has no single "job": the first group that is not a permission group is
            -- the closest honest answer, and a server can name its own in the config.
            if not Config.Compat.ignoredGroups[group] then
                jobName, jobGrade = group, grade
                break
            end
        end
        return wrap(src, tostring(player.charId),
            ((player.firstName or '') .. ' ' .. (player.lastName or '')):gsub('^%s+', ''),
            { name = jobName, label = jobName, grade = jobGrade, gradeLabel = tostring(jobGrade),
              onDuty = true, boss = false })

    elseif Bridge.framework == 'esx' then
        local player = esxPlayer(src)
        if not player then return nil end
        local job = player.getJob and player.getJob() or {}
        return wrap(src, player.identifier, player.getName and player.getName() or nil,
            { name = job.name or 'unemployed', label = job.label or job.name or 'Unemployed',
              grade = job.grade or 0, gradeLabel = job.grade_label or '',
              onDuty = true, boss = false })
    end

    -- Standalone: the phone still works, it simply has no job and no character name.
    return wrap(src, licenceOf(src), GetPlayerName(src), nil)
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
