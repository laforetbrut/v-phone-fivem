-- v-phone | bridge/shared/booth.lua
--
-- **What a payphone's number is, agreed on by both sides.**
--
-- A booth has no database row. Its number is DERIVED from where it stands, by a pure
-- function of its coordinates, so the client that dials and the server that connects the
-- call arrive at the same digits without either telling the other what they are.
--
-- That property is the point. If the number came from the client, a modified client could
-- claim to be calling from any box on the map; because both ends compute it from coords
-- the server has independently checked the player is standing next to, the worst a forged
-- coordinate buys is a different booth number that still cannot be called back.
--
-- Loaded as a shared script, after config.lua, so `Config.Booth` is already there.

Booth = Booth or {}

--- Coordinates snapped to a half metre.
---
--- Two things need this. A static prop's coords should be identical every time, but a
--- float that has been through a network round trip is not something to bet a stable
--- phone number on, so the low bits are dropped. And the step is a HALF metre rather than
--- a whole one because some booths are placed in pairs a little over a metre apart, and
--- rounding those together would give both boxes the same number.
local function snap(value)
    return math.floor((tonumber(value) or 0) * 2 + 0.5) / 2
end

--- A stable string key for a booth. Also what the server logs, so a call from a payphone
--- can be traced to a place on the map.
function Booth.Key(x, y, z)
    return ('%.1f:%.1f:%.1f'):format(snap(x), snap(y), snap(z))
end

--- FNV-1a, 32 bit. Any decent avalanche would do; this one is small, has no dependencies
--- and gives the same answer in every Lua state, which is the only requirement.
local function hash32(text)
    local h = 2166136261
    for i = 1, #text do
        h = h ~ text:byte(i)
        -- The multiply is done in parts and masked, because 32-bit overflow in Lua 5.4's
        -- integers would otherwise wrap through 64 bits and diverge from a real FNV.
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return h
end

--- The literal skeleton of the configured format: every `#` blanked out. `311-####`
--- becomes `311-@@@@`, which is what marks a number as belonging to a booth.
local function skeleton(format)
    return (tostring(format):gsub('#', '@'))
end

--- The number of the booth standing at these coordinates. Always the same digits for the
--- same box, on every restart, on every client.
function Booth.NumberAt(x, y, z)
    local format = tostring((Config.Booth and Config.Booth.numberFormat) or '311-####')
    local h = hash32(Booth.Key(x, y, z))
    -- Consume the hash a digit at a time. Dividing rather than masking keeps every `#`
    -- fed from a different part of the word.
    return (format:gsub('#', function()
        local digit = h % 10
        h = h // 10
        -- A format with more `#` than the hash has digits would start emitting zeroes;
        -- re-hashing keeps them varied instead.
        if h == 0 then h = hash32(tostring(digit) .. Booth.Key(x, y, z)) end
        return tostring(digit)
    end))
end

--- Is this number a payphone's?
---
--- Shape only, and deliberately so: there is no list of booths to check against, and a
--- shape test cannot be fooled by a number that does not exist yet. Every caller that
--- refuses to ring a booth - the call path, the SMS path, the number minter - asks here.
function Booth.IsNumber(number)
    number = tostring(number or '')
    if number == '' then return false end
    local format = tostring((Config.Booth and Config.Booth.numberFormat) or '311-####')
    if #number ~= #format then return false end
    -- Compare position by position: a literal must match exactly, a `#` must be a digit.
    for i = 1, #format do
        local want, got = format:sub(i, i), number:sub(i, i)
        if want == '#' then
            if not got:match('%d') then return false end
        elseif want ~= got then
            return false
        end
    end
    return true
end

--- Is a number one the booth places for free, with no card and no credit? Emergency
--- services, normally. Compared with the punctuation stripped, so `911` in the config
--- still matches `9-1-1` dialled on the keypad.
function Booth.IsFreeNumber(number)
    local function bare(v) return (tostring(v or ''):gsub('%D', '')) end
    local mine = bare(number)
    if mine == '' then return false end
    for _, n in ipairs((Config.Booth and Config.Booth.freeNumbers) or {}) do
        if bare(n) == mine then return true end
    end
    return false
end
