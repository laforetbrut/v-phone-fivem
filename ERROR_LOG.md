# Error log

Problems hit while working on this resource, what caused them, and the rule that stops each
one coming back.

---

## [2026-07-29 02:10] — a callback shipped with no handler, caught by a checker written the same hour

**Context:** adding "leave a group". The server callback, the sheet, the confirmation and the
strings were all written and all correct.

**Error:** none, and that is the point. `python tools/check.py` reported
`groupLeave (the screen would wait for ever)`.

**Root cause:** `post('groupLeave')` on the page is an HTTP call to the resource, which FiveM
delivers to `RegisterNUICallback('groupLeave')` on the CLIENT. I wrote the page half and the
server half and never wrote the one-line relay between them. Nothing would have said so: the page
awaits a reply that nobody sends, so the sheet sits there and the player taps again.

**Fix:** one line beside the other group relay. Then re-ran the checker.

**Prevention:** the class is "two halves of a contract, written in different files, joined by a
string". It cannot be caught by reading, because reading is what missed it. It is trivially caught
by comparing the two lists mechanically, which is now `tools/check.py`. The wider rule: when a
name has to match across a boundary, write the checker before the second half - it costs less than
finding out from a player.

---

## [2026-07-29 01:30] — a checker that reported nine things and was wrong about all nine

**Context:** building a check for "a class the page writes with no rule behind it", a bug this
repo has hit at least twice.

**Error:** it reported nine classes. Every one was fine.

**Root cause:** the project uses a class as a CLICK HANDLE as often as a style hook.
`class="row lead socfind"` is `.row` and `.lead` for the look and `socfind` for the listener, and
`.boothdial` is a bare wrapper whose children carry all thirteen rules. A checker that does not
know that reports the entire idiom.

**Fix:** only a class that is the ONLY one on its element is a finding; one sitting beside styled
classes is reported as a note and nothing more. That took nine to one, and the one is a wrapper
confirmed by hand and named in the source so a NEW unstyled class stands out against it.

**Prevention:** a checker's first output is not a bug list, it is a measurement of the checker.
Triage every hit by hand before trusting any of them, and tighten until the noise is gone - a
checker that cries wolf is worse than no checker, because the next real hit is scrolled past.
This is the second time that lesson has been paid for here; the first was the called-but-undefined
sweep that produced thirteen false positives and was deleted.

---

## [2026-07-29 00:45] — the only thing that plays a notification is only reachable when the phone is open

**Context:** https://github.com/laforetbrut/v-phone-fivem/issues/7 - no notification sound with the
phone closed. Filed separately from "sometimes the ringtones work and sometimes they do not",
which turned out to be the same thing seen from the other side.

**Error:** no message, no log. Silence.

**Root cause:** `playAlert` is called from exactly one place, `banner`, and `banner` is only
reached while the phone is OPEN. A closed phone is sent `archive` (file the card) and `peek` (lift
the handset and shake the pad), and neither makes a sound. So the alert tone worked when the
player happened to be looking at the screen and never when the phone was away - which nobody
reports as "closed phones are silent", they report it as "the ringtone works sometimes".

**Fix:** the archive plays it. The archive rather than the peek deliberately: the peek is optional
and turning off an animation must not take the sound with it.

**Prevention:** when a report says "sometimes", find the condition rather than the intermittency -
there usually is not one. And a function with exactly one caller is a function whose reachability
IS its caller's: ask what cannot reach it before assuming everything can.

---

## [2026-07-29 00:10] — a ringtone restarted by the thing that was supposed to keep it playing

**Context:** "sometimes the ringing works, sometimes it does not, sometimes it stays stuck".

**Error:** no message. A ringtone that stutters, and an MP3 that never gets past its first second.

**Root cause:** `renderCall` asks for the ringtone whenever the call is inbound, and it runs on
every push the server makes about that call - the roster, the signal bars, the state, the timer.
`playRingtone` opened with `stopTone()`, so each of those tore the sound down and started it
again. The built-in tone reset its 1600ms interval before the interval could come round; a
player's own file restarted from zero several times a second.

**Fix:** the ring is asked for by DESCRIPTION - the tone and the URL - and started only if that
description is not already what is playing. Ten calls in a row now play one ringtone. Plus a
two-second check that stops a ring with no call behind it, whatever the reason, and a release of
the game-side ring when the resource stops, which `Remote_Ring` needed because it loops until
something stops it and a restart was not something.

