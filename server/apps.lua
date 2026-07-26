-- v-phone | server/apps.lua
--
-- **Garage, Property, Wallet and Jobs, read through the bridge.**
--
-- The same fault the Bank app had, three more times. Upstream each of these is a view over a
-- companion resource - `v-vehicles`, `v-housing`, `v-licenses`, `v-cityhall` - and none of
-- them exist outside the author's own suite, so every one of these apps answered "not
-- available on this server" on qb-core, qbx, ESX and ox alike. The providers they needed were
-- already in `bridge/server/integrations.lua`, written and covering the whole ecosystem, and
-- called by nothing at all.
--
-- This file is the missing half: it hands each app what the bridge already knows, in the
-- shape the page already draws. No new features, no new tables, nothing stored. Every one of
-- these is a READ - taking a car out of a garage or issuing a licence belongs to the script
-- that owns it, and still does.
--
-- A provider that finds nothing returns nil, and that stays a distinct answer: "this server
-- has no garage script the phone can read" is not the same as "you own no cars", and the app
-- says the right one.

local function num(v, d) return tonumber(v) or d or 0 end

--- The operator's switch, shared with the home screen so the icon and the answer agree.
---
--- Tolerant of the helper being absent: it lives in the shared compatibility layer, and four
--- apps refusing to answer because one function did not load would be a poor trade.
local function appOn(key)
    if type(Bridge_AppEnabled) ~= 'function' then return true end
    return Bridge_AppEnabled(key)
end

