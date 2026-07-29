-- ══════════════════════════════════════════════════════════════
-- The GIF shelf
-- ══════════════════════════════════════════════════════════════
-- A picture chosen from a shelf rather than pasted as a link. What the phone sends afterwards
-- is an ordinary image message, so nothing downstream had to learn a new kind: the thread, the
-- conversation list, the export API and forensics all already know what `image` means.
--
-- **The library is a list of links, and the search key never leaves this file.** A NUI page is
-- a browser. An API key handed to it is an API key published, and the first person to open the
-- developer console has the operator's quota. So the page asks the server for "cats", the
-- server asks the provider, and only the pictures come back.

local GIFS = (Config.Messages and Config.Messages.gifs) or {}

-- Its own, exactly as every other server file here declares its own. `num` is a per-file local
-- throughout this resource, not a shared global: calling it from here without this line is a
-- nil global, the callback throws, and the page is answered with nothing at all - which reads
-- to a player as "the shelf is empty" rather than as an error.
local function num(v, d) return tonumber(v) or d or 0 end

--- The operator's search key, convar first.
---
--- A convar keeps the credential out of a file that gets copied between servers, pasted into
--- support threads and committed to somebody's repository. The config field stays as the
--- fallback for servers that do not use convars, and is documented as the worse of the two.
local function searchKey()
    local fromConvar = GetConvar('vphone_gifKey', '')
    if fromConvar ~= '' then return fromConvar end
    return tostring((GIFS.search and GIFS.search.key) or '')
end

local function searchOn()
    return GIFS.enabled ~= false and searchKey() ~= ''
end

--- The shelf, as the page needs it: categories in config order, and whether to draw a search
--- field above them.
---
--- Recents are NOT here. They are per character and already live in the app-data store the rest
--- of the phone uses, which the page reads for itself - a second path to the same rows would be
--- a second thing to keep in step.
V.Callback('v-phone:gifs', function(src, resolve)
    if GIFS.enabled == false then resolve({ ok = true, enabled = false, packs = {} }) return end
    local out = {}
    for _, pack in ipairs(GIFS.packs or {}) do
        local urls = {}
        for _, u in ipairs(pack.gifs or {}) do
            if type(u) == 'string' and u ~= '' then urls[#urls + 1] = u end
        end
        if #urls > 0 then
            out[#out + 1] = { key = tostring(pack.key or ''), gifs = urls }
        end
    end
    resolve({ ok = true, enabled = true, search = searchOn(), packs = out,
              recent = math.max(0, math.min(40, math.floor(num(GIFS.recent, 12)))) })
end)

-- ── Search ─────────────────────────────────────────────────────
-- One request in flight per player, and a floor between them. A search field sends a request
-- per keystroke if nothing stops it, and the quota being spent belongs to the operator.

local Searching, SearchLast = {}, {}
local SEARCH_EVERY = 450

--- What each provider is asked, and where the pictures are in what it answers.
---
--- `tinygif` and `fixed_height_small` are asked for by name rather than taking whatever comes
--- first: the full-size format off either provider is several megabytes, and several megabytes
--- is not a thing to put in a text bubble on a machine that is also running a game.
local PROVIDERS = {
    tenor = {
        url = function(key, q, limit)
            local path = (q ~= '') and 'search' or 'featured'
            return ('https://tenor.googleapis.com/v2/%s?key=%s&limit=%d&media_filter=tinygif&contentfilter=medium%s')
                :format(path, key, limit, (q ~= '') and ('&q=' .. q) or '')
        end,
        pick = function(body)
            local out = {}
            for _, r in ipairs(body.results or {}) do
                local fmt = r.media_formats or {}
                local m = fmt.tinygif or fmt.nanogif or fmt.gif
                if m and type(m.url) == 'string' then out[#out + 1] = m.url end
            end
            return out
        end,
    },
    giphy = {
        url = function(key, q, limit)
            local path = (q ~= '') and 'search' or 'trending'
            return ('https://api.giphy.com/v1/gifs/%s?api_key=%s&limit=%d&rating=pg-13%s')
                :format(path, key, limit, (q ~= '') and ('&q=' .. q) or '')
        end,
        pick = function(body)
            local out = {}
            for _, r in ipairs(body.data or {}) do
                local imgs = r.images or {}
                local m = imgs.fixed_height_small or imgs.fixed_height_downsampled or imgs.original
                if m and type(m.url) == 'string' then out[#out + 1] = m.url end
            end
            return out
        end,
    },
}

--- Percent-encode a search term.
---
--- The term goes into a URL this server builds, so it is escaped here rather than trusted: a
--- query holding `&key=` would otherwise append a parameter to the operator's own request.
local function urlEncode(text)
    return (tostring(text or ''):gsub('[^%w%-%._~]', function(c)
        return ('%%%02X'):format(c:byte())
    end))
end

V.Callback('v-phone:gifSearch', function(src, resolve, data)
    if not searchOn() then resolve({ error = 'off' }) return end

    local p = Core.GetPlayer(src)
    if not p then resolve(false) return end

    local now = GetGameTimer()
    if Searching[src] or (SearchLast[src] and now - SearchLast[src] < SEARCH_EVERY) then
        resolve({ error = 'rate' }) return
    end
    SearchLast[src] = now

    local provider = PROVIDERS[tostring((GIFS.search and GIFS.search.provider) or 'tenor')]
    if not provider then resolve({ error = 'off' }) return end

    -- Trimmed to something a search box could hold. A thousand-character query is not a search.
    local q = urlEncode(tostring((data and data.q) or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 60))
    local limit = math.max(1, math.min(50, math.floor(num(GIFS.search and GIFS.search.limit, 24))))

    Searching[src] = true
    local answered = false
    local function answer(payload)
        if answered then return end
        answered = true
        Searching[src] = nil
        resolve(payload)
    end

    PerformHttpRequest(provider.url(searchKey(), q, limit), function(status, text)
        if status ~= 200 or not text or text == '' then answer({ error = 'x' }) return end
        local okDecode, body = pcall(json.decode, text)
        if not okDecode or type(body) ~= 'table' then answer({ error = 'x' }) return end

        -- Every URL is put through the same host gate a pasted link passes. The provider is
        -- configured by the operator, but what it answers with is not: a search result pointing
        -- somewhere the operator did not allow is dropped here rather than at send time, so the
        -- player never sees a picture they are not able to send.
        local urls = {}
        for _, u in ipairs(provider.pick(body)) do
            if PhoneLinkAllowed == nil or PhoneLinkAllowed(u) then urls[#urls + 1] = u end
        end
        answer({ ok = true, gifs = urls })
    end, 'GET', '', { ['Accept'] = 'application/json' })

    -- A provider that never answers must not leave the picker spinning for ever.
    SetTimeout(9000, function() answer({ error = 'timeout' }) end)
end)

AddEventHandler('playerDropped', function()
    Searching[source], SearchLast[source] = nil, nil
end)
