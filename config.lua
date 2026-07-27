-- v-phone | shared config
-- iFruit. The framework has no player chat commands by design, which makes the phone the
-- surface most of the game is played through.
--
-- **The phone is a shell, not a feature.** Every app is a thin view over the module that
-- already owns its data: the bank app calls v-banking, it does not keep a balance. The
-- moment an app holds its own copy of anything there are two sources of truth, and one of
-- them is wrong. Messages and contacts are the only things v-phone owns outright.
--
-- **Every table this resource creates begins with `vphone_`,** so it can never collide
-- with a table another script owns. A server upgraded from an older build has its data
-- moved to the new names automatically at boot (see bridge/server/migrate.lua).
Config = {}

-- ══════════════════════════════════════════════════════════════
--  COMPATIBILITY
-- ══════════════════════════════════════════════════════════════
-- **This phone runs on your framework, not the other way round.**
--
-- Everything in this section is `auto` by default, which means "look at what is running
-- and use it". Naming something explicitly always wins over the detection, and `off`
-- switches an integration out entirely. You should be able to drop this resource on a
-- qb-core, qbx_core, ox_core or ESX server and have it work without editing a line -
-- and to bend every one of those decisions here when you do need to.

--- `auto` | `qb` | `ox` | `esx` | `standalone`
--- Standalone works: the phone falls back to the licence identifier and has no job.
Config.Framework = 'auto'

-- Moving an earlier build's data to the `vphone_` prefix at boot.
--
-- **Off by default, on purpose.** A fresh install has no legacy tables and needs none of
-- this, and nothing surprising should happen to your database the first time you start a
-- resource. Turn it on ONLY if you are upgrading a server that ran v-phone 1.0.0 to 1.0.4.
--
--   false   (default) never migrate. Fresh installs, and anyone who would rather move
--           their own data, want this. The phone creates its `vphone_` tables and starts.
--   'auto'  rename a legacy table ONLY if its columns match this resource's own schema.
--           A table that merely shares a name - another script's `phone_contacts` - fails
--           the check and is never touched. Safe to leave on while upgrading.
--   true    trust the names and rename without the column check. Only if you are certain
--           every legacy-named table on the server is this phone's.
Config.MigrateLegacyTables = false

--- The inventory item a player must carry, when `Config.Settings.requireItem` is on.
Config.PhoneItem = 'phone'

--- The item that recharges a phone, and how much it gives back.
---
--- Configurable for the same reason the handset is: a server that already calls this something
--- else should be able to say so rather than being told what its own items are named. The name
--- was hardcoded, which meant an existing `battery_pack` or `powerbank_v2` simply did not work
--- and nothing said why.
---
--- `powerbank` is registered as well whatever you set, so an existing item keeps working.
--- How much charge it returns is `Config.Settings.powerbankCharge`.
Config.PowerbankItem = 'powerbank'

Config.Compat = {
    -- ── Which script answers what ──────────────────────────────
    -- Each of these is `auto`, `off`, or the exact resource name to use.
    inventory = 'auto',   -- ox_inventory, qs-inventory, ps-inventory, qb-inventory, origen_inventory, codem-inventory
    banking   = 'auto',   -- qs-banking, Renewed-Banking, qb-banking, okokBanking, esx_banking
    garage    = 'auto',   -- qs-advancedgarages, jg-advancedgarages, qb-garages, cd_garage, okokGarage
    housing   = 'auto',   -- qs-housing, ps-housing, qb-houses, ox_property, loaf_housing, esx_property
    voice     = 'auto',   -- pma-voice, saltychat, mumble-voip
    notify    = 'auto',   -- ox_lib, qb, esx, chat, custom
    -- ── Whose phone numbers ────────────────────────────────────
    -- **The setting to reach for on a server that already has players.**
    --
    -- qb-core writes a phone number into `charinfo` when a character is created, and ox_core
    -- keeps one in `characters.phoneNumber`. On `auto` the phone ADOPTS that number, which is
    -- the friendly default: every script that already knows how to reach a player still can,
    -- and nobody's number changes under them.
    --
    -- But an adopted number is in the framework's format, not yours. If you have set
    -- `Config.NumberFormat` to something you actually want - `5555-####-####`, a French
    -- shape, whatever - `auto` means your existing players keep their old-looking numbers
    -- forever and only brand new characters get the new shape.
    --
    --   auto       adopt the framework's number if there is one, otherwise mint our own,
    --              and write ours back so the framework agrees. The default.
    --   framework  the same adoption, stated explicitly.
    --   phone      **ignore the framework's numbers entirely.** Every character is minted a
    --              number in `Config.NumberFormat`, and it is NOT written back into charinfo.
    --              Pick this when the phone's numbering is the one that matters.
    --
    -- Switching to `phone` affects characters from then on. It cannot retroactively change a
    -- number already stored - so for players whose framework number was adopted on an earlier
    -- boot, run `/phoneadmin renumber all confirm` once. That mints everybody a number in the
    -- current format. Anybody who saved an old number in their contacts keeps the old one:
    -- a contact is a row on somebody else's phone, and rewriting other people's address books
    -- to follow a staff action would be worse than the problem it solved.
    numbers   = 'auto',   -- auto | framework | phone

    -- ── Standing in for qb-phone ───────────────────────────────
    -- A stock qb-core server has eighteen resources that talk to qb-phone: job mail, police
    -- dispatch, invoices. Drop v-phone in without the stock phone and they all talk to
    -- nobody. On (the default) v-phone answers them itself.
    --
    -- `auto` stands down if the REAL qb-phone is running, so the two never double up. Set
    -- true to answer regardless, false to stay out of it entirely.
    --
    -- One thing this cannot cover on its own: `exports['qb-phone']:sendNewMailToOffline`.
    -- An export belongs to a resource NAME, so that call needs the twenty-line resource in
    -- compat/qb-phone - see COMPATIBILITY.md.
    qbPhone   = 'auto',   -- auto | true | false

    -- qb mail can carry a button that fires a client event; qb-drugs uses one to hand over
    -- the delivery location. v-phone's Mail has no buttons, so the event is fired back at
    -- the recipient instead.
    --
    -- Off by default, and deliberately: that payload arrives from a CLIENT, so switching
    -- this on lets a player's own client name the event that gets fired at it. It is fired
    -- only ever back at the sender, never at anybody else, but it is still their choice of
    -- event name. Turn it on if you run qb-drugs and want deliveries to work.
    qbPhoneMailButtons = false,

    -- The phone charges inside a property you have a key to, decided per housing script
    -- (Quasar included) in bridge/client/charging.lua. Off leaves only vehicles and the
    -- public chargers in Config.Chargers.
    chargeAtProperty = true,

    -- And in any vehicle, which is the other one the server can see for itself. Off makes
    -- a car journey drain the battery like walking does, so a long drive has a cost - and
    -- it leaves properties and the public chargers as the only ways to fill up.
    chargeInVehicle = true,

    -- With `notify = 'custom'`, the client event the phone fires instead. It receives
    -- (message, kind) where kind is inform | success | error.
    notifyEvent = 'myserver:notify',

    -- The channel range phone calls use, when the voice script is channel based. Twenty-four
    -- channels are reserved from here up, so two calls in the same minute never share one.
    --
    -- On pma-voice these are CALL channels, which are a namespace of their own: they cannot
    -- collide with the radio channels your job scripts use, and a player on a radio stays on
    -- it while taking a call. Do not confuse the two - see bridge/shared/compat.lua.
    voiceChannel = 700,

    -- How many channels calls may spread over, starting at `voiceChannel` above. This is
    -- also the ceiling on CONCURRENT calls server-wide, because a call id is its channel and
    -- no two live calls may share one - two conversations on one pma-voice channel hear each
    -- other. It was hardcoded at 24, which refused the twenty-fifth call on a busy night for
    -- no reason: a pma-voice channel is just an integer. Raise it if you run a big server;
    -- keep the range clear of any radio channels your other scripts use.
    voiceChannels = 256,

    -- ── Apps that need a script you may not run ────────────────
    -- Set one to false and its app is not offered at all: no home screen, no store, no
    -- search. This is how you switch off the garage app on a server with no garages,
    -- rather than leaving players an app that answers nothing.
    -- Which of these apps to offer at all. All of them read your framework through the
    -- bridge - qb-core, qbx, ESX, ox, and whatever banking, garage or housing script is
    -- running - so none of them needs a companion resource. Set one to false to remove it
    -- from the phone entirely.
    apps = {
        bank     = true,
        garage   = true,
        property = true,
        wallet   = true,
        jobs     = true,
    },

    -- The same switches under their old names. These were the author's own v-* module
    -- names, and setting one to true used to make the phone believe that resource was
    -- RUNNING - which is why four apps reported themselves as not installed while the
    -- bridge behind them worked perfectly. Kept only so an existing config keeps working;
    -- `apps` above is the one to use.
    modules = nil,

    -- Jobs that unlock the MDT app. Empty hides it from everybody.
    policeJobs = { 'police', 'sheriff', 'bcso', 'sast' },

    -- ox_core has no single "job": it has groups. These are the ones that are clearly
    -- not a job, so the phone does not report somebody's admin group as their employer.
    ignoredGroups = { admin = true, mod = true, support = true, group = true },

    -- ── Tables to read ─────────────────────────────────────────
    -- The phone reads these directly when no export offers the same data.
    --
    -- `auto` picks the right name for the framework that is running:
    --   qb   player_vehicles / properties
    --   ox   vehicles / ox_property / character_licenses
    --   ESX  owned_vehicles / owned_properties / user_licenses
    --
    -- Name one to override it. Set one to `false` if your server has no such table: the
    -- app hides rather than erroring.
    tables = {
        vehicles   = 'auto',
        properties = 'auto',
        licences   = 'auto',
    },

    -- ── Your own wiring ────────────────────────────────────────
    -- The escape hatch. Any hook you fill is used INSTEAD of the detection above, so a
    -- server with a bespoke banking script wires it in one function rather than forking
    -- the resource.
    --
    --     balances = function(src) return { cash = 100, bank = 5000 } end,
    --
    hooks = {
        balances = nil,       -- (src) -> { cash, bank }
        transactions = nil,   -- (src, citizenid) -> { { label, amount, at }, ... }
        vehicles = nil,       -- (citizenid) -> { { plate, model, garage, state }, ... }
        properties = nil,     -- (citizenid) -> { { label, address }, ... }
        licences = nil,       -- (src, citizenid) -> { { type, label }, ... }
        -- Who the character is, for the Wallet app's identity card. Only needed if your
        -- framework keeps none of it where the bridge looks.
        identity = nil,       -- (citizenid, src) -> { first, last, dob, sex, nationality, id }
        -- What a garage key is called and where it is. Only needed if your garage script
        -- keeps neither in a readable config - Quasar's escrowed build, for instance.
        garage = nil,         -- (key) -> { label, x, y }
        -- What a vehicle is CALLED, from its spawn code. qb-core's own shared list is read
        -- when it is there, so this is only for a server whose vehicle names live elsewhere.
        vehicleLabel = nil,   -- (model) -> 'Grotti Brioso R/A'
        jobs = nil,           -- () -> { { name, label, grades }, ... }
        status = nil,         -- (src) -> { hunger, thirst, ... }
        -- Charge a player. Return true ONLY if the money genuinely left them: the store
        -- treats false as "not paid" and does not grant the app.
        removeMoney = nil,    -- (src, amount, account) -> boolean
        -- Pay a player. Return true ONLY if the money genuinely arrived: a transfer whose
        -- credit reports false is refunded to the sender rather than lost.
        addMoney = nil,       -- (src, amount, account, reason) -> boolean
        -- CLIENT side: true when the local player is inside a property they can charge
        -- in. Only fill this if your housing script is none of the supported ones.
        atHome = nil,         -- () -> boolean, runs on the client
        -- Put money into a JOB or society account - what a paid charger charges goes here.
        -- qb-banking, Renewed-Banking, okokBanking and esx_addonaccount are handled; fill
        -- this only if your banking script is none of them. Return true only if it landed.
        society = nil,        -- (account, amount, reason) -> boolean
    },

    -- Print what the phone decided at boot, and log every social/phone write. Useful
    -- once, noisy for ever after.
    log = false,
}

