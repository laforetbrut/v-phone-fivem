-- v-phone | bridge/shared/locale.lua
--
-- The i18n helper, without v-core. Same shape as upstream: each locale file fills
-- `Locales.<lang>` and everything else calls `L(key, ...)`.
--
-- The language comes from one convar so a server sets it once:
--
--     set phone_locale "en"     # or fr - the default - or any locale file you add
--
-- **`set`, not `setr`, and the client still gets it.** A plain `set` convar exists only on
-- the server: the client's `GetConvar('phone_locale', ...)` comes back empty and falls back
-- to English. That is what put an English payphone prompt on a server whose phone was in
-- French - two code paths reading the same convar and disagreeing about the default.
--
-- So the SERVER decides and pushes the answer onto each player's state bag as they load
-- (see `pushLocale` in server/main.lua). The convar read below stays as the fallback for the
-- moment before that lands, and for a server that replicates it with `setr` anyway.
--
-- A key with no translation falls back to English rather than to nothing, because a
-- missing string should read as an oversight, not as a broken screen.

Locales = Locales or { en = {}, fr = {} }

--- The fallback language, named once. Everything that needs a default reads THIS, so no two
--- code paths can disagree about it - which is the bug this replaced.
---
--- **French.** A server that sets `phone_locale` gets what it asked for either way; this is
--- only what happens when nobody has said. It is also the language a key missing from another
--- locale file falls back to, so a partial translation reads as French rather than as nothing.
LOCALE_FALLBACK = 'fr'

--- The language for the local player, or the server's default.
---
--- Exposed rather than local because client/main.lua builds the page's string table and has
--- to arrive at the same answer as `L` does; when it had its own copy, it picked a different
--- default and the phone and the payphone ended up in different languages.
function PhoneLang()
    if IsDuplicityVersion() then
        return GetConvar('phone_locale', LOCALE_FALLBACK)
    end
    -- The state bag first: the server writes it on load, so this is right even when the
    -- operator used `set` rather than `setr` and the convar below is invisible here.
    local carried = LocalPlayer and LocalPlayer.state and LocalPlayer.state.lang
    if type(carried) == 'string' and carried ~= '' then return carried end
    local convar = GetConvar('phone_locale', '')
    if convar ~= '' then return convar end
    return LOCALE_FALLBACK
end

local function currentLang() return PhoneLang() end

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
        local lang = (state and state.lang) or GetConvar('phone_locale', LOCALE_FALLBACK)
        return translate(lang, key, ...)
    end
end
