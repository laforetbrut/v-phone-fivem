-- The whole reason this resource exists.
--
-- A FiveM export is bound to a RESOURCE NAME. qb-cityhall, qb-vehiclesales and qb-weapons
-- all call `exports['qb-phone']:sendNewMailToOffline(...)`, and no amount of code inside
-- v-phone can answer to a name it does not have. So: a resource called qb-phone, whose only
-- job is to own the name and forward.
--
-- Everything it forwards to lives in v-phone/bridge/server/qb-phone.lua, where it can be
-- read and maintained alongside the rest of the phone.

local PHONE = 'v-phone'

local function forward(citizenid, mailData)
    -- Fail quiet rather than raise. These callers are inside job flows - a player selling a
    -- car should not get a Lua error because the phone is restarting.
    if GetResourceState(PHONE) ~= 'started' then return false end
    local ok, result = pcall(function()
        return exports[PHONE]:QbMail(citizenid, mailData)
    end)
    return (ok and result) and true or false
end

exports('sendNewMailToOffline', forward)

-- Stock exposed this one too, and third-party scripts written against qb-phone use it.
exports('sendNewEventMail', forward)

-- Note what is NOT here: `qb-phone:server:sendNewMail` is registered by v-phone itself.
-- Registering it here as well would write every job mail twice.
