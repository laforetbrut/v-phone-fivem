# Error log

Problems hit while working on this resource, what caused them, and the rule that stops each
one coming back.

---

## [2026-07-26 05:10] — `undefined` on the home screen, and a black box behind the phone

**Context:** two changes made in the same pass — showing the real date on the calendar widget,
and switching the size setting from `transform: scale()` to `zoom` to stop text blurring.

**Errors:** the home screen showed the literal word "undefined" where the date belonged, and a
black rectangle appeared behind the phone whenever an app was opened.

**Root causes, both mine:**

1. `calendarWidget()` wrote `host.innerHTML += ...` and returned nothing, but it was CALLED
   from inside the expression assigning `host.innerHTML`. So it appended the calendar, then
   the outer assignment overwrote it, and `undefined` — the function's return value — was
   concatenated into the markup. A helper that both mutates the DOM and is used as a value
   is the whole bug in one line.
2. `zoom` fixed the blur and broke the layout. Chromium's `zoom` has long-standing problems
   with clipping and positioned descendants, and `.screen` relies on `overflow: hidden` to
   keep app content inside the handset.

**Fix:** the widget function now returns markup and touches nothing. The size setting is back
on `transform: scale()`, restored from the commit before the change rather than rewritten,
because that behaviour was known good.

**Consequence, stated rather than hidden:** the phone is blurry again at any size but 100%.
That is a cosmetic fault; a black box over the game is not, and I traded the wrong way round.
A crisp fix has to scale the LAYOUT without `zoom` — driving the internal sizes from one
custom property — which is a real change, not a one-liner.

**Prevention:** never let a function both write the DOM and return a value used as markup.
And when a change fixes something cosmetic by switching to a CSS feature with known engine
bugs, that is not a safe trade — verify the layout it governs, or do not make it.

---

## [2026-07-26 04:40] — Stripped the blur off every panel and made the phone see-through

**Context:** the user reported the phone felt slow. `html/style.css` opens by forbidding
`backdrop-filter` outright — "FiveM's CEF renders it as an opaque black box" — and 44
declarations had crept back in across 21 rules. Removing them looked like a free win:
correctness and performance at once.

**Error:** every menu went transparent. The Settings list, the navigation bars and the
panels all showed the home screen straight through them.

**Root cause — two failures, and the second is the one that matters:**

1. The header comment was stale. It was written for an older CEF; FiveM ships Chromium 103
   now and blurs the backdrop correctly. I trusted a comment over the running product.
2. **I had the evidence that would have stopped me and I misread it.** After the change I
   sampled three elements in a browser and reported "the affected elements keep their
   backgrounds". Two of the three came back `backgroundColor: rgba(0, 0, 0, 0)` — fully
   transparent, with only a highlight gradient. I saw `rgba(0,0,0,0)` and read it as fine
   because a `backgroundImage` was present beside it. The blur WAS the opacity on those
   panels; the gradients are sheen, not fill.

**Fix:** restored the stylesheet from the commit before the change and re-applied only the
one edit that was actually wanted — dropping `filter: drop-shadow` from `.device`, which is
what caused blurry text at non-default sizes. Verified the diff against the last good version
contains exactly one removed declaration. Rewrote the header so the next person is not told
the same wrong thing.

**Prevention:** a sampled check has to be read against a stated pass condition, decided
before looking. "Does it still have a background" is not one — `rgba(0,0,0,0)` satisfies the
question and fails the intent. The condition here was "is this panel still opaque enough to
read text on", which is `alpha >= ~0.85 OR a blur is present`, and two of three samples
failed it in the output I had already printed. And do not delete a whole class of declaration
on the authority of a comment: check what the property is actually doing on the current
runtime first.

---

## [2026-07-26 04:05] — The phone opened into nothing: an anti-iframe guard dropped Lua's own message

**Context:** with the grey screen gone and the open callback fixed, the phone went into the
player's hand and no interface appeared.

**Error:** `html/app.js` opened its message handler with
`if (e.source && e.source !== window) return;` — a guard so an app iframe cannot impersonate
Lua. It assumes a CEF host message always arrives with a null source. On this FiveM build it
does not, so every `SendNUIMessage` was discarded at the first line. Nothing threw, the page
was healthy, and `#device` simply kept its `hidden` class forever.

**Root cause of missing it for two passes:** the guard fails by RETURNING, not by raising, so
there was nothing to find in any log. Worse, I reasoned my way past it twice:
1. I concluded from an empty `cef_console.txt` that no exception had occurred and therefore
   the handler had run to completion. Wrong twice over — FiveM's cef_console captures
   `console.*` but not uncaught errors, and a silent early return produces no error anyway.
