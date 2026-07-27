-- apps/example/app.lua
--
-- The whole Lua side of a phone app. There is no more than this.
--
-- Copy this folder, rename it, change the id, and you have an app.
--
-- ── OFF BY DEFAULT ────────────────────────────────────────────────────────────
-- It is a worked example, not a feature, so it does not appear on a live server: it was
-- turning up in the FruitStore - and in the featured card at the top of it - as an app
-- called "Example" with a placeholder description, which is a developer's file leaking
-- into a player's phone.
--
-- Switch it on with `Config.SdkExample = true` while you are building against it. The file
-- stays here either way, because reading it is how you learn the shape of an app, and the
-- declaration below is the whole of that shape.
if not (Config and Config.SdkExample) then return end

PhoneApp {
    id       = 'example',
    label    = 'Example',       -- a literal, or a locale key the phone can resolve
    icon     = 'note',          -- any key from PhoneUI.icons
    category = 'utilities',     -- where it sits in the FruitStore
    desc     = 'The worked example: a folder dropped into apps/ and nothing else.',
    developer = 'iFruit SDK',
    version  = '2.0.0',
    accent   = '#0A84FF',
    permissions = { 'storage', 'contacts', 'photos', 'location', 'notifications' },
    features = { 'Persistent data', 'Native pickers', 'Quick actions', 'Live lifecycle' },
    keywords = { 'example', 'sdk', 'developer' },
    optional = true,            -- absent until downloaded from the store, like any app
}