**Prevention:** an idempotent operation and a repeated one are different functions. "Make it so"
must not be written as "tear it down and do it": anything called from a render path will be
called far more often than its author is picturing, and a render path is the normal place to ask
for state. When the answer is a resource with a lifetime - a sound, a timer, a socket - compare
before acting.

---

## [2026-07-28 22:40] — a position used as an identity, in a list rebuilt on every read

**Context:** a player reported that tapping a folder answered "that folder is no longer there"
about a folder plainly on the screen.

**Error:** no message. The toast fired and the folder did not open.

**Root cause:** every folder action took an INDEX into `layoutItems()`, and that function does not
return a stored list: it rebuilds one on each call from the saved arrangement and the installed
apps, dropping folders whose apps are all gone, de-duplicating ids and normalising page breaks.
Two calls agree only while nothing underneath has moved. The index was captured when the tile was
drawn and spent when a finger came off it, and anything in between - a refresh landing, an app
arriving, a repaint from a different array - shifted what it named. The code's own comment said
the index had already been got wrong in three separate places, which was the evidence that the
index was the fault and not any of the three sites.

**Fix:** a folder carries its identity on the tile - its name and its apps - and every action
resolves by that first. The position survives only as the tiebreak for two folders that are
genuinely identical, where the key cannot tell them apart and nothing else can either. Verified by
building a deliberately stale grid in the real page: the old path resolved the wrong item, the new
one opens the right folder, and no toast fires.

**Prevention:** an index into a list that is DERIVED rather than stored is a bug waiting for the
list to change. When a handler will be spent later than it was made - a timer, a sheet, a
pointerup, an await - it must carry what the thing IS, not where it was. The tell is a function
that recomputes its list from source on every call and hands out positions into it.

---

## [2026-07-28 21:10] — two readers of one table disagreeing about what is in it

**Context:** deleting a conversation left the contact and the last message in the Messages list.

**Error:** no message. Opening the thread showed nothing; the list went on naming the person.

**Root cause:** clearing a thread hides every message in it, one row per message in
`vphone_message_hidden`. `conversation` - the thread view - filtered on that table. `conversations`
- the list - did not, and neither did the unread count beside it. So the deletion happened, and
half the app was told.

**Fix:** the same filter in both queries, and inside the grouped subquery rather than around it so
the newest VISIBLE message is what names the thread. A counterpart whose every message is hidden
produces no group and no row. `UnreadCount`, which a HUD outside the phone reads, was closed the
same way so the two cannot contradict each other.

**Prevention:** when a filter defines what a reader may see, every reader of that table needs it.
A filter on the detail and not on the summary is a deletion that half happened. Grep the table
name, not the function you changed.

---

## [2026-07-28 20:15] — half a feature, because only calls were wired

**Context:** https://github.com/laforetbrut/v-phone-fivem/issues/6 - nobody nearby hears anything.

**Error:** no message. The reporter's own reproduction is a message, not a call.

**Root cause:** ring-out shipped for CALLS. A phone receiving a text made no sound in the room at
all, so half of "a phone is a sound in the room" had never been built. Time went into asking
whether the call ring was audible, which was the half that already worked.

**Fix:** an arrival makes one tone, sent to whoever is in earshot by the same rules the ring uses.
It does not loop, so nothing can outlive it. `phonedebug ringout` now plays both sounds so the two
possible causes of "I hear nothing" can be told apart in five seconds rather than guessed at.

**Prevention:** when a report and a feature disagree about which case is broken, read the
reproduction rather than the feature. And a feature described as "X is a sound in the room" should
be checked against every X, not the one that prompted it.

---

## [2026-07-28 19:30] — equal specificity, so the later rule won

**Context:** a screenshot of a photograph in a message framed in green.

**Error:** no message. A sent picture kept the bubble tint behind its padding; the same picture
received drew correctly.

**Root cause:** `.bub.imgb` clears the background behind a picture and `.bub.me` paints the sent
bubble. Both weigh 0,2,0, and `.bub.me` is written 1,800 lines further down, so at equal
specificity source order decided it and the override lost. The received case only looked right by
accident: `.bub.them` happens to be declared ABOVE the rule meant to beat it. That asymmetry is
what made this read as a picture bug rather than an ordering one.