2. My own boot trace was a SEPARATE listener with no guard of its own, so it logged
   "open received" for a message the real handler had already rejected. The instrument
   disagreed with the thing it was measuring, and I read it as agreement.

What finally settled it was measuring the element rather than the code path: a check 600ms
after open reported `still has .hidden; display:none; zero size`, which is only reachable if
`classList.remove('hidden')` was never executed.

**Fix:** test the thing actually being defended against. The only foreign windows a NUI page
has are its own app iframes, and `window.frames` enumerates them, so reject by identity
against that list and accept anything else whatever the host puts in `source`. Verified both
directions in a real browser: a host-style post reveals the device, and a message from a live
child iframe is still rejected with the phone left hidden and its number unchanged.

**Prevention:** a guard that drops input silently is invisible to logs by construction — when
a message-driven feature does nothing, suspect the filter before the handler. And an
instrument must sit on the same side of the guard as the code it reports on, or it measures
something else and lends false confidence.

---

## [2026-07-26 03:45] — `prefsOf` called 140 lines before it was declared

**Context:** with the grey screen finally gone, the phone could be opened for the first time.
It refused with "Something went wrong".

**Error:** `[v-phone] callback v-phone:open failed: server/main.lua:363: attempt to call a nil
value (global 'prefsOf')`. `appsFrom` reads a player's purchased apps at line 363, but
`prefsOf` was `local function prefsOf(...)` at line 503. Before that line the name is not in
scope, so Lua resolved it as a GLOBAL, which is nil. The open callback raised, never resolved,
and the client sat until its ten-second guard fired and showed the generic `ph.err_x`.

**Root cause:** the purchased-apps lookup came in with the paid FruitStore apps in 1.2.0 and
was placed in `appsFrom`, which lives near the top of the file, while `prefsOf` lives with the
preferences block much further down. The file already has a forward-declaration block at line
30 for exactly this — `Signal`, `batteryOf`, `requireItem`, `phoneReachable`, `speakerOff` —
with a comment spelling out this precise failure. `prefsOf` was simply never added to it.

It survived because nobody had opened the phone since: every session since 1.2.0 landed was
spent on the grey screen, so the open callback was never reached on a running server.

**Fix:** added `local prefsOf` to the forward-declaration block and changed the definition
from `local function prefsOf(...)` to `prefsOf = function(...)`, matching the file's own
convention. Verified by running both patterns in real Lua: the first reproduces the exact
error text, the second works.

**Prevention:** a repo-wide scan for the same class — any `local function` called earlier in
its own file than it is defined, excluding names in a forward-declaration block — now runs
clean across all eight server and client files. Run it after moving code between blocks. Lua
gives no warning for this: it silently reads a nil global, and inside a callback that means a
request that never answers rather than a visible crash.

---

## [2026-07-26 03:20] — The grey screen: a `<meta name="color-scheme">` in the NUI page

**Context:** six failed fix cycles on a grey sheet covering the whole game. The user finally
isolated it: `stop v-phone` and the game renders normally.

**Error:** `html/index.html` declared `<meta name="color-scheme" content="light dark">`. On a
machine whose OS is in dark mode, that opts the frame into the browser's own dark handling,
and the browser paints an **opaque canvas beneath the document**. In a NUI page that canvas
is a grey sheet over the entire game, present from the moment the resource starts — before
any player loads, which is why it appeared during "Validating characters".

**Root cause of missing it for so long:** the paint happens BELOW the CSS. Three separate
things hid it:
1. `html, body { background: transparent }` is a CSS background and cannot stop a canvas
   painted underneath it, so the file looked correct.
2. Every top-level element carries `hidden`, so a DOM audit found no painter — correctly,
   because there is no element involved at all.
3. **I inspected the live page and reported `getComputedStyle(html).backgroundColor` as
   `rgba(0,0,0,0)`, and treated that as proof the page could not paint.** It was not proof.
   Computed styles describe the CSS box; the color-scheme canvas is frame state below it and
   is structurally invisible to that API. My measurement could never have detected this
   mechanism, and I presented it as though it ruled the page out.

An adversarial review had already nominated this exact tag and then refuted it, reasoning
from FiveM's shipped Chromium version and the `kIfBaseNotTransparent` guard. The reasoning
was careful and it was wrong — it rested on an inference about FiveM's base background
colour that was never observed, only deduced from other pages behaving.

**Fix:** removed the tag from `html/index.html` and from `apps/example/index.html` (the
template every drop-in app is copied from, so it was propagating). Added an explicit
`html { color-scheme: normal; }` guard at the top of `style.css`, which loads last and
therefore wins over any theme or stray tag that tries to reintroduce it.