-- ══════════════════════════════════════════════════════════════
--  SETTINGS
-- ══════════════════════════════════════════════════════════════
-- Upstream these live in an admin panel. Here they are plain values, and every one of
-- them can also be set from server.cfg without touching this file:
--
--     set phone_battery false
--     set phone_requireItem false
--
-- The convar name is `phone_` followed by the key.
Config.Settings = {
    enabled         = true,
    -- On: the player carries Config.PhoneItem, or they have no phone. This is the default
    -- because a phone every character owns for free is not an item, it is a menu.
    -- `set phone_requireItem false` gives everybody one again.
    --
    -- Note it cuts both ways: a character with no handset cannot be CALLED either, which
    -- is the point, but it also means messages sent to them wait until they hold one.
    requireItem     = true,
    numberFormat    = '555-####',
    maxLength       = 500,     -- an SMS
    retentionDays   = 30,      -- how long messages are kept, 0 for ever
    ringSeconds     = 30,
    maxMinutes      = 60,
    battery         = true,
    -- A real day of USE, which is what a player measures it against. 48 hours idle with
    -- the phone in a pocket, halved to 24 with the screen on - so somebody who plays a long
    -- session and keeps checking it still ends the night with charge, and somebody who
    -- never puts it away eventually has to find a charger. The old 8/3 pair emptied a
    -- phone in under three hours of use, which read as broken rather than as a mechanic.
    -- 72 hours idle, and the screen costs 1.5x rather than 2x, so a phone that is actually
    -- being looked at lasts about 48 hours of use. 48/2x gave exactly 24 and that is the
    -- number to clear, not to land on.
    --
    -- The arithmetic, so it can be checked rather than trusted: the drain tick runs every 20
    -- seconds, 180 times an hour, and takes 100/(hours*180) percent each time. At 72 that is
    -- 1.39% an hour closed and 2.08% with the screen on - 72 hours and 48 hours to empty.
    hoursToEmpty    = 72,
    screenDrain     = 1.5,
    chargeMinutes   = 45,
    powerbankCharge = 45,
    autoDark        = true,
    darkFrom        = 20,
    darkTo          = 6,
    voicemail       = true,
    voicemailMax    = 200,
    anonymous       = false,
    customWallpaper = true,
    -- The Camera app, on. It shipped off, which meant a phone with a camera icon that
    -- opened onto "the camera is disabled on this server" - a bad thing to hand somebody
    -- out of the box, and it hid a real bug for a long time: the flag was never sent to
    -- the page at all, so switching it on changed nothing and looked like a config error.
    --
    -- A photo needs somewhere to live. Either Config.Media (server-side capture and upload,
    -- the better option, and the API key stays on the server) or `phone_cameraUpload` with
    -- screenshot-basic. With neither, the app opens and taking a shot says so plainly.
    camera          = true,
    cameraUpload    = '',
    social          = true,
    socialMaxLength = 280,
    socialFeedSize  = 50,
    socialRetentionPosts    = 60,
    socialRetentionComments = 60,
    socialRetentionStories  = 1,
    socialRetentionMessages = 30,
    socialHush      = true,
    socialDailyLikes = 30,
}

-- Open / close the phone.
--
-- **Every player can change this for themselves.** It is registered with
-- `RegisterKeyMapping`, so it appears in the game's own Settings -> Key Bindings -> FiveM
-- list under "iFruit". Whatever a player binds there wins over this value and survives a
-- restart, which is why the operator only needs to pick a sensible starting point.
--
-- F2 by default: F1 is taken by more resources than any other key, and F3 is a common radio.
--
-- Holding the item is still required (`Config.Settings.requireItem`), so the key opens a
-- phone you own and says so plainly when you do not. Set this to `false` for no binding at
-- all, and the phone then opens only by using the item. The `/vphone` command exists either
-- way, which is what you want while testing.
Config.Key = 'F2'

-- ── In hand ────────────────────────────────────────────────────
-- A phone you are using is a phone you are holding: a prop in the hand and an animation
-- to match, while you stay free to walk and drive. Open on foot and you browse one-handed;
-- open in a car and the prop still shows. A call raises it to the ear.
Config.Hold = {
    prop   = 'prop_amb_phone',           -- base-game phone prop, attached to the right hand
    bone   = 28422,                      -- SKEL_R_Hand
    pos    = vec3(0.0, 0.0, 0.0),
    rot    = vec3(0.0, 0.0, 0.0),
    dict   = 'cellphone@',
    browse = 'cellphone_text_read_base', -- one-handed, looking at the screen
    call   = 'cellphone_call_listen_base', -- to the ear
    -- Disabled while the phone is up so a click on the screen does not fire a gun, and the
    -- mouse drives the cursor instead of spinning the camera. Movement, sprint, jump and
    -- every vehicle control are left untouched, so you keep walking and driving.
    -- 199 and 200 are the pause menu (P and Escape). The page already treats Escape as
    -- "go back": it closes a sheet, then the app, then the phone. Without these two the
    -- game acts on the same keypress as well, so Escape closed a sheet AND opened the GTA
    -- menu over the top. Blocking them leaves Escape meaning one thing while the phone is
    -- out, and they are restored the moment it goes away.
    block  = { 1, 2, 24, 25, 47, 257, 263, 264, 45, 140, 141, 142, 143, 37, 44, 68, 69, 70, 91, 92,
               199, 200 },
}

-- ── Numbers ────────────────────────────────────────────────────
-- A number is how contacts, calls and messages address each other. Never the citizen id:
-- that is a database key, and a player should not be trading it.
--
-- `#` is replaced by a random digit. Anything else is kept, so a server can use its own
-- shape. Los Santos numbers in GTA are 555-xxxx, which is what this ships as.
-- Every `#` becomes a digit; everything else is kept exactly as written. So all of these
-- work, and any shape you can spell this way works:
--
--     '555-####'            555-0142        the GTA shape, and the default
--     '5555-####-####'      5555-0142-9930
--     '(###) ###-####'      (415) 555-0142
--     '+33 # ## ## ## ##'   +33 6 12 34 56 78
--     '##########'          4155550142
--
-- Three things to keep in mind, each of which the server checks at boot and names:
--
--   * at least four `#`, or a busy server runs out of numbers
--   * 20 characters at most, because that is the column - a longer format would be truncated
--     and two different numbers could end up stored as the same string
--   * it must not overlap `Config.Booth.numberFormat`. A payphone is recognised by the SHAPE
--     of its number and nothing else, so a character holding a booth-shaped number is a
--     character nobody can ring. Those draws are refused rather than handed out.
--
-- Changing this affects new characters. To renumber the ones you already have, see
-- `/phoneadmin renumber` and `Config.Compat.numbers` above.
Config.NumberFormat = '555-####'

-- ══════════════════════════════════════════════════════════════
--  LICENCE NAMES
-- ══════════════════════════════════════════════════════════════
-- What the Wallet calls each licence.
--
-- A licence arrives from your framework as an identifier - `driver`, `cdl`, `fish` - because
-- that is what the script that issues it stores. Most of them carry no label at all, so the
-- Wallet had nothing to show but the identifier, and a wallet listing `cdl` and `fish` is not
-- a wallet.
--
-- The key is the identifier your framework uses. The value is either:
--
--   * a plain label, used exactly as written - the quick way, and right for a server that runs
--     in one language
--   * a locale key (anything starting `ph.`), looked up in the player's own language - add
--     `['ph.lic_cdl'] = ...` to each of your locale files and a bilingual server gets both
--
-- An identifier that is not listed here falls back to whatever label the issuing script gave
-- it, and then to the identifier itself with its separators tidied - so `weapon_license` reads
-- as `Weapon License` even when nobody has configured it.
Config.Licences = {
    -- The ones qb-core, Qbox and ESX hand out between them. Rename freely; delete what your
    -- server does not use - an entry for a licence nobody holds costs nothing either way.
    driver   = 'Driving licence',
    cdl      = 'Heavy goods licence',
    truck    = 'Heavy goods licence',
    motorcycle = 'Motorcycle licence',
    boat     = 'Boating licence',
    pilot    = 'Pilot licence',
    weapon   = 'Firearms licence',
    business = 'Business licence',
    fish     = 'Fishing permit',
    hunting  = 'Hunting permit',
    mining   = 'Mining permit',
    taxi     = 'Taxi licence',
    press    = 'Press card',
    law      = 'Bar licence',
}

-- ══════════════════════════════════════════════════════════════
--  HOW A NUMBER IS DISPLAYED
-- ══════════════════════════════════════════════════════════════
-- Grouping for READING, which is a different question from `Config.NumberFormat` above.
--
-- A number minted as `##########` is stored as `4155550142` and that is what every script
-- reading it gets. But ten digits in a row is not something a person can read back over voice,
-- so the phone can put a separator in **visually** while the stored value is untouched.
--
-- Nothing here changes what is in the database, what is dialled, what is copied to the
-- clipboard, or what any export answers. It is presentation and only presentation.
Config.NumberDisplay = {
    -- Insert a separator every N characters. 0 turns grouping off entirely.
    --
    -- A trailing group of ONE is merged into the one before it, so ten digits at three read
    -- `415-555-0142` rather than `415-555-014-2`. A single orphaned digit looks like a bug
    -- rather than a convention, and "every three" is what somebody means rather than what
    -- they would want literally applied to the last character.
    groupEvery = 3,

    separator = '-',

    -- **A number that already carries its own punctuation is left exactly as it is.**
    --
    -- If `Config.NumberFormat` is `555-####` then the operator has already decided what the
    -- number looks like, and regrouping `555-0142` would produce `555--01-42`. So grouping
    -- only ever applies to a number that is a bare run of letters and digits. Turn this off
    -- to regroup regardless, which strips the existing punctuation first.
    onlyWhenPlain = true,

    -- Whose numbers. `own` is your own number, on the lock screen, in Settings, in Contacts
    -- and where an app asks you to confirm it. `all` extends it to every number the phone
    -- draws - a caller, a contact, a bank card.
    scope = 'own',   -- own | all
}

-- ── Required contacts ─────────────────────────────────────────
-- These entries are injected into every player's Phone and Contacts applications.
-- They cannot be renamed or deleted by a player. Use real numbers handled by your
-- server; an empty list simply disables the feature.
--
-- Available fields: name, number, favourite, photo, email, address, birthday, note.
Config.RequiredContacts = {
    -- { name = 'Police', number = '911', favourite = true, note = 'Emergency line' },
    -- { name = 'Medical services', number = '912', favourite = true },
}

-- ── Messages ───────────────────────────────────────────────────
Config.Messages = {
    maxLength   = 250,      -- characters
    pageSize    = 40,       -- messages loaded per conversation
    retentionDays = 30,     -- 0 keeps everything for ever
}

-- ── Cipher ────────────────────────────────────────────────────
-- Optional end-to-end encrypted roleplay messenger. The server stores routing metadata
-- and encrypted envelopes, never the clear text or a player's private key.
Config.Cipher = {
    maxLength = 700,
    pageSize = 80,
    pinAttempts = 5,
    burnSeconds = { 0, 300, 3600, 86400 },
}

-- ── Calls ──────────────────────────────────────────────────────
-- The phone does NO audio. v-voice owns the Mumble channel; the phone only decides who is
-- talking to whom, and it decides it on the server so that ringing somebody does not
-- depend on the caller knowing where they are.
Config.Calls = {
    ringSeconds = 30,       -- unanswered calls give up after this
    maxMinutes  = 30,       -- hard ceiling on one call, so a forgotten call is not for ever
    -- On speaker, how far the call carries to the people around you. Short: it is a
    -- phone in a hand, not a PA system.
    speakerRange = 8.0,
}