--- Read something from a provider without letting a broken schema take the app down.
---
--- The bank app taught this: one failing query answered `nil` through the callback layer and
--- the phone could only say "something went wrong". A named reason on the server console and
--- a specific code on the phone costs two lines.
local function safely(what, fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    print(('[v-phone] %s could not be read: %s'):format(what, result))
    return nil
end

-- ══════════════════════════════════════════════════════════════
-- Garage
-- ══════════════════════════════════════════════════════════════
-- Quasar answers for the player through `GetPlayerVehicles`; qb, ox and ESX each keep a
-- table with a different schema. `Bridge.Vehicles.Owned` already flattens all four, so the
-- only work left here is agreeing on what "stored" means, which every one of them spells
-- differently.
--
--   qb    `state`  0 out, 1 in a garage, 2 impounded
--   ox    `stored` the garage it is in, or nil when it is out
--   esx   `stored` a boolean
--
-- Quasar's export returns its own rows, so its keys are read defensively rather than assumed.
local function vehicleRow(v)
    if type(v) ~= 'table' then return nil end

    local plate = tostring(v.plate or v.number_plate or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local model = v.model or v.vehicle or v.name or v.spawncode or ''
    -- A model can arrive as a hash on some garage scripts, which is not a name but is at
    -- least stable to show; better a number than an empty row.
    model = tostring(model)

    -- Worked out from whichever field the script filled in. Unknown means stored: a car the
    -- phone cannot place is more likely parked than abandoned in the street, and claiming it
    -- is out when it is not sends a player looking for it.
    local out
    if v.state ~= nil and tonumber(v.state) then
        out = math.floor(num(v.state, 1)) == 0
    elseif type(v.stored) == 'boolean' then
        out = v.stored == false
    elseif v.stored ~= nil then
        out = tostring(v.stored) == ''
    else
        out = false
    end

    -- The garage it belongs to, under any of the names the scripts use for it.
    local garage = v.garage or v.parking or v.depotname
    if garage == nil and type(v.stored) == 'string' then garage = v.stored end

    return {
        plate = plate,
        model = model,
        garage = garage and tostring(garage) or nil,
        live = out,
        -- Shown by the remote sheet when the script bothered to keep them.
        fuel = v.fuel and math.floor(num(v.fuel, 0)) or nil,
        engine = v.engine and math.floor(num(v.engine, 0)) or nil,
        body = v.body and math.floor(num(v.body, 0)) or nil,
    }
end

V.Callback('v-phone:garage:data', function(src, resolve)
    if not appOn('garage') then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'nochar' }) return end

    local rows = safely('garage', function()
        return Bridge.Vehicles and Bridge.Vehicles.Owned
            and Bridge.Vehicles.Owned(p.citizenid, src)
    end)
    -- nil is "nothing here can be read", which is a different sentence from "no cars".
    if type(rows) ~= 'table' then resolve({ error = 'nogarage' }) return end

    local out = {}
    for _, v in ipairs(rows) do
        local row = vehicleRow(v)
        if row and row.plate ~= '' then
            -- Which garage, by its real name rather than its key. `motelgarage` is a
            -- database value; "Motel Parking" is what the player calls it.
            if row.garage then
                local info = Bridge.Garages and Bridge.Garages.Info
                    and Bridge.Garages.Info(row.garage)
                if info then
                    row.garageLabel = info.label
                    -- A stored car is findable at the garage that holds it.
                    if not row.live and info.x and info.y then
                        row.x, row.y = info.x, info.y
                    end
                end
            end
            -- A car that is OUT is findable where it actually stands, which is the whole
            -- point of asking a phone where you left it.
            if row.live then
                local at = Bridge.Garages and Bridge.Garages.LocatePlate
                    and Bridge.Garages.LocatePlate(row.plate)
                if at then row.x, row.y = at.x, at.y end
            end
            out[#out + 1] = row
        end
    end
    resolve({ ok = true, vehicles = out })
end)

-- ══════════════════════════════════════════════════════════════
-- Property
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:property:data', function(src, resolve)
    if not appOn('property') then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'nochar' }) return end

    local rows = safely('property', function()
        return Bridge.Properties and Bridge.Properties.Owned
            and Bridge.Properties.Owned(p.citizenid, src)
    end)

    -- An unreadable housing script is no longer a dead end. It used to answer an error, and
    -- the app became a single line of grey text with nothing to do - which is what "the
    -- property app does not work" meant. The list is empty, `readable` says why, and the
    -- second tab still tells somebody where to go and buy one.
    local readable = type(rows) == 'table'
    local PROP = Config.Property or {}
    local named = PROP.houses or {}

    local out = {}
    for _, r in ipairs(readable and rows or {}) do
        if type(r) == 'table' then
            local label = r.label or r.name or r.house or r.property or r.address
            if label ~= nil then
                local key = tostring(r.key or r.name or r.id or label)
                -- The operator's own position for a house the script would not give up.
                local override = named[key]
                local x = tonumber(r.x) or (type(override) == 'table' and tonumber(override.x))
                local y = tonumber(r.y) or (type(override) == 'table' and tonumber(override.y))
                out[#out + 1] = {
                    label = tostring((type(override) == 'table' and override.label) or label):sub(1, 60),
                    address = r.address and tostring(r.address):sub(1, 80) or nil,
                    -- Owned unless the script says otherwise. Housing scripts disagree on
                    -- the spelling, so both are accepted and anything else is a tenancy.
                    tenancy = (r.tenancy == 'rent' or r.rented == true or r.rent == true)
                        and 'rent' or 'own',
                    price = tonumber(r.price),
                    tier = tonumber(r.tier),
                    x = x or nil,
                    y = y or nil,
                }
            end
        end
    end

    local agent = PROP.agent or {}
    resolve({
        ok = true,
        readable = readable,
        rows = out,
        -- Where to buy one. Sent whether or not anything is owned, because somebody with no
        -- house is exactly who needs it.
        agent = {
            label = tostring(agent.label or 'Dynasty 8'),
            address = agent.address and tostring(agent.address) or nil,
            x = tonumber(agent.x) or nil,
            y = tonumber(agent.y) or nil,
        },
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Wallet: the licences
-- ══════════════════════════════════════════════════════════════
V.Callback('v-phone:wallet:data', function(src, resolve)
    if not appOn('wallet') then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'nochar' }) return end

    local rows = safely('licences', function()
        return Bridge.Licences and Bridge.Licences.Held
            and Bridge.Licences.Held(src, p.citizenid)
    end)
    -- Who the character is, which is the other half of a wallet. Isolated: a framework that
    -- will not say leaves the card off rather than taking the licences down with it.
    local id = safely('identity', function()
        return Bridge.Identity and Bridge.Identity(p.citizenid, src)
    end)
    local identity = nil
    if type(id) == 'table' then
        local first = id.first and tostring(id.first) or ''
        local last = id.last and tostring(id.last) or ''
        identity = {
            name = ((first .. ' ' .. last):gsub('^%s+', ''):gsub('%s+$', '')),
            dob = id.dob and tostring(id.dob):sub(1, 20) or nil,
            -- 'm' or 'f'; the page names it, so the word is never frozen here.
            sex = (id.sex == 'm' or id.sex == 'f') and id.sex or nil,
            nationality = id.nationality and tostring(id.nationality):sub(1, 40) or nil,
            height = tonumber(id.height),
            -- The citizen id is not sent. Nothing on the page shows it, and a value the
            -- client never needs is a value the client should never receive.
        }
        if identity.name == '' then identity.name = tostring(p.name or '') end
    end

    -- Licences may be unreadable while the identity is perfectly fine, so the identity is
    -- answered either way rather than being lost to an early return.
    if type(rows) ~= 'table' then
        resolve({ ok = true, licenses = {}, readable = false, identity = identity })
        return
    end

    local out = {}
    for _, r in ipairs(rows) do
        if type(r) == 'table' then
            local key = tostring(r.type or r.name or r.key or '')
            if key ~= '' then
                out[#out + 1] = {
                    key = key,
                    label = tostring(r.label or key):sub(1, 40),
                    -- The conventional key, so a server that wants "Permis de conduire"
                    -- rather than "driver" only has to add `ph.lic_driver` to its locale.
                    -- Absent is fine: the page falls back to the label.
                    i18n = 'ph.lic_' .. key,
                    issuer = r.issuer and tostring(r.issuer):sub(1, 40) or nil,
                    -- The provider returns what is HELD, so everything it returns is held.
                    held = true,
                }
            end
        end
    end
    resolve({ ok = true, licenses = out, readable = true, identity = identity })
end)

