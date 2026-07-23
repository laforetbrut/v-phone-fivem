-- apps/example/app.lua
--
-- The whole Lua side of a phone app. There is no more than this.
--
-- Copy this folder, rename it, change the id, and you have an app. Nothing outside the
-- folder needs editing: the globs in fxmanifest.lua pick it up.

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