-- ── Apps ───────────────────────────────────────────────────────
-- SEED DATA ONLY: apps live in `world_apps` (owned by v-world) and are enabled, gated and
-- reordered from the admin panel -> Editor -> Apps.
--
-- `owner` is the module the app is a view of, and an app whose owner is stopped is not
-- shown: an app that opens onto nothing is worse than an app that is not there.
-- `owner` is the resource that answers for the app; the home screen hides an app whose owner
-- is not running. Bank, Garage, Property, Wallet and Jobs used to name modules of the
-- author's own suite here - v-banking, v-vehicles and friends - which do not exist on a
-- qb-core, qbx, ESX or ox server. They read the bridge from server files shipped in THIS
-- resource, so v-phone is the honest owner. Whether they appear is `Config.Compat.apps`.
Config.Apps = {
    -- `required` cannot be removed: a phone with no Phone app is a brick, and a phone
    -- with no store cannot get anything back.
    -- `optional` is NOT installed to begin with - it has to be downloaded, which is the
    -- only honest way to make a store mean something.
    -- `category` is what the store sorts by.
    -- The order below IS the home screen on a phone nobody has rearranged yet, and it is
    -- grouped the way a real one ships: the four you reach for without thinking in the
    -- dock, then communication and travel, capture and media, life and work, the small
    -- tools, anything a job unlocks, the downloads, and the store and settings last.
    -- A player who rearranges their apps overrides this; it is only ever the default.
    { id = 'phone',    label = 'app.phone',    icon = 'phone',    owner = 'v-phone',    slot = 1, dock = true,
      required = true, category = 'essentials' },
    { id = 'messages', label = 'app.messages', icon = 'messages', owner = 'v-phone',    slot = 2, dock = true,
      required = true, category = 'essentials' },
    { id = 'contacts', label = 'app.contacts', icon = 'contacts', owner = 'v-phone',    slot = 3, dock = true,
      required = true, category = 'essentials' },
    { id = 'bank',     label = 'app.bank',     icon = 'bank',     owner = 'v-phone',    slot = 4,
      category = 'finance' },
    { id = 'mail',     label = 'app.mail',     icon = 'mail',     owner = 'v-phone',    slot = 5,
      category = 'work' },
    { id = 'maps',     label = 'app.maps',     icon = 'map',      owner = 'v-world',    slot = 6,
      category = 'travel' },
    { id = 'camera',   label = 'app.camera',   icon = 'camera',   owner = 'v-phone',    slot = 7,
      category = 'utilities' },
    { id = 'gallery',  label = 'app.gallery',  icon = 'images',   owner = 'v-phone',    slot = 8,
      category = 'utilities' },
    -- Owned by the phone, not by a radio script. The library, the playlists, the queue and
    -- the favourites are all the phone's own; a deck is only needed to make sound come out,
    -- and the app says so when there is none.
    { id = 'music',    label = 'app.music',    icon = 'music',    owner = 'v-phone',    slot = 9,
      category = 'entertainment' },
    { id = 'garage',   label = 'app.garage',   icon = 'garage',   owner = 'v-phone',    slot = 10,
      category = 'travel' },
    { id = 'property', label = 'app.property', icon = 'house',    owner = 'v-phone',    slot = 11,
      category = 'utilities' },
    -- Police only by default. The operator can open it up, or gate something else the
    -- same way, from Editor -> Phone apps.
    { id = 'wallet',   label = 'app.wallet',   icon = 'wallet',   owner = 'v-phone',    slot = 12,
      category = 'finance' },
    { id = 'jobs',     label = 'app.jobs',     icon = 'jobs',     owner = 'v-phone',    slot = 13,
      category = 'work' },
    { id = 'health',   label = 'app.health',   icon = 'heart',    owner = 'v-status',   slot = 14,
      category = 'health' },
    { id = 'notes',    label = 'app.notes',    icon = 'note',     owner = 'v-phone',    slot = 15,
      category = 'utilities' },
    { id = 'reminders', label = 'app.reminders', icon = 'check',  owner = 'v-phone',    slot = 16,
      category = 'utilities' },
    { id = 'calc',     label = 'app.calc',     icon = 'calc',     owner = 'v-phone',    slot = 17,
      category = 'utilities' },
    { id = 'mdt',      label = 'app.mdt',      icon = 'shield',   owner = 'v-police',   slot = 18,
      -- Job apps get their own aisle: it is only in the store at all for the people
      -- who hold the job, so it has no business sitting under Work next to Jobs.
      job = 'police', category = 'duty' },
    { id = 'bleeter',  label = 'app.bleeter',  icon = 'bleet',    owner = 'v-phone', slot = 19,
      optional = true, category = 'social' },
    { id = 'snap',     label = 'app.snap',     icon = 'snap',     owner = 'v-phone', slot = 20,
      optional = true, category = 'social' },
    { id = 'hush',     label = 'app.hush',     icon = 'hush',     owner = 'v-phone', slot = 21,
      optional = true, category = 'social' },
    { id = 'store',    label = 'app.store',    icon = 'store',    owner = 'v-phone',    slot = 22,
      required = true, category = 'essentials' },
    { id = 'settings', label = 'app.settings', icon = 'settings', owner = 'v-phone',    slot = 23, dock = true,
      required = true, category = 'essentials' },
    -- Downloaded rather than shipped, so it lands after the built-ins instead of
    -- pushing the home screen around on the day a server enables it.
    { id = 'cipher',   label = 'app.cipher',   icon = 'cipher',   owner = 'v-phone',    slot = 24,
      optional = true, category = 'social', version = '1.0' },
}

-- Rich FruitStore catalogue. These are presentation/search hints, not duplicated game
-- logic: every feature below is already backed by the app or the module that owns it.
-- A server may change any wording without touching the renderers.
Config.AppMetadata = {
    phone = {
        features = { 'Clavier et appels', 'Favoris', 'Historique', 'Messagerie vocale', 'Contacts intégrés' },
        keywords = { 'appel', 'numéro', 'favoris', 'répondeur' },
    },
    messages = {
        features = { 'Conversations privées', 'Groupes', 'Photos et GIF', 'Position', 'Réactions et transfert' },
        keywords = { 'sms', 'groupe', 'image', 'localisation', 'emoji' },
    },
    contacts = {
        features = { 'Fiches détaillées', 'Favoris', 'Contacts serveur', 'Photos', 'Partage FruitDrop' },
        keywords = { 'annuaire', 'numéro', 'email', 'adresse', 'anniversaire' },
    },
    bank = {
        features = { 'Solde en direct', 'Comptes', 'Transactions', 'Carte bancaire' },
        keywords = { 'argent', 'compte', 'carte', 'transaction' },
    },
    mail = {
        features = { 'Adresse personnalisée', 'Boîte de réception', 'Messages enregistrés', 'Envoi multiple' },
        keywords = { 'email', 'courrier', 'boîte', 'travail' },
    },
    maps = {
        features = { 'Lieux de la ville', 'Filtres', 'Itinéraire GPS', 'Repères instantanés' },
        keywords = { 'gps', 'garage', 'commerce', 'station', 'itinéraire' },
    },
    camera = {
        features = { 'Capture en jeu', 'Mode paysage', 'Aperçu instantané', 'Accès direct aux Photos' },
        keywords = { 'photo', 'capture', 'paysage' },
    },
    gallery = {
        features = { 'Albums', 'Filtres photo', 'Fond d’écran', 'FruitDrop', 'Suppression sécurisée' },
        keywords = { 'photo', 'album', 'filtre', 'partage', 'fond écran' },
    },
    music = {
        features = { 'Bibliothèque', 'Favoris', 'File d’attente', 'Recherche', 'Sorties audio' },
        keywords = { 'musique', 'radio', 'playlist', 'artiste', 'album' },
    },
    garage = {
        features = { 'Véhicules personnels', 'État en direct', 'Garage actuel', 'Informations du véhicule' },
        keywords = { 'voiture', 'véhicule', 'plaque', 'garage' },
    },
    property = {
        features = { 'Propriétés', 'Locataires', 'Loyer', 'Paiement à distance' },
        keywords = { 'maison', 'appartement', 'loyer', 'logement' },
    },
    wallet = {
        features = { 'Identité', 'Permis', 'Licences', 'Documents officiels' },
        keywords = { 'carte', 'identité', 'permis', 'licence' },
    },
    jobs = {
        features = { 'Emploi actuel', 'Offres disponibles', 'Salaire', 'Échelle des grades' },
        keywords = { 'travail', 'emploi', 'salaire', 'grade' },
    },
    health = {
        features = { 'Signes vitaux', 'Activité', 'Pas et distance', 'Dossier médical', 'Tendances' },
        keywords = { 'santé', 'faim', 'soif', 'stress', 'médical' },
    },
    notes = {
        features = { 'Notes persistantes', 'Création rapide', 'Modification', 'Suppression' },
        keywords = { 'texte', 'mémo', 'brouillon', 'écriture' },
    },
    reminders = {
        features = { 'Listes de rappels', 'Validation rapide', 'Stockage persistant' },
        keywords = { 'tâche', 'liste', 'rappel', 'todo' },
    },
    calc = {
        features = { 'Calculs rapides', 'Décimales', 'Opérations en chaîne', 'Grand affichage tactile' },
        keywords = { 'calcul', 'math', 'addition', 'division' },
    },
    mdt = {
        features = { 'Recherche citoyen', 'Dossiers', 'Mandats actifs', 'Accès métier sécurisé' },
        keywords = { 'police', 'citoyen', 'mandat', 'mdt' },
    },
    bleeter = {
        features = { 'Fil public', 'Publication', 'Photos', 'Mentions J’aime', 'Compte séparé' },
        keywords = { 'réseau', 'bleet', 'publication', 'social' },
    },
    snap = {
        features = { 'Fil photo', 'Légendes', 'Galerie iFruit', 'Mentions J’aime' },
        keywords = { 'photo', 'snapmatic', 'publication', 'social' },
    },
    hush = {
        features = { 'Profils privés', 'Découverte', 'Match mutuel', 'Échange protégé du numéro' },
        keywords = { 'rencontre', 'profil', 'match', 'social' },
    },
    cipher = {
        features = { 'Chiffrement de bout en bout', 'Identité anonyme', 'Messages éphémères', 'Empreinte de sécurité' },
        keywords = { 'privé', 'chiffré', 'illégal', 'anonyme', 'sécurité' },
    },
    store = {
        features = { 'Catalogue complet', 'Recherche avancée', 'Installation', 'Mises à jour', 'Fiches détaillées' },
        keywords = { 'application', 'téléchargement', 'installation', 'catalogue' },
    },
    settings = {
        features = { 'Apparence', 'Clear Glass', 'Sécurité', 'Sons', 'Accessibilité', 'Organisation des apps' },
        keywords = { 'réglages', 'thème', 'face id', 'code', 'fond écran' },
    },
}

-- ── The home screen, in one place ──────────────────────────────
-- `Config.Apps` above is the CATALOGUE: everything that exists. This is the LAYOUT: what
-- a phone opened for the first time actually has, and in what order. It is separate
-- because the two questions are separate, and because an operator changing their mind
-- about the default home screen should not have to edit twenty entries to do it.
--
-- Whatever is written here wins over the `slot`, `dock`, `optional` and `required` fields
-- of the catalogue, so this table is the single answer to "what does a new phone look
-- like". A player who rearranges their apps overrides it in turn; it is only the start.
Config.Home = {
    -- The dock, left to right. Four fits comfortably; five is tight; more is a mess.
    -- These are always installed, whatever `installed` below says.
    dock = { 'phone', 'messages', 'contacts', 'settings' },

    -- Installed on a new phone, in this order, filling the grid after the dock.
    -- **Anything in the catalogue and NOT listed here has to be downloaded from the
    -- FruitStore.** That is how the store is made to mean something: remove a line to
    -- turn an app into a download, add one to ship it.
    --
    -- Bleeter, Snapmatic, Hush and Cipher are deliberately absent: a social account is
    -- something a character chooses to open, not something their phone arrives with.
    installed = {
        'bank', 'mail', 'maps', 'camera', 'gallery', 'music',
        'garage', 'property', 'wallet', 'jobs', 'health',
        'notes', 'reminders', 'calc',
        'mdt',        -- gated to the police by `job` in the catalogue; absent for everyone else
        'store',
    },

    -- Cannot be removed by the player. A phone with no Phone app is a brick, and a phone
    -- with no store can never get anything back.
    required = { 'phone', 'messages', 'contacts', 'store', 'settings' },

    -- Not offered at all: not on the home screen, not in the store, not searchable.
    -- Use this to switch an app off entirely rather than deleting its catalogue entry,
    -- which would lose its metadata and its translations.
    hidden = {},
}

