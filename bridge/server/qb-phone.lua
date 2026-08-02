-- ══════════════════════════════════════════════════════════════
--  qb-phone compatibility - server
-- ══════════════════════════════════════════════════════════════
-- A stock qb-core server has eighteen resources that talk to `qb-phone`. Removing the stock
-- phone and dropping v-phone in its place leaves all of them talking to nobody, which is
-- quiet in some places and an error in others. This file answers them.
--
-- What it does NOT do is provide `exports['qb-phone']`. An export is bound to a RESOURCE
-- NAME, so that one call has to come from a resource literally called qb-phone - see
-- compat/qb-phone/, which is twenty lines that forward straight back here.
--
-- The split matters: the logic lives in v-phone where it can be maintained, and the compat
-- resource is a name and nothing else.

if not V or not V.Setting then return end

QbPhone = QbPhone or {}

local RES = GetCurrentResourceName()

-- Per-source throttle for the contact swap, cleared on disconnect.
local ContactCooldown = {}

-- ── Is this bridge in charge? ─────────────────────────────────
-- Evaluated LAZILY and cached, never at file load. The recommended server.cfg has
-- `ensure v-phone` BEFORE `ensure qb-phone`, so at the moment this file is parsed the compat
-- resource is still stopped - a gate decided here would ship permanently disabled.
local claimed

local function active()
    local mode = (Config and Config.Compat and Config.Compat.qbPhone)
    if mode == false then return false end
    if mode == true then return true end

    if claimed == nil then
        local state = GetResourceState('qb-phone')
        -- Our compat resource declares `vphone_compat 'yes'` in its manifest; the real
        -- qb-phone does not. If somebody is running the genuine article, stand down
        -- completely rather than answering every event twice.
        claimed = (state ~= 'started' and state ~= 'starting')
            or GetResourceMetadata('qb-phone', 'vphone_compat', 0) == 'yes'
    end
    return claimed
end

AddEventHandler('onResourceStart', function(r) if r == 'qb-phone' then claimed = nil end end)
AddEventHandler('onResourceStop', function(r) if r == 'qb-phone' then claimed = nil end end)

-- ── Shapes ────────────────────────────────────────────────────
-- qb-core writes mail bodies as small HTML: <br> for lines, <strong> for emphasis. v-phone
-- stores text. Converting is better than either escaping the tags into the body or letting
-- them through - a player should not read `<br>` in their inbox.
local function detag(html)
    local text = tostring(html or '')
    text = text:gsub('<%s*[bB][rR]%s*/?%s*>', '\n')
    text = text:gsub('</%s*[pP]%s*>', '\n')
    text = text:gsub('<[^>]->', '')
    text = text:gsub('&nbsp;', ' '):gsub('&amp;', '&'):gsub('&lt;', '<'):gsub('&gt;', '>')
    text = text:gsub('&quot;', '"'):gsub('&#39;', "'")
    text = text:gsub('\n%s*\n%s*\n+', '\n\n')
    return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- qb's `sender` is a display name ('Township', 'Los Santos Police'), not an address, and
--- v-phone addresses mail to a mailbox. Left alone if it already looks like an address.
function QbPhone.AddressOf(sender)
    sender = tostring(sender or 'Los Santos')
    if sender:find('@', 1, true) then return sender:sub(1, 64) end
    local slug = sender:lower():gsub('[^%w]', '')
    if slug == '' then slug = 'noreply' end
    return (slug .. '@ls.com'):sub(1, 64)
end