**Fix:** both classes named in one selector, which outweighs either rule wherever they move to.
Measured in the real page with the new rule switched off and on: tint plus gradient without it,
transparent with it.

**Prevention:** an override that relies on being further down the file is not an override. When a
rule exists to beat another, say so in its selector. And check both sides of a symmetric pair -
one of them working is not evidence, it can be a coincidence of ordering.

---

## [2026-07-28 15:05] — a looping sound with a lost id rang until the player reconnected

**Context:** 1.5.2 made the nearby-phone ring configurable, because "nobody around me hears my
phone" had two possible causes and no way to tell them apart. Two versions later, players
reported the opposite: a caller standing next to the phone being rung heard the tone for ever.

**Error:** no message. `Remote_Ring` kept playing on the caller's client with nothing able to
stop it, through answering, hanging up and walking away.

**Root cause:** mine, and introduced by that same 1.5.2 change. The original loop was
`PlaySoundFromEntity(id, ...)`, `Wait(1400)`, `StopSound(id)`, `ReleaseSoundId(id)`, so the
stop was in the same iteration as the start and could not be missed. I replaced it with a
`SetTimeout(1500, ...)` and a local `id`, which broke the link between the sound and the loop
that owned it. `Remote_Ring` LOOPS: it plays until `StopSound` is called on its id. Clearing
`ringingPeds[who]` ended the loop and left whatever was playing to a timer, and any id whose
timer had already fired while the loop went round was unreachable. An unreachable id on a
looping sound is a sound that plays until the client restarts.

**Fix:** `ringOutIds[who]` holds the live id per player. `ringOutStop(who)` is called before
each new pass so ids cannot pile up whatever the repeat interval is set to, when the loop ends
however it ends, and by the event that says the ringing is over rather than at the loop's next
turn (that loop sits inside a Wait of up to a second and a half).

**Prevention:** when a resource is acquired and released in one iteration, moving the release
onto a timer changes an invariant, not just a schedule. Ask what happens if the loop exits
between the two. And a looping game sound needs its id reachable from whatever ends it, so
store it where the stopper can see it rather than in the closure that started it.

---

## [2026-07-28 14:40] — a passcode that cleared itself, from a view written back over the record

**Context:** players reported that the six-digit code and Face ID cleared themselves "often,
and at every reboot". Two symptoms in one sentence, which turned out to be two separate bugs.

**Error:** no message. `securityEnabled` came back false and the phone opened with no lock.

**Root cause:** two, and both had to go.

The "often" half: `prefsOf` is a VIEW of the stored record. It applies defaults, clamps values,
and leaves `passcodeHash` out unless the caller passes `includeSecrets`. The app-store install
path read that view and wrote it straight back over the record, so the digest went with it. The
next read computes "is security on" from the digest being non-empty, so the code and the Face ID
vanished together, on every install and every removal.

The "every reboot" half: the write was `SetMetadata`, which fires the query and returns. An
un-awaited query dies in the queue when the process tears down. The bridge already carried a
comment saying exactly this, written when the same failure was fixed for the battery and again
for photographs. The preferences had been left on the async write.

**Fix:** one function, `savePhonePrefs`, is the only thing that writes that record. It re-reads
the stored digest and merges it back in whatever the caller hands it, then waits for the row to
land. The health record, the Zuber favourites and the charging preferences were moved to the
waited write too. The step counter was deliberately left async: it runs on a timer while
somebody walks, and losing a few paces to a restart is not something anybody can notice.

**Prevention:** never write a sanitised view back over the record it was read from. A view
exists to drop things, so writing it back drops them from storage. Either read the raw record,
modify the fields you own and write that (which is what the public API exports already did
correctly), or funnel every write through one function that reconciles what the view omits.
And when a report contains two adverbs of frequency, treat it as two bugs until proven
otherwise.

---

## [2026-07-27 23:05] — a guard meant for joining also rejected every leave

**Context:** the staff voice broadcast. A player reported that after `/phoneadmin voice stop`
everyone on the server could still hear each other talking.