-- Apply the layout to the catalogue. Order of business: drop what is hidden, then let
-- `dock` and `installed` decide slots, and let anything they do not mention become a
-- download. Written as a loop rather than by hand so the two tables cannot drift.
do
    local hidden, required, dock, order = {}, {}, {}, {}
    for _, id in ipairs(Config.Home.hidden or {}) do hidden[id] = true end
    for _, id in ipairs(Config.Home.required or {}) do required[id] = true end
    for i, id in ipairs(Config.Home.dock or {}) do dock[id] = i end
    for i, id in ipairs(Config.Home.installed or {}) do order[id] = i end

    local kept = {}
    for _, app in ipairs(Config.Apps) do
        if not hidden[app.id] then
            local metadata = Config.AppMetadata[app.id] or {}
            app.developer = app.developer or 'iFruit Studio'
            app.version = app.version or '2.0.0'
            app.features = app.features or metadata.features or {}
            app.keywords = app.keywords or metadata.keywords or {}

            app.required = required[app.id] or false
            if dock[app.id] then
                -- The dock comes first and is never a download.
                app.dock = true
                app.optional = false
                app.slot = dock[app.id]
            else
                app.dock = false
                -- Listed means shipped; unlisted means the store has it.
                app.optional = order[app.id] == nil
                -- Dock slots are 1..n, so the grid starts after them and a download
                -- lands past everything shipped rather than in the middle of it.
                app.slot = order[app.id]
                    and (#(Config.Home.dock or {}) + order[app.id])
                    or (100 + #kept)
            end
            kept[#kept + 1] = app
        end
    end
    Config.Apps = kept
end

-- What the store groups by. The order here is the order of the sections.
Config.Categories = { 'social', 'finance', 'utilities', 'travel', 'work', 'duty',
                      'entertainment', 'health', 'essentials' }

-- ── Social ─────────────────────────────────────────────────────
-- Bleeter, Snapmatic and Hush. They used to live in a separate resource because they need
-- something the rest of the phone avoids - data SHARED between players - but a phone that
-- cannot show its own social apps without a second resource running is not a phone, it is
-- half of one. The model lives here now, and the apps are views of it.
--
-- The brands are Rockstar's own: Bleeter and Snapmatic ship in the game.
Config.Social = {
    -- How far back the Explore grid looks, in hours. A week by default: long enough that a
    -- quiet server still has a grid, short enough that it is not a hall of fame.
    exploreHours = 168,

    -- How far back "trending" looks, in hours. A window rather than all time: trending that
    -- never changes is a list of whatever was posted in the server's first week.
    trendingHours = 48,

    enabled = true,

    handleMin = 3,
    handleMax = 20,

    -- ── What a player may write ────────────────────────────────
    postMax    = 280,       -- a bleet
    captionMax = 160,       -- a Snapmatic caption or a story line
    commentMax = 280,
    dmMax      = 500,
    bioMax     = 160,
    feedSize   = 50,        -- newest N per feed

    -- ── How long any of it lives ───────────────────────────────
    -- Every one of these is in DAYS and 0 means "for ever". They are swept once at boot
    -- and then once an hour, so a server left running for weeks trims itself instead of
    -- growing a table nobody looks at. Each kind expires on its own clock, because a
    -- throwaway story and a conversation are not the same thing.
    retention = {
        posts    = 60,      -- bleets and Snapmatic photos
        comments = 60,      -- 0 follows the post they belong to, which is deleted with it
        stories  = 1,       -- a day, the way a story is supposed to work
        messages = 30,      -- direct messages between two handles
        likes    = 0,       -- kept while the post is
    },

    -- Stories are the one thing measured in hours rather than days, because a day is the
    -- whole of their life. `retention.stories` is the sweep; this is what a viewer sees.
    storyHours = 24,

    -- ── Hush ───────────────────────────────────────────────────
    hush = {
        enabled = true,
        dailyLikes = 30,    -- a ceiling, so liking everybody is not a strategy
        -- Super likes per day. The cap IS the feature: a signal anybody can send at will says
        -- nothing at all. One is what Tinder gives away.
        dailySuper = 1,
        -- How long a pass is remembered before that profile can come round again. 0 means
        -- never show them twice.
        passDays = 7,
    },

    -- Avatars, Snapmatic shots and Hush photos are URLs other clients will fetch, so the
    -- hosts are an operator decision - the same rule, and the same list, as wallpapers.
    imageHosts = {
        'i.imgur.com', 'imgur.com',
        'cdn.discordapp.com', 'media.discordapp.net',
        'i.ibb.co', 'raw.githubusercontent.com',
    },
}

-- ── Look ───────────────────────────────────────────────────────
-- The chrome is the phone's; the accent, panel and radius come from v-ui, so a server that
-- themes the framework purple gets a purple phone rather than an orange rectangle in a
-- purple world.
Config.Wallpapers = { 'ifruit', 'aurora', 'lagoon', 'dune', 'grid', 'night', 'ember' }
Config.DefaultWallpaper = 'ifruit'

-- iOS 27's transparency slider, as a starting value: 0 is ultra clear glass, 100 is
-- fully tinted. Players move it themselves in Settings; this is only where they begin.
Config.DefaultGlass = 42

-- ── Custom wallpapers ──────────────────────────────────────────
-- A player may point the phone at an image on the web. That is a URL a client will fetch,
-- so the hosts it may fetch from are an OPERATOR decision, exactly as they are for music.
-- It ships narrow on purpose: an open list is a way to make somebody's client load
-- anything at all.
Config.WallpaperHosts = {
    'i.imgur.com', 'imgur.com',
    'cdn.discordapp.com', 'media.discordapp.net',
    'i.ibb.co', 'raw.githubusercontent.com',
}

-- How a linked image is fitted. `cover` fills the screen and crops; `contain` shows all of
-- it with bars. Both are offered because neither is right for every picture.
Config.WallpaperFit = 'cover'

-- The device itself. Players with small screens want it smaller, and left-handers want it
-- on the other side; neither is worth making them live without.
-- How big the handset is drawn, for everyone. 1.0 is the ONLY value that renders exactly:
-- the phone is laid out in pixels at 372x784, so any other size is a `transform: scale()`
-- over an already-drawn image and the text goes soft. There is no player-facing slider for
-- that reason. Change this if you want a different fixed size and accept the softness.
Config.DeviceSize = 1.0        -- 0.75 .. 1.15, but only 1.0 is pixel-exact
Config.DeviceSide = 'right'    -- right | left

-- ── Mail ───────────────────────────────────────────────────────
-- Addresses are chosen once and belong to the character. The domains are the game's own
-- companies, because inventing a webmail brand would break the world every other module
-- is set in.
Config.Mail = {
    -- The domains offered when a player creates their address. Add, remove or reorder
    -- freely: the first one is simply what the picker starts on, and the server accepts an
    -- address only if its domain is in this list. Existing addresses are never touched by a
    -- change here, so removing a domain stops new sign-ups on it without breaking anyone.
    domains  = { 'ls.com', 'eyefind.info', 'lifeinvader.com', 'bilkinton.com' },

    -- ── Domains only certain jobs may sign up on ───────────────
    -- A public service needs an address that cannot be impersonated. `@lspd.gov` is worth
    -- nothing if any player can take `chief@lspd.gov` before the actual chief does.
    --
    -- The key is the domain, the value is the list of jobs allowed on it. A reserved domain
    -- does NOT need to be in `domains` above and should not be: that list is what everybody
    -- is offered, and this one is only offered to whoever qualifies. Both are checked on the
    -- server, so a client asking for a domain it was never shown is refused.
    --
    -- **An address already created survives the player losing the job.** A dismissed officer
    -- keeping their `@lspd.gov` address is a roleplay matter to settle in character, not a
    -- mailbox for a script to delete behind them - and revoking it would silently break every
    -- thread they are part of. Take the job away and they simply cannot make a NEW one.
    -- Two shapes, because two different things get asked for:
    --
    --   a list of jobs          any grade of that job qualifies
    --   a job -> minimum grade  only from that grade upwards
    --
    -- Mix them freely in the same table, and mix them inside one domain: a list entry means
    -- "any grade", a `job = n` entry means "grade n or higher". So a domain every officer may
    -- use and one only command staff may use are both expressible, and so is a domain the whole
    -- of one force shares with only the chiefs of another.
    reserved = {
        -- ['lspd.gov']    = { 'police', 'sheriff', 'bcso' },
        -- ['ems.gov']     = { 'ambulance', 'ems' },
        -- ['ls.gov']      = { 'judge', 'mayor', 'government' },
        -- ['weazel.news'] = { 'reporter', 'journalist' },

        -- Command staff only. Grade 4 and above of the police, any grade of `chief`.
        -- ['command.lspd.gov'] = { police = 4, 'chief' },
    },

    -- ── How many addresses one character may hold ──────────────
    -- One is the classic mailbox. More is what somebody actually wants: a personal address and
    -- a work one, kept apart, switched between in the app.
    --
    -- There is no "active address" stored anywhere. The page names which of its addresses it is
    -- acting as on every request, and the server checks that the address belongs to the caller
    -- - which is both simpler than a stored pointer and stricter, because there is no state to
    -- get out of step with the truth.
    maxAccounts = 3,

    -- ── A domain a player buys ─────────────────────────────────
    -- The state's domains are yours to define in `reserved` above. This is the other half: a
    -- player registering a domain of their own, for a company or a newspaper, by paying for it.
    --
    -- Owning a domain lets THAT player create addresses on it. It does not let them hand
    -- addresses to other people - that is a company directory, a bigger feature than this, and
    -- pretending to offer it would be worse than not.
    custom = {
        enabled = false,       -- off by default: a server should decide to sell something
        price   = 25000,
        account = 'bank',      -- which account the money comes out of
        minLen  = 4,
        maxLen  = 24,

        -- Words a player may not register, checked as a whole label and as any dot-separated
        -- part of one. The point is that a bought domain must never be able to READ like a
        -- public service: `police.ls` and `ls-police.com` are both refused by this list.
        --
        -- A domain already in `domains` or `reserved` is refused regardless of this list, so
        -- there is no need to repeat them here.
        blocked = {
            'gov', 'gouv', 'police', 'lspd', 'bcso', 'sheriff', 'ems', 'ambulance',
            'sams', 'fib', 'iaa', 'state', 'etat', 'mairie', 'city', 'justice',
            'court', 'tribunal', 'prison', 'admin', 'staff', 'ifruit', 'phone',
        },
    },

    -- Attach an image to a mail: one picked from the phone's own gallery, or a link.
    --
    -- The URL faces every recipient's client, so it goes through the same host allowlist as a
    -- wallpaper or an avatar - `Config.Media.hosts`. Off refuses both, and an existing mail
    -- that carries one still shows it.
    images = true,
    maxSubject = 80,
    maxBody    = 2000,
    maxTo      = 10,       -- a group mail, not a mailing list
    localMin   = 3,
    localMax   = 20,
}

-- ── Sounds ─────────────────────────────────────────────────────
-- Ringtones and alerts are played by the page, not by the game, so a player can point one
-- at their own MP3. The built-ins are synthesised in the browser - no audio ships with the
-- resource, and nothing is fetched unless somebody chose a link.
--
-- A custom tone is a URL a client will fetch, so the hosts are an operator decision, the
-- same rule as wallpapers and avatars.
Config.Sounds = {
    -- `signal` and `note` are the two that only exist as shipped files; everything else
    -- has a synthesised fallback of the same name.
    ringtones = { 'classic', 'chime', 'pulse', 'radar', 'signal', 'none' },
    alerts    = { 'ping', 'pop', 'tick', 'note', 'none' },

    -- Use the WAV files in `sounds/` rather than synthesising the tones in the browser.
    -- They are generated, not sampled: `python tools/make-sounds.py` rebuilds all of
    -- them, so changing a melody is changing a table in that script.
    --
    -- Off falls back to the oscillators, which is also what happens automatically if a
    -- file is missing. A phone always rings.
    files = true,

    allowCustom = true,
    hosts = {
        'cdn.discordapp.com', 'media.discordapp.net',
        'raw.githubusercontent.com', 'github.com',
        'files.catbox.moe', 'i.imgur.com',
    },
}

-- ── AirDrop ────────────────────────────────────────────────────
-- Send a contact, your number or a photo to a nearby phone. Both ends must have
-- Bluetooth on in the control centre, and be within range - the same two conditions the
-- real thing needs to see a device at all.
Config.Airdrop = { range = 12.0, offerTtl = 30 }

-- ── Battery ────────────────────────────────────────────────────
-- Eight real-world hours from full to flat, which is roughly what a phone does. The
-- number is a setting because "how long is a session here" is a server's answer, not
-- ours.
--
-- **It only drains while the player is connected.** A phone genuinely goes flat in a
-- drawer, but so does the ability to charge it: coming back from a week away to a dead
-- phone and no way to have prevented it is a punishment for logging off.
Config.Battery = {
    -- These are the fallbacks the code uses when Config.Settings has no answer; keep them
    -- in step with it or the two disagree the moment somebody clears a setting.
    hoursToEmpty = 72.0,    -- idle, phone closed: three days
    screenMultiplier = 1.5, -- with the screen on, so about two days of actual use
    chargeMinutes = 45.0,   -- flat to full at a charger
    lowAt = 20,             -- first warning
    criticalAt = 5,
}

-- Charging happens at these, and also in any vehicle and inside a property you hold a key
-- to. Those two are code, because they follow the player rather than a coordinate.
-- SEED DATA ONLY: chargers live in `world_chargers` and are edited from the admin panel.
--
-- A charger can COST money. Give a row a `price` and the phone asks before it charges - see
-- Config.PaidCharging below. `account` overrides where that money goes, so the airport's
-- kiosks can pay the airport and the hospital's can pay the hospital.
Config.Chargers = {
    { id = 'ch_lsia',      label = 'LSIA, arrivals hall',    x = -1037.0, y = -2737.0, z = 20.2, radius = 8.0,
      -- The paid example. Delete `price` and this charger is free like the rest.
      price = 40, account = 'airport' },
    { id = 'ch_legion',    label = 'Legion Square kiosk',    x = 195.0,   y = -933.0,  z = 30.7, radius = 6.0 },
    { id = 'ch_pillbox',   label = 'Pillbox Hill Medical',   x = 306.0,   y = -595.0,  z = 43.3, radius = 8.0 },
    { id = 'ch_paleto',    label = 'Paleto Bay, sheriff',    x = -448.0,  y = 6013.0,  z = 31.7, radius = 6.0 },
    { id = 'ch_sandy',     label = 'Sandy Shores, clinic',   x = 1839.0,  y = 3672.0,  z = 34.3, radius = 8.0 },
    { id = 'ch_vespucci',  label = 'Vespucci boardwalk',     x = -1223.0, y = -1493.0, z = 4.4,  radius = 6.0 },
}

-- ══════════════════════════════════════════════════════════════
--  PAID CHARGING
-- ══════════════════════════════════════════════════════════════
-- A public charger that takes money.
--
-- The phone asks, the player accepts or refuses, and one payment buys the whole stop: they
-- charge for as long as they like and pay again only if they LEAVE the zone and come back.
-- Nothing here is per-minute, on purpose - a meter that ticks while somebody is stood at a
-- kiosk is a thing to watch rather than a thing to forget about.
--
-- The offer is sent from the server, from the ped's real position, and accepting is checked
-- again there: a client cannot claim to be at a charger it is not standing at.
Config.PaidCharging = {
    -- Off leaves every charger free, whatever prices the rows above carry.
    enabled = true,

    -- What a stop costs at a charger whose row names no `price` of its own. 0 means the
    -- default is free and only the rows that say otherwise charge.
    price = 0,

    -- Which purse pays: 'cash' or 'bank'. A kiosk that takes a card is 'bank'.
    money = 'cash',

    -- Where the money GOES: a job or society account name. The phone credits it through
    -- your banking script (qb-banking, Renewed-Banking, okokBanking, esx_addonaccount) or
    -- through Config.Compat.hooks.society.
    --
    -- '' pays nobody: the money leaves the player and the operator is scenery. A charger
    -- row's own `account` wins over this, so different sites can pay different owners.
    account = '',

    -- A refusal is remembered this long, so walking past a charger you have already said no
    -- to does not ask again every few seconds. Seconds.
    refusedFor = 90,

    -- How long the offer stands before it expires on its own. Seconds.
    offerSeconds = 45,

    -- How often the server looks for a player standing at a paid charger. The offer cannot
    -- arrive faster than this, so it is the responsiveness of the whole feature - and it is
    -- a handful of distance checks per player, which is nothing.
    checkSeconds = 4,

    -- Charge nothing when the battery is already this full. Somebody who walks past with a
    -- nearly-full phone is not a customer, and being asked anyway is just noise. 101 asks
    -- always; 100 skips only a phone that is completely full.
    skipAbove = 95,
}

-- Where the network does not reach. `bars` is the CEILING inside the zone: 0 means no
-- service at all. Real places, chosen because they are places a story would put you.
-- SEED DATA ONLY: edited from the admin panel -> Editor -> Dead zones.
Config.DeadZones = {
    { id = 'dz_chiliad',   label = 'Mount Chiliad',          x = 501.0,   y = 5604.0,  z = 797.0, radius = 700.0, bars = 0 },
    { id = 'dz_raton',     label = 'Raton Canyon',           x = -1500.0, y = 4400.0,  z = 40.0,  radius = 500.0, bars = 0 },
    { id = 'dz_zancudo',   label = 'Fort Zancudo',           x = -2100.0, y = 3200.0,  z = 32.0,  radius = 900.0, bars = 0 },
    { id = 'dz_humane',    label = 'Humane Labs',            x = 3600.0,  y = 3700.0,  z = 30.0,  radius = 400.0, bars = 0 },
    { id = 'dz_wilderness',label = 'Chiliad Wilderness',     x = -700.0,  y = 5000.0,  z = 100.0, radius = 900.0, bars = 1 },
    { id = 'dz_senora',    label = 'Grand Senora Desert',    x = 1400.0,  y = 2800.0,  z = 60.0,  radius = 800.0, bars = 1 },
    { id = 'dz_tunnel_ls', label = 'Los Santos tunnels',     x = 800.0,   y = -1300.0, z = -40.0, radius = 260.0, bars = 0 },
    { id = 'dz_mine',      label = 'Davis Quartz',           x = 2900.0,  y = 2800.0,  z = 40.0,  radius = 350.0, bars = 1 },
}

-- ══════════════════════════════════════════════════════════════
--  ADMIN
-- ══════════════════════════════════════════════════════════════
-- Staff actions on a player's phone, from the console, an ACE-gated command, or the
-- qb-core admin menu. Every one of them is also an export (see API.md), so an admin menu
-- of any framework can drive them.
-- ══════════════════════════════════════════════════════════════
--  LOGGING
-- ══════════════════════════════════════════════════════════════
-- What the resource says on the way up.
--
-- Everything here is OFF, and the reason is worth stating: a resource that prints twenty
-- lines at every start teaches an operator to scroll past its output, and then the one line
-- that mattered scrolls past too. Problems always print - a framework that was named but is
-- not running, a table that could not be read, a callback with no handler. These switches
-- only govern the lines that are merely true.
-- ══════════════════════════════════════════════════════════════
--  THE CLOCK
-- ══════════════════════════════════════════════════════════════
-- What the status bar, the lock screen and the control centre show.
--
-- It reads the PLAYER'S OWN MACHINE by default, which means somebody connecting from another
-- country sees their time and not the city's - two characters standing next to each other
-- disagree about what time it is. Naming a zone here gives everybody the same clock.
--
-- Any IANA name: 'Europe/Paris', 'America/New_York', 'Australia/Sydney'. Empty keeps the
-- player's own machine. A name the browser does not recognise falls back to the machine
-- rather than stopping the clock.
Config.Clock = {
    timezone = 'Europe/Paris',
}

-- ══════════════════════════════════════════════════════════════
--  THE NETS UNDER THE PHONE
-- ══════════════════════════════════════════════════════════════
-- Nothing here adds a feature. Every switch is a way of not being stuck with a cursor you
-- cannot get rid of, which is the one bug a phone must not have: a player who cannot close it
-- cannot play, and their only remaining move is to reconnect.
--
-- Leave these on. They are here as switches only because a server that finds one of them
-- fighting its own scripts should be able to turn that one off rather than the phone.
-- See bridge/client/safety.lua.
Config.Watchdog = {
    -- Once a second: if the cursor is held and nothing on this phone wants it, let it go.
    -- Two consecutive checks, so the frame between opening and being open is not mistaken
    -- for a stuck phone.
    enabled = true,

    -- Dying with the phone open used to leave it open, over a death screen that cannot be
    -- clicked through. Off if your server deliberately keeps the phone usable while down.
    closeOnDeath = true,
}

Config.Log = {
    -- The boot summary: framework detected, which app groups are on, the bank, the payphones,
    -- the admin command, each app folder loaded. Useful exactly once, when setting a server up.
    -- `set phone_verbose true` in server.cfg turns it on without editing this file.
    boot = false,

    -- The PAGE's tracing, in the browser console (F8): what each layer paints and its computed
    -- style, which inputs decided the camera, whether a keypress reached the page, when free
    -- look goes on and off. Perhaps forty lines every time an app opens.
    --
    -- Off, and it has to stay off on anything but a machine you are debugging on. It is
    -- genuinely useful when a screen renders wrong and useless noise the rest of the time -
    -- and F8 is also where a player's own errors appear, so filling it hides those.
    --
    -- `setr phone_debug true` turns it on without editing this file. `setr`, not `set`: the
    -- page reads it client-side and a plain `set` never reaches a client.
    debug = false,
}

-- ══════════════════════════════════════════════════════════════
--  A PHONE HEARD RINGING
-- ══════════════════════════════════════════════════════════════
-- A ringing phone is a sound in the room, not a private notification. Somebody standing next to
-- a player whose phone goes off should hear it - that is how a phone gives its owner away, and
-- it is worth having for exactly that reason.
Config.RingOut = {
    enabled = true,

    -- How far it carries, in metres. GTA's own phone ring is a quiet sound; much past ten
    -- metres and it is inaudible anyway, so this mostly decides who gets told about it.
    range = 12.0,

    -- A phone on Do Not Disturb, or with its ring volume at zero, makes no sound for its owner
    -- and makes none here either. Silencing a phone that still rings out loud would be worse
    -- than not having the feature.
    respectSilent = true,
}

Config.Admin = {
    -- The ACE permission a command or menu action is checked against. `command.PLAYERID`
    -- style aces and qb-core's `qbadmin.menu` / god group are both accepted; this is the
    -- one the phone registers its own commands under.
    ace = 'vphone.admin',

    -- Register the `/phoneadmin` command set. Off leaves only the exports, for a server
    -- that drives everything from its own menu.
    commands = true,

    -- Print, at boot, the one line an operator needs to add the phone's staff menu to
    -- qb-adminmenu.
    --
    -- It does not add entries to that menu itself, and it never could: qb-adminmenu builds
    -- its menu from locals in its own client file, and nothing outside that file can reach
    -- them. The phone's staff menu is its own, opened by `/phoneadmin` with no arguments,
    -- drawn through ox_lib or qb-menu - whichever is running.
    qbAdminMenu = true,

    -- What staff may do. Turn any of these off to hide it from the command and the menu.
    actions = {
        openRemote   = true,   -- open a player's phone on their screen (support)
        -- Grant or revoke the verified badge on a Bleeter or Snapmatic account. Off leaves
        -- nobody able to hand one out, including through the export.
        verify       = true,
        setBattery   = true,
        setNumber    = true,
        wipe         = true,   -- delete every trace of a character's phone data
        sendMessage  = true,   -- send them a service message
        readInfo     = true,   -- number, battery, unread count, social handles
        -- Cut the network: globally, or inside a circle. `/phoneadmin outage`.
        -- Also reachable from another script through the AddOutage export, for a heist
        -- that jams a block or a storm that drops the whole map to one bar.
        outage       = true,
        -- Take one handset out of service. Not an outage - the network is fine, the phone
        -- is not - for a phone that was smashed, confiscated or is dead for a scene.
        brick        = true,
        -- Install or remove an app on a character's phone.
        apps         = true,
        -- A banner on their phone, which is not the same thing as a text message: it does
        -- not persist, and it does not come from a number.
        notify       = true,
        -- **Hold another character's phone on your own screen, as them.** Their messages,
        -- their contacts, their bank, their apps - and anything done while holding it is done
        -- as them. It is the support tool, and it is also the most powerful thing in this
        -- list: every session is logged with both names, and it expires on its own.
        --
        -- Off leaves staff with the read-only routes: `info`, `contacts`, `apps`, and the
        -- police forensics terminal.
        view         = true,
    },

    -- How long a held phone stays held before it lets go on its own. Seconds.
    --
    -- It expires because forgetting is the realistic failure: a staff member walks away with
    -- somebody else's phone still open on their screen, and the next thing they type goes out
    -- under that character's name.
    viewSeconds = 600,

    -- ── The emergency alert ────────────────────────────────────
    -- A loud broadcast to every phone on the server: an earthquake, a wildfire, a citywide
    -- evacuation.
    --
    -- It arrives as a notification, and two things about it are true of nothing else on this
    -- phone: the buzz ignores Do Not Disturb and the sound ignores the player's own ring
    -- volume. That is exactly why it is behind the staff ace and its own switch. A channel
    -- that overrides somebody's silence has to be hard to reach, or it will be used for
    -- things that are not emergencies and then muted along with everything else.
    emergency = true,

    -- Accept the bare `command` ace as proof of being staff.
    --
    -- OFF, and it used to be on. `IsPlayerAceAllowed(src, 'command')` is true for anybody
    -- granted ANY command at all, which on many servers includes moderators, trusted
    -- players and donors - none of whom were meant to be able to wipe a character's phone
    -- or cut the network for everybody. Turn it back on only if your staff genuinely have
    -- no other ace, and prefer `add_ace group.admin vphone.admin allow` instead.
    aceCommandFallback = false,

    -- Draw the alert as a card over the WHOLE screen as well as sounding it.
    --
    -- Off. It used to be the only behaviour, and a screen-filling warning triangle is a lot of
    -- screen for something a phone announces - what makes an alert impossible to miss is the
    -- hard buzz and the tone that ignores the volume setting, both of which happen either way.
    -- On for a server that wants the takeover.
    emergencyFullScreen = false,

    -- Wiping is destructive. Require a second confirmation in the command flow.
    confirmWipe = true,
}

-- ══════════════════════════════════════════════════════════════
--  EXTERNAL CHARGING
-- ══════════════════════════════════════════════════════════════
-- Another script can charge the phone: an electric car, a solar backpack, a wall socket
-- prop. It calls `exports['v-phone']:SetCharging(src, on, rate)` and the phone treats the
-- player as if they were at a charger for as long as `on` is true. See API.md.
Config.ExternalCharging = {
    -- The default rate an external charger applies when it does not name one. 1.0 is the
    -- same speed as a wall charger; 2.0 is twice as fast.
    defaultRate = 1.0,
    -- A ceiling, so a misbehaving script cannot charge a phone in one tick.
    maxRate = 4.0,
}

-- ══════════════════════════════════════════════════════════════
--  POLICE FORENSICS
-- ══════════════════════════════════════════════════════════════
--  THE HEALTH RECORD
-- ══════════════════════════════════════════════════════════════
-- Blood group, allergies, conditions, medication, next of kin, organ donor. A player writes
-- their own; this is about who else may see it.
Config.HealthRecord = {
    -- Let a player hand their record to somebody standing next to them, over FruitDrop. Their
    -- own record and nobody else's, and the other person has to accept it.
    share = true,

    -- ── Jobs that may READ a record without being handed it ────
    -- A paramedic treating an unconscious player cannot ask them for their blood group. So a
    -- job on this list gets a fourth tab in the Health app listing everybody nearby, and can
    -- open the record of any of them.
    --
    -- Same two shapes as `Config.Mail.reserved`: a list means any grade of that job, a
    -- `job = n` entry means grade n or higher, and both may be mixed.
    --
    --   readers = { 'ambulance', 'ems' }        every medic
    --   readers = { ambulance = 3 }             only from grade 3
    --   readers = { 'ambulance', police = 6 }   medics, plus police command
    --
    -- **This is a real privacy decision, so it ships EMPTY.** A record holds a person's
    -- medical history; who may read it without being handed it is not something to default on
    -- somebody's behalf.
    readers = {},

    -- How close a reader has to be, in metres. A record is read at the patient's side, not
    -- from across the city - and this is checked on the server, from real positions, so a
    -- modified client cannot ask about somebody it is nowhere near.
    readRange = 5.0,

    -- Tell the patient their record was read, and by whom.
    --
    -- ON, and deliberately: a record that can be read silently is a record whose owner has no
    -- way of knowing it happened. Turn it off only if your server has decided that medics
    -- reading records is routine enough not to mention.
    notifyOwner = true,
}

-- ══════════════════════════════════════════════════════════════
--  HOSPITALS
-- ══════════════════════════════════════════════════════════════
-- The Health app's third tab. A list you control: what your server calls its hospitals, and
-- where they are, because that is a map decision rather than something a phone can work out.
--
-- Tapping one sets a waypoint. Leave `x` and `y` off an entry and it is still listed with its
-- address, it simply cannot be pointed at - useful for a clinic somebody has to be told
-- about but that has no door on the map.
--
-- The defaults are the five medical centres GTA ships, at the coordinates FiveM scripts
-- generally use for their doors. They are a starting point: check them against your own map
-- and your own MLOs, because an interior replaced by an MLO often moves the entrance.
-- Set this to `{}` and the tab disappears.
Config.Hospitals = {
    { label = 'Pillbox Hill Medical Center', address = 'Strawberry Avenue, Pillbox Hill',
      x = 298.6,  y = -584.7 },
    { label = 'Mount Zonah Medical Center',  address = 'Roy Lowenstein Boulevard, Rockford Hills',
      x = -449.7, y = -340.8 },
    { label = 'Central Los Santos Medical',  address = 'Elgin Avenue, Davis',
      x = 341.0,  y = -1397.3 },
    { label = 'Sandy Shores Medical Center', address = 'Alhambra Drive, Sandy Shores',
      x = 1839.6, y = 3672.9 },
    { label = 'Paleto Bay Care Center',      address = 'Paleto Boulevard, Paleto Bay',
      x = -247.8, y = 6331.4 },
}

-- ══════════════════════════════════════════════════════════════
--  PROPERTY
-- ══════════════════════════════════════════════════════════════
-- The Property app lists the houses a character owns and points at them on the map. It
-- reads your housing script through the bridge - qb-houses, ps-housing, Quasar's, ESX's -
-- and needs nothing here to do that.
--
-- What it CANNOT know is where somebody goes to buy one, because that is a decision you
-- made when you placed the estate agent. So you say it here, and the app's second tab sends
-- players there.
Config.Property = {
    -- The estate agent. `x` and `y` are what the button sets a waypoint to; leave them out
    -- and the tab still explains where to go, it just cannot mark it.
    --
    -- The default is Dynasty 8's office on Portola Drive, which is where GTA's own property
    -- signs point and where most servers put theirs.
    agent = {
        label = 'Dynasty 8',
        address = 'Portola Drive, Rockford Hills',
        x = -718.06,
        y = 261.28,
    },

    -- Houses whose position your housing script does not expose - Quasar keeps its own
    -- behind an escrowed core - so the app can still point at them. Keyed by the house id or
    -- name the script uses.
    --
    --     houses = { ['1'] = { label = 'Mirror Park 12', x = 1234.5, y = -567.8 } },
    houses = {},
}

-- ══════════════════════════════════════════════════════════════
--  GARAGES
-- ══════════════════════════════════════════════════════════════
-- Only needed to OVERRIDE. The Garage app reads your garage script's own config for the
-- name and position of each garage - qb-garages and its forks all keep
-- `Config.Garages.<key> = { label = ..., takeVehicle = vector3(...) }`, and that is read
-- straight from the file - so most servers need nothing here.
--
-- Fill it in when the script keeps its garages somewhere unreadable (an escrowed build), or
-- when you want your own names. Anything listed here wins over what the script says.
--
--     Config.Garages = {
--         motelgarage = { label = 'Motel Parking', x = 274.29, y = -334.15 },
--     }
--
-- `x` and `y` are what the "Locate" button sets a waypoint to. Leave them out and the app
-- still shows the name, it just cannot point at it.
Config.Garages = {}

-- ══════════════════════════════════════════════════════════════
--  BANK
-- ══════════════════════════════════════════════════════════════
-- The bank app reads the balance your framework already keeps - qb-core, qbx, ESX, ox, or
-- whatever banking script is running - through the bridge. Nothing here needs a companion
-- resource, and nothing here invents an account: the phone is a window onto the money the
-- server already believes in.
--
-- What it ADDS is the phone part: a statement, transfers between characters, and a list of
-- saved beneficiaries. Those are the phone's own, kept in its own tables, because no
-- framework has them.
Config.Bank = {
    enabled = true,

    -- Transfers, character to character, from the bank balance. Off leaves the app a
    -- read-only statement, which is what a server with its own banking UI usually wants.
    transfers = true,

    -- The bounds of one transfer. `max = 0` means no ceiling.
    minAmount = 1,
    maxAmount = 100000,

    -- A cut the bank takes, as a percentage of the amount, rounded down. 0 for none. The
    -- sender pays it on top: sending 1000 at 1.5% costs 1015 and delivers 1000, so the
    -- number the recipient was promised is the number they get.
    feePercent = 0,

    -- How much one character may send per real day, 0 for no limit. Counted on the phone's
    -- own ledger, so it cannot be walked around by closing the app.
    dailyLimit = 0,

    -- Paying somebody who is not connected. On: the money leaves the sender now and is
    -- held by the phone until that character next looks at their bank, then credited once.
    -- Off: the transfer is refused with "they are not connected".
    --
    -- On is the honest default. The alternative is a transfer that silently does nothing
    -- because the recipient logged off between choosing them and pressing send.
    offlineTransfers = true,

    -- Saved beneficiaries per character.
    maxFavourites = 25,

    -- ── Being told when money arrives ──────────────────────────
    -- A banking app that says nothing when you are paid is not a banking app. The phone
    -- listens to the framework's own money events, so a salary, a society payout or a shop
    -- refund raises a banner with the bank's icon on it.
    --
    -- Instant and with a reason attached on qb-core, qbx_core and ESX, which all announce
    -- their money changes. ox_core has no equivalent event - see `pollSeconds`.
    notify = {
        enabled = true,

        -- Ignore anything smaller, so a one dollar tip is not a notification.
        minAmount = 1,

        -- Announce money LEAVING too. Off by default: most servers already have a HUD that
        -- flashes spending, and a phone buzzing at every purchase gets muted.
        outgoing = false,

        -- Write a statement line for money the phone did not move itself.
        --   'auto'  only when no dedicated banking script is running (the default: with one
        --           present that line already exists in its history, which the statement
        --           merges, so writing a second would show every salary twice)
        --   true    always      false   never
        record = 'auto',

        -- The fallback for a framework with no money event, ox_core in practice: sample the
        -- balance every N seconds and announce what changed. 0 is off, and off is right on
        -- qb, qbx and ESX where the events above are instant and carry a reason. The
        -- minimum is 15 seconds; it costs one balance read per online player per interval.
        pollSeconds = 0,
    },

    -- How many statement lines the app shows, and how long the phone keeps its own.
    historyLimit = 50,
    retentionDays = 60,       -- 0 keeps them for ever
}

-- ══════════════════════════════════════════════════════════════
-- A warrant terminal: police walk to a point on the map and, with the target's number,
-- read what is on that phone. Everything that is stored in the clear - texts, contacts,
-- the call log, mail, social posts and DMs - is theirs to read.
--
-- Cipher is different, and honestly so. Its messages are end-to-end encrypted: the key
-- lives on the sender's and recipient's devices, never on the server, so NOBODY on the
-- server can read the content - not the operator, not the police. The terminal shows the
-- metadata that IS recoverable (who spoke to whom, when, how often, the key fingerprints)
-- and, if you opt into lawful intercept below, a deliberately hard crack of the content.
Config.Police = {
    enabled = true,

    -- Who may use the terminal. Same list style as the MDT app. Empty means no one.
    jobs = { 'police', 'sheriff', 'bcso', 'sast' },

    -- A minimum rank on that job, 0 for any. Keeps a cadet out of the wiretap room.
    minGrade = 0,

    -- An item the officer must carry to start a session, or nil for none. A "forensic
    -- kit", a warrant, a laptop - whatever your server calls it.
    item = nil,

    -- How the terminal is opened.
    --
    -- `key` is ALWAYS live, and that is deliberate. The target-script route was the only way
    -- in when one was running, and on a server where the zone did not register - a target
    -- version whose signature moved, a job check somewhere in the middle - the terminal was
    -- simply unreachable with nothing on screen to say so. Walking up and pressing a key is
    -- the route that cannot fail quietly.
    key = 38,              -- E. Any control id from the FiveM list.
    marker = true,         -- draw the small marker at each point
    helpText = true,       -- and the "[E] Forensic terminal" prompt when you are in range
    useTarget = true,      -- also register an ox_target/qb-target zone when one is running

    -- The terminals. Interact within `radius` - by key press, and by target when a target
    -- script is running.
    points = {
        { label = 'Mission Row - Digital Forensics', x = 484.6, y = -996.5, z = 30.7, radius = 1.5 },
        { label = 'Sandy Shores Sheriff - Tech Bench', x = 1853.0, y = 3689.5, z = 34.3, radius = 1.5 },
        { label = 'Paleto Bay Sheriff - Evidence',    x = -448.5, y = 6012.0, z = 31.9, radius = 1.5 },
    },

    -- A session lasts this long before the officer must re-authorise at the terminal, so
    -- a warrant is not a permanent tap. Seconds.
    sessionSeconds = 300,

    -- Log every lookup to the server console (and to your framework log if it has one),
    -- so a wiretap leaves a paper trail an admin can audit.
    log = true,

    cipher = {
        -- Lawful intercept. OFF by default, on purpose: leaving it off keeps Cipher a
        -- true end-to-end secret that the police tool can describe but never read, which
        -- is the promise the app makes to players.
        --
        -- ON changes the deal: the phone keeps a recoverable copy of each Cipher message
        -- so the terminal CAN crack the content - slowly, and not always. Turn this on
        -- only if your server wants an encrypted app the police can eventually break.
        intercept = false,

        -- The crack, when intercept is on. Deliberately expensive.
        crackSeconds = 20,       -- real seconds of "processing" per message
        successChance = 0.6,     -- and it can still fail, so it is never a sure thing
    },
}

-- ══════════════════════════════════════════════════════════════
--  MEDIA  (photos and video hosting)
-- ══════════════════════════════════════════════════════════════
-- Where the camera's photos and the social apps' videos are hosted. By default the phone
-- keeps photo URLs a player pastes and nothing else; turn this on to capture and upload
-- to a CDN so a photo taken in game has a real link.
--
-- The upload runs on the SERVER through the `screencapture` resource, so the API key
-- never reaches a client. Install it: https://github.com/itschip/screencapture
Config.Media = {
    -- Off leaves the camera taking local gallery photos only, and hides video recording.
    --
    -- `set phone_media true` in server.cfg overrides this either way. Prefer it: this is the
    -- one feature whose configuration carries a secret, and the convar lets you switch it on
    -- in the same file that holds the key, without editing a tracked file to do it.
    enabled = false,

    -- 'fivemanage' is the one wired here. 'custom' posts to `endpoint` with `headers`,
    -- for any host that takes a multipart file and answers with a URL.
    provider = 'fivemanage',

    -- The upload endpoint. Fivemanage's v3 file API takes both images and video.
    endpoint = 'https://api.fivemanage.com/api/v3/file',

    -- Your API key. Prefer the convar so it stays out of the repo:
    --     set phone_media_key "fm_xxxxxxxx"
    -- A value here is used only when the convar is unset.
    apiKey = '',

    -- The multipart field name the endpoint expects. Fivemanage uses `file`.
    formField = 'file',

    -- Image encoding for photos: 'webp' (small), 'jpg', or 'png'.
    imageEncoding = 'webp',

    -- ── Video recording: OFF ───────────────────────────────────
    -- `video = nil` removes it entirely: the Video tab is not drawn, the record button does
    -- not exist, and the server refuses a recording request even if one arrives.
    --
    -- Turned off because it does not work well enough to ship. screencapture records in the
    -- player's own browser and streams it to the server, and on a real connection that means
    -- a visible stall while it runs plus a `stream-finalize` failure often enough to be the
    -- normal outcome rather than an edge case - the clip is lost after the player has already
    -- stood still for fifteen seconds.
    --
    -- Photographs are unaffected: they are a single frame and they work.
    --
    -- To try it again, restore the table below. Nothing else has to change - every part of the
    -- feature is still here and reads this switch.
    --
    --  video = {
    --      maxSeconds = 15,       -- hard ceiling, 1..30
    --      maxWidth = 1280,
    --      maxHeight = 720,
    --  },
    video = nil,

    -- ── Auto-deletion ──────────────────────────────────────────
    -- The phone tracks every file it uploaded in `vphone_media` and removes it after this
    -- many days: the row goes, and the file is deleted from the host if `deleteEndpoint`
    -- is set. 0 keeps everything for ever.
    --
    -- Fivemanage also has its own retention; this is the phone's own clock on top of it,
    -- so a server keeps control even if it changes host.
    autoDeleteDays = 30,

    -- How the host deletes a file, if it can. `{id}` and `{url}` are filled in. Left
    -- empty, the phone only forgets the file (drops the row) and leaves the host to its
    -- own retention. Fivemanage v3 deletes by id.
    deleteEndpoint = 'https://api.fivemanage.com/api/v3/file/{id}',
    deleteMethod = 'DELETE',

    -- Extra headers for a 'custom' provider. For Fivemanage the Authorization header is
    -- added from the key automatically.
    headers = {},
}

-- ══════════════════════════════════════════════════════════════
--  FACETIME  (experimental live video feed)
-- ══════════════════════════════════════════════════════════════
-- A FaceTime call is always a real voice call. With `videoFeed` on, it ALSO streams a
-- live picture between the two phones: each side captures its front camera a few times a
-- second, shrinks the frame to something tiny, and relays it to the other phone through
-- the server. It is the same trick the paid phones use.
--
-- **Experimental, and off by default, for good reasons:**
--   * it needs `screenshot-basic`,
--   * it moves image data through the network every frame, so it costs bandwidth - the
--     defaults are deliberately small (a thumbnail, a few frames a second),
--   * screenshot-basic itself warns against sending screenshots through events, which is
--     why the frame is shrunk hard in the page before it is ever sent, and why the server
--     caps the size and the rate and drops anything larger.
--
-- Leave it off and FaceTime stays the clean voice-call-with-a-video-layout from 1.1.2.
Config.FaceTime = {
    videoFeed = false,     -- opt in to the live picture

    fps = 6,               -- frames per second each side sends, capped at 12
    width = 220,           -- the frame is scaled to this before sending
    height = 300,
    quality = 0.4,         -- JPEG quality 0.1..0.9; lower is smaller and blurrier

    -- The server drops a relayed frame larger than this many KILOBYTES, so a client
    -- cannot turn the relay into a flood. A 220x300 q0.4 JPEG is well under this.
    maxFrameKb = 24,
}

-- ══════════════════════════════════════════════════════════════
--  PAYPHONES  (call boxes and prepaid cards)
-- ══════════════════════════════════════════════════════════════
-- The phone boxes that are ALREADY on the map, made to work.
--
-- There is no coordinate list here on purpose. Every booth in Los Santos is one of a
-- handful of props, so the client looks for those props around the player instead of
-- trusting a list somebody has to maintain. Add an MLO with a booth in it and it works;
-- move one with a map edit and it moves with it.
--
-- **A booth places calls. It never receives them.** That is the whole character of a
-- payphone, and it is enforced in three independent places: a booth number is never put
-- in the online table, it is never written to `vphone_characters`, and both the call and
-- the SMS paths refuse a booth-shaped number outright. See server/booth.lua.
--
-- Paying for the call is a prepaid card: an inventory item the player feeds into the box,
-- which turns into seconds of talk time held against their character. Emergency numbers
-- are free, because a payphone that will not call an ambulance is a prop, not a phone.
Config.Booth = {
    enabled = true,

    -- The props that count as a phone box. These are the base-game booths; add your own
    -- model names here if your map ships others.
    -- The `b` suffixes are the ones actually scattered around Los Santos - the plain
    -- `prop_phonebox_01` is rarer than its variant, which is why a player can stand at a
    -- box on the street and have nothing happen if only the base names are listed. Both
    -- forms are here; a model that is not on the map simply never matches.
    models = {
        'prop_phonebox_01', 'prop_phonebox_01b',
        'prop_phonebox_02', 'prop_phonebox_02b',
        'prop_phonebox_03', 'prop_phonebox_03b',
        'prop_phonebox_04', 'prop_phonebox_04b',
        'prop_ld_phonebox',
    },

    -- How close the player must be to use the box, in metres.
    radius = 1.6,

    -- Walk away and the call drops, the way a handset on a cord would. Metres from the
    -- box; keep it a little above `radius` so leaning away is not a hang-up.
    leashDistance = 3.5,

    -- What a booth number looks like. `#` becomes a digit, and every booth derives its
    -- OWN digits from where it stands, so the box outside the Vanilla Unicorn always has
    -- the same number and a player can recognise it.
    --
    -- **This must not overlap `Config.NumberFormat`.** The literal part ("311-" here) is
    -- what marks a number as a booth, and the phone refuses to mint a player number that
    -- would look like one.
    --
    -- More `#` means fewer boxes sharing digits. Four gives 10,000 numbers against the
    -- hundred-odd booths in Los Santos, so a collision is unlikely but not impossible; two
    -- boxes on opposite sides of the city showing the same number is the only consequence,
    -- since neither can be called back either way. Use five or six if that bothers you.
    numberFormat = '311-#####',

    -- The anim the player plays while on the box. A booth has its own handset, so no
    -- phone prop is attached.
    anim = { dict = 'cellphone@', clip = 'cellphone_call_listen_base' },

    -- The operator's name, struck into the plate at the top of the panel. Los Santos has two
    -- payphone operators, Badger and Whiz, and plenty of unbranded boxes - put your own city's
    -- telco here if you have one.
    brand = 'Badger',

    -- ── Paying for the call ────────────────────────────────────
    -- Seconds of talk time. `0` makes every booth call free and hides the card entirely,
    -- which is a fine way to run this if you do not want an economy attached to it.
    costPerMinute = 60,        -- seconds of credit spent per minute of call
    minimumSeconds = 30,       -- refuse to connect a call there is not this much credit for

    -- Numbers that never cost anything and never need a card. Only useful if something on
    -- your server actually answers them.
    freeNumbers = { '911', '112', '999' },

    -- The prepaid card. An ordinary inventory item; the box eats one and pays out seconds.
    -- Set `item = nil` to run booths on free calls only.
    card = {
        item = 'prepaid_card',
        seconds = 600,         -- talk time one card is worth
        maxCredit = 7200,      -- a character cannot bank more than this, so cards are not a wallet
    },

    -- Log every booth call to the server console, the way the forensics terminal logs a
    -- lookup. A payphone is the classic untraceable call, so an admin trail is worth having.
    log = false,

    -- ── Rules of the box ───────────────────────────────────────
    -- Let a player use a box from the driver's seat. Off is the honest default: you cannot
    -- reach a handset on a cord through a car window.
    allowInVehicle = false,

    -- The longest number the keypad will accept. Raise it if your server uses long numbers
    -- or extensions.
    maxDialLength = 20,

    -- Seconds a player must wait between calls from a box, counted from when the last one
    -- ENDED. 0 is no limit. Useful against someone using a payphone to spam a number they
    -- cannot be traced on.
    cooldownSeconds = 0,

    -- Hide the box's number from the person being called, so the call shows as withheld.
    -- OFF by default: the number is what makes a payphone call interesting to receive, and
    -- with it hidden the recipient has nothing at all to go on.
    anonymous = false,

    -- Slack, in metres, on the SERVER's check that the player is really at the box they
    -- claim to be at. It exists because the prop's origin is not where a player stands to
    -- use it. Tighten it to be strict, raise it only if a map edit puts the prop origin
    -- oddly far from its front.
    reachTolerance = 2.5,

    -- ── How the player reaches the box ─────────────────────────
    interact = {
        -- `off` is the default: a marker on the box and an [E] prompt, which works the
        -- moment a player walks up to one and needs nothing installed.
        --
        -- `auto` hands the box to whichever target script is running instead. That is the
        -- prettier integration, but it is not self-evident: qb-target only shows its eye
        -- while the player HOLDS Left Alt, so somebody standing at a phone box wondering
        -- why nothing happens is the normal outcome rather than a bug. Choose it when your
        -- players already know the targeting key.
        --
        -- Naming a script forces that one and falls back to the marker if it is not running.
        target = 'off',           -- off | auto | ox_target | qb-target | qtarget

        key = 38,                 -- the control id for the prompt. 38 is E.
        icon = 'fas fa-phone',    -- the target script's icon
        label = nil,              -- override the prompt text; nil uses the translation

        scanDistance = 12.0,      -- how far out the marker mode looks for a box
        -- How often the marker mode re-runs its spatial search, in milliseconds. Finding a
        -- box costs one query per model, so this is deliberately not every frame; the props
        -- do not move. Drawing stays on the frame, which is what it has to be.
        scanInterval = 500,

        marker = {
            enabled = true,
            type = 2,             -- 2 is the small downward chevron
            colour = { r = 60, g = 130, b = 200, a = 140 },
            scale = { x = 0.18, y = 0.18, z = 0.12 },
            height = 1.35,        -- metres above the prop's origin
            bob = false,          -- float it up and down
        },
    },

    -- ── On the map ─────────────────────────────────────────────
    -- Blips for the boxes, added as the player comes near them. OFF by default and on
    -- purpose: there are around a hundred payphones in Los Santos and blipping all of them
    -- turns the map into confetti. `shortRange` keeps them off the main map and on the
    -- minimap only, which is the version most servers actually want.
    blip = {
        enabled = false,
        sprite = 64,              -- 64 is the telephone icon
        colour = 3,
        scale = 0.6,
        shortRange = true,
        label = nil,              -- nil uses the translation

        -- **Only show a box's blip while the player is within this many metres of it.**
        -- Beyond it the blip is removed, and it comes back on the next approach.
        --
        -- `0` keeps every box the player has walked past, for ever, which is the setting
        -- for a server that wants a permanent payphone map. A value here is what you want
        -- if you would rather the map stayed readable: 150 shows the boxes on your street,
        -- 500 shows the ones in your district.
        --
        -- This is a real distance cull, and it is not the same thing as `shortRange`.
        -- `shortRange` is a GTA flag that hides a blip from the big paused map and leaves
        -- it on the minimap at any distance; this removes the blip outright.
        distance = 0,

        -- How often, in milliseconds, the blips are re-checked against `distance`. Only
        -- matters when `distance` is set. Cheap - it walks a handful of known positions,
        -- it does not search the world.
        refresh = 2000,
    },
}

-- ══════════════════════════════════════════════════════════════
--  MUSIC  (playback, playlists and the deck the phone hands off to)
-- ══════════════════════════════════════════════════════════════
-- The Music app is a library, a playlist manager and a remote. What it is NOT is an audio
-- engine: FiveM has no way to stream a URL from a phone UI, so the sound itself always comes
-- from a music resource the server already runs.
--
-- **Read this before reporting that a track does not play.**
--
-- The two rcore scripts this ships support - the car radio and the DJ deck - expose only UI
-- exports in their public API. There is no documented export in either that takes a URL and
-- plays it. So the phone does the honest thing: it keeps your library and playlists, puts the
-- track's URL on your clipboard, and opens the right deck for where you are standing. You
-- paste and press play. That is a real, working integration with what those scripts actually
-- publish, and it is the whole of what they publish.
--
--   rcore_radiocar   https://store.rcore.cz/package/4342933   in a vehicle
--   xDiskJockey      https://store.rcore.cz/package/4357520   on foot
--
-- If your music script CAN be driven programmatically, fill in `hooks` below and the phone
-- will drive it instead - no paste, no deck, the track just plays. That path is the one to
-- use with a script you wrote yourself or one with a richer API.
Config.Music = {
    enabled = true,

    -- Which deck the phone hands a track to.
    --   auto          the car radio when the player is in a vehicle that has one,
    --                 the DJ deck otherwise
    --   rcore_radiocar / xdiskjockey    always that one
    --   hooks         never open a deck; use the `hooks` below only
    --   off           the app stays hidden entirely
    provider = 'auto',

    -- Put the track's URL on the clipboard when handing off to a deck, so it is a paste away
    -- rather than something to retype. Off if you find it intrusive.
    copyUrl = true,

    -- Drive a music resource directly, for a script that supports it. Each hook runs on the
    -- CLIENT. Return true from `play` and the phone treats the track as playing and never
    -- opens a deck.
    --
    --     Config.Music.hooks.play = function(track, output)
    --         -- track = { url, title, artist, volume }, output = 'headphones' | 'speaker'
    --         return exports['my-music']:PlayUrl(track.url, track.volume)
    --     end
    hooks = {
        play = nil,      -- function(track, output) -> boolean
        stop = nil,      -- function() -> boolean
        volume = nil,    -- function(level 0..1) -> boolean
    },

    -- ── What a player may add ──────────────────────────────────
    maxLibrary = 120,          -- saved tracks per character
    maxPlaylists = 20,         -- playlists per character
    maxTracksPerPlaylist = 100,

    -- How far a phone SPEAKER carries, in metres. The car radio uses the same ceiling.
    --
    -- A limit rather than whatever the page asks for: a phone speaker is a phone speaker, and
    -- the obvious abuse is one player broadcasting across a district. 12 m is about right for
    -- a handset on a table.
    speakerRange = 12.0,

    -- Where a track URL may point. Same idea as the wallpaper hosts: an operator decision,
    -- not the player's. An empty list allows any host, which is the permissive setting.
    allowCustomUrl = true,
    hosts = {
        'youtube.com', 'www.youtube.com', 'youtu.be', 'music.youtube.com',
        'soundcloud.com', 'www.soundcloud.com',
        'open.spotify.com',
        'files.catbox.moe', 'cdn.discordapp.com', 'media.discordapp.net',
    },

    -- ── Playlists every character starts with ──────────────────
    -- Read-only: a player can play them and copy a track out of them, but not edit or delete
    -- them, so a server's own selections stay intact. Their own playlists sit alongside.
    --
    -- `icon` is any icon the phone already ships (music, radio, star, heart, disc...).
    -- Leave `tracks` empty and the playlist is a heading a player can fill from the library.
    -- **A word on what you put here.** These links get streamed on your server, in public.
    -- Music that is licence-free stays up; a rip of a commercial radio station is taken down
    -- sooner or later and the entry quietly stops working. The first two lists below are
    -- royalty-free on purpose - NoCopyrightSounds is free for streams as long as the artist,
    -- the track and NCS are credited (https://ncs.io). The third is the in-game sound, and it
    -- carries the risk that comes with it.
    --
    -- Whether a PLAYLIST link works, as opposed to a single video, depends on the deck your
    -- server runs. Single-video URLs are the safe bet; try a playlist and keep it if it plays.
    defaultPlaylists = {
        {
            id = 'ls_classics',
            name = 'Free To Play',
            icon = 'music',
            tint = '#34C759',
            tracks = {
                { title = 'NCS 10 Year Mix (3 hours)', artist = 'NoCopyrightSounds',
                  url = 'https://www.youtube.com/watch?v=yUXJjIvhZz8' },
                { title = 'Gaming Music - No Copyright', artist = 'NCS and friends',
                  url = 'https://www.youtube.com/playlist?list=PL7ya7p5KV7zulnn3d17Qq0PGYLycMHZMx' },
                { title = 'Gaming, No Copyright', artist = 'Royalty free',
                  url = 'https://www.youtube.com/playlist?list=PLRPR8uJQx5tHxkGUSqu-Xvesjc0lDbdrX' },
            },
        },
        {
            id = 'late_night',
            name = 'Late Night Drive',
            icon = 'moon',
            tint = '#5856D6',
            tracks = {
                { title = 'NCS 10 Year Mix (3 hours)', artist = 'NoCopyrightSounds',
                  url = 'https://www.youtube.com/watch?v=yUXJjIvhZz8' },
            },
        },
        {
            id = 'los_santos',
            name = 'Los Santos Radio',
            icon = 'speaker',
            tint = '#FF9500',
            -- The in-game stations. Fun, and the entries most likely to go dead one day: these
            -- are uploads of commercial music, not licence-free tracks. Swap in your own
            -- mirrors if a link stops playing.
            tracks = {
                { title = 'Radio Los Santos', artist = 'GTA V',
                  url = 'https://www.youtube.com/playlist?list=PLgbI0QcBNn5jsj7Ju1BEgGbT0bn4bLOdS' },
                { title = 'West Coast Classics', artist = 'GTA V',
                  url = 'https://www.youtube.com/watch?v=UNzZIIbc0jY' },
            },
        },
    },
}

-- ══════════════════════════════════════════════════════════════
--  VEHICLE REMOTE  (lights, neons, doors and locks from the phone)
-- ══════════════════════════════════════════════════════════════
-- Your car, from your pocket. Open the Garage app, pick a vehicle you own that is parked
-- nearby, and flash the lights, change the underglow, pop a door or lock it.
--
-- **This needs no dependency at all.** Neons, lights, doors and locks are engine natives, so
-- this works identically on qb-core, qbx_core, ox_core, ESX and standalone, with any garage
-- or inventory script. What the framework decides is only WHICH vehicles are yours, and that
-- is read through the same bridge the Garage app already uses.
--
-- **jim-mechanic.** It ships a "Neon Controller" item that sets underglow and xenon colour.
-- It publishes no exports, so there is nothing to call into - and nothing to fight over
-- either: both write the same engine state. Leave `persist` off and the phone is a remote,
-- with jim-mechanic remaining the thing that SAVES a build. Turn it on and a colour set from
-- the phone is written to the vehicle's state so it survives a re-spawn, which is what you
-- want on a server with no mechanic script at all.
Config.VehicleRemote = {
    enabled = true,

    -- **How far the phone reaches, in metres.** Checked on the SERVER against the vehicle's
    -- real position, so a modified client cannot open its car from across the city.
    distance = 20.0,

    -- Only vehicles the framework says belong to this character. Off lets a player control
    -- any vehicle in range, which is a very different game - keep it on unless you mean it.
    requireOwnership = true,

    -- Refuse while the engine is running and somebody is in the driver's seat, so this
    -- cannot be used to lock a thief in or pop a door on a moving car.
    refuseWhileDriven = true,

    -- Seconds between commands from one player. Stops the buttons being held down.
    cooldownSeconds = 1,

    -- Which controls the app offers. Each one hides its own button.
    controls = {
        lights   = true,     -- flash / low beam / full beam
        neon     = true,     -- underglow on/off and colour
        doors    = true,     -- pop and shut each door
        locks    = true,     -- lock and unlock
        engine   = false,    -- remote start. OFF by default: it is the strongest of these
        horn     = true,     -- a short honk, to find it in a car park
        alarm    = false,    -- the full alarm, for the same reason and louder
    },

    -- The underglow palette the app offers. `name` is shown, `rgb` is what is applied.
    neonColours = {
        { name = 'White',   rgb = { 255, 255, 255 } },
        { name = 'Red',     rgb = { 255, 45, 85 } },
        { name = 'Orange',  rgb = { 255, 149, 0 } },
        { name = 'Yellow',  rgb = { 255, 214, 10 } },
        { name = 'Green',   rgb = { 52, 199, 89 } },
        { name = 'Cyan',    rgb = { 90, 200, 250 } },
        { name = 'Blue',    rgb = { 10, 132, 255 } },
        { name = 'Purple',  rgb = { 175, 82, 222 } },
        { name = 'Pink',    rgb = { 255, 55, 175 } },
    },

    -- Write a neon change to the vehicle's state bag so it survives the vehicle being
    -- re-created. Off by default: on a server running a mechanic script, that script owns
    -- what a build looks like, and two writers of the same value is one too many.
    persist = false,

    -- Log every remote command to the server console. A car that unlocks itself is worth
    -- being able to explain.
    log = false,
}

-- ══════════════════════════════════════════════════════════════
--  FRUITSTORE  (apps you add, free or paid)
-- ══════════════════════════════════════════════════════════════
-- Your own apps in the store, without writing a resource.
--
-- Anything listed here appears in FruitStore alongside the built-in apps. Give it a `page`
-- and the phone frames that URL as the app; leave it out and it is a listing for something
-- your own resource draws (see DEVELOPERS.md for a real drop-in app).
--
-- **Paid apps.** Set a `price` and the phone charges for it once, the first time it is
-- installed. What is bought is remembered against the character, so removing the app and
-- installing it again later is free - a player pays for an app, not for a download.
--
-- The charge goes through `Bridge.RemoveMoney`, which handles qb-core, qbx_core and ESX
-- directly and ox through its money item. **It fails closed:** if the debit cannot be
-- confirmed, the app is not granted. On any other money script, wire
-- `Config.Compat.hooks.removeMoney` and it is used instead.
Config.StoreApps = {
    -- {
    --     id = 'taxi_meter',              -- unique, [a-z0-9_-]
    --     label = 'Taxi Meter',           -- shown as-is, or a locale key like 'app.taxi'
    --     icon = 'car',                   -- any icon the phone ships
    --     accent = '#FFD60A',             -- the tint on its store page
    --     developer = 'Downtown Cab Co.', -- who "made" it, in character
    --     description = 'Fares, distance and a running total for the shift.',
    --     category = 'work',              -- one of Config.Categories
    --
    --     price = 250,                    -- 0 or nil for a free app
    --     account = 'bank',               -- 'bank' (default) or 'cash'
    --
    --     job = nil,                      -- restrict to one job, or a list: { 'taxi' }
    --     page = 'https://my-server.tld/taxi/index.html',   -- optional: framed as the app
    --
    --     features = { 'Live fare', 'Shift total' },
    --     permissions = { 'Location' },
    -- },
}
