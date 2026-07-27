-- v-phone | server/taxi.lua
--
-- **Taxi: hail a ride from the phone.**
--
-- Two providers, one app, and the page is written for both:
--
--   * **doc-taxijob**, when it is running. Its drivers, its calls, its fares, its ratings and
--     its tips, reached from client/taxi.lua through the same server callbacks its own phone app
--     used. **Nothing in doc-taxijob is touched** - not a line edited, wrapped or replaced - so
--     this file does not run at all in that mode beyond answering "not me".
--   * **`Config.Taxi`** otherwise, which is what makes the app worth installing on an ESX, ox or
--     standalone server where doc-taxijob does not exist. Its own ride queue, its own fare
--     arithmetic, its own money.
--
-- In config mode every decision is the server's:
--
--   * who is a driver is the job the framework reports, never a claim from a page;
--   * a fare is measured from the ride's own recorded distance and priced from the config;
--   * the passenger is debited before the driver is paid, and the driver is paid only once the
--     debit is confirmed - a fare that cannot be taken leaves the ride unpaid rather than
--     inventing money;
--   * a passenger may rate only a ride they actually took, and only once.
--
-- Rides live in memory. A ride is about right now: a server that restarts has nobody in a car.

local CFG = Config.Taxi or {}

local function num(v, d) return tonumber(v) or d or 0 end
local function enabled() return CFG.enabled ~= false end

--- Is doc-taxijob the provider? Asked per request, so starting it mid-session works.
local function docMode()
    local want = tostring(CFG.provider or 'auto'):lower()
    if want == 'config' then return false end
    if want == 'doc-taxijob' then return true end
    return GetResourceState('doc-taxijob') == 'started'
end

local function jobName() return tostring(CFG.job or 'taxi') end

--- Is this character an on-duty driver? The framework's answer, never the page's.
local function isDriver(p)
    if not p then return false end
    local job = p.job
    if type(job) ~= 'table' then return false end
    if tostring(job.name) ~= jobName() then return false end
    -- Through `Bridge.OnDuty`, not `job.onDuty` directly: that is the one place that knows how
    -- each framework answers, and the one place a server with esx_service hooks into. Reading
    -- the field here would make this app the only one that ignores the hook.
    if CFG.onDutyOnly ~= false and Bridge and Bridge.OnDuty
        and not Bridge.OnDuty(p.source, p) then
        return false
    end
    if num(job.grade, 0) < num(CFG.minGrade, 0) then return false end
    return true
end

