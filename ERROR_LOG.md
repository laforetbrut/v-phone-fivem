# Error log

Problems hit while working on this resource, what caused them, and the rule that stops each
one coming back.

---

## [2026-07-25 01:40] — `Core.Notify` was never defined

**Context:** adding the prepaid card to the payphone feature, and following the existing
usable-item registration in `server/main.lua` as the pattern to copy.

**Error:** `server/main.lua` calls `Core.Notify(src, ..., 'info')` in the power bank handler.
`Core` is built in `bridge/server/framework.lua` with exactly three fields — `GetPlayer`,
`GetPlayerByCitizenId`, `Log`. `Notify` was not one of them, so using a power bank raised
`attempt to call a nil value (field 'Notify')`.

**Root cause:** upstream's `v-core` carries a notifier, and the bridge that replaces it was
written from the reader side (what the phone asks a *player* for) without auditing what the
phone asks *Core* for. Nothing referenced it in the files the bridge was tested against, so
it went unnoticed.

**Fix:** `Core.Notify` added in `bridge/server/framework.lua`, forwarding to `Bridge.Notify`
— the same destination `V.Notify` uses on the server.

**Prevention:** when a bridge replaces an upstream module, grep the whole resource for every
field that is read off it (`Core%.`, `Bridge%.`, `V%.`) and check each one exists. A shim is
only complete against its call sites, not against its own design.

---

## [2026-07-25 01:40] — the `v-inventory` shim had no `RemoveItem`

**Context:** the payphone has to consume a prepaid card, and the natural route was the
`v-inventory` shim the power bank already uses.

**Error:** `V.Use('v-inventory').RemoveItem(src, 'powerbank', 1)` in `server/main.lua`
resolves to nil on any server without a real `v-inventory` resource — which is every server
this bridge exists for. The stub in `bridge/shared/compat.lua` published only
`RegisterUsableItem` and `HasItem`.

**Root cause:** the same blind spot as above, one layer down. The stub was written to satisfy
the call sites that were being ported at the time, and a later call site assumed the full
upstream surface.

**Fix:** `RemoveItem` and `ItemCount` added to the stub, wired to new `Bridge.RemoveItem` and
`Bridge.ItemCount` in `bridge/server/integrations.lua`, which cover ox_inventory, qs, ps, qb,
origen, codem and the qb/ESX player objects.

**Prevention:** a stub table is an interface. Before using one, read the stub and confirm the
method exists rather than assuming it mirrors upstream. And when adding a method to a stub,
give it the same fail-direction as its siblings — deliberately here: `HasItem` fails *open*
so a missing integration cannot lock everyone out of the phone, while `RemoveItem` fails
*closed* so it can never grant credit for an item that was not spent.

---

## [2026-07-25 01:55] — no Lua toolchain to verify Lua changes

**Context:** twelve Lua files changed for the payphone feature, and rule 10.4 says test before
reporting done.

**Error:** `luac` is not on PATH on this machine, and WSL has no distribution installed, so
there was no way to even syntax-check a Lua change, let alone run one.

**Root cause:** a FiveM resource is Lua, but the workstation is set up for the JS half of it.

**Fix:** `pip install luaparser` for parsing every file, and `pip install lupa` for a real
embedded Lua 5.4 — which made it possible to actually execute `bridge/shared/booth.lua` and
assert its properties (determinism, number shape, the booth-number guard) rather than only
parse it.

**Prevention:** for any Lua work in this repo, `lupa` is the test harness. Pure shared logic
belongs in a file with no FiveM natives in it — as `bridge/shared/booth.lua` is — precisely so
it can be loaded and asserted against outside the game.
