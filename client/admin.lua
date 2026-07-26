-- v-phone | client/admin.lua
--
-- **The staff menu.**
--
-- `Config.Admin.qbAdminMenu` promised "phone actions in the qb-core admin menu" and delivered
-- two lines of console advice, which on a server with boot logging off - the default - is
-- nothing at all. This is the menu it should have been.
--
-- **Why it is not literally inside qb-adminmenu.** That resource builds its menu from local
-- variables in its own client file and hands them to MenuV; there is no event, export or hook
-- for a third party to add a button. Nothing outside that file can reach `menu1`. So the phone
-- brings its own menu, opened by `/phoneadmin` with no arguments - and any admin menu, qb's
-- included, can point a button at it in one line:
--
--     TriggerServerEvent('v-phone:admin:menu')
--
-- Everything the menu does goes back through `/phoneadmin`, which is ACE-gated on the server
-- and logs every refusal. The menu is a front end, not a second set of permissions: a client
-- that fired these events by hand would be refused exactly as a client typing the command is.

local ADMIN = Config.Admin or {}

-- qb-menu can only fire an EVENT, never a closure, so the rows on screen are held here and
-- one event dispatches on the index. Rebuilt every time a menu is drawn, so an index left
-- over from a previous menu cannot fire anything.
local MenuActions = {}

--- Which menu system is running, if any. In preference order: ox_lib's is the nicest, qb-menu
--- is on every qb server, MenuV is what qb-adminmenu itself uses.
local function menuKind()
    if GetResourceState('ox_lib') == 'started' then return 'ox' end
    if GetResourceState('qb-menu') == 'started' then return 'qb' end
    return nil
end

--- Ask for one line of text. Returns nil when the officer cancels.
---
--- Both dialogs block, which is why every caller runs inside a thread of its own.
local function askText(title, label, kind)
    if GetResourceState('ox_lib') == 'started' then
        local ok, answer = pcall(function()
            return exports.ox_lib:inputDialog(title, { { type = kind == 'number' and 'number' or 'input',
                                                         label = label, required = true } })
        end)
        if not ok or type(answer) ~= 'table' then return nil end
        local value = answer[1]
        return value ~= nil and tostring(value) or nil
    end

    if GetResourceState('qb-input') == 'started' then
        local ok, answer = pcall(function()
            return exports['qb-input']:ShowInput({
                header = title,
                submitText = L('ph.admin_submit'),
                inputs = { { text = label, name = 'v', type = kind == 'number' and 'number' or 'text',
                             isRequired = true } },
            })
        end)
        if not ok or type(answer) ~= 'table' then return nil end
        return answer.v ~= nil and tostring(answer.v) or nil
    end

    -- No input dialog on this server. Say so rather than opening a menu whose buttons do
    -- nothing: the command takes the same arguments and always works.
    V.Notify(L('ph.admin_noinput'), 'error')
    return nil
end