--- The one mapping everything else goes through.
---
--- v-phone addresses mail to a MAILBOX, so `SendMail` returns false with 'nomailbox' for a
--- character who has never opened the Mail app. qb's phone had no such concept and its
--- callers assume delivery, so rather than dropping the message it falls back to a service
--- message, which needs no mailbox.
function QbPhone.Mail(citizenid, mailData)
    citizenid = tostring(citizenid or '')
    if citizenid == '' or type(mailData) ~= 'table' then return false end

    local sender  = tostring(mailData.sender or 'Los Santos')
    local subject = tostring(mailData.subject or '')
    local body    = detag(mailData.message or mailData.body or '')

    local ok, why = exports[RES]:SendMail(citizenid, QbPhone.AddressOf(sender), subject, body)
    if ok then return true end
    if why ~= 'nomailbox' then return false end

    -- The fallback thread is keyed on `('svc:%s'):format(label):sub(1, 16)` in api.lua, which
    -- leaves twelve characters of the label to tell services apart. Shortened deliberately
    -- here: left to itself, 'Los Santos Police Department' and 'Los Santos Customs' land in
    -- the same conversation.
    local label = sender:gsub('^[Ll]os [Ss]antos%s+', '')
    if label == '' then label = sender end

    local text = subject ~= '' and (subject .. '\n\n' .. body) or body
    return (exports[RES]:SendServiceMessage(citizenid, label:sub(1, 12), text)) and true or false
end

-- ── The events ────────────────────────────────────────────────
-- Ten call sites across qb-ambulancejob, qb-cityhall, qb-drugs, qb-pawnshop, qb-policejob,
-- qb-scrapyard and qb-truckrobbery. It is a net event because the stock phone made it one,
-- and every caller is a client script.
--
-- The recipient is the SOURCE's own citizen id, never a value from the payload. Stock had
-- the same property by accident; here it is on purpose.
RegisterNetEvent('qb-phone:server:sendNewMail', function(mailData)
    if not active() then return end
    local src = source
    local player = Core and Core.GetPlayer and Core.GetPlayer(src)
    if not player or type(mailData) ~= 'table' then return end

    -- Flat `citizenid`, not PlayerData.citizenid: Core.GetPlayer hands back the bridge's own
    -- normalised player (bridge/server/framework.lua wrap()), which carries the framework's
    -- fields flattened. The raw qb object never leaves that function.
    local cid = player.citizenid
    if not cid then return end

    QbPhone.Mail(cid, mailData)

    -- qb mail can carry a button that fires a client event - qb-drugs uses one to set the
    -- delivery waypoint, and dropping it silently breaks deliveries. v-phone's Mail has no
    -- buttons, so the event is fired back at the player instead.
    --
    -- OFF by default, and re-fired ONLY at the sender: the payload arrived from a client, so
    -- honouring an arbitrary event name for an arbitrary target would let any player make
    -- any other player's client fire anything.
    local buttons = Config and Config.Compat and Config.Compat.qbPhoneMailButtons
    if buttons and type(mailData.button) == 'table' and mailData.button.buttonEvent then
        TriggerClientEvent(tostring(mailData.button.buttonEvent), src, mailData.button.buttonData)
    end
end)

-- Deliberately AddEventHandler and NOT RegisterNetEvent. The stock version took an arbitrary
-- citizen id straight off the wire (qb-phone/server.lua:718), which let any client post mail
-- to any character on the server. Nothing on a stock qb-core install calls it from a client,
-- so server-only costs nothing and closes that.
AddEventHandler('qb-phone:server:sendNewEventMail', function(citizenid, mailData)
    if not active() then return end
    QbPhone.Mail(citizenid, mailData)
end)

--- The qb-phone export, reachable from anywhere. compat/qb-phone forwards to this, and a
--- script that would rather not depend on the compat resource can call it directly.
--- Printed once, not once per call: a script making this mistake makes it in a loop.
local warnedQbMailSignature = false

exports('QbMail', function(citizenid, mailData)
    -- **Called the way API.md used to document it.** One table, no citizen id: nothing was
    -- sent and `false` came back with no reason. A citizen id is a string, never a table, so
    -- this cannot fire on a correct call - and it sits above the `active()` gate so the
    -- message appears even on a server with qb-phone compatibility switched off.
    if type(citizenid) == 'table' and mailData == nil then
        if not warnedQbMailSignature then
            warnedQbMailSignature = true
            print('^3[v-phone]^7 QbMail(citizenid, mailData) takes TWO arguments. It was '
                  .. 'called with one table, so nothing was sent. See API.md.')
        end
        return false, 'nocitizenid'
    end
    if not active() then return false end
    return QbPhone.Mail(citizenid, mailData)
end)

