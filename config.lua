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

--- The inventory item a player must carry, when `Config.Settings.requireItem` is on.
Config.PhoneItem = 'phone'

Config.Compat = {
    -- ── Which script answers what ──────────────────────────────
    -- Each of these is `auto`, `off`, or the exact resource name to use.
    inventory = 'auto',   -- ox_inventory, qs-inventory, ps-inventory, qb-inventory, origen_inventory, codem-inventory
    banking   = 'auto',   -- qs-banking, Renewed-Banking, qb-banking, okokBanking, esx_banking
    garage    = 'auto',   -- qs-advancedgarages, jg-advancedgarages, qb-garages, cd_garage, okokGarage
    housing   = 'auto',   -- qs-housing, ps-housing, qb-houses, ox_property, loaf_housing, esx_property
    voice     = 'auto',   -- pma-voice, saltychat, mumble-voip
    notify    = 'auto',   -- ox_lib, qb, esx, chat, custom
    numbers   = 'auto',   -- auto | framework (keep the number in the framework) | phone (keep it here)

    -- With `notify = 'custom'`, the client event the phone fires instead. It receives
    -- (message, kind) where kind is inform | success | error.
    notifyEvent = 'myserver:notify',

    -- The radio channel range phone calls use, when the voice script is channel based.
    -- Twenty-four channels are reserved from here up, so two calls never share one.
    voiceChannel = 700,

    -- ── Apps that need a script you may not run ────────────────
    -- Set one to false and its app is not offered at all: no home screen, no store, no
    -- search. This is how you switch off the garage app on a server with no garages,
    -- rather than leaving players an app that answers nothing.
    modules = {
        ['v-banking']  = true,    -- Bank
        ['v-vehicles'] = true,    -- Garage
        ['v-housing']  = true,    -- Property
        ['v-licenses'] = true,    -- Wallet
        ['v-cityhall'] = true,    -- Jobs
    },

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
        jobs = nil,           -- () -> { { name, label, grades }, ... }
        status = nil,         -- (src) -> { hunger, thirst, ... }
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
--     set phone_requireItem true
--
-- The convar name is `phone_` followed by the key.
Config.Settings = {
    enabled         = true,
    requireItem     = false,   -- carry Config.PhoneItem to open the phone
    numberFormat    = '555-####',
    maxLength       = 500,     -- an SMS
    retentionDays   = 30,      -- how long messages are kept, 0 for ever
    ringSeconds     = 30,
    maxMinutes      = 60,
    battery         = true,
    hoursToEmpty    = 8,
    screenDrain     = 3,
    chargeMinutes   = 45,
    powerbankCharge = 45,
    autoDark        = true,
    darkFrom        = 20,
    darkTo          = 6,
    voicemail       = true,
    voicemailMax    = 200,
    anonymous       = false,
    customWallpaper = true,
    camera          = false,
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
Config.Key = 'F1'

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
    block  = { 1, 2, 24, 25, 47, 257, 263, 264, 45, 140, 141, 142, 143, 37, 44, 68, 69, 70, 91, 92 },
}

-- ── Numbers ────────────────────────────────────────────────────
-- A number is how contacts, calls and messages address each other. Never the citizen id:
-- that is a database key, and a player should not be trading it.
--
-- `#` is replaced by a random digit. Anything else is kept, so a server can use its own
-- shape. Los Santos numbers in GTA are 555-xxxx, which is what this ships as.
Config.NumberFormat = '555-####'

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
    { id = 'bank',     label = 'app.bank',     icon = 'bank',     owner = 'v-banking',  slot = 4,
      category = 'finance' },
    { id = 'mail',     label = 'app.mail',     icon = 'mail',     owner = 'v-phone',    slot = 5,
      category = 'work' },
    { id = 'maps',     label = 'app.maps',     icon = 'map',      owner = 'v-world',    slot = 6,
      category = 'travel' },
    { id = 'camera',   label = 'app.camera',   icon = 'camera',   owner = 'v-phone',    slot = 7,
      category = 'utilities' },
    { id = 'gallery',  label = 'app.gallery',  icon = 'images',   owner = 'v-phone',    slot = 8,
      category = 'utilities' },
    { id = 'music',    label = 'app.music',    icon = 'music',    owner = 'v-music',    slot = 9,
      category = 'entertainment' },
    { id = 'garage',   label = 'app.garage',   icon = 'garage',   owner = 'v-vehicles', slot = 10,
      category = 'travel' },
    { id = 'property', label = 'app.property', icon = 'house',    owner = 'v-housing',  slot = 11,
      category = 'utilities' },
    -- Police only by default. The operator can open it up, or gate something else the
    -- same way, from Editor -> Phone apps.
    { id = 'wallet',   label = 'app.wallet',   icon = 'wallet',   owner = 'v-licenses', slot = 12,
      category = 'finance' },
    { id = 'jobs',     label = 'app.jobs',     icon = 'jobs',     owner = 'v-cityhall', slot = 13,
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
Config.DeviceSize = 1.0        -- 0.75 .. 1.15
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
    hoursToEmpty = 8.0,     -- idle, phone closed
    screenMultiplier = 3.0, -- how much faster it drains with the screen on
    chargeMinutes = 45.0,   -- flat to full at a charger
    lowAt = 20,             -- first warning
    criticalAt = 5,
}

-- Charging happens at these, and also in any vehicle and inside a property you hold a key
-- to. Those two are code, because they follow the player rather than a coordinate.
-- SEED DATA ONLY: chargers live in `world_chargers` and are edited from the admin panel.
Config.Chargers = {
    { id = 'ch_lsia',      label = 'LSIA, arrivals hall',    x = -1037.0, y = -2737.0, z = 20.2, radius = 8.0 },
    { id = 'ch_legion',    label = 'Legion Square kiosk',    x = 195.0,   y = -933.0,  z = 30.7, radius = 6.0 },
    { id = 'ch_pillbox',   label = 'Pillbox Hill Medical',   x = 306.0,   y = -595.0,  z = 43.3, radius = 8.0 },
    { id = 'ch_paleto',    label = 'Paleto Bay, sheriff',    x = -448.0,  y = 6013.0,  z = 31.7, radius = 6.0 },
    { id = 'ch_sandy',     label = 'Sandy Shores, clinic',   x = 1839.0,  y = 3672.0,  z = 34.3, radius = 8.0 },
    { id = 'ch_vespucci',  label = 'Vespucci boardwalk',     x = -1223.0, y = -1493.0, z = 4.4,  radius = 6.0 },
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
