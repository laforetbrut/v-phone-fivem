-- v-phone | server/outage.lua
--
-- **Network outages, imposed by staff.**
--
-- The phone already decides signal from the player's real position: `signalAt` walks the
-- dead zones and the WORST one wins, so a tunnel inside a weak-signal desert is still a
-- tunnel. An outage is the same idea with a different author - the operator instead of the
-- map - and it obeys the same rule, so a global outage at zero bars cannot be escaped by
-- standing somewhere the map calls perfect reception.
--
-- Two kinds:
--
--   * **global** - the whole server. A storm, a mast fire, the start of an event where
--     nobody may call the police.
--   * **area** - a circle. A jammer in a bank during a heist, one district cut off.
--
-- Both carry a ceiling in bars rather than an on/off flag, because "one bar" is a far more
-- interesting outage than "no phone": messages crawl, calls drop, and players have to move.
-- Zero bars is available and is what most staff will reach for.
--
-- **Nothing here is persisted, on purpose.** A restart clears every outage. That is the
-- safety valve: an outage that survived a crash, with no staff online who remembered
-- setting it, is a server whose phones are broken for reasons nobody can find. Staff who
-- want one back after a restart set it again, which takes one line.

-- [id] = { bars, expires, reason, x, y, z, radius }  -- x/y/z absent on a global outage
local Zones = {}
local NextId = 1

--- Drop anything whose clock has run out. Called on every read rather than on a timer:
--- a timer would need to be right about the tick, and this only ever walks a handful of
--- entries that staff typed by hand.
local function sweep()
    local now = os.time()
    for id, z in pairs(Zones) do
        if z.expires and now >= z.expires then Zones[id] = nil end
    end
end

--- The ceiling any outage puts on a position, or 4 when there is none.
---
--- Global first, then every area containing the point, worst wins. Called from `signalAt`
--- in server/main.lua on every signal tick, so it stays cheap: no allocation, no SQL, and
--- an early return on the overwhelmingly common case of no outage at all.
function OutageCeiling(coords)
    if next(Zones) == nil then return 4 end
    sweep()
    local bars = 4
    for _, z in pairs(Zones) do
        if not z.x then
            bars = math.min(bars, z.bars)
        elseif coords then
            local d = #(coords - vector3(z.x, z.y, z.z))
            if d <= z.radius then bars = math.min(bars, z.bars) end
        end
    end
    return bars
end

--- Raise one. `area` is nil for a global outage, or { x, y, z, radius }.
--- Returns the id, which is what staff clear it by.
function OutageAdd(bars, minutes, reason, area)
    bars = math.max(0, math.min(4, math.floor(tonumber(bars) or 0)))
    minutes = math.max(0, math.floor(tonumber(minutes) or 0))
    local id = NextId
    NextId = NextId + 1
    Zones[id] = {
        bars = bars,
        -- 0 minutes means "until somebody clears it". Deliberately allowed: a heist jammer
        -- lasts as long as the heist, and staff should not have to guess.
        expires = minutes > 0 and (os.time() + minutes * 60) or nil,
        reason = tostring(reason or ''),
        x = area and (area.x + 0.0) or nil,
        y = area and (area.y + 0.0) or nil,
        z = area and (area.z + 0.0) or nil,
        radius = area and math.max(1.0, tonumber(area.radius) or 100.0) or nil,
    }
    return id
end

--- Clear one by id, or every one of them. Returns how many went.
function OutageClear(id)
    sweep()
    if id == nil or id == 'all' then
        local n = 0
        for k in pairs(Zones) do Zones[k] = nil; n = n + 1 end
        return n
    end
    id = math.floor(tonumber(id) or 0)
    if not Zones[id] then return 0 end
    Zones[id] = nil
    return 1
end

--- Everything currently in force, for staff to read back.
function OutageList()
    sweep()
    local out = {}
    for id, z in pairs(Zones) do
        out[#out + 1] = {
            id = id, bars = z.bars, reason = z.reason,
            global = z.x == nil,
            x = z.x, y = z.y, z = z.z, radius = z.radius,
            -- Seconds left, or nil when it runs until cleared.
            left = z.expires and math.max(0, z.expires - os.time()) or nil,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- ══════════════════════════════════════════════════════════════
-- A phone taken out of service, one character at a time
-- ══════════════════════════════════════════════════════════════
-- Distinct from an outage: the network is fine, this handset is not. A phone somebody
-- smashed, a phone confiscated at booking, a phone staff need dead for a scene.
--
-- Keyed by CITIZEN id rather than by source, so it survives the player rejoining - which
-- is the whole point of confiscating something. Cleared on restart like everything else
-- here, for the same reason.

local Bricked = {}   -- [citizenid] = { expires, reason }

--- Is this character's phone out of service? Also sweeps its own expiry.
function PhoneBricked(citizenid)
    local row = Bricked[tostring(citizenid or '')]
    if not row then return false end
    if row.expires and os.time() >= row.expires then
        Bricked[tostring(citizenid)] = nil
        return false
    end
    return true, row.reason
end

function PhoneBrick(citizenid, minutes, reason)
    citizenid = tostring(citizenid or '')
    if citizenid == '' then return false end
    minutes = math.max(0, math.floor(tonumber(minutes) or 0))
    Bricked[citizenid] = {
        expires = minutes > 0 and (os.time() + minutes * 60) or nil,
        reason = tostring(reason or ''),
    }
    -- Shut it now if they are holding it. Leaving an open phone on screen that answers
    -- nothing is worse than closing it: the player would read every failure as a bug.
    local target = Core.GetPlayerByCitizenId(citizenid)
    if target and target.source then
        TriggerClientEvent('v-phone:client:close', target.source)
    end
    return true
end

function PhoneUnbrick(citizenid)
    citizenid = tostring(citizenid or '')
    if not Bricked[citizenid] then return false end
    Bricked[citizenid] = nil
    return true
end

function BrickedList()
    local out = {}
    for cid in pairs(Bricked) do
        if PhoneBricked(cid) then out[#out + 1] = cid end
    end
    table.sort(out)
    return out
end

-- ══════════════════════════════════════════════════════════════
-- For other resources
-- ══════════════════════════════════════════════════════════════
-- A heist script wants to jam a block for the length of a robbery; a storm script wants
-- the whole map on one bar. Neither should have to fake an admin command to do it.
exports('AddOutage', function(bars, minutes, reason, area) return OutageAdd(bars, minutes, reason, area) end)
exports('ClearOutage', function(id) return OutageClear(id) end)
exports('GetOutages', function() return OutageList() end)
exports('BrickPhone', function(citizenid, minutes, reason) return PhoneBrick(citizenid, minutes, reason) end)
exports('UnbrickPhone', function(citizenid) return PhoneUnbrick(citizenid) end)
exports('IsPhoneBricked', function(citizenid) return (PhoneBricked(citizenid)) end)