**Error:** no message. The broadcast stopped, the speaker went quiet, and every listener stayed
audible to every other listener until they reconnected.

**Root cause:** the voice shim was one expression with one guard:

    local n = math.floor(tonumber(channel) or 0)
    if n <= 0 then return false end
    return pcall(function() exports['pma-voice']:setCallChannel(on and n or 0) end)

The guard is right for joining, since there is no channel zero to join. But `vbRelease` leaves
by calling this with channel 0, which is how pma-voice itself spells "leave the call", so every
release hit the guard and returned false without ever reaching `setCallChannel`. The volume
overrides were handed back correctly, which is why the speaker went quiet and the failure
looked like it had worked. A broadcast channel is MUTUAL, so nobody leaving it meant a server
full of open microphones.

**Fix:** leaving is decided before the channel number is looked at. A number is only needed to
arrive somewhere. Verified in real Lua across five cases including "joining channel 0 is still
refused".

**Prevention:** a validation guard on a parameter must be scoped to the operations that use
that parameter. When one function does two jobs and only one of them needs an argument,
validate inside the branch, not at the top. Watch for the shape `on and X or Y`: it hides the
fact that the two paths have different preconditions.

---

## [2026-07-27 22:50] — a redirected GetPlayer bound the wrong source to a phone number

**Context:** staff can hold a player's phone and act as them. A player reported that after the
admin released it, the admin kept receiving their notifications.

**Error:** no message. Worse than reported: the owner stopped receiving their own messages and
calls entirely, and releasing the phone did not undo it.

**Root cause:** `Core.GetPlayer` is redirected while a phone is held, so the phone's boot
callback ran with the TARGET's player object and the ADMIN's source id. `ensureNumber` writes
`Online[number] = src` from that pair, which pointed the player's own number at the staff
member. Nothing rewrote the map on release, so it survived the session and lasted until one of
them reconnected.

**Fix:** `ensureNumber` asks `AdminViewTarget(src)` and refuses to bind a number when the
source is only looking at that character. The number is still returned, because it is drawn on
the screen they are looking at; only the routing is withheld. Releasing a session also rebinds
the character to their real source, which repairs a binding taken before the fix rather than
waiting for a reconnect.

**Prevention:** where a framework accessor is deliberately redirected for impersonation, every
write keyed on `source` is suspect. Redirection changes who the object describes but not whose
machine the id belongs to, so any code pairing the two is writing a relationship that is half
one player and half another. Audit for `X[fromPlayerObject] = src` whenever an impersonation
layer exists.

---

## [2026-07-27 22:20] — a const read above its own declaration, invisible to every check

**Context:** the player crashed in FiveM and asked whether the phone had caused it. The crash
itself was an early-exit trap with nothing tying it to this resource, but the client log carried
a real error from the phone, eleven times over.

**Error:**

    Uncaught ReferenceError: Cannot access 'chosen' before initialization
    (@v-phone/html/app.js:11553)

**Root cause:** `zuberCheckout` computed the loyalty discount twenty-five lines above the
`const chosen` it reads. `const` is hoisted but unreachable until its declaration runs, which is
the temporal dead zone. The Zuber basket therefore threw before drawing anything, every time,
and had done since 1.4.4. Nothing caught it: it is not a syntax error, so `node --check` passed,
and every test in the suite passed because they all assert on source text rather than running
the page.

**Fix:** the loyalty block moved above the money block, which had no dependency on it. A static
check for the whole class of mistake now runs with the rest of the suite and was verified
against the version that had the bug, where it reports both `points` and `chosen`.

**Prevention:** `node --check` proves a file parses, not that a line can run. For a page nobody
loads in CI, add checks for the failure modes that parse cleanly: a name read above its own
`const`/`let`, and a function called but defined nowhere. Write them against a version that has
the bug before trusting them, and delete a checker that produces false positives rather than
keeping one that teaches you to ignore it (my first attempt at the second check produced
thirteen and zero real, so it was dropped).

---

## [2026-07-26 10:30] — One nil call, five wrong fixes, and a probe that lied

**Context:** the Camera app showed no preview, and after taking a photograph the player was
stranded in the phone with no cursor and no way out. Five fixes were shipped for this. None of
them touched the cause.

