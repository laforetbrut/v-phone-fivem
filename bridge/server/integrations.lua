-- v-phone | bridge/server/integrations.lua
--
-- **Where the phone meets the rest of the server.**
--
-- Upstream, each app is a view over a v-* module that owns the data: the bank app over
-- v-banking, the garage app over v-vehicles, and so on. None of those exist here, so
-- each of them becomes a PROVIDER: a small table with the two or three functions that
-- app actually needs, implemented once per ecosystem.
--
-- Every provider follows the same three rules:
--
--  1. **Auto-detected, overridable.** `Config.Compat.<thing>` is `auto` by default and
--     picks whatever is running. Naming one explicitly always wins.
--  2. **Absent is not broken.** A provider that finds nothing to talk to returns nil,
--     and the phone hides the app rather than showing an empty one.
--  3. **Read-mostly.** The phone shows a balance and a garage list. It does not move
--     money or spawn cars: those belong to the scripts that own them.
--
-- Supported out of the box: qb-core, qbx_core, ox_core, es_extended, ox_inventory,
-- qs-inventory, qb-inventory, ps-inventory, Renewed-Banking, qb-banking, okokBanking,
-- Quasar's inventory / banking / housing / vehicleshop, and a `custom` mode where a
-- server points each hook at its own exports without touching this file.

Bridge = Bridge or {}

local function started(resource)
    return resource and resource ~= '' and GetResourceState(resource) == 'started'
end

--- The first started resource in a list, or nil.
local function firstStarted(list)
    for _, res in ipairs(list or {}) do
        if started(res) then return res end
    end
    return nil
end

--- Read a config choice: `auto` scans the list, a name is taken at its word, `off`
--- disables the integration entirely.
local function choose(key, candidates)
    local wanted = tostring(Config.Compat[key] or 'auto'):lower()
    if wanted == 'off' then return nil end
    if wanted ~= 'auto' then return started(wanted) and wanted or nil end
    return firstStarted(candidates)
end

local function callExport(resource, method, ...)
    if not started(resource) then return nil end
    local ok, result = pcall(function(...) return exports[resource][method](exports[resource], ...) end, ...)
    if not ok then return nil end
    return result
end

-- ══════════════════════════════════════════════════════════════
-- Phone numbers
-- ══════════════════════════════════════════════════════════════
-- A number has to survive a restart and belong to one character, so it is stored, and
-- the only question is where. If the framework already keeps one - qb writes it into
-- charinfo - the phone uses THAT, so a character keeps the number other scripts already
-- know. Otherwise the phone mints and keeps its own.
Bridge.Numbers = {}

