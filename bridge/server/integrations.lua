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
--  3. **Read-mostly, and where it is not, it fails closed.** The phone shows a balance and
--     a garage list; it does not spawn cars. It does move money - the app store charges,
--     and the bank app transfers - and both directions report honestly whether the
--     framework confirmed the movement, so a half-finished transfer can be undone.
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
            -- **The in-memory copy has to change too, not just the row.**
            --
            -- qb-core holds charinfo on the player object and writes it back over the row on
            -- every save (`charinfo = json.encode(PlayerData.charinfo)` in Player:Save). An
            -- UPDATE on its own is therefore undone the moment the character logs out, and the
            -- number the phone minted quietly reverts. SetPlayerData changes the live copy and
            -- syncs it to the client, and qb-core then persists it itself.
            local online = Bridge.GetPlayerByCitizenId(citizenid)
            local qbp = online and online.source and Bridge.QBGetPlayer(online.source)
            if qbp and qbp.PlayerData then
                local info = qbp.PlayerData.charinfo or {}
                info.phone = number
                -- qb-core pre-binds `self` when it builds the method table, so these take the
                -- key and value alone. Both spellings exist across builds.
                local setter = (qbp.Functions and qbp.Functions.SetPlayerData) or qbp.SetPlayerData
                if setter then pcall(setter, 'charinfo', info) else qbp.PlayerData.charinfo = info end
            end

            -- And the row, which is what an OFFLINE character has instead.
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

    local own = MySQL.scalar.await("SELECT citizenid FROM vphone_kv WHERE `key` = 'number' AND value = ?",
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

    -- No inventory script: ask the framework itself. On qb that means reading the player's
    -- own item table, NOT `Functions.GetItemByName` - modern qb-core does not have it.
    if Bridge.framework == 'qb' then
        local count = Bridge.QBItemCount(src, item)
        if count ~= nil then return count > 0 end
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

--- Take one of an item away, and say whether it actually went.
---
--- Used where the phone CONSUMES something rather than merely checking for it: feeding a
--- prepaid card into a payphone. Unlike `HasItem`, this one fails CLOSED. HasItem answers
--- "true" when there is no inventory to ask, because locking everybody out of the phone
--- over a missing integration is the worse mistake; here the opposite is true, since a
--- remove that silently did nothing would hand out free credit for ever.
function Bridge.RemoveItem(src, item, count)
    src, count = tonumber(src), math.max(1, math.floor(tonumber(count) or 1))
    if not src or not item or item == '' then return false end
    local inv = Bridge.InventoryResource()

    if inv == 'ox_inventory' then
        -- ox answers with a boolean, and refuses rather than going negative.
        return callExport(inv, 'RemoveItem', src, item, count) == true
    end

    -- Quasar and the qb-derived inventories all expose RemoveItem, but they disagree on
    -- what it returns: a boolean on some forks, nil on others. A nil is not a failure
    -- here, so the count is re-read afterwards to find out what really happened.
    if inv == 'qs-inventory' or inv == 'ps-inventory' or inv == 'qb-inventory'
        or inv == 'origen_inventory' or inv == 'codem-inventory' then
        local before = Bridge.ItemCount(src, item)
        if before < count then return false end
        local result = callExport(inv, 'RemoveItem', src, item, count)
        if result == false then return false end
        return Bridge.ItemCount(src, item) < before
    end

    -- No inventory script: the framework's own player object.
    if Bridge.framework == 'qb' then
        local qbp = Bridge.QBGetPlayer(src)
        local remove = qbp and qbp.Functions and qbp.Functions.RemoveItem
        -- Older qb builds still carry it. Modern qb-core does not, and there is then nothing
        -- that can safely take an item away - so refuse, rather than report a success that
        -- would hand out credit for a card still sitting in the player's pocket.
        if remove then return remove(item, count) == true end
        return false
    elseif Bridge.framework == 'esx' then
        local ok, ESX = pcall(function() return exports['es_extended']:getSharedObject() end)
        if not ok or not ESX then return false end
        local xPlayer = ESX.GetPlayerFromId(src)
        if not xPlayer then return false end
        local found = xPlayer.getInventoryItem(item)
        if not found or (tonumber(found.count) or 0) < count then return false end
        xPlayer.removeInventoryItem(item, count)
        return true
    end

    -- Nothing to take it from. Refuse, so credit is never granted for an item that was
    -- never actually spent.
    return false
end

--- How many of an item the player carries. Zero when there is nothing to ask, which keeps
--- every caller of this on the safe side of the question.
function Bridge.ItemCount(src, item)
    src = tonumber(src)
    if not src or not item or item == '' then return 0 end
    local inv = Bridge.InventoryResource()

    if inv == 'ox_inventory' then
        return math.floor(tonumber(callExport(inv, 'GetItemCount', src, item)) or 0)
    end

    if inv == 'qs-inventory' then
        local count = callExport(inv, 'GetItemTotalAmount', src, item)
        if count ~= nil then return math.floor(tonumber(count) or 0) end
    end

    if inv == 'ps-inventory' or inv == 'qb-inventory'
        or inv == 'origen_inventory' or inv == 'codem-inventory' then
        local result = callExport(inv, 'GetItemByName', src, item)
        if type(result) == 'table' then return math.floor(tonumber(result.amount) or 0) end
        if type(result) == 'number' then return math.floor(result) end
        local count = callExport(inv, 'GetItemCount', src, item)
        if count ~= nil then return math.floor(tonumber(count) or 0) end
    end

    if Bridge.framework == 'qb' then
        return Bridge.QBItemCount(src, item) or 0
    elseif Bridge.framework == 'esx' then
        local ok, ESX = pcall(function() return exports['es_extended']:getSharedObject() end)
        if ok and ESX then
            local xPlayer = ESX.GetPlayerFromId(src)
            local found = xPlayer and xPlayer.getInventoryItem(item)
            return found and math.floor(tonumber(found.count) or 0) or 0
        end
    end

    return 0
end

--- Take money off a player, and say whether it actually went.
---
--- Used where the phone CHARGES for something: a paid app in the store. Like
--- `Bridge.RemoveItem`, it **fails closed** - a charge that cannot be confirmed grants
--- nothing, because the alternative is handing out paid apps for free.
---
--- `account` is 'bank' or 'cash'. Returns true only when the framework confirmed the debit.
function Bridge.RemoveMoney(src, amount, account)
    src = tonumber(src)
    amount = math.floor(tonumber(amount) or 0)
    account = (account == 'cash') and 'cash' or 'bank'
    if not src or amount <= 0 then return false end

    -- The operator's own wiring wins, for a server whose money lives somewhere bespoke.
    local custom = Config.Compat.hooks.removeMoney
    if custom then
        local ok, done = pcall(custom, src, amount, account)
        if ok then return done == true end
        return false
    end

    if Bridge.framework == 'qb' then
        local qbp = Bridge.QBGetPlayer(src)
        local remove = qbp and qbp.Functions and qbp.Functions.RemoveMoney
        -- qb returns false when the balance would go under its own floor, which is exactly
        -- the answer wanted here.
        if remove then return remove(account, amount, 'v-phone: app store') == true end
        return false

    elseif Bridge.framework == 'esx' then
        local ok, ESX = pcall(function() return exports['es_extended']:getSharedObject() end)
        if not ok or not ESX then return false end
        local xPlayer = ESX.GetPlayerFromId(src)
        if not xPlayer then return false end
        if account == 'cash' then
            if (tonumber(xPlayer.getMoney and xPlayer.getMoney()) or 0) < amount then return false end
            xPlayer.removeMoney(amount)
            return true
        end
        local acc = xPlayer.getAccount and xPlayer.getAccount('bank')
        if not acc or (tonumber(acc.money) or 0) < amount then return false end
        xPlayer.removeAccountMoney('bank', amount)
        return true

    elseif Bridge.framework == 'ox' then
        -- ox keeps money as an inventory item rather than a column, so the inventory is
        -- what has to be asked.
        local item = (account == 'cash') and 'money' or 'money'
        if Bridge.ItemCount(src, item) < amount then return false end
        return Bridge.RemoveItem(src, item, amount)
    end

    -- Standalone, or a framework with no money to take. Refuse rather than give it away.
    return false
end

--- Put money into a player, and say whether it actually arrived.
---
--- The credit half of `Bridge.RemoveMoney`, needed because a transfer has two ends. Same
--- contract: **true only when the framework confirmed it**, so the bank app can put a
--- failed transfer back where it came from instead of quietly destroying it.
---
--- `account` is 'bank' or 'cash'. `reason` is what the framework writes in its own log.
---
--- Deliberately narrower than the read side: this asks the FRAMEWORK for money and never
--- a banking script, even when one is running. Banking scripts observe the framework's
--- money and add their own statement line; calling both would credit twice. A missing line
--- in somebody's statement is a cosmetic problem, money invented from nothing is not.
function Bridge.AddMoney(src, amount, account, reason)
    src = tonumber(src)
    amount = math.floor(tonumber(amount) or 0)
    account = (account == 'cash') and 'cash' or 'bank'
    reason = tostring(reason or 'v-phone')
    if not src or amount <= 0 then return false end

    local custom = Config.Compat.hooks.addMoney
    if custom then
        local ok, done = pcall(custom, src, amount, account, reason)
        return ok and done == true
    end

    if Bridge.framework == 'qb' then
        local qbp = Bridge.QBGetPlayer(src)
        local add = qbp and qbp.Functions and qbp.Functions.AddMoney
        if add then return add(account, amount, reason) == true end
        return false

    elseif Bridge.framework == 'esx' then
        local ok, ESX = pcall(function() return exports['es_extended']:getSharedObject() end)
        if not ok or not ESX then return false end
        local xPlayer = ESX.GetPlayerFromId(src)
        if not xPlayer then return false end
        if account == 'cash' then
            if not xPlayer.addMoney then return false end
            local done = pcall(xPlayer.addMoney, amount, reason)
            return done
        end
        if not xPlayer.addAccountMoney then return false end
        return pcall(xPlayer.addAccountMoney, 'bank', amount, reason)

    elseif Bridge.framework == 'ox' then
        -- ox keeps cash as an inventory item and the bank as an account with its own
        -- methods. The account is tried first because that is where a bank transfer
        -- belongs; cash falls through to the item.
        if account == 'bank' then
            local ok = pcall(function()
                local player = exports.ox_core:GetPlayer(src)
                if not player or not player.charId then error('no character') end
                local acc = exports.ox_core:GetCharacterAccount(player.charId)
                if not acc then error('no account') end
                if acc.addBalance then
                    if acc:addBalance(amount, reason) == false then error('refused') end
                elseif acc.id and exports.ox_core.AddAccountBalance then
                    if exports.ox_core:AddAccountBalance(acc.id, amount) == false then error('refused') end
                else
                    error('no credit method')
                end
            end)
            if ok then return true end
        end
        local ok, added = pcall(function()
            return exports.ox_inventory:AddItem(src, 'money', amount)
        end)
        return ok and added ~= false
    end

    -- Standalone, or a framework with nowhere to put it. Say so: the caller refunds.
    return false
end

-- ══════════════════════════════════════════════════════════════
-- Money: the bank app
-- ══════════════════════════════════════════════════════════════
local BANKS = { 'Renewed-Banking', 'qb-banking', 'okokBanking', 'qs-banking', 'esx_banking' }

Bridge.Banking = {}

--- Which dedicated banking script is running, or nil for none.
---
--- The bank app asks because it decides whether to write its own statement line for a
--- paycheck: with a banking script present that line already exists and writing a second
--- one would show every salary twice.
function Bridge.Banking.Script() return choose('banking', BANKS) end

--- Cash and bank, as two plain numbers. Anything richer is that script's own UI.
function Bridge.Banking.Balances(src)
    local custom = Config.Compat.hooks.balances
    if custom then
        local ok, result = pcall(custom, src)
        if ok and type(result) == 'table' then return result end
    end

    -- A dedicated banking script is the truth when there is one: qb's own money table
    -- can lag behind a script that keeps its accounts elsewhere.
    local bank = choose('banking', BANKS)
    if bank == 'qs-banking' then
        local p = Core.GetPlayer(src)
        local balance = p and callExport(bank, 'GetAccountBalance', p.citizenid)
        if balance ~= nil then
            local cash = 0
            if Bridge.framework == 'qb' then
                local player = Bridge.QBGetPlayer(src)
                cash = player and (tonumber((player.PlayerData.money or {}).cash) or 0) or 0
            end
            return { cash = cash, bank = tonumber(balance) or 0 }
        end
    elseif bank == 'Renewed-Banking' then
        local p = Core.GetPlayer(src)
        local account = p and callExport(bank, 'getAccount', p.citizenid)
        if type(account) == 'table' and account.amount then
            return { cash = 0, bank = tonumber(account.amount) or 0 }
        end
    end

    if Bridge.framework == 'qb' then
        local player = Bridge.QBGetPlayer(src)
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

--- The banking scripts whose own history this bridge can actually READ.
---
--- Detecting a script is not the same as being able to read it, and conflating the two cost
--- the bank app its entire statement: `shouldRecord` treated "a banking script is running" as
--- "somebody else is keeping the history", so on qb-banking - which has no branch below - the
--- phone recorded nothing AND could read nothing, and the app showed "no activity" to a player
--- who had been paid all evening.
---
--- Anything not in this list means the phone keeps its own lines. Add a script here only when
--- `Transactions` genuinely returns its rows.
local READABLE_HISTORY = { ['Renewed-Banking'] = true, ['qs-banking'] = true }

--- Can the running banking script's own statement be read?
function Bridge.Banking.HistoryReadable()
    local script = choose('banking', BANKS)
    return (script ~= nil) and (READABLE_HISTORY[script] == true)
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
    if bank == 'qs-banking' then
        -- Quasar keeps statements in its own table; the export set is write-side only,
        -- so the history is read straight from it when it is there.
        local ok, rows = pcall(function()
            return MySQL.query.await([[SELECT reason AS label, amount, date AS at
                FROM bank_statements WHERE citizenid = ? ORDER BY id DESC LIMIT 25]],
                { citizenid })
        end)
        if ok and type(rows) == 'table' then return rows end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Vehicles, properties, licences, jobs
-- ══════════════════════════════════════════════════════════════
-- Each of these reads a table the ecosystem agrees on. A server whose script uses a
-- different one points `Config.Compat.tables` at it rather than editing this file.
-- The default table names differ per framework, so `auto` resolves them once the
-- framework is known rather than making the config file wrong for three servers out of
-- four. Naming one in `Config.Compat.tables` always wins.
local AUTO_TABLES = {
    qb  = { vehicles = 'player_vehicles', properties = 'properties',       licences = nil },
    ox  = { vehicles = 'vehicles',        properties = 'ox_property',      licences = 'character_licenses' },
    esx = { vehicles = 'owned_vehicles',  properties = 'owned_properties', licences = 'user_licenses' },
}

local function T(name)
    local configured = Config.Compat.tables[name]
    if configured == false then return nil end
    if configured and configured ~= 'auto' then return configured end
    return (AUTO_TABLES[Bridge.framework] or AUTO_TABLES.qb)[name]
end

-- ── The garage app ─────────────────────────────────────────────
-- Every garage script keeps the same handful of facts in a table of its own name. The
-- phone only shows them, so reading the table is enough and no export is required - but
-- a script with an export is asked first, because a table can lie about what is stored.
local GARAGES = { 'qs-advancedgarages', 'jg-advancedgarages', 'qb-garages', 'cd_garage', 'okokGarage' }

Bridge.Vehicles = {}

function Bridge.Vehicles.Owned(citizenid, src)
    local custom = Config.Compat.hooks.vehicles
    if custom then
        local ok, rows = pcall(custom, citizenid, src)
        if ok and type(rows) == 'table' then return rows end
    end

    -- Quasar's garage answers for the player rather than for the character id.
    local garage = choose('garage', GARAGES)
    if garage == 'qs-advancedgarages' and src then
        local rows = callExport(garage, 'GetPlayerVehicles', src)
        if type(rows) == 'table' and #rows > 0 then return rows end
    end

    local tbl = T('vehicles')
    if not tbl then return nil end

    -- Three schemas, one per ecosystem, all shaped into { plate, model, garage, state }.
    local ok, rows = pcall(function()
        if Bridge.framework == 'ox' then
            return MySQL.query.await(([[SELECT plate, model, stored, `owner`
                FROM %s WHERE `owner` = ?]]):format(tbl), { citizenid })
        end
        if Bridge.framework == 'esx' then
            return MySQL.query.await(([[SELECT plate, vehicle AS model, stored, `type`
                FROM %s WHERE owner = ?]]):format(tbl), { citizenid })
        end
        return MySQL.query.await(([[SELECT plate, vehicle AS model, garage, state, fuel, engine, body
            FROM %s WHERE citizenid = ?]]):format(tbl), { citizenid })
    end)
    if not ok or type(rows) ~= 'table' then return nil end

    -- ESX stores the model inside a JSON blob rather than in a column.
    if Bridge.framework == 'esx' then
        for _, r in ipairs(rows) do
            if type(r.model) == 'string' and r.model:sub(1, 1) == '{' then
                local decoded, data = pcall(json.decode, r.model)
                r.model = (decoded and data and (data.model or data.modelName)) or '?'
            end
        end
    end
    return rows
end

-- ── Who the character is ───────────────────────────────────────
-- The Wallet app shows an identity card, which means it needs the facts a framework already
-- keeps about a character. Every one of them keeps the same handful under different names and
-- in a different place, so this is a read per ecosystem, normalised once.
--
--   qb / qbx   `players.charinfo`, JSON: firstname, lastname, birthdate, gender, nationality
--   ox         `characters`: firstName, lastName, dateofbirth, gender
--   esx        `users`: firstname, lastname, dateofbirth, sex, height
--
-- `gender` is a number on qb (0 male, 1 female) and a letter on ESX ('m' / 'f'). The phone
-- hands back a plain 'm' or 'f' and lets the page name it in the reader's language, so
-- nothing here has to know the word for it.
function Bridge.Identity(citizenid, src)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return nil end

    local custom = Config.Compat.hooks.identity
    if custom then
        local ok, info = pcall(custom, citizenid, src)
        if ok and type(info) == 'table' then return info end
    end

    --- 0/1, 'm'/'f', 'male'/'female', or anything else, as 'm' or 'f' or nil.
    local function sexOf(value)
        if value == nil then return nil end
        local v = tostring(value):lower()
        if v == '0' or v == 'm' or v == 'male' or v == 'homme' then return 'm' end
        if v == '1' or v == 'f' or v == 'female' or v == 'femme' then return 'f' end
        return nil
    end

    if Bridge.framework == 'qb' then
        local raw = MySQL.scalar.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        local ok, info = pcall(json.decode, raw or '{}')
        if ok and type(info) == 'table' then
            return {
                first = info.firstname, last = info.lastname,
                dob = info.birthdate, sex = sexOf(info.gender),
                nationality = info.nationality, id = citizenid,
            }
        end

    elseif Bridge.framework == 'ox' then
        local row = MySQL.single.await([[SELECT firstName, lastName, dateofbirth, gender
            FROM characters WHERE charId = ?]], { citizenid })
        if row then
            return {
                first = row.firstName, last = row.lastName,
                dob = row.dateofbirth, sex = sexOf(row.gender), id = citizenid,
            }
        end

    elseif Bridge.framework == 'esx' then
        -- ESX keys `users` by the licence identifier, not by a citizen id, and that is what
        -- the bridge carries as `citizenid` on an ESX server.
        local row = MySQL.single.await([[SELECT firstname, lastname, dateofbirth, sex, height
            FROM users WHERE identifier = ?]], { citizenid })
        if row then
            return {
                first = row.firstname, last = row.lastname,
                dob = row.dateofbirth, sex = sexOf(row.sex),
                height = tonumber(row.height), id = citizenid,
            }
        end
    end
    return nil
end

-- ── Naming a garage, and finding it on the map ─────────────────
-- A garage row carries a KEY - `motelgarage`, `casinoparking` - which is not something to
-- show a player. The label and the coordinates live in the garage script's own config, and
-- that config is a global inside ITS resource, so it cannot simply be read from here.
--
-- It can be read from disk, though. `LoadResourceFile` hands over any file in another
-- resource, and qb-garages and its many forks all keep the same shape:
--
--     Config.Garages.motelgarage = { label = 'Motel Parking', takeVehicle = vector3(...) }
--
-- So the file is loaded into a sandbox with the vector constructors stubbed, and the two
-- fields that matter are lifted out. Nothing else in that file is executed for its effects,
-- and a file that will not load is simply skipped.
--
-- An escrowed script (Quasar's core is encrypted) may not expose a readable config. That is
-- what `Config.Garages` in this resource's own config is for, and it always wins.
Bridge.Garages = {}

local garageCache = nil

--- Read `Config.Garages` out of whichever garage script is running.
local function garagesFromScript()
    local resource = choose('garage', GARAGES)
    if not resource then return {} end

    local out = {}
    for _, file in ipairs({ 'config.lua', 'configs/config.lua', 'shared/config.lua' }) do
        local raw = LoadResourceFile(resource, file)
        if raw and raw ~= '' then
            -- A sandbox: the file gets vectors and a table to fill, and nothing else. It
            -- cannot reach the server's globals even if it tries.
            local env = {
                Config = {}, Configs = {}, math = math, table = table, string = string,
                pairs = pairs, ipairs = ipairs, tonumber = tonumber, tostring = tostring,
                vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
                vector4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
                vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
                vec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
            }
            local chunk = load(raw, 'garages', 't', env)
            if chunk and pcall(chunk) then
                local list = (env.Config and env.Config.Garages) or (env.Configs and env.Configs.Garages)
                if type(list) == 'table' then
                    for key, g in pairs(list) do
                        if type(g) == 'table' then
                            local at = g.takeVehicle or g.spawnPoint or g.putVehicle or g.coords
                            if type(at) == 'table' and at[1] then at = at[1] end
                            out[tostring(key)] = {
                                label = tostring(g.label or g.name or key),
                                x = at and tonumber(at.x) or nil,
                                y = at and tonumber(at.y) or nil,
                            }
                        end
                    end
                end
            end
        end
        if next(out) then break end
    end
    return out
end

--- The label and map position of one garage, or nil when nothing here knows it.
---
--- Cached: reading and sandboxing a config file per vehicle per app open would be absurd.
function Bridge.Garages.Info(key)
    key = tostring(key or '')
    if key == '' then return nil end

    local custom = Config.Compat.hooks.garage
    if custom then
        local ok, info = pcall(custom, key)
        if ok and type(info) == 'table' then return info end
    end

    -- The operator's own names always win: they know what their garages are called, and an
    -- escrowed script may never tell us.
    local named = (Config.Garages or {})[key]
    if type(named) == 'table' then
        return { label = tostring(named.label or key), x = tonumber(named.x), y = tonumber(named.y) }
    end

    if garageCache == nil then
        local ok, found = pcall(garagesFromScript)
        garageCache = (ok and found) or {}
        local n = 0
        for _ in pairs(garageCache) do n = n + 1 end
        if n > 0 then print(('[v-phone] garages: read %d from the garage script'):format(n)) end
    end
    return garageCache[key]
end

--- Where a car with this plate is standing right now, if it is out in the world.
---
--- Server-side entity iteration, so it finds the car whether or not it is streamed to the
--- player asking. `GetAllVehicles` is not present on every build, hence the pcall: a server
--- without it loses the "locate" button and nothing else.
function Bridge.Garages.LocatePlate(plate)
    local wanted = tostring(plate or ''):upper():gsub('%s', '')
    if wanted == '' then return nil end

    local ok, result = pcall(function()
        for _, vehicle in ipairs(GetAllVehicles()) do
            if DoesEntityExist(vehicle) then
                local found = tostring(GetVehicleNumberPlateText(vehicle) or ''):upper():gsub('%s', '')
                if found == wanted then
                    local at = GetEntityCoords(vehicle)
                    return { x = at.x, y = at.y, z = at.z }
                end
            end
        end
        return nil
    end)
    return ok and result or nil
end

-- ── The property app ───────────────────────────────────────────
local HOUSING = { 'qs-housing', 'ps-housing', 'qb-houses', 'ox_property', 'loaf_housing', 'esx_property' }

Bridge.Properties = {}

function Bridge.Properties.Owned(citizenid, src)
    local custom = Config.Compat.hooks.properties
    if custom then
        local ok, rows = pcall(custom, citizenid, src)
        if ok and type(rows) == 'table' then return rows end
    end

    local housing = choose('housing', HOUSING)

    -- Quasar: GetPlayerHouses takes the SOURCE and returns house ids, not rows. The
    -- phone wants something to show, so each id is turned into a labelled entry.
    if housing == 'qs-housing' and src then
        local ids = callExport(housing, 'GetPlayerHouses', src)
        if type(ids) == 'table' then
            local out = {}
            for _, id in ipairs(ids) do
                -- Quasar hands back an id and nothing else. Its own coordinates live behind
                -- an escrowed core, so a house is listed and named but cannot be pointed at
                -- unless the operator fills in `Config.Property.houses`.
                out[#out + 1] = { label = tostring(id), address = tostring(id), owned = true,
                                  key = tostring(id) }
            end
            if #out > 0 then return out end
        end
    end

    -- qb-houses, which is what a qb-core server almost always runs, and which this bridge
    -- did not read at all: it fell through to a generic `properties` table that qb-houses
    -- does not have, so the app reported no readable housing script on every qb server.
    --
    -- Two tables, joined on the house name. Schema taken from qb-houses' own SQL file:
    --   player_houses  (house, citizenid, keyholders)
    --   houselocations (name, label, coords JSON, price, tier)
    if housing == 'qb-houses' then
        local ok, rows = pcall(function()
            return MySQL.query.await([[SELECT hl.name AS name, hl.label AS label,
                    hl.coords AS coords, hl.price AS price, hl.tier AS tier,
                    ph.citizenid AS owner
                FROM player_houses ph
                LEFT JOIN houselocations hl ON hl.name = ph.house
                WHERE ph.citizenid = ?]], { citizenid })
        end)
        if ok and type(rows) == 'table' then
            local out = {}
            for _, r in ipairs(rows) do
                local row = {
                    label = r.label or r.name,
                    address = r.label or r.name,
                    key = r.name,
                    price = tonumber(r.price),
                    tier = tonumber(r.tier),
                    owned = true,
                }
                -- `coords` is JSON in the column, not three numbers.
                if type(r.coords) == 'string' and r.coords ~= '' then
                    local decoded, at = pcall(json.decode, r.coords)
                    if decoded and type(at) == 'table' then
                        row.x, row.y = tonumber(at.x), tonumber(at.y)
                    end
                end
                out[#out + 1] = row
            end
            if #out > 0 then return out end
        end

        -- Owning nothing is a real answer on a server whose housing IS readable, and it is
        -- not the same as having no housing script. An empty table says so.
        if ok then return {} end
    end

    if housing == 'ps-housing' then
        local ok, rows = pcall(function()
            return MySQL.query.await([[SELECT property_id AS id, street AS address, owner
                FROM properties WHERE owner = ?]], { citizenid })
        end)
        if ok and type(rows) == 'table' and #rows > 0 then return rows end
        if ok and type(rows) == 'table' then return {} end
    end

    if housing == 'esx_property' then
        local ok, rows = pcall(function()
            return MySQL.query.await([[SELECT name AS label, name AS address
                FROM owned_properties WHERE owner = ?]], { citizenid })
        end)
        if ok and type(rows) == 'table' and #rows > 0 then return rows end
    end

    local tbl = T('properties')
    if not tbl then return nil end
    local ok, rows = pcall(function()
        return MySQL.query.await(('SELECT * FROM %s WHERE citizenid = ? OR owner = ?'):format(tbl),
            { citizenid, citizenid })
    end)
    return ok and rows or nil
end

-- ── The wallet app ─────────────────────────────────────────────
Bridge.Licences = {}

function Bridge.Licences.Held(src, citizenid)
    local custom = Config.Compat.hooks.licences
    if custom then
        local ok, rows = pcall(custom, src, citizenid)
        if ok and type(rows) == 'table' then return rows end
    end

    if Bridge.framework == 'qb' then
        -- qb keeps them as a map of name -> true in the character's metadata, under
        -- either spelling depending on the fork.
        local raw = MySQL.scalar.await('SELECT metadata FROM players WHERE citizenid = ?', { citizenid })
        local ok, meta = pcall(json.decode, raw or '{}')
        if ok and type(meta) == 'table' then
            local held = meta.licences or meta.licenses
            if type(held) == 'table' then
                local out = {}
                for name, has in pairs(held) do
                    if has then out[#out + 1] = { type = name, label = name } end
                end
                return out
            end
        end

    elseif Bridge.framework == 'ox' then
        local ok, rows = pcall(function()
            return MySQL.query.await([[SELECT cl.name AS type, ol.label
                FROM character_licenses cl
                LEFT JOIN ox_licenses ol ON ol.name = cl.name
                WHERE cl.charId = ?]], { citizenid })
        end)
        if ok and type(rows) == 'table' then return rows end

    elseif Bridge.framework == 'esx' then
        local tbl = T('licences')
        if tbl then
            local ok, rows = pcall(function()
                return MySQL.query.await(('SELECT type, type AS label FROM %s WHERE owner = ?')
                    :format(tbl), { citizenid })
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
        -- qbx exposes the whole job table as an export; classic qb keeps it on the shared
        -- object. Both end up the same map of name -> { label, grades }.
        local jobs
        if Bridge.frameworkResource == 'qbx_core' then
            local ok, all = pcall(function() return exports.qbx_core:GetJobs() end)
            jobs = ok and all or nil
        else
            local QB = Bridge.QBCore()
            jobs = QB and QB.Shared and QB.Shared.Jobs or nil
        end
        if jobs then
            local out = {}
            for name, job in pairs(jobs) do
                local grades = {}
                for level, grade in pairs(job.grades or {}) do
                    -- `salary` is the name every caller reads. This used to emit only `pay`,
                    -- which nothing read, so every wage on the Jobs app was zero on qb while
                    -- the job list itself looked perfectly healthy. `pay` is kept beside it in
                    -- case an operator's own code came to depend on it.
                    local wage = tonumber(grade.payment) or tonumber(grade.salary) or 0
                    grades[#grades + 1] = { grade = tonumber(level) or 0,
                                            label = grade.name or '',
                                            salary = wage, pay = wage }
                end
                table.sort(grades, function(a, b) return a.grade < b.grade end)
                out[#out + 1] = { name = name, label = job.label or name,
                                  defaultDuty = job.defaultDuty, grades = grades }
            end
            table.sort(out, function(a, b) return (a.label or '') < (b.label or '') end)
            return out
        end

    elseif Bridge.framework == 'esx' then
        -- The ladder as well as the list. This read `SELECT name, label FROM jobs` and
        -- stopped, so on ESX every job had no grades, no wage and no rank count - the app
        -- drew a list of titles and nothing else. ESX keeps the rest in `job_grades`, per its
        -- own schema: (job_name, grade, name, label, salary).
        local ok, rows = pcall(function()
            return MySQL.query.await([[SELECT j.name AS name, j.label AS label,
                    g.grade AS grade, g.label AS grade_label, g.salary AS salary
                FROM jobs j
                LEFT JOIN job_grades g ON g.job_name = j.name
                ORDER BY j.label, g.grade]])
        end)
        if ok and type(rows) == 'table' then
            local byName, out = {}, {}
            for _, r in ipairs(rows) do
                local key = tostring(r.name or '')
                if key ~= '' then
                    local job = byName[key]
                    if not job then
                        job = { name = key, label = r.label or key, grades = {} }
                        byName[key] = job
                        out[#out + 1] = job
                    end
                    -- A job with no rows in job_grades joins to a single NULL grade.
                    if r.grade ~= nil then
                        local wage = tonumber(r.salary) or 0
                        job.grades[#job.grades + 1] = {
                            grade = math.floor(tonumber(r.grade) or 0),
                            label = r.grade_label or '',
                            salary = wage, pay = wage,
                        }
                    end
                end
            end
            return out
        end

    elseif Bridge.framework == 'ox' then
        -- ox has no jobs: it has GROUPS, and a group is what the phone shows as a job. Both
        -- tables come from ox_core's own install.sql - `ox_groups (name, label, type)` and
        -- `ox_group_grades (group, grade, label)`.
        --
        -- There is deliberately no wage: ox_group_grades has no salary column, because ox does
        -- not pay through groups. An honest zero beats a number invented to fill a field.
        local ok, rows = pcall(function()
            return MySQL.query.await([[SELECT g.name AS name, g.label AS label, g.type AS type,
                    gr.grade AS grade, gr.label AS grade_label
                FROM ox_groups g
                LEFT JOIN ox_group_grades gr ON gr.`group` = g.name
                ORDER BY g.label, gr.grade]])
        end)
        if ok and type(rows) == 'table' then
            local byName, out = {}, {}
            for _, r in ipairs(rows) do
                local key = tostring(r.name or '')
                -- The config's ignore list keeps admin and permission groups out of a list of
                -- jobs, the same list `Bridge.GetPlayer` uses to decide somebody's employer.
                if key ~= '' and not Config.Compat.ignoredGroups[key] then
                    local job = byName[key]
                    if not job then
                        job = { name = key, label = r.label or key, grades = {} }
                        byName[key] = job
                        out[#out + 1] = job
                    end
                    if r.grade ~= nil then
                        job.grades[#job.grades + 1] = {
                            grade = math.floor(tonumber(r.grade) or 0),
                            label = r.grade_label or '',
                            salary = 0, pay = 0,
                        }
                    end
                end
            end
            return out
        end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Status: the health app
-- ══════════════════════════════════════════════════════════════
Bridge.Status = {}

function Bridge.Status.Get(src)
    src = tonumber(src)
    if not src then return nil end

    local custom = Config.Compat.hooks.status
    if custom then
        local ok, result = pcall(custom, src)
        if ok and type(result) == 'table' then return result end
    end

    -- esx_status keeps its vitals on the CLIENT and nowhere else, so there is nothing to read
    -- from here. The client half asks it directly; nil is the correct answer, not a failure.
    if started('esx_status') then return nil end

    if Bridge.framework == 'qb' then
        -- **qb keeps hunger and thirst in the character's metadata, not on a state bag.**
        --
        -- This used to read a `phone_status` key out of the phone's own storage - a key
        -- nothing has ever written - so it always came back nil and the Health app showed
        -- hunger, thirst and stress as zero on every qb server while cheerfully reporting
        -- health, which the client reads off the ped. Half a working app.
        --
        -- `SetMetaData` clamps hunger and thirst to 0..100 in qb-core itself, so the numbers
        -- here are already percentages. `stress` is qb-hud's, in the same table.
        local qbp = Bridge.QBGetPlayer(src)
        local meta = qbp and qbp.PlayerData and qbp.PlayerData.metadata
        if type(meta) == 'table' then
            return {
                hunger = tonumber(meta.hunger),
                thirst = tonumber(meta.thirst),
                stress = tonumber(meta.stress),
                -- Not every fork carries these, and an absent one stays absent rather than
                -- becoming a confident zero.
                armour = tonumber(meta.armor) or tonumber(meta.armour),
                bloodtype = meta.bloodtype and tostring(meta.bloodtype) or nil,
                dead = (meta.isdead == true) or (meta.inlaststand == true) or nil,
            }
        end
        return nil
    end

    if Bridge.framework == 'ox' then
        -- ox_core and the scripts around it publish vitals on the player's state bag. Read
        -- through a pcall because a server that publishes none of it must not error.
        local ok, out = pcall(function()
            local st = Player(src).state
            if not st then return nil end
            local found = {
                hunger = tonumber(st.hunger),
                thirst = tonumber(st.thirst),
                stress = tonumber(st.stress),
            }
            if found.hunger == nil and found.thirst == nil then return nil end
            return found
        end)
        if ok then return out end
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
    V.RegisterProvider('v-housing', {
        GetOwned = Bridge.Properties.Owned,
        -- Upstream's housing module names this differently; both reach the same place.
        GetProperties = Bridge.Properties.Owned,
    })
    V.RegisterProvider('v-licenses', { GetHeld = Bridge.Licences.Held })
    V.RegisterProvider('v-cityhall', { GetJobs = Bridge.Jobs.All })
    V.RegisterProvider('v-status', { Get = Bridge.Status.Get })
    V.RegisterProvider('v-inventory', { HasItem = Bridge.HasItem })
end)
