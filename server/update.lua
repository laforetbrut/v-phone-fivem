-- ══════════════════════════════════════════════════════════════
-- The update check
-- ══════════════════════════════════════════════════════════════
-- Asks GitHub once, at boot, whether the release published is newer than the copy running, and
-- says so in the server console. That is the whole feature. It does not download anything, it
-- does not write anything, and no part of it is reachable from a client.
--
-- **Why the console and nowhere else.** The person who needs to know a phone is out of date is
-- the operator, and the operator reads the console. Telling a player would tell them what
-- version the server runs, which is the first thing anybody looking for a known bug wants -
-- so the answer goes to the console and stops there.
--
-- **Everything GitHub sends is treated as hostile text.** It is a public endpoint answering
-- with somebody's release notes, and a console line is assembled by concatenation: a tag
-- containing a newline forges a second line, and one containing `^1` recolours the rest of the
-- output. Both are stripped in `clean` below before anything is printed. This is not a
-- hypothetical - a release title is free text on GitHub's side.

local RES = GetCurrentResourceName()

local CFG = Config.UpdateCheck or {}

-- ── The two things it compares ─────────────────────────────────

--- The running version, from the manifest rather than from a constant here.
---
--- A number written down twice is a number that disagrees with itself eventually, and the
--- manifest's is the one an operator sees in `ensure` output and in a bug report.
local function currentVersion()
    return tostring(GetResourceMetadata(RES, 'version', 0) or '')
end

--- `owner/repo`, taken from the manifest's `repository` line.
---
--- Also from the manifest, and for the same reason: a fork that changes the repository line
--- gets its own release feed without editing this file, and one that removes it gets no check
--- at all rather than a check against somebody else's project.
local function repoSlug()
    local url = CFG.repository
    if type(url) ~= 'string' or url == '' then
        url = tostring(GetResourceMetadata(RES, 'repository', 0) or '')
    end
    if url == '' then return nil end
    -- Only github.com. A repository line pointing at a private forge is not an error worth
    -- printing about; there is simply no releases API here to ask.
    local owner, name = url:match('^https?://github%.com/([%w%.%-_]+)/([%w%.%-_]+)')
    if not owner then return nil end
    name = name:gsub('%.git$', '')
    if owner == '' or name == '' then return nil end
    return owner .. '/' .. name
end

-- ── Comparing them ─────────────────────────────────────────────

