-- v-phone | bridge/shared/locale.lua
--
-- The i18n helper, without v-core. Same shape as upstream: each locale file fills
-- `Locales.<lang>` and everything else calls `L(key, ...)`.
--
-- The language comes from one convar so a server sets it once:
--
--     set phone_locale "en"     # or fr, or any locale file you add
--
-- A key with no translation falls back to English rather than to nothing, because a
-- missing string should read as an oversight, not as a broken screen.

Locales = Locales or { en = {}, fr = {} }

local function currentLang()
    if IsDuplicityVersion() then
        return GetConvar('phone_locale', 'en')
    end
    -- A player may carry their own language on their state bag; the convar is the
    -- server's default for everyone who does not.
    return (LocalPlayer and LocalPlayer.state and LocalPlayer.state.lang)
        or GetConvar('phone_locale', 'en')
end

local function translate(lang, key, ...)
    local tbl = Locales[lang] or Locales.en or {}
    local str = tbl[key]
    if str == nil then str = (Locales.en and Locales.en[key]) or key end
    if select('#', ...) > 0 then
        local ok, res = pcall(string.format, str, ...)
        return ok and res or str
    end
    return str
end

function L(key, ...)
    return translate(currentLang(), key, ...)
end

if IsDuplicityVersion() then
    --- Translate for one player, in whatever language that player carries.
    function LP(source, key, ...)
        local state = source and Player(source) and Player(source).state
        local lang = (state and state.lang) or GetConvar('phone_locale', 'en')
        return translate(lang, key, ...)
    end
end
