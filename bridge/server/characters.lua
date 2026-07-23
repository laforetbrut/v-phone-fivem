-- v-phone | bridge/server/characters.lua
--
-- **The one table the phone needs about people, filled from whatever framework runs.**
--
-- The phone joins on a character's name, date of birth and number in a dozen queries:
-- a contact card, a Hush profile, a voicemail from somebody offline. Upstream that is
-- v-core's `characters` table. qb has `players`, ox has `characters` with different
-- column names, ESX has `users`, and a standalone server has none.
--
-- Rather than write four dialects of every query, the bridge keeps ONE table -
-- `phone_characters` - and refreshes a row each time somebody loads in. It is a
-- projection, not a source of truth: nothing here is authoritative except the phone
-- number, which is the phone's own business anyway.

Bridge = Bridge or {}

function Bridge.CharactersBoot()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `phone_characters` (
        `citizenid` VARCHAR(64) NOT NULL,
        `firstname` VARCHAR(40) NOT NULL DEFAULT '',
        `lastname`  VARCHAR(40) NOT NULL DEFAULT '',
        `dob`       VARCHAR(20) NOT NULL DEFAULT '',
        `phone`     VARCHAR(20) NULL,
        PRIMARY KEY (`citizenid`),
        UNIQUE KEY `phone` (`phone`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end

--- Split a display name into the two halves the phone shows separately. A framework
--- that only has one name gives a first name and an empty surname, which reads fine.
local function splitName(name)
    name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local first, last = name:match('^(%S+)%s+(.+)$')
    return first or name, last or ''
end

--- Read the character's identity from the framework, in that framework's own words.
local function identityOf(src, citizenid)
    if Bridge.framework == 'qb' then
        local raw = MySQL.scalar.await('SELECT charinfo FROM players WHERE citizenid = ?', { citizenid })
        local ok, info = pcall(json.decode, raw or '{}')
        if ok and info then
            return info.firstname or '', info.lastname or '', info.birthdate or ''
        end

    elseif Bridge.framework == 'ox' then
        local row = MySQL.single.await(
            'SELECT firstName, lastName, dateOfBirth FROM characters WHERE charId = ?', { citizenid })
        if row then
            return row.firstName or '', row.lastName or '', tostring(row.dateOfBirth or '')
        end

    elseif Bridge.framework == 'esx' then
        local row = MySQL.single.await(
            'SELECT firstname, lastname, dateofbirth FROM users WHERE identifier = ?', { citizenid })
        if row then
            return row.firstname or '', row.lastname or '', tostring(row.dateofbirth or '')
        end
    end

    local first, last = splitName(src and GetPlayerName(src) or '')
    return first, last, ''
end

--- Refresh one character's row. Called when they load in, and again whenever the phone
--- mints them a number.
function Bridge.SyncCharacter(src, citizenid)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return end
    local first, last, dob = identityOf(src, citizenid)
    MySQL.query([[INSERT INTO phone_characters (citizenid, firstname, lastname, dob)
                  VALUES (?,?,?,?)
                  ON DUPLICATE KEY UPDATE firstname = VALUES(firstname),
                                          lastname = VALUES(lastname),
                                          dob = VALUES(dob)]],
        { citizenid, first, last, dob })
end

--- Every framework announces a loaded character differently, and a server may run its
--- own. All of them end in the same place.
local function onLoaded(src)
    if not src then return end
    CreateThread(function()
        -- The framework writes the character a moment after the event fires on some
        -- builds; one short wait is cheaper than a retry loop everywhere else.
        Wait(500)
        local p = Core.GetPlayer(src)
        if p then Bridge.SyncCharacter(src, p.citizenid) end
    end)
end

RegisterNetEvent('QBCore:Server:PlayerLoaded', function(player)
    onLoaded(player and player.PlayerData and player.PlayerData.source)
end)
RegisterNetEvent('qbx_core:playerLoaded', function(player)
    onLoaded(player and player.PlayerData and player.PlayerData.source)
end)
AddEventHandler('ox:playerLoaded', function(src) onLoaded(src) end)
RegisterNetEvent('esx:playerLoaded', function(_, xPlayer)
    onLoaded(xPlayer and xPlayer.source)
end)

--- A standalone server has no such event, and a server whose framework fires one this
--- file does not know about should still work. The phone asks on its first open too.
function Bridge.EnsureCharacter(src)
    local p = Core.GetPlayer(src)
    if not p then return nil end
    local known = MySQL.scalar.await('SELECT 1 FROM phone_characters WHERE citizenid = ?', { p.citizenid })
    if not known then Bridge.SyncCharacter(src, p.citizenid) end
    return p
end
