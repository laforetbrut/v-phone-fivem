-- v-phone | apps/_loader.lua
--
-- **Drop a folder in `apps/`, and the phone has a new app.**
--
-- Everything under `apps/` is picked up by the globs in fxmanifest.lua, so an app folder
-- needs no edit anywhere else - not here, not in config.lua, not in the manifest. This
-- file only defines the one function those folders call.
--
-- The shape of an app folder:
--
--     apps/
--       myapp/
--         app.lua        -- required: calls PhoneApp{...} to declare itself
--         index.html     -- required: the page, which loads sdk.js for the kit and bridge
--         client.lua     -- optional: runs on the client, like any other client script
--         server.lua     -- optional: runs on the server, like any other server script
--
-- `app.lua` is a *shared* script: it runs on both sides. That is deliberate - the phone
-- needs the declaration on the server to register it, and PhoneApp is written so calling
-- it twice is harmless.

PhoneApps = PhoneApps or {}

--- Declare a phone app.
---
--- Called from `apps/<id>/app.lua`. The only required fields are `id` and `label`; ids
--- use letters, numbers, `_` and `-` so the SDK namespace and folder URL stay unambiguous.
--- page defaults to `index.html` inside your own folder, which is where it should be.
---
---     PhoneApp {
---         id       = 'myapp',
---         label    = 'My App',        -- a literal, or a locale key the phone can resolve
---         icon     = 'note',          -- any key from PhoneUI.icons
---         category = 'utilities',
---         desc     = 'One line for its FruitStore page.',
---         developer = 'My Studio',
---         version  = '1.0.0',
---         accent   = '#0A84FF',
---         permissions = { 'storage', 'contacts', 'photos', 'location' },
---         features = { 'Fast search', 'Offline favourites' },
---         keywords = { 'search', 'roleplay' },
---         optional = true,            -- absent until downloaded from the store
---     }
function PhoneApp(def)
    if type(def) ~= 'table' then return end
    local id = tostring(def.id or '')
    if id == '' or not id:match('^[%w_-]+$') then
        print(('^1[v-phone] invalid app id %q (use letters, numbers, _ or -); skipped^0'):format(id))
        return
    end

    -- The page lives in the app's own folder. A folder that wants a different file name
    -- says so; everything else gets index.html for free.
    local resource = GetCurrentResourceName()
    def.page = def.page or ('https://cfx-nui-' .. resource .. '/apps/' .. id .. '/' .. (def.file or 'index.html'))
    def.label = def.label or id
    def.icon = def.icon or 'dot'
    def.category = def.category or 'utilities'
    def.developer = def.developer or resource
    def.version = def.version or '1.0.0'
    -- A dropped-in app is a download by nature: nobody wakes up with somebody else's app
    -- already on their phone. A folder that disagrees sets `optional = false`.
    if def.optional == nil then def.optional = true end
    -- Slots after the built-ins, in the order the folders load, unless one asks for a place.
    def.slot = tonumber(def.slot) or (100 + #PhoneApps)

    PhoneApps[#PhoneApps + 1] = def
end