**Error:** `client/main.lua` called `CellFrontCamActivate` at four sites and defined it at
none. It is not a FiveM native — it has no name in the native list and can only be reached by
hash. So it was a nil global, and the call raised on the first line after
`CellCamActivate`, aborting the rest of the handler:

    camActive = true
    CellCamActivate(true, true)
    CellFrontCamActivate(camFront)      -- raises here
    SendNUIMessage({ action = 'camLive', on = true })   -- never sent
    SetNuiFocus(false, false)                          -- never ran
    CreateThread(...)                                  -- never spawned

That one line caused BOTH symptoms. No `camLive` meant the class that makes the screen
see-through was never applied, so there was no preview — and **the CSS was never under test at
all**. No thread meant no shutter key and no exit key. And `camActive` latched true, which is
exactly the condition I had added to `shoot` to stop it restoring the cursor, so the cursor
never came back.

**Why five fixes missed it:** I diagnosed by symptom and fixed the first plausible mechanism
each time — a convar read on the wrong side, an absent payload field, a specificity loss, a
backdrop-filter, a bezel pseudo-element. Every one of those was a real defect. None was
reachable, because the code that would have exercised them was dead. I never checked that the
handler ran to completion.

**And my own probe lied to me, three times, the same way.** It read `backgroundColor`. Three
of the layers that were blacking the screen paint a background-IMAGE — `.bezel`'s titanium
gradient, `.camui`'s `#000` under a gradient, and a dark-mode-only app surface at
`style.css:7193` that is (0,6,0) and silently out-specified my (0,4,0) reset. The `background`
shorthand zeroes background-color, so all three reported as transparent. I wrote "none of the
six paint any more" and believed it.

**Fixes, in the order they were applied:**
- `frontCam(on)` wrapper over `Citizen.InvokeNative(0x2491A93618B7D838, ...)`, pcall'd, since
  the hash is undocumented and a rejection should cost the selfie and not the phone.
- Every camera path now assigns state and restores focus BEFORE touching the engine, with the
  natives inside `pcall`. `closePhone` releases focus before `camModeOff` for the same reason.
- A watchdog in the guard thread: `camActive` is cleared only by `camModeOff`, which only the
  camera thread calls, so a thread that never spawns leaves the flag with no owner. If it is
  set with no heartbeat for 1.5s, the guard ends camera mode.
- `forceReset` — the documented way out of a stuck phone — now clears the camera too; it was
  freeing the cursor while leaving the game in cellphone-camera view.
- Controls 1 and 2 are released during camera mode. The guard blocked look left/right and
  up/down the whole time, so even a working viewfinder could not be aimed.
- The CSS became ONE flagged rule over seven selectors plus the wallpaper, replacing six that
  competed on specificity. Verified in a browser on `backgroundImage` as well as colour, in
  DARK mode where the (0,6,0) rule lives: ten elements and pseudo-elements, all reporting they
  paint nothing.

**Prevention:**
- When a feature does nothing at all, prove the entry point runs to its last line before
  theorising about anything it was supposed to do. A raise mid-handler looks exactly like
  fifteen different configuration bugs.
- Never call a name that is not defined in the file and not a documented native. A grep for
  the definition costs one command.
- A probe that reads `backgroundColor` cannot see a gradient. Read `backgroundImage` too, and
  check pseudo-elements, or the probe will keep confirming what you hoped.
- Assign state and hand back control before calling into the engine. Anything after a native
  that can raise is code that might not run.

---

## [2026-07-26 09:10] — The battery emptied in half an hour whatever it was set to

**Context:** the user reported the battery draining far too fast. I raised `hoursToEmpty`
twice — 8 to 48, then 48 to 72 — and wrote out the arithmetic each time. It made no
difference, because the setting was never involved.

**Error:** the drain loop read its starting value through `batteryOf`, which FLOORS:

    setBattery(src, batteryOf(src) - drainPerTick * mult)

At 72 hours a tick removes 0.0077%. So: floor(100) - 0.0077 = 99.99 stored; next tick
floor(99.99) = **99**, minus 0.0077 = 98.99; then 98. A whole percent every twenty seconds,
independent of the configured rate. Simulated in real Lua across 8h/3x and 72h/1.5x, screen on
and off: every combination emptied in 0.56 h. The user said "barely 30 minutes".

