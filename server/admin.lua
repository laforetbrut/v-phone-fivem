-- v-phone | server/admin.lua
--
-- **Staff actions on a player's phone.**
--
-- Everything here is a thin wrapper over the exports in api.lua, gated by one ACE
-- permission. A server that runs its own admin menu ignores all of this and calls the
-- exports directly; a server that wants something out of the box gets `/phoneadmin` and,
-- on qb-core, entries in the admin menu.
--
-- The permission is `Config.Admin.ace` (default `vphone.admin`). Grant it in server.cfg:
--
--     add_ace group.admin vphone.admin allow
--
-- qb-core's own admin group and `command` aces are accepted too, so existing staff work
-- without a second grant on most servers.

local ADMIN = Config.Admin or {}

--- May this source run an admin action? The console (src 0) always may.
local function allowed(src)
    if src == 0 then return true end
    if IsPlayerAceAllowed(src, ADMIN.ace or 'vphone.admin') then return true end
    -- qb-core staff: its menu grants `qbadmin.menu`, and god/admin groups carry `command`.
    if IsPlayerAceAllowed(src, 'qbadmin.menu') then return true end
    if IsPlayerAceAllowed(src, 'command') then return true end
    return false
end

local function actionOn(key)
    return (ADMIN.actions and ADMIN.actions[key]) ~= false
end

--- Resolve "1", a citizen id, or a phone number to a citizen id. Staff type whichever
--- they have to hand.
local function resolveCitizen(token)
    token = tostring(token or '')
    if token == '' then return nil end

    -- A server id.
    local asSrc = tonumber(token)
    if asSrc and Core.GetPlayer(asSrc) then
        return Core.GetPlayer(asSrc).citizenid
    end
    -- A phone number.
    local byNumber = exports[GetCurrentResourceName()]:CitizenOfNumber(token)
    if byNumber then return byNumber end
    -- Assume it is already a citizen id.
    return token
end

-- ══════════════════════════════════════════════════════════════
-- The command
-- ══════════════════════════════════════════════════════════════
if ADMIN.commands ~= false then
    local self = exports[GetCurrentResourceName()]

    local function reply(src, msg)
        if src == 0 then print('[v-phone] ' .. msg)
        else TriggerClientEvent('chat:addMessage', src, { args = { 'iFruit admin', msg } }) end
    end

    RegisterCommand('phoneadmin', function(src, args)
        if not allowed(src) then reply(src, 'You do not have permission.') return end
        local sub = (args[1] or ''):lower()

        if sub == 'info' and actionOn('readInfo') then
            local cid = resolveCitizen(args[2])
            local info = cid and self:AdminReadPhone(cid)
            if not info then reply(src, 'No such character.') return end
            reply(src, ('%s | number %s | battery %s | unread %d | online %s')
                :format(info.name or cid, info.number or '-', tostring(info.battery or '-'),
                        info.unread or 0, tostring(info.online)))

        elseif sub == 'open' and actionOn('openRemote') then
            local target = tonumber(args[2])
            local ok = target and self:OpenPhoneFor(target)
            reply(src, ok and 'Opened.' or 'That player is not online.')

        elseif sub == 'battery' and actionOn('setBattery') then
            local target = tonumber(args[2])
            local pct = tonumber(args[3])
            if not target or not pct then reply(src, 'Usage: /phoneadmin battery [id] [0-100]') return end
            self:SetBattery(target, pct)
            reply(src, ('Battery set to %d%%.'):format(math.floor(pct)))

        elseif sub == 'number' and actionOn('setNumber') then
            local cid = resolveCitizen(args[2])
            local number = args[3]
            if not cid or not number then reply(src, 'Usage: /phoneadmin number [id|cid] [number]') return end
            local ok, err = self:SetNumber(cid, number)
            reply(src, ok and ('Number set to ' .. number) or ('Failed: ' .. tostring(err)))

        elseif sub == 'message' and actionOn('sendMessage') then
            local cid = resolveCitizen(args[2])
            local body = table.concat(args, ' ', 3)
            if not cid or body == '' then reply(src, 'Usage: /phoneadmin message [id|cid] [text]') return end
            self:SendServiceMessage(cid, 'Staff', body)
            reply(src, 'Sent.')

        elseif sub == 'wipe' and actionOn('wipe') then
            local cid = resolveCitizen(args[2])
            if not cid then reply(src, 'Usage: /phoneadmin wipe [id|cid] confirm') return end
            if ADMIN.confirmWipe and (args[3] or '') ~= 'confirm' then
                reply(src, 'This deletes everything on that phone. Repeat with "confirm" to do it.')
                return
            end
            local ok, removed = self:WipePhone(cid)
            reply(src, ok and ('Wiped %d row(s).'):format(removed or 0) or 'Failed.')

        else
            reply(src, 'phoneadmin: info | open | battery | number | message | wipe')
        end
    end, false)

    -- The ACE the command checks, so `add_ace group.admin command.phoneadmin allow` also
    -- works for a server that gates by command name.
    print('[v-phone] admin command /phoneadmin registered (ace: ' .. (ADMIN.ace or 'vphone.admin') .. ')')
end

-- ══════════════════════════════════════════════════════════════
-- qb-core admin menu
-- ══════════════════════════════════════════════════════════════
-- qb-adminmenu lets other resources contribute options through an event. When it is
-- running and enabled, the phone adds its actions so staff get them without a command.
-- ox and ESX have no equivalent menu to extend, so this simply does nothing there.
if ADMIN.qbAdminMenu ~= false then
    CreateThread(function()
        Wait(2000)
        if GetResourceState('qb-adminmenu') ~= 'started' then return end
        -- qb-adminmenu reads `qb-adminmenu:client:...` menus; the supported way for a
        -- third party is to register a header + buttons it exposes. Rather than depend on
        -- an internal shape that changes between builds, the phone registers a single
        -- command the menu can point a button at, and prints how to add it.
        print('[v-phone] qb-adminmenu detected. Add a button that runs: phoneadmin info [id]')
        print('[v-phone] full staff actions: /phoneadmin (info|open|battery|number|message|wipe)')
    end)
end
