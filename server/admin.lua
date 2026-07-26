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
---
--- **The bare `command` ace is no longer accepted by default, and that is a deliberate
--- narrowing.** `IsPlayerAceAllowed(src, 'command')` is true for anybody the server has
--- granted ANY command at all - on a lot of configurations that includes whole groups of
--- trusted players, moderators and even donors, none of whom were meant to be able to wipe
--- a character's phone or cut the network. It was a convenience that quietly widened the
--- door. `Config.Admin.aceCommandFallback` puts it back for a server that genuinely relied
--- on it, off unless asked for.
---
--- What remains is the phone's own ace and qb-core's admin menu grant, both of which mean
--- "this person is staff" rather than "this person may run some command somewhere".
local function allowed(src)
    if src == 0 then return true end
    if IsPlayerAceAllowed(src, ADMIN.ace or 'vphone.admin') then return true end
    -- qb-core staff: its admin menu is granted to staff and nobody else.
    if IsPlayerAceAllowed(src, 'qbadmin.menu') then return true end
    if ADMIN.aceCommandFallback == true and IsPlayerAceAllowed(src, 'command') then return true end
    return false
end

--- Every refusal is logged with who tried it.
---
--- A staff command that silently says "no" tells an operator nothing about somebody
--- probing for one, and these commands can end a heist or delete a character's phone.
local function denied(src, sub)
    if src ~= 0 then
        print(('[v-phone] admin DENIED: %s (id %d, %s) tried /phoneadmin %s')
            :format(GetPlayerName(src) or '?', src,
                    GetPlayerIdentifierByType and (GetPlayerIdentifierByType(src, 'license') or '?') or '?',
                    tostring(sub ~= '' and sub or '(no subcommand)')))
    end
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

    -- Forward declared: `runAdmin` calls it when the menu opens, and it is defined below with
    -- the suggestion table it reads. A `local` is only in scope after its own line.
    local suggestTo

    local function reply(src, msg)
        if src == 0 then print('[v-phone] ' .. msg)
        else TriggerClientEvent('chat:addMessage', src, { args = { 'iFruit admin', msg } }) end
    end

    -- Named, rather than anonymous inside `RegisterCommand`.
    --
    -- The staff MENU is a second front end to exactly this: same handler, same permission
    -- check on its first line, same replies. A menu with its own copy of twenty-four actions
    -- would be twenty-four places for the two to drift apart.
    local function runAdmin(src, args)
        local sub = (args[1] or ''):lower()
        if not allowed(src) then
            denied(src, sub)
            reply(src, 'You do not have permission.')
            return
        end

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

        -- `args[3]` is part of the condition, not just checked inside it: without a number to
        -- set, `number [id]` has to fall through to the READ branch further down. An elseif
        -- chain is ordered, so a branch that claims the subcommand unconditionally makes every
        -- later branch for it dead code.
        elseif sub == 'number' and args[3] ~= nil and actionOn('setNumber') then
            local cid = resolveCitizen(args[2])
            local number = args[3]
            if not cid then reply(src, 'Usage: /phoneadmin number [id|cid] [number]') return end
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

        -- ── Holding somebody else's phone ───────────────────────────────
        --
        -- `open` puts a player's phone on THEIR screen; this puts it on YOURS, as them. See
        -- server/adminview.lua for why it is one wrapped function rather than sixty patches.
        elseif sub == 'view' and actionOn('view') then
            if src == 0 then reply(src, 'The console has no phone to hold it on.') return end
            local target = tonumber(args[2])
            if not target then
                -- A citizen id or a number resolves too, but only to somebody ONLINE: the
                -- session hands back a live player object, and there is none for a character
                -- who is not connected.
                local cid = resolveCitizen(args[2])
                local p = cid and Core.GetPlayerByCitizenId(cid)
                target = p and p.source
            end
            if not target then
                reply(src, 'Usage: /phoneadmin view [id|cid|number]   (they must be online)')
                return
            end
            local ok, result = AdminViewOpen(src, target)
            if not ok then
                reply(src, result == 'self' and 'That is your own phone.' or 'No such player online.')
                return
            end
            reply(src, ('Holding %s\'s phone. Anything you do is done as them. /phoneadmin unview to stop.')
                :format(tostring(result)))

        elseif sub == 'unview' and actionOn('view') then
            reply(src, AdminViewClose(src) and 'Back on your own phone.' or 'You were not holding one.')

        elseif sub == 'verify' and actionOn('verify') then
            -- `/phoneadmin verify @handle [off] [snap]`
            --
            -- By handle rather than by character: a badge belongs to an account, and staff
            -- reading a report have the @handle in front of them, not a citizen id.
            local handle = args[2]
            if not handle then
                reply(src, 'Usage: /phoneadmin verify [@handle] (off) (snap)')
                return
            end
            local rest = table.concat(args, ' ', 3):lower()
            local on = not rest:find('off', 1, true)
            local app = rest:find('snap', 1, true) and 'snap' or 'bleeter'

            local ok, result = self:SetVerified(app, handle, on)
            if not ok then
                reply(src, result == 'nosuchhandle'
                    and ('No %s account called @%s.'):format(app, tostring(handle):gsub('^@', ''))
                    or 'Usage: /phoneadmin verify [@handle] (off) (snap)')
                return
            end
            reply(src, ('@%s is %s verified on %s.')
                :format(result, on and 'now' or 'no longer', app))

        elseif sub == 'verified' and actionOn('verify') then
            local app = ((args[2] or ''):lower() == 'snap') and 'snap' or 'bleeter'
            local list = self:VerifiedHandles(app)
            reply(src, #list == 0
                and ('Nobody is verified on %s.'):format(app)
                or ('Verified on %s: @%s'):format(app, table.concat(list, ', @')))

        -- ── Network outages ─────────────────────────────────────────────
        --
        -- `outage` on its own is a global one; `here` and `at` are areas. Bars rather than
        -- on/off, because "one bar" is a far more interesting outage than "no phone": calls
        -- drop, messages crawl, and players have to move to be heard.
        elseif sub == 'outage' and actionOn('outage') then
            local what = (args[2] or ''):lower()

            if what == 'clear' then
                local n = OutageClear(args[3])
                reply(src, n > 0 and ('Cleared %d outage(s).'):format(n) or 'No such outage.')

            elseif what == 'here' or what == 'at' then
                local x, y, z, radius, bars, minutes
                if what == 'here' then
                    if src == 0 then reply(src, 'The console is nowhere. Use: outage at [x] [y] [z] [radius] [bars] (minutes)') return end
                    local c = GetEntityCoords(GetPlayerPed(src))
                    x, y, z = c.x, c.y, c.z
                    radius, bars, minutes = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
                else
                    x, y, z = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
                    radius, bars, minutes = tonumber(args[6]), tonumber(args[7]), tonumber(args[8])
                end
                if not radius or not bars or not x then
                    reply(src, what == 'here'
                        and 'Usage: /phoneadmin outage here [radius] [bars 0-4] (minutes)'
                        or 'Usage: /phoneadmin outage at [x] [y] [z] [radius] [bars 0-4] (minutes)')
                    return
                end
                local id = OutageAdd(bars, minutes, ('by %s'):format(GetPlayerName(src) or 'console'),
                    { x = x, y = y, z = z, radius = radius })
                reply(src, ('Outage #%d: %d bar(s) within %.0fm%s.')
                    :format(id, math.floor(bars), radius,
                            (minutes and minutes > 0) and (' for ' .. math.floor(minutes) .. ' min') or ''))

            else
                local bars = tonumber(args[2])
                if not bars then
                    reply(src, 'Usage: /phoneadmin outage [bars 0-4] (minutes) | outage here [radius] [bars] (minutes) | outage clear [id|all]')
                    return
                end
                local minutes = tonumber(args[3])
                local id = OutageAdd(bars, minutes, ('by %s'):format(GetPlayerName(src) or 'console'), nil)
                reply(src, ('Outage #%d: the whole server is on %d bar(s)%s.')
                    :format(id, math.floor(math.max(0, math.min(4, bars))),
                            (minutes and minutes > 0) and (' for ' .. math.floor(minutes) .. ' min') or ''))
            end

        elseif sub == 'outages' and actionOn('outage') then
            local list = OutageList()
            if #list == 0 then reply(src, 'No outage in force.') return end
            for _, o in ipairs(list) do
                reply(src, ('#%d | %d bar(s) | %s | %s')
                    :format(o.id, o.bars,
                            o.global and 'whole server'
                                or ('%.0f, %.0f within %.0fm'):format(o.x, o.y, o.radius),
                            o.left and (math.floor(o.left / 60) .. ' min left') or 'until cleared'))
            end

        -- ── A handset out of service ────────────────────────────────────
        elseif sub == 'brick' and actionOn('brick') then
            local cid = resolveCitizen(args[2])
            if not cid then reply(src, 'Usage: /phoneadmin brick [id|cid|number] (minutes)') return end
            PhoneBrick(cid, tonumber(args[3]), ('by %s'):format(GetPlayerName(src) or 'console'))
            local mins = tonumber(args[3])
            reply(src, ('%s phone is out of service%s.'):format(cid,
                (mins and mins > 0) and (' for ' .. math.floor(mins) .. ' min') or ''))

        elseif sub == 'unbrick' and actionOn('brick') then
            local cid = resolveCitizen(args[2])
            local ok = cid and PhoneUnbrick(cid)
            reply(src, ok and 'Back in service.' or 'That phone was not out of service.')

        elseif sub == 'bricked' and actionOn('brick') then
            local list = BrickedList()
            reply(src, #list == 0 and 'No phone is out of service.'
                or ('Out of service: ' .. table.concat(list, ', ')))

        -- ── Apps on a character's phone ─────────────────────────────────
        elseif sub == 'app' and actionOn('apps') then
            local cid = resolveCitizen(args[2])
            local verb = (args[3] or ''):lower()
            local appId = args[4]
            if not cid or not appId or (verb ~= 'give' and verb ~= 'take') then
                reply(src, 'Usage: /phoneadmin app [id|cid] give|take [appid]')
                return
            end
            local ok, err = (verb == 'give') and self:InstallApp(cid, appId) or self:UninstallApp(cid, appId)
            reply(src, ok and ('%s %s %s.'):format(verb == 'give' and 'Installed' or 'Removed', appId,
                                                   verb == 'give' and 'for ' .. cid or 'from ' .. cid)
                or ('Failed: ' .. tostring(err)))

        -- ── A banner, which is not a text message ───────────────────────
        elseif sub == 'notify' and actionOn('notify') then
            local cid = resolveCitizen(args[2])
            local body = table.concat(args, ' ', 3)
            if not cid or body == '' then reply(src, 'Usage: /phoneadmin notify [id|cid] [text]') return end
            local ok = self:NotifyCitizen(cid, 'phone', 'iFruit', body)
            reply(src, ok and 'Shown.' or 'That character is not online.')

        -- ── Read a phone without touching it ────────────────────────────
        --
        -- Support work is mostly answering "what does their phone actually think", and every
        -- one of these is a READ. They are behind `readInfo` rather than their own switch,
        -- because refusing staff the ability to look while allowing them to wipe would be a
        -- strange place to draw a line.
        elseif sub == 'contacts' and actionOn('readInfo') then
            local cid = resolveCitizen(args[2])
            local list = cid and self:GetContacts(cid) or nil
            if not list then reply(src, 'No such character.') return end
            if #list == 0 then reply(src, 'No contacts.') return end
            for _, c in ipairs(list) do
                reply(src, ('%s  %s%s'):format(c.name or '?', c.number or '-',
                    c.favourite and '  *' or ''))
            end

        elseif sub == 'apps' and actionOn('readInfo') then
            local cid = resolveCitizen(args[2])
            if not cid then reply(src, 'Usage: /phoneadmin apps [id|cid]') return end
            local prefs = Bridge.KvGet(cid, 'phone') or {}
            local added = prefs.added or {}
            reply(src, #added == 0
                and 'Nothing installed beyond the defaults.'
                or ('Installed: ' .. table.concat(added, ', ')))

        elseif sub == 'number' and args[3] == nil and actionOn('readInfo') then
            -- `number [id]` with nothing to set reads it instead of complaining. Staff type
            -- this constantly and the two-argument form is the rarer one.
            local cid = resolveCitizen(args[2])
            local info = cid and self:AdminReadPhone(cid)
            reply(src, info and ('%s: %s'):format(info.name or cid, info.number or '-')
                or 'No such character.')

        -- ── A citywide alert ────────────────────────────────────────────
        --
        -- `/phoneadmin alert [kind] [text...]`. The kind is the banner word - EARTHQUAKE,
        -- TSUNAMI, EVACUATION - and the rest is the message.
        elseif sub == 'alert' and actionOn('emergency') then
            local kind = args[2]
            local body = table.concat(args, ' ', 3)
            if not kind or body == '' then
                reply(src, 'Usage: /phoneadmin alert [kind] [message...]   e.g. alert EARTHQUAKE Get outside now')
                return
            end
            local n = self:EmergencyAlert(kind, body)
            reply(src, ('Alert sent to %d phone(s).'):format(n))

        -- ── A new number, in the phone's own format ─────────────────────
        --
        -- Behind `setNumber`, because that is what it is: setting a number, with the phone
        -- choosing it instead of staff typing it.
        elseif sub == 'renumber' and actionOn('setNumber') then
            local who = args[2]
            if not who then
                reply(src, 'Usage: /phoneadmin renumber [id|cid|number|all] confirm')
                return
            end
            if (args[3] or '') ~= 'confirm' then
                reply(src, 'This gives them a NEW number. Anybody who saved the old one in '
                    .. 'their contacts keeps the old one. Repeat with "confirm" to do it.')
                return
            end

            if who:lower() == 'all' then
                reply(src, 'Renumbering every character. This runs in the background.')
                CreateThread(function()
                    local done, failed = self:RenumberAll()
                    reply(src, ('Renumbered %d character(s), %d failed.'):format(done, failed))
                end)
                return
            end

            local cid = resolveCitizen(who)
            local ok, fresh, was = self:Renumber(cid)
            reply(src, ok and ('%s: %s -> %s'):format(cid, tostring(was), fresh)
                or ('Failed: ' .. tostring(fresh)))

        -- ── The whole server at once ────────────────────────────────────
        elseif sub == 'announce' and actionOn('notify') then
            local body = table.concat(args, ' ', 2)
            if body == '' then reply(src, 'Usage: /phoneadmin announce [text]') return end
            self:NotifyAll('phone', 'iFruit', body)
            reply(src, 'Announced to everybody online.')

        elseif sub == 'who' and actionOn('readInfo') then
            -- Everybody with a phone open right now. The support question behind it is
            -- "is anybody actually looking at this", before changing something live.
            local open, total = {}, 0
            for _, raw in ipairs(GetPlayers()) do
                local id = tonumber(raw)
                total = total + 1
                if self:IsPhoneOpen(id) then
                    open[#open + 1] = ('%s (%d)'):format(GetPlayerName(id) or '?', id)
                end
            end
            reply(src, ('%d of %d online have their phone open%s'):format(#open, total,
                #open > 0 and (': ' .. table.concat(open, ', ')) or '.'))

        -- ── Battery, for everybody ──────────────────────────────────────
        elseif sub == 'batteryall' and actionOn('setBattery') then
            local pct = tonumber(args[2])
            if not pct then reply(src, 'Usage: /phoneadmin batteryall [0-100]') return end
            local n = 0
            for _, raw in ipairs(GetPlayers()) do
                self:SetBattery(tonumber(raw), pct)
                n = n + 1
            end
            reply(src, ('Battery set to %d%% on %d phone(s).'):format(math.floor(pct), n))

        elseif sub == '' or sub == 'menu' then
            -- No arguments opens the menu. `Config.Admin.qbAdminMenu` used to promise entries
            -- in qb-core's admin menu and print two lines of advice instead, which with boot
            -- logging off - the default - is nothing at all. See client/admin.lua for why the
            -- menu cannot literally live inside qb-adminmenu.
            TriggerClientEvent('v-phone:admin:openMenu', src)
            suggestTo(src)
        else
            reply(src, 'phoneadmin: info | who | number | renumber | contacts | apps | open | ' ..
                       'battery | batteryall | message | notify | announce | alert | app | ' ..
                       'outage | outages | brick | unbrick | bricked | verify | verified | wipe')
        end
    end

    RegisterCommand('phoneadmin', runAdmin, false)

    --- The menu's actions, arriving as an argument list instead of a typed line.
    ---
    --- Unauthenticated by design at this layer: `runAdmin` checks the ace on its first line and
    --- logs the refusal, so a client firing this event by hand is refused exactly as a client
    --- typing the command is. What IS done here is bounding the input - eight arguments of
    --- sixty-four characters, all strings - because a command handler is not the place to
    --- discover that somebody sent it a table.
    RegisterNetEvent('v-phone:admin:run', function(args)
        local src = source
        if type(args) ~= 'table' then return end
        local clean = {}
        for i = 1, 8 do
            local v = args[i]
            if v == nil then break end
            if type(v) ~= 'string' and type(v) ~= 'number' then return end
            clean[i] = tostring(v):sub(1, 64)
        end
        if not clean[1] then return end
        runAdmin(src, clean)
    end)

    --- Open the menu. For a button in any admin menu: one line, and this is the line.
    RegisterNetEvent('v-phone:admin:menu', function()
        local src = source
        if not allowed(src) then denied(src, 'menu') return end
        TriggerClientEvent('v-phone:admin:openMenu', src)
    end)

    -- ── What the chat box offers as you type ────────────────────────
    --
    -- `chat:addSuggestion` is what puts a command in the autocomplete list with its arguments
    -- named. Without it staff have to remember twenty-four subcommands and their order, which
    -- in practice means they use four and guess at the rest.
    --
    -- Registered SERVER-side and per player, on join, rather than broadcast to everybody:
    -- suggesting `/phoneadmin wipe` to a player who cannot run it is an invitation to try, and
    -- telling everyone which staff tools exist is telling everyone what to look for. Only
    -- somebody the ace allows is offered it at all.
    --
    -- One entry per subcommand rather than one for the command: the chat box matches on the
    -- whole string, so `/phoneadmin out` narrows to the outage lines, which is the entire
    -- point of having them listed.
    local SUGGESTIONS = {
        { 'info', 'What a phone thinks: number, battery, unread, online', { { 'id|cid|number', 'the target' } } },
        { 'who', 'Everybody with their phone open right now', {} },
        { 'number', 'Read a number, or set one', { { 'id|cid', 'the target' }, { 'number', 'omit to read it' } } },
        { 'contacts', "Read a character's contact book", { { 'id|cid', 'the target' } } },
        { 'apps', 'What is installed on a phone', { { 'id|cid', 'the target' } } },
        { 'open', "Open a player's phone on their screen", { { 'id', 'server id' } } },
        { 'battery', 'Set a battery level', { { 'id', 'server id' }, { '0-100', 'percent' } } },
        { 'batteryall', 'Set every phone online', { { '0-100', 'percent' } } },
        { 'renumber', "A new number in the phone's own format", { { 'id|cid|all', 'the target' }, { 'confirm', 'required' } } },
        { 'alert', 'A loud full-screen alert on every phone', { { 'kind', 'e.g. EARTHQUAKE' }, { 'message...', 'what is happening' } } },
        { 'message', 'Send a text message, from Staff', { { 'id|cid', 'the target' }, { 'text...', 'the message' } } },
        { 'notify', 'A banner on their phone (does not persist)', { { 'id|cid', 'the target' }, { 'text...', 'the message' } } },
        { 'announce', 'That banner, to every phone online', { { 'text...', 'the message' } } },
        { 'app', 'Install or remove an app', { { 'id|cid', 'the target' }, { 'give|take', 'which way' }, { 'appid', 'e.g. bleeter' } } },
        { 'outage', 'Cut the network: bars 0-4, whole server', { { 'bars', '0 = no signal' }, { 'minutes', 'omit for until cleared' } } },
        { 'outage here', 'Cut the network in a circle around you', { { 'radius', 'metres' }, { 'bars', '0-4' }, { 'minutes', 'optional' } } },
        { 'outage clear', 'Lift an outage', { { 'id|all', 'from /phoneadmin outages' } } },
        { 'outages', 'What outages are in force, and for how long', {} },
        { 'brick', 'Take one handset out of service', { { 'id|cid', 'the target' }, { 'minutes', 'omit for until unbricked' } } },
        { 'unbrick', 'Put it back in service', { { 'id|cid', 'the target' } } },
        { 'bricked', 'Which phones are out of service', {} },
        { 'view', "Hold their phone on YOUR screen, as them", { { 'id|cid|number', 'the target, online' } } },
        { 'unview', 'Give it back and return to your own', {} },
        { 'verify', 'Grant or revoke the verified badge', { { '@handle', 'the account' }, { 'off', 'to revoke' }, { 'snap', 'Snapmatic instead of Bleeter' } } },
        { 'verified', 'Who holds a badge', { { 'snap', 'Snapmatic instead of Bleeter' } } },
        { 'wipe', 'DELETE everything on a phone. Irreversible', { { 'id|cid', 'the target' }, { 'confirm', 'required' } } },
    }

    suggestTo = function(src)
        if not allowed(src) then return end
        for _, entry in ipairs(SUGGESTIONS) do
            local params = {}
            for _, pair in ipairs(entry[3]) do
                params[#params + 1] = { name = pair[1], help = pair[2] }
            end
            TriggerClientEvent('chat:addSuggestion', src,
                '/phoneadmin ' .. entry[1], entry[2], params)
        end
    end

    -- On join, and again a moment later: chat is not always up when a player first loads, and
    -- a suggestion sent to a chat resource that has not started yet is simply lost.
    AddEventHandler('playerJoining', function()
        local src = source
        CreateThread(function()
            Wait(4000)
            if GetPlayerName(src) then suggestTo(src) end
        end)
    end)

    -- And for anybody already connected when the resource restarts, which is every refresh
    -- during development and the case that would otherwise never be tested.
    CreateThread(function()
        Wait(2000)
        for _, raw in ipairs(GetPlayers()) do suggestTo(tonumber(raw)) end
    end)

    -- A staff member whose ace was granted after they joined can ask for the list.
    RegisterCommand('phoneadminhelp', function(src)
        if not allowed(src) then denied(src, 'help') return end
        suggestTo(src)
        reply(src, ('%d subcommands are now in your chat suggestions. Type /phoneadmin and '
            .. 'the list narrows as you go.'):format(#SUGGESTIONS))
    end, false)

    -- The ACE the command checks, so `add_ace group.admin command.phoneadmin allow` also
    -- works for a server that gates by command name.
    V.Info('[v-phone] admin command /phoneadmin registered (ace: ' .. (ADMIN.ace or 'vphone.admin') .. ')')
end

-- ══════════════════════════════════════════════════════════════
-- Other admin menus
-- ══════════════════════════════════════════════════════════════
-- **qb-adminmenu cannot be extended by a third party.** It builds its menu from local
-- variables in its own client file and hands them to MenuV; there is no event, export or hook
-- that reaches those locals. The old code here knew that and settled for printing advice -
-- which, with boot logging off by default, printed nothing to anybody.
--
-- So the phone brings its own menu (client/admin.lua), opened by `/phoneadmin` with no
-- arguments. Any admin menu can put a button in front of it with one line:
--
--     TriggerServerEvent('v-phone:admin:menu')
--
-- Said once at boot, for an operator who wants that button.
if ADMIN.qbAdminMenu ~= false then
    CreateThread(function()
        Wait(2000)
        if GetResourceState('qb-adminmenu') ~= 'started' then return end
        V.Info('[v-phone] staff menu: /phoneadmin with no arguments. To add it to qb-adminmenu, '
            .. "point a button at TriggerServerEvent('v-phone:admin:menu')")
    end)
end