--- Run a `/phoneadmin` subcommand.
---
--- It goes to the same handler the typed command reaches, so there is one implementation, one
--- permission check and one set of replies for both front ends. The event carries no authority
--- of its own: the ace is checked on the handler's first line, exactly as it is for the command.
local function run(...)
    local args = {}
    for _, a in ipairs({ ... }) do args[#args + 1] = tostring(a) end
    TriggerServerEvent('v-phone:admin:run', args)
end

-- ══════════════════════════════════════════════════════════════
-- Drawing it
-- ══════════════════════════════════════════════════════════════
-- Two levels: who, then what. `target` is whatever `/phoneadmin` accepts - a server id, a
-- citizen id or a phone number - so the menu never has to resolve anybody itself.

local function actionOn(key)
    return (ADMIN.actions and ADMIN.actions[key]) ~= false
end

local openTargetMenu   -- forward declaration: the two menus open each other
local openActionMenu

--- The nearest player, for the common case of standing in front of somebody.
local function nearestPlayer()
    local me = PlayerPedId()
    local from = GetEntityCoords(me)
    local best, bestDistance = nil, 12.0
    for _, id in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(id)
        if ped ~= me and ped ~= 0 then
            local d = #(from - GetEntityCoords(ped))
            if d < bestDistance then best, bestDistance = GetPlayerServerId(id), d end
        end
    end
    return best
end

--- One menu, drawn through whichever system is present.
---
--- `rows` are `{ title, subtitle, action }`; the action is a plain Lua function, so nothing
--- here depends on a menu library's own event plumbing.
local function show(title, rows)
    local kind = menuKind()

    if kind == 'ox' then
        local options = {}
        for i, row in ipairs(rows) do
            options[i] = { title = row.title, description = row.subtitle, onSelect = row.action }
        end
        pcall(function()
            exports.ox_lib:registerContext({ id = 'vphone_admin', title = title, options = options })
            exports.ox_lib:showContext('vphone_admin')
        end)
        return
    end

    if kind == 'qb' then
        MenuActions = {}
        local data = { { isMenuHeader = true, header = title } }
        for i, row in ipairs(rows) do
            MenuActions[i] = row.action
            data[#data + 1] = {
                header = row.title,
                txt = row.subtitle or '',
                params = { event = 'v-phone:admin:pick', args = { index = i } },
            }
        end
        TriggerEvent('qb-menu:client:openMenu', data)
        return
    end

    -- No menu system at all. The command is the menu.
    V.Notify(L('ph.admin_nomenu'), 'error')
end

RegisterNetEvent('v-phone:admin:pick', function(data)
    local fn = MenuActions and MenuActions[tonumber(data and data.index)]
    if type(fn) == 'function' then fn() end
end)

openActionMenu = function(target)
    local rows = {}
    local function add(on, title, subtitle, action)
        if on then rows[#rows + 1] = { title = title, subtitle = subtitle, action = action } end
    end

    add(actionOn('readInfo'), L('ph.admin_info'), L('ph.admin_info_hint'),
        function() run('info', target) end)

    add(actionOn('openRemote'), L('ph.admin_open'), L('ph.admin_open_hint'),
        function() run('open', target) end)

    add(actionOn('setBattery'), L('ph.admin_battery'), L('ph.admin_battery_hint'), function()
        CreateThread(function()
            local level = askText(L('ph.admin_battery'), L('ph.admin_battery_field'), 'number')
            if level then run('battery', target, level) end
        end)
    end)

    add(actionOn('setNumber'), L('ph.admin_number'), L('ph.admin_number_hint'), function()
        CreateThread(function()
            local number = askText(L('ph.admin_number'), L('ph.number'))
            if number then run('number', target, number) end
        end)
    end)

    add(actionOn('sendMessage'), L('ph.admin_message'), L('ph.admin_message_hint'), function()
        CreateThread(function()
            local from = askText(L('ph.admin_message'), L('ph.admin_message_from'))
            if not from then return end
            local text = askText(L('ph.admin_message'), L('ph.write'))
            if text then run('message', target, from, text) end
        end)
    end)

    add(actionOn('notify'), L('ph.admin_notify'), L('ph.admin_notify_hint'), function()
        CreateThread(function()
            local text = askText(L('ph.admin_notify'), L('ph.write'))
            if text then run('notify', target, text) end
        end)
    end)

    add(actionOn('apps'), L('ph.admin_app'), L('ph.admin_app_hint'), function()
        CreateThread(function()
            local app = askText(L('ph.admin_app'), L('ph.admin_app_field'))
            if not app then return end
            -- `app [target] give|take [appid]`: the verb is not optional, so it is asked for
            -- rather than assumed. Guessing "give" would make the menu unable to take one away.
            show(L('ph.admin_app'), {
                { title = L('ph.admin_app_give'), action = function() run('app', target, 'give', app) end },
                { title = L('ph.admin_app_take'), action = function() run('app', target, 'take', app) end },
                { title = L('ph.back'), action = function() openActionMenu(target) end },
            })
        end)
    end)

    add(actionOn('brick'), L('ph.admin_brick'), L('ph.admin_brick_hint'),
        function() run('brick', target) end)
    add(actionOn('brick'), L('ph.admin_unbrick'), L('ph.admin_unbrick_hint'),
        function() run('unbrick', target) end)

    -- Wipe asks again. It deletes a character's phone, and a menu row next to eight harmless
    -- ones is exactly where a mis-tap happens.
    add(actionOn('wipe'), L('ph.admin_wipe'), L('ph.admin_wipe_hint'), function()
        show(L('ph.admin_wipe_confirm'), {
            { title = L('ph.admin_wipe_yes'), subtitle = L('ph.admin_wipe_yes_hint'),
              action = function() run('wipe', target, 'confirm') end },
            { title = L('ph.cancel'), action = function() openActionMenu(target) end },
        })
    end)

    rows[#rows + 1] = { title = L('ph.back'), action = openTargetMenu }
    show(L('ph.admin_on_target'):format(tostring(target)), rows)
end

openTargetMenu = function()
    local rows = {}
    local near = nearestPlayer()
    if near then
        rows[#rows + 1] = {
            title = L('ph.admin_nearest'),
            subtitle = L('ph.admin_nearest_hint'):format(tostring(near)),
            action = function() openActionMenu(near) end,
        }
    end
    rows[#rows + 1] = {
        title = L('ph.admin_by_id'),
        subtitle = L('ph.admin_by_id_hint'),
        action = function()
            CreateThread(function()
                local who = askText(L('ph.admin_by_id'), L('ph.admin_by_id_field'))
                if who then openActionMenu(who) end
            end)
        end,
    }

    -- Server-wide, so they hang off the first menu rather than off a player.
    if actionOn('outage') then
        rows[#rows + 1] = {
            title = L('ph.admin_outage'),
            subtitle = L('ph.admin_outage_hint'),
            action = function()
                CreateThread(function()
                    local minutes = askText(L('ph.admin_outage'), L('ph.admin_outage_field'), 'number')
                    -- `outage [bars 0-4] (minutes)`. Zero bars is a blackout, which is what a
                    -- menu row called "network outage" has to mean.
                    if minutes then run('outage', 0, minutes) end
                end)
            end,
        }
        rows[#rows + 1] = {
            title = L('ph.admin_outage_clear'),
            subtitle = L('ph.admin_outage_clear_hint'),
            action = function() run('outage', 'clear', 'all') end,
        }
    end

    show(L('ph.admin_menu'), rows)
end

--- The server says this player is staff. It has already checked the ace.
RegisterNetEvent('v-phone:admin:openMenu', function()
    openTargetMenu()
end)