local function driversOnline()
    local out = {}
    for _, raw in ipairs(GetPlayers()) do
        local src = tonumber(raw)
        local p = src and Core.GetPlayer(src)
        if p and isDriver(p) then out[#out + 1] = src end
    end
    return out
end

-- ══════════════════════════════════════════════════════════════
-- The rides
-- ══════════════════════════════════════════════════════════════

local Rides = {}     -- [id] = ride
local Order = {}     -- ids, oldest first
local nextId = 0
local LastCall = {}  -- [citizenid] = os.time(), for the cooldown

local function fareFor(metres)
    local km = math.max(0, num(metres, 0)) / 1000.0
    local base = math.max(0, math.floor(num(CFG.basePrice, 50)))
    local perKm = math.max(0, num(CFG.pricePerKm, 15))
    local fare = base + math.floor(km * perKm)
    local ceiling = math.floor(num(CFG.maxFare, 0))
    if ceiling > 0 then fare = math.min(fare, ceiling) end
    return fare
end

local function expireSeconds()
    return math.max(30, math.floor(num(CFG.expireSeconds, 300)))
end

local function isLive(r)
    if not r then return false end
    if r.state ~= 'pending' then return r.state == 'accepted' or r.state == 'riding' end
    return (os.time() - r.at) < expireSeconds()
end

--- What a driver sees of a waiting fare. The passenger's coordinates travel to a driver on duty
--- and to nobody else, which is the whole job - and never their citizen id.
local function rideFor(r, forDriver)
    local out = {
        id = r.id, name = r.name, passengers = r.passengers, destination = r.destination,
        at = r.at, state = r.state, note = r.note,
        estimate = r.estimate, fare = r.fare,
        driver = r.driverName,
    }
    if forDriver then
        out.x, out.y, out.z = r.x, r.y, r.z
    end
    return out
end

local function myRide(cid)
    for i = #Order, 1, -1 do
        local r = Rides[Order[i]]
        if r and r.cid == cid and isLive(r) then return r end
    end
    return nil
end

local function tellDrivers(payload, except)
    for _, src in ipairs(driversOnline()) do
        if src ~= except then TriggerClientEvent('v-phone:client:taxi', src, payload) end
    end
end

local function tellPassenger(r, payload)
    local p = r.cid and Core.GetPlayerByCitizenId(r.cid)
    if p and p.source then TriggerClientEvent('v-phone:client:taxi', p.source, payload) end
end

-- ══════════════════════════════════════════════════════════════
-- What the app reads
-- ══════════════════════════════════════════════════════════════

V.Callback('v-phone:taxi:open', function(src, resolve)
    if not enabled() then resolve({ error = 'off' }) return end
    -- In doc-taxijob mode the client talks to it directly; this says so rather than answering
    -- with an empty queue that would read as "no drivers".
    if docMode() then resolve({ ok = true, doc = true }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    local driver = isDriver(p)

    -- A driver's queue: every fare still waiting. A passenger's: their own ride only.
    local queue = {}
    if driver then
        for _, id in ipairs(Order) do
            local r = Rides[id]
            if r and r.state == 'pending' and isLive(r) then queue[#queue + 1] = rideFor(r, true) end
        end
    end

    local mine = myRide(p.citizenid)
    local wait = 0
    local last = LastCall[p.citizenid]
    if last then
        wait = math.max(0, math.floor(num(CFG.cooldown, 60)) - (os.time() - last))
    end

    resolve({
        ok = true,
        doc = false,
        isDriver = driver,
        playerName = p.name or '',
        drivers = #driversOnline(),
        queue = queue,
        ride = mine and rideFor(mine, driver) or nil,
        basePrice = math.max(0, math.floor(num(CFG.basePrice, 50))),
        pricePerKm = math.max(0, num(CFG.pricePerKm, 15)),
        maxPassengers = math.max(1, math.floor(num(CFG.maxPassengers, 4))),
        money = tostring(CFG.account or 'cash'),
        tip = {
            on = (CFG.tip or {}).enabled ~= false,
            presets = (CFG.tip or {}).presets or { 0, 10, 20 },
            max = math.max(0, math.floor(num((CFG.tip or {}).max, 500))),
        },
        rating = CFG.rating ~= false,
        cooldown = wait > 0 and wait or nil,
        -- What a passenger owes for a finished ride, so the app can ask to settle it.
        due = (mine and mine.state == 'done' and mine.fare) or nil,
    })
end)

--- Book a ride. The position is the ped's, on this server.
V.Callback('v-phone:taxi:call', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if docMode() then resolve({ error = 'viadoc' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end
    if isDriver(p) and CFG.driversMayCall == false then resolve({ error = 'youaredriver' }) return end

    if myRide(p.citizenid) then resolve({ error = 'already' }) return end

    local last = LastCall[p.citizenid]
    local cooldown = math.floor(num(CFG.cooldown, 60))
    if last and (os.time() - last) < cooldown then
        resolve({ error = 'cooldown', wait = cooldown - (os.time() - last) })
        return
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then resolve({ error = 'x' }) return end
    local c = GetEntityCoords(ped)

    nextId = nextId + 1
    local id = 'ride' .. tostring(nextId)
    local passengers = math.max(1, math.min(math.floor(num(CFG.maxPassengers, 4)),
                                           math.floor(num(data and data.passengers, 1))))
    local ride = {
        id = id,
        cid = p.citizenid,
        name = p.name or '',
        passengers = passengers,
        destination = tostring((data and data.destination) or ''):gsub('[%c]', ''):sub(1, 60),
        note = tostring((data and data.note) or ''):gsub('[%c]', ''):sub(1, 120),
        at = os.time(),
        state = 'pending',
        x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0,
        -- What it will cost if it goes nowhere at all. The real fare is measured on arrival.
        estimate = fareFor(0),
    }
    Rides[id] = ride
    Order[#Order + 1] = id
    LastCall[p.citizenid] = os.time()

    local drivers = driversOnline()
    tellDrivers({ kind = 'incoming', ride = rideFor(ride, true) })
    Core.Log('taxi', ('%s called a taxi (%d driver(s) on duty)')
        :format(p.name or p.citizenid, #drivers), nil, p.citizenid)

    resolve({ ok = true, id = id, drivers = #drivers, estimate = ride.estimate })
end)

--- Everything a ride can have done to it. One callback, because they share every check: who is
--- asking, which ride, and whether they are allowed near it.
V.Callback('v-phone:taxi:act', function(src, resolve, data)
    if not enabled() then resolve({ error = 'off' }) return end
    if docMode() then resolve({ error = 'viadoc' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local op = tostring((data and data.op) or '')
    local r = Rides[tostring((data and data.id) or '')]

    -- ── the passenger's own ride ──
    if op == 'cancel' then
        if not r then resolve({ error = 'gone' }) return end
        if r.cid ~= p.citizenid then resolve({ error = 'notyours' }) return end
        if r.state ~= 'pending' and r.state ~= 'accepted' then resolve({ error = 'toolate' }) return end
        r.state = 'cancelled'
        tellDrivers({ kind = 'cancelled', id = r.id })
        resolve({ ok = true })
        return
    end

    -- ── the driver's side ──
    if not isDriver(p) then resolve({ error = 'notdriver' }) return end

    if op == 'accept' then
        if not r then resolve({ error = 'gone' }) return end
        if r.state ~= 'pending' then resolve({ error = 'taken', driver = r.driverName }) return end
        r.state = 'accepted'
        r.driver = p.citizenid
        r.driverName = p.name or ''
        r.driverSrc = src
        r.acceptedAt = os.time()
        -- Where it started, so the fare can be measured against where it ends.
        r.fromX, r.fromY = r.x, r.y
        tellPassenger(r, { kind = 'accepted', id = r.id, driver = r.driverName })
        tellDrivers({ kind = 'taken', id = r.id }, src)
        resolve({ ok = true, ride = rideFor(r, true) })
        return
    end

    if op == 'arrived' then
        if not r or r.driver ~= p.citizenid then resolve({ error = 'notyours' }) return end
        r.state = 'riding'
        r.startedAt = os.time()
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            r.fromX, r.fromY = c.x + 0.0, c.y + 0.0
        end
        tellPassenger(r, { kind = 'riding', id = r.id })
        resolve({ ok = true })
        return
    end

    -- The end of the ride: the fare is measured here, from the distance actually covered.
    if op == 'finish' then
        if not r or r.driver ~= p.citizenid then resolve({ error = 'notyours' }) return end
        if r.state ~= 'riding' and r.state ~= 'accepted' then resolve({ error = 'toolate' }) return end

        local metres = 0
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 and r.fromX then
            local c = GetEntityCoords(ped)
            metres = #(vector3(c.x, c.y, c.z) - vector3(r.fromX, r.fromY, c.z))
        end
        r.metres = math.floor(metres)
        r.fare = fareFor(metres)
        r.state = 'done'
        r.doneAt = os.time()

        -- Taking the money is a separate step the PASSENGER confirms, so a driver cannot debit
        -- somebody by pressing a button. The app asks them to settle.
        tellPassenger(r, { kind = 'done', id = r.id, fare = r.fare, km = r.metres })
        resolve({ ok = true, fare = r.fare, km = r.metres })
        return
    end

    resolve({ error = 'x' })
end)

--- Settle a finished ride: the passenger pays, the driver is paid.
V.Callback('v-phone:taxi:pay', function(src, resolve, data)
    if not enabled() or docMode() then resolve({ error = 'viadoc' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local r = Rides[tostring((data and data.id) or '')]
    if not r or r.cid ~= p.citizenid then resolve({ error = 'notyours' }) return end
    if r.state ~= 'done' then resolve({ error = 'toolate' }) return end
    if r.paid then resolve({ error = 'paid' }) return end

    local fare = math.max(0, math.floor(num(r.fare, 0)))
    local tip = 0
    if (CFG.tip or {}).enabled ~= false then
        tip = math.max(0, math.floor(num(data and data.tip, 0)))
        tip = math.min(tip, math.max(0, math.floor(num((CFG.tip or {}).max, 500))))
    end
    local total = fare + tip
    if total <= 0 then r.paid = true resolve({ ok = true, total = 0 }) return end

    local purse = tostring(CFG.account or 'cash')
    local acting = PhoneActingSource and PhoneActingSource(src) or src
    if not Bridge.RemoveMoney(acting, total, purse) then
        resolve({ error = 'nomoney', price = total })
        return
    end
    -- Marked paid before the driver is credited: a credit that fails must not let the fare be
    -- charged twice.
    r.paid = true

    local driver = r.driver and Core.GetPlayerByCitizenId(r.driver)
    if driver and driver.source then
        if not Bridge.AddMoney(driver.source, total, purse, 'v-phone: taxi fare') then
            -- The driver could not be paid, so the passenger is refunded rather than the money
            -- vanishing between them.
            --
            -- **And the refund is checked.** It goes through the same `AddMoney` that just
            -- failed, so assuming it worked is assuming the thing that did not. If it fails too,
            -- the company holds the fare - and if there is no company either, it is logged
            -- UNCONDITIONALLY with the amount and the character, because money that stopped
            -- existing is the one outcome nobody may discover from a player's complaint.
            r.paid = false
            if not Bridge.AddMoney(acting, total, purse, 'v-phone: taxi fare reversed') then
                local held = false
                if CFG.paySociety ~= false and Bridge.AddSociety then
                    held = Bridge.AddSociety(tostring(CFG.society or jobName()), total,
                        ('v-phone: taxi fare owed to %s'):format(p.citizenid)) and true or false
                end
                V.Log(('taxi: %d could not be paid to the driver OR refunded to %s (%s)%s')
                    :format(total, p.name or '?', p.citizenid,
                            held and ' - held on the company account' or ' - NOT held anywhere'))
            end
            resolve({ error = 'x' })
            return
        end
        TriggerClientEvent('v-phone:client:taxi', driver.source,
            { kind = 'paid', id = r.id, total = total, tip = tip })
    elseif CFG.paySociety ~= false and Bridge.AddSociety then
        -- The driver logged off mid-fare. The company takes it, which is better than nobody.
        Bridge.AddSociety(tostring(CFG.society or jobName()), total, 'v-phone: taxi fare')
    end

    Core.Log('taxi', ('%s paid %d for a taxi (%dm)')
        :format(p.name or p.citizenid, total, math.floor(num(r.metres, 0))), nil, p.citizenid)
    resolve({ ok = true, total = total, tip = tip })
end)

--- Rate the ride. Once, and only a ride this character actually took.
V.Callback('v-phone:taxi:rate', function(src, resolve, data)
    if not enabled() or docMode() then resolve({ error = 'viadoc' }) return end
    if CFG.rating == false then resolve({ error = 'off' }) return end
    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local r = Rides[tostring((data and data.id) or '')]
    if not r or r.cid ~= p.citizenid then resolve({ error = 'notyours' }) return end
    if r.state ~= 'done' then resolve({ error = 'toolate' }) return end
    if r.rated then resolve({ error = 'rated' }) return end

    r.rated = math.max(1, math.min(5, math.floor(num(data and data.stars, 5))))
    r.comment = tostring((data and data.comment) or ''):gsub('[%c]', ''):sub(1, 200)

    -- Told to the driver, because a rating nobody sees is a rating that changes nothing.
    local driver = r.driver and Core.GetPlayerByCitizenId(r.driver)
    if driver and driver.source then
        TriggerClientEvent('v-phone:client:taxi', driver.source,
            { kind = 'rated', id = r.id, stars = r.rated, comment = r.comment })
    end
    resolve({ ok = true, stars = r.rated })
end)

-- ══════════════════════════════════════════════════════════════
-- Housekeeping and the outside
-- ══════════════════════════════════════════════════════════════

CreateThread(function()
    while true do
        Wait(30000)
        if enabled() and not docMode() then
            for _, id in ipairs(Order) do
                local r = Rides[id]
                if r and r.state == 'pending' and (os.time() - r.at) >= expireSeconds() then
                    r.state = 'expired'
                    tellPassenger(r, { kind = 'expired', id = r.id })
                    tellDrivers({ kind = 'cancelled', id = r.id })
                end
            end
            -- Trim what nobody will look at again.
            local keep = math.max(10, math.floor(num(CFG.history, 40)))
            while #Order > keep do
                local id = table.remove(Order, 1)
                Rides[id] = nil
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local p = Core.GetPlayerReal and Core.GetPlayerReal(src) or Core.GetPlayer(src)
    if not p then return end
    for _, id in ipairs(Order) do
        local r = Rides[id]
        -- A passenger who leaves cancels their waiting ride; a driver who leaves hands theirs
        -- back to the queue rather than stranding somebody in an accepted ride nobody is driving.
        if r and r.cid == p.citizenid and r.state == 'pending' then
            r.state = 'cancelled'
            tellDrivers({ kind = 'cancelled', id = r.id })
        elseif r and r.driver == p.citizenid and (r.state == 'accepted' or r.state == 'riding') then
            r.state = 'pending'
            r.driver, r.driverName, r.driverSrc = nil, nil, nil
            tellPassenger(r, { kind = 'dropped', id = r.id })
            tellDrivers({ kind = 'incoming', ride = rideFor(r, true) })
        end
    end
end)

-- ══════════════════════════════════════════════════════════════
-- Reaching the passenger, on doc-taxijob
-- ══════════════════════════════════════════════════════════════
--- The phone number of a fare a driver has just accepted.
---
--- Asked for because a driver needs to be able to ring the person they are driving to - "I am
--- outside", "which gate?" - and doc-taxijob's accept payload hands the driver the passenger's
--- SERVER ID and name, and no number. The number is this resource's own data, so this is where
--- it is resolved.
---
--- What is enforced here, and why it is not simply "look up any number":
---
---   * the caller holds the taxi job and is on duty, by the same `isDriver` every other part of
---     this file uses - so a civilian cannot use it as a directory;
---   * the operator can switch it off entirely with `Config.Taxi.docCallClient = false`;
---   * every lookup is logged, with both citizen ids, so a driver mining numbers leaves a trail.
---
--- What is NOT enforced, stated plainly rather than implied: this server cannot verify that
--- doc-taxijob really did pair these two, because that pairing lives in doc-taxijob's memory and
--- reading it would mean modifying it. An on-duty driver could therefore ask for the number of
--- any player id. That is the honest limit of integrating without touching the other resource -
--- hence the job gate, the switch and the log.
V.Callback('v-phone:taxi:peer', function(src, resolve, data)
    if not enabled() or not docMode() then resolve({ error = 'notdoc' }) return end
    if CFG.docCallClient == false then resolve({ error = 'off' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve({ error = 'noplayer' }) return end
    if not isDriver(p) then resolve({ error = 'notdriver' }) return end

    local target = tonumber(data and data.target)
    if not target then resolve({ error = 'args' }) return end
    local other = Core.GetPlayer(target)
    if not other then resolve({ error = 'gone' }) return end

    local number = Bridge.Numbers.Get and Bridge.Numbers.Get(other.citizenid) or nil
    if not number or number == '' then resolve({ error = 'nonumber' }) return end

    V.Log(('taxi: %s looked up the number of their fare %s')
        :format(tostring(p.citizenid), tostring(other.citizenid)))
    resolve({
        ok = true,
        number = number,
        name = tostring(Bridge.NameOfCitizen and Bridge.NameOfCitizen(other.citizenid) or ''),
    })
end)

--- For a dispatch board, or a taxi script of your own on a framework doc-taxijob does not serve.
exports('GetTaxiRides', function()
    local out = {}
    for _, id in ipairs(Order) do
        local r = Rides[id]
        if r and isLive(r) then out[#out + 1] = rideFor(r, true) end
    end
    return out
end)

exports('GetTaxiDrivers', function() return #driversOnline() end)
