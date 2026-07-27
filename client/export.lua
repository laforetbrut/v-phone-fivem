-- v-phone | client/export.lua
--
-- **The Export app's client side, which is deliberately thin.**
--
-- Every other doc integration in this resource lives on the client, because doc-restaurant,
-- doc-taxijob, doc-lottery, doc-civilalerte and doc-mechanicmdt all publish their data as QB
-- *server callbacks* - registered on the framework, reachable only by a client.
--
-- doc-shops is the exception, and it is a happy one: `GetMarketData(market)` is a **server**
-- export. The phone's own server reads the board directly, on a timer, with no player involved -
-- so the market is watched whether or not anybody has the app open, and a price alert fires
-- while its owner is in a field somewhere with the phone in their pocket. That is the whole
-- reason this file has no bridging in it: see server/export.lua.
--
-- What is left here is the two things a client is for: passing the page's questions along, and
-- putting a banner on screen when one of them comes true.

local function exportOn()
    return (Config.Export or {}).enabled ~= false
end

RegisterNUICallback('exportOpen', function(data, cb)
    V.Request('v-phone:export:open', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('exportWatch', function(data, cb)
    V.Request('v-phone:export:watch', function(res) cb(res or { error = 'x' }) end, data or {})
end)

RegisterNUICallback('exportAlert', function(data, cb)
    V.Request('v-phone:export:alert', function(res) cb(res or { error = 'x' }) end, data or {})
end)

--- The board moved while somebody had the app open.
---
--- Pushed by the server's poll rather than asked for, and only to people who have the app open:
--- see `Watching` in server/export.lua. Without this the only way to see a new price was to
--- close the app and open it again, which on a board that moves every twenty minutes is exactly
--- when somebody is staring at it.
RegisterNetEvent('v-phone:client:exportBoard', function(d)
    if type(d) ~= 'table' or not exportOn() then return end
    SendNUIMessage({ action = 'exportBoard', board = d })
end)

--- The app was closed. Said out loud so the server stops pushing at a screen nobody is reading.
RegisterNUICallback('exportLeave', function(_, cb)
    TriggerServerEvent('v-phone:export:leave')
    cb({ ok = true })
end)

--- A price a player asked to be told about has been reached.
---
--- The banner goes through `PhoneNotify` like everything else, so muting the app or turning on
--- Do Not Disturb silences it the same way. That matters here more than it looks: a market that
--- moves every twenty minutes is a lot of buzzing for somebody who set six alerts and then went
--- to do something else.
---
--- The page is told as well, so an open app moves the card without refetching - and a closed one
--- has the new price ready when it opens.
RegisterNetEvent('v-phone:client:exportAlert', function(d)
    if type(d) ~= 'table' or not exportOn() then return end

    SendNUIMessage({ action = 'exportAlert', alert = d })

    if not PhoneNotify then return end
    local S = PhoneString or function(k) return k end
    local body
    if d.kind == 'move' then
        -- The direction, from the sign of the change: "moved 14%" leaves out the half of the
        -- sentence somebody actually wants.
        local up = (tonumber(d.percent) or 0) >= 0
        body = S(up and 'ph.export_n_up' or 'ph.export_n_down')
            :gsub('{n}', tostring(math.abs(tonumber(d.percent) or 0)))
            :gsub('{p}', tostring(d.price or 0))
    else
        body = S(d.kind == 'below' and 'ph.export_n_below' or 'ph.export_n_above')
            :gsub('{n}', tostring(d.value or 0))
            :gsub('{p}', tostring(d.price or 0))
    end

    PhoneNotify({
        app = 'export', icon = 'export',
        title = tostring(d.label or d.item or ''),
        body = body,
        hasItem = true,
    })
end)