**Root cause:** one function serving two purposes. `batteryOf` exists to give the status bar a
whole number, and it was also the only reader, so arithmetic inherited the rounding. The
rounding then WAS the drain, and it swamped the real one by two orders of magnitude.

**Why I did not see it for two rounds:** I checked the formula, and the formula was right. I
computed 1.39%/hour by hand, wrote it in a comment as if that settled it, and never ran the
loop. A closed-form calculation cannot show you that the value you feed back in is not the
value you wrote out. Simulating twenty seconds of it would have.

**Fix:** `batteryRaw` returns the unrounded stored level, and every arithmetic site uses it —
the drain, the charge, the power bank and the AddBattery export, which had the same flaw in the
other direction. `batteryOf` keeps its job: display.

**Prevention:** never do arithmetic on a value that has passed through a display formatter. And
when a rate is wrong by an order of magnitude, simulate the loop rather than re-deriving the
formula — the formula was correct every time I checked it.

---

## [2026-07-26 08:05] — Every photo upload rejected: multipart never happened

**Context:** with the Camera app finally reachable, taking a photo failed with
`400 {"error":"request Content-Type isn't multipart/form-data"}` from Fivemanage.

**Error:** `exports['screencapture']:remoteUpload(source, url, options, callback)` was called
with four arguments. Its real signature is

    remoteUpload(source, url, options, callback, dataType = "base64")

and inside, `createRequestBody` builds a `FormData` — the only path that sets a multipart
Content-Type — **only when dataType is `'blob'`**. On the default `'base64'` it posts the raw
string with nothing but the caller's own headers, so the request carries no Content-Type at
all and any API expecting multipart refuses it.

**Fix:** pass `'blob'` as the fifth argument. Read out of the resource's own bundle rather
than guessed: `uploadFile` branches on `body instanceof FormData`, and `createRequestBody`
gates that on the dataType.

**What NOT to do, checked while fixing it:** the video call looks parallel but is not.
`startVideoCaptureUpload(source, url, options, callback, legacyCallback)` takes a BOOLEAN
fifth, so adding `'blob'` there would have silently switched its callback convention. Video
uploads a file from disk and builds its own FormData, so it needed nothing.

**Prevention:** a defaulted trailing parameter in a third-party export is the kind of thing
that changes the wire format without changing the call. Read the signature in the shipped
bundle before assuming a four-argument call is complete — and never copy a fifth argument
from one export to its neighbour on the assumption they match.

---

## [2026-07-26 07:40] — The camera gate accepted only one of its two destinations

**Context:** the Camera app reported "disabled on this server" across five rounds of fixes on
a server where everything was configured correctly.

**Error:** the open payload built `camera` as

    V.SettingBool('camera', false) and (tostring(V.Setting('cameraUpload', '')) ~= '') or false

There are TWO places a photo can go: `Config.Media` (screencapture uploading to a CDN, with
the API key kept server-side) and `cameraUpload` (screenshot-basic posting to a URL). This
accepted only the second. A server running the first — the better of the two — got the app
switched off with nothing it could change to fix it.

**Root cause of five rounds, and it is a method failure, not a code one:**

1. I grepped the payload for `^\s+camera = ` and got one hit, then asserted the key was
   "absent" and added my own. The existing key is written `camera     =` with several spaces;
   my pattern required exactly one. **A negative grep result is not evidence of absence** — it
   is evidence about my pattern. I built three commits on top of that assertion.
2. I fixed two real bugs on adjacent links of the same chain (the client reading
   `Config.Media.enabled` while the server resolved a convar; the page treating an absent
   field as off) and each felt like the fix, because each was genuinely wrong. Neither was
   this.
3. What finally settled it was printing the resolver's INPUTS beside its output. The line
   `camera inputs: convar=true config=true resolved=true` next to `payload: camera=false`
   proved in one glance that something wrote the field after the resolver ran. I added that
   diagnostic four rounds too late.

**Fix:** the gate is `V.SettingBool('camera', true) and (MediaEnabled() or cameraUpload ~= '')`.
Truth table run in real Lua across all five combinations, including this server's exact shape
— media live, no upload target — which now enables the app. The duplicate key I had added is
gone.