-- ══════════════════════════════════════════════════════════════
-- Vitals
-- ══════════════════════════════════════════════════════════════
-- Hunger, thirst and stress are the framework's, and health and armour are the ped's. The
-- ped can only be read on the client, so the two halves meet in the client's `health`
-- handler: this answers the half a server knows about.
V.Callback('v-phone:vitals', function(src, resolve)
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'nochar' }) return end

    local st = safely('vitals', function()
        return Bridge.Status and Bridge.Status.Get and Bridge.Status.Get(src)
    end)
    if type(st) ~= 'table' then
        -- Nothing readable here. Not an error: on ESX the vitals live on the client and the
        -- client reads them itself, so an empty answer is the normal case there.
        resolve({ ok = true })
        return
    end

    resolve({
        ok = true,
        hunger = tonumber(st.hunger),
        thirst = tonumber(st.thirst),
        stress = tonumber(st.stress),
        armour = tonumber(st.armour),
        bloodtype = st.bloodtype and tostring(st.bloodtype):sub(1, 6) or nil,
        dead = st.dead == true or nil,
    })
end)

-- ══════════════════════════════════════════════════════════════
-- Jobs
-- ══════════════════════════════════════════════════════════════
-- Two halves: the character's own employment, which the framework already told the bridge
-- when it wrapped the player, and the list of openings, which is the server's job table.
--
-- Neither the salary nor the ladder is on the player - a framework only says which grade you
-- hold - so both are looked up in the job table by name. A server whose job table cannot be
-- read still gets a correct employment card, just without the pay.
local function jobsList()
    local all = safely('jobs', function()
        return Bridge.Jobs and Bridge.Jobs.All and Bridge.Jobs.All()
    end)
    return type(all) == 'table' and all or nil
end

--- The grades of one job, lowest first, as the app's ladder.
local function ladderOf(all, name)
    if type(all) ~= 'table' then return nil end
    for _, job in ipairs(all) do
        if type(job) == 'table' and tostring(job.name or '') == name then
            local out = {}
            for _, g in ipairs(job.grades or {}) do
                if type(g) == 'table' then
                    out[#out + 1] = {
                        grade = math.floor(num(g.grade or g.level, 0)),
                        label = tostring(g.label or g.name or ''),
                        salary = math.floor(num(g.salary or g.payment, 0)),
                    }
                end
            end
            table.sort(out, function(a, b) return a.grade < b.grade end)
            return out, job
        end
    end
    return nil
end

V.Callback('v-phone:jobs:data', function(src, resolve)
    if not appOn('jobs') then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'nochar' }) return end

    local job = p.job or {}
    local all = jobsList()
    local ladder, found = ladderOf(all, tostring(job.name or ''))

    -- The pay for the grade actually held, from the ladder rather than from a guess.
    local salary = 0
    for _, step in ipairs(ladder or {}) do
        if step.grade == math.floor(num(job.grade, 0)) then salary = step.salary end
    end

    local openings = {}
    for _, j in ipairs(all or {}) do
        if type(j) == 'table' and j.name then
            local grades = j.grades or {}
            -- The entry-level wage is what an opening is worth advertising.
            local entry, ranks = 0, 0
            local lowest
            for _, g in ipairs(grades) do
                if type(g) == 'table' then
                    ranks = ranks + 1
                    local lvl = math.floor(num(g.grade or g.level, 0))
                    if lowest == nil or lvl < lowest then
                        lowest = lvl
                        entry = math.floor(num(g.salary or g.payment, 0))
                    end
                end
            end
            openings[#openings + 1] = {
                name = tostring(j.name),
                label = tostring(j.label or j.name),
                salary = entry,
                ranks = ranks > 0 and ranks or nil,
            }
        end
    end
    table.sort(openings, function(a, b) return a.label < b.label end)

    resolve({
        ok = true,
        me = {
            name = tostring(job.name or 'unemployed'),
            label = tostring(job.label or (found and found.label) or job.name or ''),
            grade = math.floor(num(job.grade, 0)),
            gradeLabel = tostring(job.gradeLabel or ''),
            onDuty = job.onDuty ~= false,
            boss = job.boss == true,
            salary = salary,
            ladder = ladder or {},
        },
        jobs = openings,
    })
end)

-- One line at boot saying which of these the phone can actually answer, because an app that
-- reports "not available" without saying why cost several rounds of guessing once already.
CreateThread(function()
    Wait(3000)
    local function state(label, fn)
        local ok, result = pcall(fn)
        return label .. '=' .. ((ok and type(result) == 'table') and 'yes' or 'no')
    end
    print(('[v-phone] bridge apps: %s %s %s %s'):format(
        state('garage', function()
            return Bridge.Vehicles.Owned('__probe__', nil) end),
        state('property', function()
            return Bridge.Properties.Owned('__probe__', nil) end),
        state('licences', function()
            return Bridge.Licences.Held(nil, '__probe__') end),
        state('jobs', function() return Bridge.Jobs.All() end)))
end)