-- ── Client round trips ────────────────────────────────────────
-- A qb-phone client event arrives at one player and wants a phone notification. The client
-- cannot raise one honestly by itself: whether a banner is shown depends on whether that
-- player is carrying a handset, and only the server knows. So the client asks, and the
-- server answers with the normal Notify path, which applies that check.
--
-- Self-addressed only. The worst a modified client can do is notify itself.
RegisterNetEvent('v-phone:compat:qbBanner', function(app, title, body)
    if not active() then return end
    local src = source
    exports[RES]:Notify(src, tostring(app or 'phone'):sub(1, 24),
        tostring(title or ''):sub(1, 64), tostring(body or ''):sub(1, 240))
end)

-- A police dispatch. The job check lives here rather than on the client because the client
-- does not track its own job, and because an alert that a modified client could opt into
-- would leak every robbery in the city to anybody who asked.
RegisterNetEvent('v-phone:compat:qbAlert', function(alert)
    if not active() or type(alert) ~= 'table' then return end
    local src = source

    local p = Core and Core.GetPlayer and Core.GetPlayer(src)
    if not p then return end

    local name = (p.job and p.job.name) or ''
    local allowed = false
    for _, j in ipairs((Config.Compat and Config.Compat.policeJobs) or {}) do
        if name == j then allowed = true break end
    end
    if not allowed then return end

    exports[RES]:Notify(src, 'mdt', tostring(alert.title or 'Dispatch'):sub(1, 64),
        tostring(alert.description or ''):sub(1, 240))

    local c = alert.coords
    if type(c) == 'table' and tonumber(c.x) and tonumber(c.y) then
        TriggerClientEvent('v-phone:compat:qbWaypoint', src, tonumber(c.x), tonumber(c.y))
    end
end)

-- qb-phone's "give contact details" handshake: the caller picked the nearest player, and the
-- server writes each into the other's contacts. Distance is re-checked here, because the
-- target came from a client.
RegisterNetEvent('v-phone:compat:qbGiveContact', function(targetSrc)
    if not active() then return end
    local src = source
    targetSrc = tonumber(targetSrc)
    if not targetSrc or targetSrc == src then return end

    -- Rate limited before anything touches the database. Without this, sweeping every server
    -- id in a loop costs four awaited queries per hit and hands back a phone number each time.
    local now = GetGameTimer()
    if ContactCooldown[src] and now < ContactCooldown[src] then return end
    ContactCooldown[src] = now + 3000

    local a = Core and Core.GetPlayer and Core.GetPlayer(src)
    local b = Core and Core.GetPlayer and Core.GetPlayer(targetSrc)
    if not a or not b then return end

    -- Both peds have to actually exist. Server side GetPlayerPed is 0 for a character who has
    -- logged in but not spawned, and GetEntityCoords(0) is vector3(0,0,0) - so two pedless
    -- players measure as standing on top of each other, and a client that stalls its own spawn
    -- could harvest numbers from everyone else who is still loading.
    local pa, pb = GetPlayerPed(src), GetPlayerPed(targetSrc)
    if not pa or pa == 0 or not pb or pb == 0 then return end

    -- 3.5, not 5.0: the honest client picker caps at 3.0, so anything looser only ever helps
    -- a modified one. The half metre absorbs movement between the pick and this check.
    if #(GetEntityCoords(pa) - GetEntityCoords(pb)) > 3.5 then return end

    -- Numbers come from Bridge.Numbers, not from charinfo.phone. On a server with
    -- Config.Compat.numbers = 'phone' the framework's own field is stale, and reading it
    -- would write a contact nobody can call. `name` is already flattened by wrap().
    local numA = Bridge.Numbers.Get(a.citizenid)
    local numB = Bridge.Numbers.Get(b.citizenid)
    if not numA or not numB then return end

    exports[RES]:AddContact(a.citizenid, b.name, numB)
    exports[RES]:AddContact(b.citizenid, a.name, numA)
end)

AddEventHandler('playerDropped', function()
    ContactCooldown[source] = nil
end)
