-- v-phone | server/banner.lua
-- Author: vyrriox
--
-- One framed block in the console at boot: which version runs, and what the phone found to
-- talk to. It is the first thing an operator reads when "the garage app shows nothing", so it
-- names every integration it picked, or says none was found.

local RES = GetCurrentResourceName()
local WIDTH = 58

local function started(list)
    for _, res in ipairs(list) do
        if GetResourceState(res) == 'started' then return res end
    end
    return nil
end

local function line(level, text)
    local plain = tostring(text):gsub('%^%d', '')
    if #plain > WIDTH then plain = plain:sub(1, WIDTH - 3) .. '...' end
    print(('^%s[v-phone]^7 ║ %-' .. WIDTH .. 's ║'):format(level == 'warn' and '3' or '2', plain))
end

local function centred(text)
    return string.rep(' ', math.max(0, math.floor((WIDTH - #text) / 2))) .. text
end

local function pick(fn)
    local ok, v = pcall(fn)
    return ok and v or nil
end

CreateThread(function()
    -- After every other file has run and the framework object has been fetched.
    Wait(1500)

    local apps = 0
    for _, app in pairs(Config.Apps or {}) do
        if type(app) == 'table' and app.enabled ~= false then apps = apps + 1 end
    end

    local fw = Bridge.framework or 'standalone'
    local fwRes = Bridge.frameworkResource
    local inv = pick(function() return Bridge.InventoryResource() end) or 'none'
    local bank = pick(function() return Bridge.Banking.Script() end) or 'framework'
    local garage = started({ 'qs-advancedgarages', 'jg-advancedgarages', 'qb-garages', 'cd_garage', 'okokGarage' }) or 'framework'
    local housing = started({ 'qs-housing', 'ps-housing', 'qb-houses', 'ox_property', 'loaf_housing', 'esx_property' }) or 'none'
    local media = tostring((Config.Media or {}).provider or 'none')

    print(('^2[v-phone]^7 ╔%s╗'):format(string.rep('═', WIDTH + 2)))
    line('info', centred('\\      /'))
    line('info', centred('\\    /'))
    line('info', centred('\\  /'))
    line('info', centred('\\/'))
    line('info', string.rep('-', WIDTH))
    line('info', ('V-PHONE  v%s  |  Copyright vyrriox')
        :format((PhoneVersion and PhoneVersion()) or GetResourceMetadata(RES, 'version', 0) or 'unknown'))
    line('info', ('framework: %s%s'):format(fw, fwRes and (' (' .. fwRes .. ')') or ''))
    if GetResourceState('oxmysql') == 'started' then
        line('info', 'database: oxmysql, tables prefixed `vphone_`')
    else
        line('warn', 'WARNING: oxmysql is not started, nothing will be saved')
    end
    line('info', ('%d app(s) configured | media %s'):format(apps, media))
    line('info', ('inventory %s | banking %s'):format(inv, bank))
    line('info', ('garages %s | housing %s'):format(garage, housing))
    if GetResourceState('v-park') == 'started' then
        line('info', 'v-park detected: parked cars located through it')
    end
    if fw == 'standalone' then
        line('warn', 'WARNING: no framework found, running standalone')
    end
    line('info', '/phoneadmin panel')
    print(('^2[v-phone]^7 ╚%s╝'):format(string.rep('═', WIDTH + 2)))
end)
