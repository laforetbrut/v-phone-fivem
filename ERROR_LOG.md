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

---

## [2026-07-25 02:40] — phone calls were routed through pma-voice's radio

**Context:** a full compatibility audit, with pma-voice named as the must-work target.

**Error:** `bridge/shared/compat.lua` implemented `v-voice.PhoneCallStart` as
`setVoiceProperty('radioEnabled', true)` + `setRadioChannel(callChannel(id))`, and
`PhoneCallEnd` as `setRadioChannel(0)`.

**Root cause:** pma-voice ships two separate subsystems and the shim picked the wrong one.
Read from its source, `client/module/phone.lua` builds voice targets as
`addVoiceTargets((radioPressed and isRadioEnabled()) and radioData or {}, callData)` — radio
targets are gated on the push-to-talk key being held, call targets are unconditional. Four
consequences, all real: a phone call needed PTT to be heard; taking a call overwrote the
player's `radioChannel` and hanging up set it to 0, silently removing them from their job
radio; `voice_enableRadios 0` made calls mute while `voice_enableCalls` was never consulted;
and calls sat in the *radio* channel namespace at 700–724, where a server using a radio
channel in that range would have a call and a radio merge.

**Fix:** `setCallChannel(n)` to join, `setCallChannel(0)` to leave, `SpeakerListen` likewise.
Radio is no longer touched at all. Verified with 8 assertions against the shim in real Lua,
including that `setRadioChannel` and `setVoiceProperty` are never called.

**Prevention:** when integrating a third-party resource, read its source or docs for the
feature you actually want rather than reaching for the first export with a familiar name.
"Radio" and "call" are not synonyms in any voice script. The same mistake is still present
for saltychat and is recorded as outstanding.

---

## [2026-07-25 02:40] — the Jobs app died on a stub that was never written

**Context:** the same audit, sweeping every method called on a `v-*` stub against what the
stubs actually publish — the check the `Core.Notify` entry above says to run.

**Error:** `server/main.lua` calls `V.Use('v-cityhall').OpenPositions()` unguarded.
`STUBS['v-cityhall']` did not exist, but `stubIsLive('v-cityhall')` returns true because
`Config.Compat.modules['v-cityhall']` is `true`. So `V.Use` skipped the provider path, saw
`GetResourceState` say "started", and returned a proxy onto the real exports of a resource
that is not installed. The call raised, the pcall in `V.Callback` swallowed it, and the
client's `v-phone:jobs` request timed out.

**Root cause:** `stubIsLive` and `STUBS` are two lists that have to agree, and nothing made
them. A module can be declared live without anything standing behind it.

**Fix:** a `v-cityhall` stub whose `OpenPositions` maps `Bridge.Jobs.All()` into the shape
the app's Openings tab reads. Verified with 6 assertions, including the ESX shape where a
job has no grades at all.

**Prevention:** the sweep that found this is the one to keep running — extract every
`V.Use('x').Method` and `exports['x']:Method` in the tree, extract the keys of every `STUBS`
entry, and diff. Any name reported live by `stubIsLive` must have a stub. Automate it before
adding another module.

---

## [2026-07-25 04:10] — three qb-core incompatibilities, all from assuming an old API

**Context:** an audit for full qb-core and Quasar compatibility, checked against the real
qb-core, qb-inventory, qbx_core and Quasar sources rather than from memory.

**Error:** three separate failures, none of which produced a console error:

1. `Bridge.QBUsable` registered usable items through
   `exports['qb-core']:CreateUseableItem`. That export does not exist. qb-core's complete
   export list is SetMethod, SetField, the job/gang/item-registry helpers, GetCoreVersion
   and ExploitBan. The call raised inside a pcall, the pcall swallowed it, and the item was
   never registered — so the power bank and the prepaid calling card did nothing when used.
2. `Bridge.HasItem` and `Bridge.RemoveItem` fell back to
   `Player.Functions.GetItemByName` / `Player.Functions.RemoveItem`. Neither exists on
   modern qb-core; `GetItemByName` does not appear anywhere in the repository any more.
   Both raised "attempt to call a nil value".
3. `Bridge.Numbers.Set` wrote the phone number into `players.charinfo` with a direct UPDATE.
   qb-core keeps charinfo on the player object and writes it back over the row on every save
   (`charinfo = json.encode(PlayerData.charinfo)` in `Player:Save`), so the number reverted
   the moment the character logged out.

**Root cause:** the bridge was written against a qb-core that no longer exists. Item handling
moved out to qb-inventory, and qbx_core diverged from qb-core on exactly the surface being
used — qbx exports CreateUseableItem, qb-core only has it on the shared object.

**Fix:** the shared object is tried first for usable items and the export second, which covers
both. Item reads go through `Bridge.QBItemCount`, which sums `PlayerData.items` — the one
thing every qb build still has. Removal without an inventory resource now fails closed rather
than raising. The number is written to the live `PlayerData.charinfo` through `SetPlayerData`
as well as to the row, so qb-core persists it itself.

**Prevention:** never assume a framework API from memory, and never assume two forks of one
framework share a surface just because they share a player shape. Read the source. And treat
a silent pcall as a place a bug can hide: `QBUsable` returned false and nobody looked, for
however long. Where a pcall guards an integration that is *supposed* to be there, log the
failure once rather than swallowing it.
