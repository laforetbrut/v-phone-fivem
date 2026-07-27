-- v-phone | server/adminview.lua
--
-- **Holding somebody else's phone.**
--
-- A staff member opens a target's handset on their OWN screen and uses it as that character:
-- their messages, their contacts, their bank, their apps. Not a read-only inspector - the
-- police forensics terminal is the read-only one, and it is deliberately narrow. This is the
-- support tool: see what they see, and fix it from there.
--
-- **How it works, in one sentence:** every callback in this resource asks `Core.GetPlayer(src)`
-- for who is calling, so a session makes that one function answer with the TARGET's player for
-- the staff member's source, and the entire phone follows without a single app knowing.
--
-- That is also why this file is small and why it sits on its own. One choke point is the only
-- honest way to do this: sixty call sites patched by hand would have left the ones nobody
-- thought of - a bank transfer, an AirDrop - still acting as the admin, which is worse than
-- not having the feature.
--
-- **What it deliberately does NOT do.** It does not follow the target's position: coordinates
-- still come from the staff member's own ped, so an AirDrop or a charging point works where the
-- staff member is standing, not where the target is. Making position follow too would mean a
-- second choke point and a much larger blast radius, and none of the support cases need it.
--
-- Paid charging is left on the staff member's own purse for exactly that reason, and it is the
-- one money path that is: the offer is about a charger THEY are standing at, so it would be
-- incoherent for somebody else to pay for it. Everything addressed to "this phone's account" -
-- the bank, Bank Pro, a store purchase, a mail domain - follows the held character.
--
-- Every session is logged with both names, opens only behind the ace, expires on its own, and
-- ends when either player drops. A tool that acts as somebody else has to leave a trail.

local ADMIN = Config.Admin or {}

--- [staff source] = { cid, name, until, opened }
local Viewing = {}

local function viewSeconds()
    return math.max(30, math.floor(tonumber(ADMIN.viewSeconds) or 600))
end

--- The citizen id a staff member is currently holding, or nil.
function AdminViewTarget(src)
    local v = Viewing[tonumber(src) or 0]
    if not v then return nil end
    if os.time() >= v.expires then
        Viewing[tonumber(src)] = nil
        return nil
    end
    return v.cid, v.name
end

--- Close a session, and tell the phone so it stops showing the banner.
function AdminViewClose(src)
    src = tonumber(src)
    if not src or not Viewing[src] then return false end
    local v = Viewing[src]
    Viewing[src] = nil
    V.Log(('admin view: %s released %s (%s)')
        :format(GetPlayerName(src) or '?', v.name or '?', v.cid))
    TriggerClientEvent('v-phone:client:adminView', src, false)
    return true
end

--- Open one. The target must be ONLINE.
---
--- An offline character would mean building a player object out of the database - a second way
--- of constructing the thing the whole bridge exists to construct, and one that would drift
--- from the real one. Staff who need an offline character have `/phoneadmin info`, `contacts`,
--- `apps` and `wipe`, all of which take a citizen id.
function AdminViewOpen(src, targetSrc)
    src, targetSrc = tonumber(src), tonumber(targetSrc)
    if not src or not targetSrc then return false, 'nosuchplayer' end
    if src == targetSrc then return false, 'self' end

    local target = Core.GetPlayerReal and Core.GetPlayerReal(targetSrc) or Core.GetPlayer(targetSrc)
    if not target then return false, 'nosuchplayer' end

    Viewing[src] = {
        cid = target.citizenid,
        name = target.name or tostring(targetSrc),
        expires = os.time() + viewSeconds(),
        opened = os.time(),
    }
    V.Log(('admin view: %s (id %d) opened the phone of %s (%s) for up to %d minutes')
        :format(GetPlayerName(src) or '?', src, target.name or '?', target.citizenid,
                math.floor(viewSeconds() / 60)))

    TriggerClientEvent('v-phone:client:adminView', src, {
        name = target.name or '',
        seconds = viewSeconds(),
    })
    -- Their own phone opens on their screen, holding the other character's.
    TriggerClientEvent('v-phone:client:open', src)
    return true, target.name
end

-- ══════════════════════════════════════════════════════════════
-- The choke point
-- ══════════════════════════════════════════════════════════════
-- `Core.GetPlayer` is what every callback in this resource asks who is calling. Wrapping it
-- here, once, is what makes a session work everywhere - and keeping the original under
-- `Core.GetPlayerReal` is what lets the few places that must know the REAL caller ask.
--
-- Loaded after bridge/server/framework.lua, which builds `Core`, and before server/main.lua,
-- which is the first file to use it.

Core.GetPlayerReal = Core.GetPlayer

Core.GetPlayer = function(src)
    local cid = AdminViewTarget(src)
    if cid then
        local held = Core.GetPlayerByCitizenId(cid)
        -- A target who dropped ends the session rather than silently handing back the staff
        -- member's own phone, which would be the worst possible failure: acting on your own
        -- account while believing you are on somebody else's.
        if held then return held end
        AdminViewClose(src)
    end
    return Core.GetPlayerReal(src)
end

--- **The source a MONEY call should act on.**
---
--- `Core.GetPlayer` covers everything the phone reads through a player object - messages,
--- contacts, apps, metadata - because those all start from the object. Money does not: the
--- framework bridges take a SOURCE, so `Bridge.Banking.Balances(src)` and
--- `Bridge.RemoveMoney(src, ...)` were still answering for the staff member. Opening the Bank
--- app inside a session showed the staff member their own balance, and a transfer would have
--- moved their own money while the screen said somebody else's name.
---
--- So the money calls that mean "the caller's own account" ask this instead of using `src`
--- directly. It is a second choke point, and it is deliberately NOT a wrapper around
--- `Bridge.AddMoney`: a wrapper would also redirect money being paid TO a staff member who
--- happens to have a session open - a Bank Pro payment from somebody else, say - because a
--- wrapper cannot tell "this source is the caller" from "this source is the recipient". The
--- call sites can, so they are where the question is asked.
---
--- Returns `src` unchanged when no session is open, which is every ordinary call.
function PhoneActingSource(src)
    src = tonumber(src)
    local cid = AdminViewTarget(src)
    if not cid then return src end
    local held = Core.GetPlayerByCitizenId(cid)
    if held and held.source then return tonumber(held.source) or src end
    -- Same rule as above: a target who is gone ends the session rather than quietly letting
    -- the staff member act on their own account.
    AdminViewClose(src)
    return src
end

-- ══════════════════════════════════════════════════════════════
-- Housekeeping
-- ══════════════════════════════════════════════════════════════

AddEventHandler('playerDropped', function()
    local src = source
    if Viewing[src] then AdminViewClose(src) end
    -- And any session held ON this player, by anybody.
    local cid = Core.GetPlayerReal and Core.GetPlayerReal(src)
    cid = cid and cid.citizenid
    if not cid then return end
    for staff, v in pairs(Viewing) do
        if v.cid == cid then AdminViewClose(staff) end
    end
end)

-- One sweep, rather than a timer per session.
CreateThread(function()
    while true do
        Wait(15000)
        local now = os.time()
        for staff, v in pairs(Viewing) do
            if now >= v.expires then AdminViewClose(staff) end
        end
    end
end)

--- For another resource's own admin menu.
exports('AdminViewOpen', function(src, targetSrc) return AdminViewOpen(src, targetSrc) end)
exports('AdminViewClose', function(src) return AdminViewClose(src) end)
exports('AdminViewTarget', function(src) return AdminViewTarget(src) end)