**Prevention:** never conclude "this page cannot paint" from computed styles or from the DOM
alone — both are blind to frame-level paint. And when a refutation rests on an inference
about the host's behaviour rather than on something observed, record it as unresolved rather
than closed. The cheap test beats the careful argument: this fix was always one deleted line,
and the reviewer said so while refuting it.

---

## [2026-07-26 03:10] — Wrote `player.PlayerData.citizenid` against the bridge's own player

**Context:** writing the qb-phone compatibility bridge, whose handlers need the citizen id of
the player who fired the event.

**Error:** `bridge/server/qb-phone.lua` read `player.PlayerData and player.PlayerData.citizenid`
and, in the contact swap, `p.charinfo.firstname`. `Core.GetPlayer` returns the bridge's own
normalised player from `wrap()` (`bridge/server/framework.lua:174`), which carries
`source`, `citizenid`, `name`, `job`, `lang` and two metadata functions — and nothing else.
The raw qb-core object is read inside the qb branch and deliberately not carried out. So
`PlayerData` was nil on every framework including qb-core, and both handlers returned early:
every job mail and every contact swap silently did nothing, with no error in the console.

**Root cause:** I wrote qb-core code inside a framework-agnostic bridge. The whole point of
`wrap()` is that callers never see a framework's shape, and I reached for the shape anyway
because the surrounding task was qb-core compatibility. The two are unrelated: being
compatible with qb-core's EVENTS does not mean handling qb-core's OBJECTS.

**Fix:** `player.citizenid`, and `a.name` / `b.name` for the display names, which `wrap()`
already builds from `charinfo.firstname`/`lastname`.

**Prevention:** before reading a field off anything `Core.GetPlayer` returned, read `wrap()`
in `bridge/server/framework.lua` and use only the fields it builds. If a field is needed that
`wrap()` does not expose, add it there — once, for every framework — rather than reaching
past it at the call site. A nil field guarded by `if not x then return end` fails silently,
which is why this one would have shipped.

---

## [2026-07-26 02:30] — `requireItem` was a landmine, not a setting

**Context:** making the phone item required by default, which the setting already claimed to
support. The intention was a one-line flip of `Config.Settings.requireItem`.

**Error:** `server/main.lua` read `if num(inv.GetItemCount(src, item), 0) > 0 then` where
`inv` is the merged `v-inventory` provider table. `GetItemCount` is not a key in it. The
provider is merged from exactly two registrations — `bridge/server/integrations.lua:720`
(`{ HasItem = Bridge.HasItem }`) and the stub table in `bridge/shared/compat.lua`
(`RegisterUsableItem`, `HasItem`, `RemoveItem`, `ItemCount`). Turning the setting on would
have raised `attempt to call a nil value (field 'GetItemCount')` on all eight call sites, the
`v-phone:open` callback would never have resolved, and the client would have sat in
`isOpening` until its ten-second guard cleared it — with no error shown to the player.

**Root cause:** the setting shipped with a default of `false` and an early return
(`if not V.SettingBool('requireItem', false) then return true end`) in front of the broken
line. The guard meant the code below it never executed, so nothing — not a load, not a test,
not a play session — ever reached it. A wrong name behind an off-by-default switch is
invisible until the day somebody turns the switch on.

**Fix:** `inv.HasItem(src, item)`, dropping the `num(...) > 0` wrapper because `HasItem`
returns a boolean and `num(true, 0)` is `0`. `HasItem` is the better choice regardless: it is
the only key BOTH providers register, so it does not depend on which registration won the
merge, and `Bridge.HasItem` fails open on a server with no recognised inventory rather than
locking every player out of their phone.

**Prevention:** a config default of `false` is not coverage. Any code path that only runs
when a setting is flipped must be executed at least once with it flipped — or the name it
calls must be checked against the provider table it calls into. When adding a call on a
provider table, grep the registration sites for the key before trusting the name.

---

## [2026-07-26 02:35] — A CHANGELOG section inserted into the middle of another one

**Context:** adding entries for this change under the existing `## [1.2.0]` heading.

**Error:** the new `### Changed` heading and its bullet landed between the first and second
bullets of the existing `### Fixed` list, which silently re-filed nine unrelated entries —
the whole vehicle-remote and music history — under `Changed`.

**Root cause:** the insertion anchored on the section HEADING and offset a fixed number of
lines, rather than finding where that section ENDS. It also assumed one version block per
release; this changelog has two, English then French, each with its own `## [x.y.z]` heading.

**Fix:** restored from git, then re-inserted by scanning forward from each heading to the
next `###`/`##`/`---` and appending there, working bottom-up so earlier line numbers stay
valid.

**Prevention:** never insert into a structured document by line offset from a heading.
Find the section boundary. And check the document's shape first — this one mirrors every
release in two languages, which a single `## [1.2.0]` search does not reveal.

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