function Bridge.Numbers.Get(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return nil end

    if Config.Compat.numbers == 'framework' or Config.Compat.numbers == 'auto' then
        if Bridge.framework == 'qb' then
            local raw = MySQL.scalar.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
            if raw then
                local ok, info = pcall(json.decode, raw)
                if ok and info and info.phone and info.phone ~= '' then return tostring(info.phone) end
            end
        elseif Bridge.framework == 'ox' then
            local phone = MySQL.scalar.await('SELECT phoneNumber FROM characters WHERE charId = ?', { citizenid })
            if phone and phone ~= '' then return tostring(phone) end
        end
    end

    return Bridge.KvGet(citizenid, 'number')
end

function Bridge.Numbers.Set(citizenid, number)
    Bridge.KvSet(tostring(citizenid), 'number', number)

    -- Write it back where the framework keeps its own, so a script that reads the
    -- character's phone number from the framework agrees with the phone.
    if Config.Compat.numbers ~= 'phone' then
        if Bridge.framework == 'qb' then
            local raw = MySQL.scalar.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
            local ok, info = pcall(json.decode, raw or '{}')
            info = ok and info or {}
            info.phone = number
            MySQL.query('UPDATE players SET charinfo = ? WHERE citizenid = ?', { json.encode(info), citizenid })
        elseif Bridge.framework == 'ox' then
            MySQL.query('UPDATE characters SET phoneNumber = ? WHERE charId = ?', { number, citizenid })
        end
    end
end

--- Who owns a number, by citizen id. One indexed read rather than a scan of everybody.
function Bridge.Numbers.Owner(number)
    number = tostring(number or '')
    if number == '' then return nil end

    local own = MySQL.scalar.await("SELECT citizenid FROM phone_kv WHERE `key` = 'number' AND value = ?",
        { json.encode(number) })
    if own then return own end

    if Bridge.framework == 'qb' then
        return MySQL.scalar.await(
            "SELECT citizenid FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.phone')) = ?", { number })
    elseif Bridge.framework == 'ox' then
        return MySQL.scalar.await('SELECT charId FROM characters WHERE phoneNumber = ?', { number })
    end
    return nil
end

--- The character's display name, for somebody who is not connected.
function Bridge.CharacterName(citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return nil end
    if Bridge.framework == 'qb' then
        local raw = MySQL.scalar.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        local ok, info = pcall(json.decode, raw or '{}')
        if ok and info then
            return ((info.firstname or '') .. ' ' .. (info.lastname or '')):gsub('^%s+', '')
        end
    elseif Bridge.framework == 'ox' then
        local row = MySQL.single.await('SELECT firstName, lastName FROM characters WHERE charId = ?', { citizenid })
        if row then return ((row.firstName or '') .. ' ' .. (row.lastName or '')):gsub('^%s+', '') end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Inventory: does this character carry a phone?
-- ══════════════════════════════════════════════════════════════
-- Only consulted when `requireItem` is on. Off - the default - everybody has a phone,
-- which is the friendlier setting for a server that has not decided yet.
local INVENTORIES = { 'ox_inventory', 'qs-inventory', 'ps-inventory', 'qb-inventory', 'origen_inventory', 'codem-inventory' }

function Bridge.InventoryResource()
    return choose('inventory', INVENTORIES)
end

function Bridge.HasItem(src, item)
    item = item or Config.PhoneItem or 'phone'
    local inv = Bridge.InventoryResource()

    if inv == 'ox_inventory' then
        local count = callExport(inv, 'GetItemCount', src, item)
        return (tonumber(count) or 0) > 0
    end

    -- Quasar names it `GetItemTotalAmount`, which returns a plain count.
    if inv == 'qs-inventory' then
        local count = callExport(inv, 'GetItemTotalAmount', src, item)
        if count ~= nil then return (tonumber(count) or 0) > 0 end
    end

    -- The qb family answers with a row, or with a count, depending on the fork. Both
    -- shapes are accepted rather than betting on one.
    if inv == 'ps-inventory' or inv == 'qb-inventory'
        or inv == 'origen_inventory' or inv == 'codem-inventory' then
        local result = callExport(inv, 'GetItemByName', src, item)
        if type(result) == 'table' then return (tonumber(result.amount) or 0) > 0 end
        if type(result) == 'number' then return result > 0 end
        local count = callExport(inv, 'GetItemCount', src, item)
        if count ~= nil then return (tonumber(count) or 0) > 0 end
    end

    -- No inventory script: ask the framework itself.
    if Bridge.framework == 'qb' then
        local player = Core.GetPlayer(src)
        if not player then return false end
        local ok, QB = pcall(function() return exports[Bridge.frameworkResource]:GetCoreObject() end)
        if ok and QB then
            local qbp = QB.Functions.GetPlayer(src)
            local found = qbp and qbp.Functions.GetItemByName(item)
            return found ~= nil and (tonumber(found.amount) or 0) > 0
        end
    elseif Bridge.framework == 'esx' then
        local ok, ESX = pcall(function() return exports['es_extended']:getSharedObject() end)
        if ok and ESX then
            local xPlayer = ESX.GetPlayerFromId(src)
            local found = xPlayer and xPlayer.getInventoryItem(item)
            return found ~= nil and (tonumber(found.count) or 0) > 0
        end
    end

    -- Nothing to ask. Refusing the phone here would lock everybody out of it over a
    -- missing integration, which is the worse failure.
    return true
end

-- ══════════════════════════════════════════════════════════════
-- Money: the bank app
-- ══════════════════════════════════════════════════════════════
local BANKS = { 'Renewed-Banking', 'qb-banking', 'okokBanking', 'qs-banking', 'esx_banking' }

Bridge.Banking = {}

--- Cash and bank, as two plain numbers. Anything richer is that script's own UI.
function Bridge.Banking.Balances(src)
    local custom = Config.Compat.hooks.balances
    if custom then
        local ok, result = pcall(custom, src)
        if ok and type(result) == 'table' then return result end
    end

    if Bridge.framework == 'qb' then
        local ok, QB = pcall(function() return exports[Bridge.frameworkResource]:GetCoreObject() end)
        local player = ok and QB and QB.Functions.GetPlayer(src)
        if player then
            local money = player.PlayerData.money or {}
            return { cash = tonumber(money.cash) or 0, bank = tonumber(money.bank) or 0 }
        end

    elseif Bridge.framework == 'ox' then
        -- ox keeps cash as an inventory item and the bank as an account row.
        local cash = callExport('ox_inventory', 'GetItemCount', src, 'money') or 0
        local bank = 0
        local ok, player = pcall(function() return exports.ox_core:GetPlayer(src) end)
        if ok and player and player.charId then
            local gotAccount, account = pcall(function()
                return exports.ox_core:GetCharacterAccount(player.charId)
            end)
            if gotAccount and type(account) == 'table' and account.balance then
                bank = tonumber(account.balance) or 0
            end
        end
        return { cash = tonumber(cash) or 0, bank = bank }

    elseif Bridge.framework == 'esx' then
        local ok, ESX = pcall(function() return exports['es_extended']:getSharedObject() end)
        local xPlayer = ok and ESX and ESX.GetPlayerFromId(src)
        if xPlayer then
            return { cash = xPlayer.getMoney() or 0, bank = (xPlayer.getAccount('bank') or {}).money or 0 }
        end
    end
    return nil
end

--- Recent movements, when the server runs a banking script that keeps them. Returning
--- nil is normal and the app simply shows the balance without a history.
function Bridge.Banking.Transactions(src, citizenid)
    local custom = Config.Compat.hooks.transactions
    if custom then
        local ok, rows = pcall(custom, src, citizenid)
        if ok and type(rows) == 'table' then return rows end
    end

    local bank = choose('banking', BANKS)
    if bank == 'Renewed-Banking' then
        local rows = callExport(bank, 'getAccountTransactions', citizenid)
        if type(rows) == 'table' then return rows end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Vehicles, properties, licences, jobs
-- ══════════════════════════════════════════════════════════════
-- Each of these reads a table the ecosystem agrees on. A server whose script uses a
-- different one points `Config.Compat.tables` at it rather than editing this file.
local T = function(name) return Config.Compat.tables[name] end

Bridge.Vehicles = {}

function Bridge.Vehicles.Owned(citizenid)
    local custom = Config.Compat.hooks.vehicles
    if custom then
        local ok, rows = pcall(custom, citizenid)
        if ok and type(rows) == 'table' then return rows end
    end

    local tbl = T('vehicles')
    if not tbl then return nil end
    local ok, rows = pcall(function()
        if Bridge.framework == 'ox' then
            return MySQL.query.await(
                ('SELECT plate, model, stored FROM %s WHERE owner = ?'):format(tbl), { citizenid })
        end
        return MySQL.query.await(
            ('SELECT plate, vehicle AS model, garage, state, fuel, engine, body FROM %s WHERE citizenid = ?')
            :format(tbl), { citizenid })
    end)
    return ok and rows or nil
end

Bridge.Properties = {}

function Bridge.Properties.Owned(citizenid)
    local custom = Config.Compat.hooks.properties
    if custom then
        local ok, rows = pcall(custom, citizenid)
        if ok and type(rows) == 'table' then return rows end
    end

    -- Quasar's housing keeps an export for exactly this; everything else is a table.
    if started('qs-housing') then
        local rows = callExport('qs-housing', 'GetPlayerHouses', citizenid)
        if type(rows) == 'table' then return rows end
    end

    local tbl = T('properties')
    if not tbl then return nil end
    local ok, rows = pcall(function()
        return MySQL.query.await(('SELECT * FROM %s WHERE citizenid = ? OR owner = ?'):format(tbl),
            { citizenid, citizenid })
    end)
    return ok and rows or nil
end

Bridge.Licences = {}

function Bridge.Licences.Held(src, citizenid)
    local custom = Config.Compat.hooks.licences
    if custom then
        local ok, rows = pcall(custom, src, citizenid)
        if ok and type(rows) == 'table' then return rows end
    end

    if Bridge.framework == 'qb' then
        local player = Core.GetPlayer(src)
        if player then
            local held = player.GetMetadata('licences') or player.GetMetadata('licenses')
            if type(held) == 'table' then return held end
        end
        local raw = MySQL.scalar.await('SELECT metadata FROM players WHERE citizenid = ?', { citizenid })
        local ok, meta = pcall(json.decode, raw or '{}')
        if ok and meta then return meta.licences or meta.licenses end
    elseif Bridge.framework == 'esx' then
        local tbl = T('licences')
        if tbl then
            local ok, rows = pcall(function()
                return MySQL.query.await(('SELECT type FROM %s WHERE owner = ?'):format(tbl), { citizenid })
            end)
            if ok then return rows end
        end
    end
    return nil
end

Bridge.Jobs = {}

--- Every job the server offers, for the Jobs app. qb ships them in a shared table; ox
--- keeps groups; ESX has a table. Nothing is invented when none of that is readable.
function Bridge.Jobs.All()
    local custom = Config.Compat.hooks.jobs
    if custom then
        local ok, rows = pcall(custom)
        if ok and type(rows) == 'table' then return rows end
    end

    if Bridge.framework == 'qb' then
        local ok, QB = pcall(function() return exports[Bridge.frameworkResource]:GetCoreObject() end)
        if ok and QB and QB.Shared and QB.Shared.Jobs then
            local out = {}
            for name, job in pairs(QB.Shared.Jobs) do
                local grades = {}
                for level, grade in pairs(job.grades or {}) do
                    grades[#grades + 1] = { grade = tonumber(level) or 0,
                                            label = grade.name or '', pay = grade.payment or 0 }
                end
                table.sort(grades, function(a, b) return a.grade < b.grade end)
                out[#out + 1] = { name = name, label = job.label or name,
                                  defaultDuty = job.defaultDuty, grades = grades }
            end
            table.sort(out, function(a, b) return (a.label or '') < (b.label or '') end)
            return out
        end
    elseif Bridge.framework == 'esx' then
        local ok, rows = pcall(function()
            return MySQL.query.await('SELECT name, label FROM jobs')
        end)
        if ok then return rows end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Status: the health app
-- ══════════════════════════════════════════════════════════════
Bridge.Status = {}

function Bridge.Status.Get(src)
    local custom = Config.Compat.hooks.status
    if custom then
        local ok, result = pcall(custom, src)
        if ok and type(result) == 'table' then return result end
    end

    -- The two status scripts this ecosystem actually runs.
    if started('esx_status') then
        return nil     -- esx_status is client-owned; the phone reads vitals client side
    end
    if Bridge.framework == 'qb' then
        local player = Core.GetPlayer(src)
        if player then
            local meta = player.GetMetadata('phone_status')
            if type(meta) == 'table' then return meta end
        end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Registration
-- ══════════════════════════════════════════════════════════════
-- The phone calls `V.Use('v-banking')` and friends. Those names are kept because they
-- are what upstream calls, and this is where they are answered.
CreateThread(function()
    V.RegisterProvider('v-banking', {
        GetBalances = Bridge.Banking.Balances,
        GetTransactions = Bridge.Banking.Transactions,
    })
    V.RegisterProvider('v-vehicles', { GetOwned = Bridge.Vehicles.Owned })
    V.RegisterProvider('v-housing', { GetOwned = Bridge.Properties.Owned })
    V.RegisterProvider('v-licenses', { GetHeld = Bridge.Licences.Held })
    V.RegisterProvider('v-cityhall', { GetJobs = Bridge.Jobs.All })
    V.RegisterProvider('v-status', { Get = Bridge.Status.Get })
    V.RegisterProvider('v-inventory', { HasItem = Bridge.HasItem })
end)
