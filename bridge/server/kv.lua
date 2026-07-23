-- v-phone | bridge/server/kv.lua
--
-- **Per-character storage the phone owns.**
--
-- Upstream keeps phone preferences in v-core's character metadata. Every framework has
-- an equivalent - qb has `PlayerData.metadata`, ox has its own key/value store, ESX has
-- none worth the name - and writing into any of them is how a phone breaks the day that
-- framework changes its schema.
--
-- So it does not. Preferences, wallpapers, layouts, health records and photo lists live
-- in `vphone_kv`, keyed by citizen id. One table, owned by this resource, portable across
-- every framework and readable by a server admin without a decoder.
--
-- The cache in front of it is per character, not per session: the phone reads its prefs
-- on nearly every screen, and a database round trip for "which wallpaper" is a database
-- round trip nobody needs.

Bridge = Bridge or {}

local cache = {}

local function encode(value)
    if value == nil then return nil end
    return json.encode(value)
end

local function decode(raw)
    if raw == nil or raw == '' then return nil end
    local ok, value = pcall(json.decode, raw)
    return ok and value or nil
end

--- Read one key for one character. Missing is nil, never an error: the phone treats an
--- absent preference as "the default", which is exactly right for a new character.
function Bridge.KvGet(citizenid, key)
    citizenid = tostring(citizenid or '')
    if citizenid == '' or not key then return nil end

    local mine = cache[citizenid]
    if mine and mine[key] ~= nil then
        if mine[key] == false then return nil end   -- cached "known absent"
        return mine[key]
    end

    local raw = MySQL.scalar.await(
        'SELECT value FROM vphone_kv WHERE citizenid = ? AND `key` = ?', { citizenid, key })
    local value = decode(raw)
    cache[citizenid] = cache[citizenid] or {}
    cache[citizenid][key] = value == nil and false or value
    return value
end

--- Write one key. Passing nil deletes it, so "reset to default" is not a special case.
function Bridge.KvSet(citizenid, key, value)
    citizenid = tostring(citizenid or '')
    if citizenid == '' or not key then return false end

    cache[citizenid] = cache[citizenid] or {}
    cache[citizenid][key] = value == nil and false or value

    if value == nil then
        MySQL.query('DELETE FROM vphone_kv WHERE citizenid = ? AND `key` = ?', { citizenid, key })
        return true
    end
    MySQL.query([[INSERT INTO vphone_kv (citizenid, `key`, value) VALUES (?,?,?)
                  ON DUPLICATE KEY UPDATE value = VALUES(value)]],
        { citizenid, key, encode(value) })
    return true
end

--- Dropped players keep nothing warm. A character that comes back reads from the table,
--- which is the only copy that was ever authoritative.
AddEventHandler('playerDropped', function()
    local src = source
    local p = Bridge.GetPlayer and Bridge.GetPlayer(src)
    if p then cache[p.citizenid] = nil end
end)

function Bridge.KvBoot()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS `vphone_kv` (
        `citizenid` VARCHAR(64) NOT NULL,
        `key`       VARCHAR(48) NOT NULL,
        `value`     LONGTEXT    NULL,
        PRIMARY KEY (`citizenid`, `key`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end
