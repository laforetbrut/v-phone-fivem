-- v-phone | client/verify.lua
--
-- **The verification desk, on the ground.**
--
-- A player walks to a point, interacts, and the phone raises the sheet that sells the blue
-- tick on Bleeter or Snapmatic. If ox_target or qb-target is running the desk is also a
-- target zone; either way the key press is live, because a third-party script must not be the
-- only route to a place the map has a blip for.
--
-- Nothing here decides anything. It opens the sheet and stops: the price, whether this player
-- is actually standing at a desk, and the payment are all read on the server from the ped's
-- real position - see the Verification section of server/social.lua. The ORANGE mark has no
-- route through this file at all; it is granted by staff and by nothing else.

local VERIFY = Config.SocialVerify or {}

local function num(v, d) return tonumber(v) or d or 0 end

local function enabled()
    return VERIFY.enabled ~= false and (Config.Social or {}).enabled ~= false
end

--- The desks, as plain coordinates. `normalisePlaces` in config.lua has already turned any
--- `coords = vector3(...)` into x/y/z, so there is one shape to read.
local function points()
    local out = {}
    local fallback = math.max(0.5, num(VERIFY.distance, 2.0))
    for i, pt in ipairs(VERIFY.points or {}) do
        if type(pt) == 'table' and pt.enabled ~= false and pt.x ~= nil and pt.y ~= nil then
            out[#out + 1] = {
                index = i,
                label = pt.label and tostring(pt.label) or nil,
                blip = pt.blip,
                x = num(pt.x, 0.0) + 0.0, y = num(pt.y, 0.0) + 0.0, z = num(pt.z, 0.0) + 0.0,
                radius = math.max(0.5, num(pt.radius, fallback)),
            }
        end
    end
    return out
end

--- What one desk is called. A config string is used as written; nil reads in the player's own
--- language. `L()` on free text hands it straight back, so both shapes go through one call.
local function labelOf(pt)
    local own = pt and pt.label
    if own and own ~= '' then return L(tostring(own)) end
    return L('ph.verify_desk')
end

-- ══════════════════════════════════════════════════════════════
-- Opening the desk
-- ══════════════════════════════════════════════════════════════
-- One screen, on the phone. The desk is a place rather than a menu of its own: the account
-- being verified lives on the phone, the money is spent from the phone, and a second full
-- screen NUI would be a second thing to keep in step with the first.
--
-- The phone opens itself if it is pocketed. `PhoneShowScreen` queues the message behind the
-- open sequence, so the sheet arrives after the page has been reset rather than before it.
local function openDesk()
    if not enabled() then return end
    if PhoneShowScreen then PhoneShowScreen({ action = 'verifyDesk' }) end
end

-- ══════════════════════════════════════════════════════════════
-- The desks on the map
-- ══════════════════════════════════════════════════════════════
CreateThread(function()
    if not enabled() then return end
    local list = points()
    if #list == 0 then return end

    -- ── The blips ─────────────────────────────────────────────
    -- Made once and left. A desk does not move, and there are a handful of them, so there is
    -- nothing here worth culling on distance the way the payphones are.
    local blipCfg = VERIFY.blip or {}
    if blipCfg.enabled ~= false then
        for _, pt in ipairs(list) do
            if pt.blip ~= false then
                local blip = AddBlipForCoord(pt.x, pt.y, pt.z)
                SetBlipSprite(blip, math.floor(num(blipCfg.sprite, 480)))
                SetBlipColour(blip, math.floor(num(blipCfg.colour, 5)))
                SetBlipScale(blip, num(blipCfg.scale, 0.75) + 0.0)
                SetBlipAsShortRange(blip, blipCfg.shortRange ~= false)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName(
                    blipCfg.label and L(tostring(blipCfg.label)) or labelOf(pt))
                EndTextCommandSetBlipName(blip)
            end
        end
    end

    -- ── The target zones ──────────────────────────────────────
    -- An addition, never the only way in. Same reasoning as client/police.lua, written down
    -- there: a zone that silently fails to register left the terminal unreachable with nothing
    -- on screen to say why, and the key press below is what cannot fail quietly.
    local targetRes = nil
    if VERIFY.useTarget ~= false then
        for _, res in ipairs({ 'ox_target', 'qb-target', 'qtarget' }) do
            if GetResourceState(res) == 'started' then targetRes = res break end
        end
    end

    if targetRes == 'ox_target' then
        for _, pt in ipairs(list) do
            exports.ox_target:addBoxZone({
                coords = vec3(pt.x, pt.y, pt.z),
                size = vec3(1.5, 1.5, 2.0),
                rotation = 0,
                debug = false,
                options = {
                    { name = 'vphone_verify_' .. pt.index, icon = 'fas fa-circle-check',
                      label = labelOf(pt), onSelect = openDesk },
                },
            })
        end
    end

    if targetRes == 'qb-target' or targetRes == 'qtarget' then
        for _, pt in ipairs(list) do
            exports[targetRes]:AddBoxZone('vphone_verify_' .. pt.index,
                vec3(pt.x, pt.y, pt.z), 1.5, 1.5,
                { name = 'vphone_verify_' .. pt.index, heading = 0,
                  minZ = pt.z - 1.0, maxZ = pt.z + 1.5 },
                { options = { { label = labelOf(pt), icon = 'fas fa-circle-check',
                                action = openDesk } }, distance = pt.radius + 0.5 })
        end
    end

    -- ── The marker and the key ────────────────────────────────
    local key = math.floor(num(VERIFY.key, 38))   -- 38 is E
    CreateThread(function()
        while true do
            local sleep = 1000
            local coords = GetEntityCoords(PlayerPedId())
            for _, pt in ipairs(list) do
                local d = #(coords - vec3(pt.x, pt.y, pt.z))
                if d < 12.0 then
                    sleep = 0
                    if VERIFY.marker ~= false then
                        DrawMarker(2, pt.x, pt.y, pt.z + 0.9, 0, 0, 0, 0, 180.0, 0,
                            0.22, 0.22, 0.14, 255, 141, 40, 160, false, true, 2, nil, nil, false)
                    end
                    if d < pt.radius then
                        if VERIFY.helpText ~= false then
                            BeginTextCommandDisplayHelp('STRING')
                            AddTextComponentSubstringPlayerName(
                                ('[~INPUT_CONTEXT~] %s'):format(labelOf(pt)))
                            EndTextCommandDisplayHelp(0, false, true, -1)
                        end
                        if IsControlJustReleased(0, key) then openDesk() end
                    end
                end
            end
            Wait(sleep)
        end
    end)
end)