--- `1.5.6` -> `{1, 5, 6}`, tolerating a `v` prefix and a `-beta.2` suffix.
---
--- **Only the leading run of dotted numbers counts.** Scanning the whole tag for digits reads
--- `1.5.6-rc1` as `{1,5,6,1}`, which makes a release candidate compare as NEWER than the
--- release it precedes - so the server announces an update to a version that is behind it. The
--- suffix is cut before the scan instead.
---
--- A tag that is not a version at all (`nightly`) reads as `{}` and compares as older than
--- everything, which is the safe direction: it means "do not shout about it".
local function parts(v)
    local out = {}
    local core = tostring(v or ''):gsub('^[vV]', ''):match('^%d[%d%.]*') or ''
    for n in core:gmatch('(%d+)') do
        out[#out + 1] = tonumber(n) or 0
        if #out >= 4 then break end
    end
    return out
end

--- Is `b` a later version than `a`?
local function isNewer(a, b)
    local x, y = parts(a), parts(b)
    if #y == 0 then return false end
    for i = 1, math.max(#x, #y) do
        local l, r = x[i] or 0, y[i] or 0
        if r > l then return true end
        if r < l then return false end
    end
    -- Equal numbers. `1.5.6` published against `1.5.6-beta` running means the real one is out:
    -- a prerelease suffix on the LOCAL copy makes the plain published tag newer.
    local pre = tostring(a or ''):match('%d%-(%w)')
    return pre ~= nil
end

-- ── Printing it ────────────────────────────────────────────────

--- Strip everything that could forge a console line out of a string GitHub supplied.
---
--- Control characters go (that covers CR, LF and the terminal's own escape introducer), `^`
--- goes because FiveM reads `^1`..`^9` as a colour change, and the result is cut short. A
--- version tag is a handful of characters; anything claiming to be two hundred is not a
--- version tag.
local function clean(s, max)
    s = tostring(s or ''):gsub('%c', ' '):gsub('%^', ''):gsub('%s+', ' ')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    max = max or 40
    if #s > max then s = s:sub(1, max) .. '...' end
    return s
end

local function announce(latest, url, name)
    local here = clean(currentVersion(), 20)
    local there = clean(latest, 20)
    print('^3[v-phone]^7 ─────────────────────────────────────────────')
    print(('^3[v-phone]^7 An update is available: ^2%s^7 (running ^3%s^7)'):format(there, here))
    if name ~= '' and name ~= there then
        print(('^3[v-phone]^7 %s'):format(clean(name, 70)))
    end
    -- The release URL is rebuilt from the slug rather than taken from the answer, so what is
    -- printed always points at the repository the manifest names.
    print(('^3[v-phone]^7 %s'):format(clean(url, 120)))
    print('^3[v-phone]^7 ─────────────────────────────────────────────')
end

-- ── Asking ─────────────────────────────────────────────────────

local checking = false

--- One request. `loud` prints the up-to-date and failure cases too, which the console command
--- wants and the boot check does not: a server that is current should start in silence.
local function check(loud)
    if checking then
        if loud then print('^3[v-phone]^7 update check: already running') end
        return
    end
    local slug = repoSlug()
    if not slug then
        if loud then
            print('^3[v-phone]^7 update check: no github repository in the manifest, nothing to ask')
        end
        return
    end
    local here = currentVersion()
    if here == '' then
        if loud then print('^3[v-phone]^7 update check: the manifest has no version line') end
        return
    end

    checking = true
    PerformHttpRequest('https://api.github.com/repos/' .. slug .. '/releases/latest',
        function(status, body)
            checking = false
            if status ~= 200 or type(body) ~= 'string' or body == '' then
                -- Quiet on failure at boot. GitHub being unreachable, rate-limited or between
                -- releases is not the operator's problem and not worth a line they cannot act
                -- on. 404 in particular is the ordinary answer for a repository that has never
                -- published a release.
                if loud then
                    print(('^3[v-phone]^7 update check: GitHub answered %s'):format(tostring(status)))
                end
                return
            end
            local ok, data = pcall(json.decode, body)
            if not ok or type(data) ~= 'table' then
                if loud then print('^3[v-phone]^7 update check: could not read the answer') end
                return
            end
            -- A draft is not published and a prerelease is not for everybody. `releases/latest`
            -- excludes both already; this is the belt for the braces.
            if data.draft == true or (data.prerelease == true and CFG.prerelease ~= true) then
                if loud then print('^3[v-phone]^7 update check: the newest release is a prerelease') end
                return
            end
            local tag = tostring(data.tag_name or data.name or '')
            if tag == '' then
                if loud then print('^3[v-phone]^7 update check: the release has no tag') end
                return
            end
            if isNewer(here, tag) then
                announce(tag, 'https://github.com/' .. slug .. '/releases/latest',
                    tostring(data.name or ''))
            elseif loud then
                print(('^3[v-phone]^7 up to date (^2%s^7)'):format(clean(here, 20)))
            end
        end, 'GET', '', {
            -- GitHub rejects a request with no User-Agent outright, and the documented form is
            -- the project's own name. No token: this reads a public endpoint, and a credential
            -- sitting in a resource for a read anybody can do is a credential to lose.
            ['User-Agent'] = 'v-phone',
            ['Accept'] = 'application/vnd.github+json',
        })
end

-- ── When ───────────────────────────────────────────────────────

if CFG.enabled ~= false then
    CreateThread(function()
        -- Not at the first frame. A server starting up is fetching a hundred things and this is
        -- the least important of them.
        Wait(math.max(5, tonumber(CFG.firstRunSeconds) or 20) * 1000)
        check(false)

        -- Then on a timer, if the operator wants one. Off by default: a server that restarts
        -- daily learns about a release at the next restart, which is soon enough, and GitHub
        -- allows sixty unauthenticated requests an hour per address for everything on the box.
        local hours = tonumber(CFG.everyHours) or 0
        if hours > 0 then
            local gap = math.max(1, hours) * 3600 * 1000
            while true do
                Wait(gap)
                check(false)
            end
        end
    end)
end

--- `vphone_update` in the server console.
---
--- Restricted, which for a command with no ace attached means the console and nothing else. A
--- player typing it in chat gets no reaction at all, which is the intent: the version this
--- server runs is not a thing to hand out.
RegisterCommand('vphone_update', function(src)
    if src ~= 0 then return end
    check(true)
end, true)