**Prevention:** when a grep is the basis for a claim about absence, widen it and count, or
read the block. And when a value is wrong, print the inputs that produced it before theorising
about which of them is wrong — one line of that would have replaced four rounds of it.

---

## [2026-07-26 07:00] — The camera flag was never sent, and I repeated the scope bug fixing it

**Context:** the Camera app reported "the camera is disabled on this server" no matter what
the operator configured. `set phone_camera true` was in server.cfg and changed nothing.

**Error:** the page decides from `state.camera`. The `v-phone:open` payload did not contain
`camera` — not wrongly, not stale, absent. So the page read `undefined`, took it as off, and
said so. The app has never opened for anybody on any server since it was written.

**Why it took several passes:** the previous round found a real and adjacent bug — the client
reading `Config.Media.enabled` from the file while the server resolved `phone_media` from a
convar — and fixing it felt like fixing this. It was a different link in the same chain:
that one governs whether a photo can be UPLOADED, this one governs whether the app exists at
all. Two switches, both off, one visible symptom. I should have traced the exact string in the
screenshot to its condition before touching anything; `ph.camera_off` comes from
`if (!state.camera)` and nothing else, and grepping the payload for `camera` would have taken
a minute.

**And I reproduced the `prefsOf` bug while fixing it.** The startup report I added called
`apiKey()` from a `CreateThread` placed ABOVE the `local function apiKey` that defines it.
Lua resolves that name at compile time, so the closure captured the nil global; the
`Wait(3000)` inside makes no difference, which is exactly the trap. Caught before shipping by
re-running the use-before-definition scan I wrote for `prefsOf` — which now covers 24 files
and comes back clean.

**Fix:** `camera` is sent in the open payload. `Config.Settings.camera` now ships ON, because
a phone with a camera icon that opens onto "disabled" is a poor default and it is what hid
this for so long. And `server/media.lua` prints one line at startup saying what the camera
will actually do — off, uploading through screencapture, uploading through screenshot-basic,
or on with nowhere to put a photo. Three things can be missing and nothing said which.

**Prevention:** when a symptom is a literal string on screen, find that string's condition
first and check every input to it, before forming a theory. And run the scope scan after
adding any `CreateThread` that calls a local — a delay inside the thread does not change
when the name is bound.

---

## [2026-07-26 06:20] — Blocked the camera myself, then broke the glass twice chasing a square

**Context:** two long-running complaints — Alt not freeing the camera, and a black square
behind the phone whenever an app was open.

**Errors:**

1. **Alt.** Four attempts, each fixing a real defect and none fixing the symptom: reading the
   key in Lua (the browser holds the keyboard), dropping focus and polling for release (the
   game had not registered the key yet), `SetNuiFocus(true, false)`, then a settle delay.
   The actual cause was in `Config.Hold.block`, which lists controls **1 and 2** — look
   left/right and up/down — and the guard thread disables every entry in it EVERY FRAME while
   the phone is open. So focus was released correctly all along, the game did have the mouse,
   and my own guard threw the camera movement away sixty times a second.
2. **The black square.** Three guesses, each removing something real and none of them the
   cause: 44 `backdrop-filter` declarations (which made every panel see-through), the bezel's
   shadow, then the full-screen `.app` backdrop-filter (which made the apps transparent). Two
   of the three visibly broke the phone.

**Root cause of the pattern, which matters more than either bug:** I was proposing mechanisms
and shipping them as fixes. Each mechanism was genuinely capable of producing a dark rectangle,
so each felt like an answer — but I could not see the rendered result, and a mechanism that
COULD cause a symptom is not evidence that it DID.

The user's own observations were better data than my reasoning every single time: "only when I
am in an application" localised it to app-open state; "it appeared with the zoom problems"
dated it to a specific commit range. I under-weighted both.

**Fix:** `style.css` restored wholesale to the last state the user had confirmed looked right
(`23ee55a^`), then only the two structural fixes that were independently verified re-applied —
`#appfoot` above the home indicator, and the social tab bar's bottom padding. The guard now
leaves controls 1 and 2 alone while free look is on.

**Prevention:** when the symptom is visual and cannot be observed from here, do not ship a
mechanism as a fix. Restore to a state the user has confirmed, change ONE thing, and let them
look. And when a change is a guess, say so in the message rather than describing it as the
cause — three of these were written up as though they were established.

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
