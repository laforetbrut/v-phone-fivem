-- v-phone | client/police.lua
--
-- **The forensics terminal, on the ground.**
--
-- An officer walks to a point and interacts. If ox_target or qb-target is running, it is
-- a target on a small zone; otherwise it is a marker and a key press. Either way the
-- terminal NUI opens, and everything it asks for is re-authorised on the server: this
-- file only opens the door, it grants nothing.

local POLICE = Config.Police or {}
local terminalOpen = false

-- ══════════════════════════════════════════════════════════════
-- Opening the terminal
-- ══════════════════════════════════════════════════════════════
local function openTerminal()
    if terminalOpen then return end
    terminalOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'forensic:open' })
end

-- The NUI closes itself; this hears about it to release focus.
RegisterNUICallback('forensicClose', function(_, cb)
    terminalOpen = false
    SetNuiFocus(false, false)
    cb('ok')
end)

-- ══════════════════════════════════════════════════════════════
-- NUI -> server relays
-- ══════════════════════════════════════════════════════════════
-- Each of these forwards to a server callback that checks the officer's job and session
-- again. The page cannot reach anything a normal player uses: these names exist only
-- here, and only map to the police callbacks.
RegisterNUICallback('forensicStart', function(data, cb)
    V.Request('v-phone:police:start', function(res) cb(res or { error = 'x' }) end, data)
end)

local READS = { messages = true, contacts = true, calls = true, social = true, cipher = true }
RegisterNUICallback('forensicRead', function(data, cb)
    local what = tostring((data and data.what) or '')
    if not READS[what] then cb({ error = 'x' }) return end
    V.Request('v-phone:police:' .. what, function(res) cb(res or { error = 'x' }) end, {})
end)

RegisterNUICallback('forensicCrack', function(data, cb)
    V.Request('v-phone:police:crack', function(res) cb(res or { error = 'x' }) end, data)
end)

-- ══════════════════════════════════════════════════════════════
-- The points on the map
-- ══════════════════════════════════════════════════════════════
CreateThread(function()
    if not POLICE.enabled then return end
    local points = POLICE.points or {}
    if #points == 0 then return end

    -- Prefer a target script; both expose the same idea under different names.
    local targetRes = nil
    for _, res in ipairs({ 'ox_target', 'qb-target', 'qtarget' }) do
        if GetResourceState(res) == 'started' then targetRes = res break end
    end

    if targetRes == 'ox_target' then
        for i, pt in ipairs(points) do
            exports.ox_target:addBoxZone({
                coords = vec3(pt.x, pt.y, pt.z),
                size = vec3(1.5, 1.5, 2.0),
                rotation = 0,
                debug = false,
                options = {
                    { name = 'vphone_forensic_' .. i, icon = 'fas fa-fingerprint',
                      label = pt.label or 'Forensic terminal', onSelect = openTerminal },
                },
            })
        end
        return
    end

    if targetRes == 'qb-target' or targetRes == 'qtarget' then
        for i, pt in ipairs(points) do
            exports[targetRes]:AddBoxZone('vphone_forensic_' .. i,
                vec3(pt.x, pt.y, pt.z), 1.5, 1.5,
                { name = 'vphone_forensic_' .. i, heading = 0, minZ = pt.z - 1.0, maxZ = pt.z + 1.5 },
                { options = { { label = pt.label or 'Forensic terminal', icon = 'fas fa-fingerprint',
                                action = openTerminal } }, distance = 1.8 })
        end
        return
    end

    -- No target script: a marker you walk into and open with E.
    CreateThread(function()
        while true do
            local sleep = 1000
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            for _, pt in ipairs(points) do
                local d = #(coords - vec3(pt.x, pt.y, pt.z))
                if d < 12.0 then
                    sleep = 0
                    DrawMarker(2, pt.x, pt.y, pt.z + 0.9, 0, 0, 0, 0, 180.0, 0,
                        0.22, 0.22, 0.14, 60, 130, 200, 160, false, true, 2, nil, nil, false)
                    if d < (pt.radius or 1.5) then
                        SetTextComponentFormat('STRING')
                        AddTextComponentString('[E] ' .. (pt.label or 'Forensic terminal'))
                        DisplayHelpTextFromStringLabel(0, 0, 1, -1)
                        if IsControlJustReleased(0, 38) then openTerminal() end   -- E
                    end
                end
            end
            Wait(sleep)
        end
    end)
end)
