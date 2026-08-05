# Error log

Problems hit while working on this resource, what caused them, and the rule that stops each
one coming back.

---

## [2026-08-05 22:40] - Two sweeps over one table, and the shorter clock won in silence

**Context:** wiring `socialRetentionS3` into `socKeep` so the social retentions follow the media
provider. Checking what else deletes those rows before claiming the setting worked.

**Error:** `Config.Settings.socialRetentionPosts = 60` had no effect. `vphone_social_posts` is swept
by `socialSweep` in server/social.lua on that number AND by `PhoneRetentionSweep` in
server/retention.lua on `Config.Retention.socialPosts = 30`, both hourly. Thirty won. The setting
had read sixty for four releases and the docs said sixty; posts went at thirty. `socialRetentionS3`
would have been dead on arrival for the same reason - a hundred and eighty days of feed against a
thirty-day delete in another file.

**Root cause:** two files owning one question. server/retention.lua was written to gather the
phone's retentions into one place and took a copy of the social numbers instead of asking for them,
so the two drifted the moment either moved. Neither sweep knew the other existed, so there was
nothing to log and no way to see it short of reading both files.

**Fix:** `SocialKeepDays` in server/social.lua is the single answer - convar, then a
`Config.Retention.social*` key a server set for itself, then `socialRetentionS3` on s3, then
`Config.Settings` - and retention.lua asks it for all four tables. The four social keys left the
shipped `Config.Retention` so the settings can apply, and are still read first when present, so an
existing config decides as it did. `tools/test-social-retention.py` asserts the two call sites
agree per table on both providers, and was run with each half of the old arrangement put back.

**Prevention:** before believing a setting works, grep for every statement that deletes from the
table it governs. A number that is read in two files is a number that is wrong in one of them, and
the sweep that loses is invisible: it deletes nothing, prints nothing, and looks correct in review.

---

## [2026-08-05 22:10] - A fallback chain read a typo as an absence

**Context:** wiring `Config.Settings.socialRetentionS3` into `socKeep` in server/social.lua, so the
four social retentions follow the media provider. The convar has to keep winning over both tables,
and `V.Setting` cannot express that on its own - it falls back to `Config.Settings` before it ever
reaches a default, and on s3 those four values are exactly what is being replaced.

**Error:** the first version asked `tonumber(GetConvar(...))` and treated a nil as "no convar". With
`set phone_socialRetentionPosts never` and `provider = 's3'`, posts went from being kept for ever to
being deleted at 180 days. Caught by a harness that ran the real function under Lua 5.4 with the
provider, the convar and both tables faked, before any of it was committed.

**Root cause:** "does not parse as a number" and "was never set" are different states, and the code
collapsed them. A convar that is set is the operator speaking, whatever they typed; the answer the
resource has always given to an unparseable one is 0, keep for ever, because `V.Setting` hands the
string back and `tonumber` fails on it further down.

**Fix:** the test is `GetConvar('phone_' .. key, '') == ''` - the existence of the convar, not its
value. Empty counts as unset, which is what `V.Setting` already does, so both agree on which values
are the operator speaking. Seventeen cases now cover it, including the typo.

**Prevention:** when a new source is inserted into a resolution chain, enumerate the states of the
old one first and check each survives. A `tonumber` in a condition merges two of them silently, and
the one it merges is always the one nobody types on purpose.

---

## [2026-08-05 21:10] - Zero dead space was the wrong target, and it reached the game

**Context:** the collapsed nav bar reserved 54px of nothing below its row and drew the hairline
under the lot. The measurement was right and the fix removed all 54.

**Error:** reported in game, with a screenshot. "Le trait est beaucoup trop haut maintenant il
touche les boutons" - the rule under the header ran into the two circular buttons and cut them.
Seen in OnlyFruits, Messages and every other app.

**Root cause:** the bar's bottom was derived from the row and nothing else, so the row's bottom
edge and the bar's bottom edge became the same line. A header needs the row PLUS the space the
platform leaves under it; removing the wrong space and removing all the space are different
fixes and I shipped the second one.

**Fix:** `--nav-gap`, measured rather than chosen. `Examples/Toolbars - Top.svg` in the iOS 26 kit
draws a compact top toolbar as a `402 x 116` chrome band at `translate(24 23)` with its two
`44x44 rx=22` buttons at y 85, which is screen y 62 to 106: the band ends **ten pixels** below the
buttons, and `Scroll Edge Effect - Hard.svg` puts the hairline on that band's inner edge.
Confirmed independently in `Examples/Menus.svg`. Cross-checked in the large-title state against
`Examples/List.svg`: its grouped card starts 121 below that kit's status bar, ours starts 122
below `--nav-top`. The gap is the same in both states, so the collapsed bar still hands back
exactly the large title's block and the content still does not move.

**Prevention:** when a measurement says a value is wrong, it has said nothing about what the right
value is. Go back to the reference for the replacement instead of taking the nearest round number,
and state the file it came from so the next person can check it.

---

## [2026-08-05 21:35] - A sweep that stepped by eleven, and a midpoint that meant nothing

**Context:** after the ten-pixel gap landed, `tools/probe-input.js` failed: "no control ever
scrolls into the band (Settings, 17 positions): 1 caught, e.g. Informations".

**Error:** it looked like the fix had pushed a row into the home indicator's hit band. It had not.

**Root cause:** two faults in the check, both of which read as a pass until something moved.
The sweep stepped through the scroll range by 11, which visits 17 of 173 positions; an exhaustive
sweep of the SHIPPED tree flags the same two rows at offsets 26 and 78, which no multiple of 11
ever visits. Making the body ten pixels shorter moved those offsets to 36 and 88, and 88 is a
multiple of 11. The phone's behaviour at the bottom of the screen was byte-identical before and
after - measured both ways.
The second fault is why those rows were flagged at all: the check judged a control by whether its
MIDPOINT was in the band. A row half-clipped by the scroller has its midpoint exactly on the
body's bottom edge, which is exactly where the band starts, and not one pixel of it is painted
below that edge. It also missed the real case in the other direction - a row whose top half is in
the band and whose midpoint is above it is pressable inside the band and was never counted.

**Fix:** the sweep visits every position, and a control is judged by how much of it is both
VISIBLE and inside the band, which is the area where a press meant for the row goes home instead.
Proved able to fail rather than assumed: with `.app:not(.hasfoot) #appfoot { height: 0 }`, the
exact defect the reserve exists to prevent, the new check reports three controls and 39.95px of
pressable area in the band. On the shipped tree it reports 0.00px over 173 positions.

**Prevention:** before changing a check that has started failing, prove which of the two moved -
the phone or the sampling. Run the check exhaustively on the shipped tree first. And a check that
is relaxed must be shown to still fail on the defect it was written for, in the same session.

---

## [2026-08-05 20:05] - A transition on a height that cannot interpolate clamped the scroller

**Context:** making the collapsed nav bar hand back the block its faded large title was holding,
with the app body taking exactly the same number as scroll padding so nothing on screen moves.
Both sides were given `transition: .2s ease` so they would cancel at every frame and not only at
the ends.

**Error:** they did not cancel at all. Measured on Settings: a scrollTop of 140 came back as 114
and stayed there. The content jumped 26px and did not come back.

**Root cause:** `height: auto -> 0` is not interpolable. The bar snapped shut in one frame while
the body's `padding-top` eased in over 200ms, so for those 200ms the scroller's box was 54px
taller than its content had grown to allow. Chromium clamps the scroll offset to fit, and a clamp
is destructive: the position does not come back when the padding catches up.

**Fix:** neither side transitions. One style change, one layout pass, both halves moving together.
Verified over 60 frames crossing the threshold in both directions in two apps: 0.00px of content
drift, and `scrollHeight - clientHeight` identical before and after the collapse. The title's own
fade is kept by NOT clipping it - its box collapses at the same top edge, so the text overflows
into the pixels it already occupied and finishes the fade there, with `pointer-events: none` so
the invisible band cannot eat the first content row's taps.

**Prevention:** a compensating pair of layout changes must land in the same style recalculation.
If either half is animated, both must be, with the same easing AND with properties that actually
interpolate - `auto` on either end of a length means the transition silently does not run.

---

## [2026-08-05 19:55] - A one-shot animation class that nothing ever removed

**Context:** stopping the entry stagger from replaying on a tab tap. After the gate landed, the
harness reported `ph27-push` firing on the tab bar tap where it had reported `ph27-view-in` before.

**Error:** the animation had not gone away, it had changed name. `.appbody.pushin > *` and
`.appbody.view-enter > *` both set `animation`, so only the later rule ever ran; suppressing
`view-enter` simply revealed the one underneath it.

**Root cause:** `pushAnim()` adds `pushin` and nothing took it off. `body()` clears
`frame-loading`, `view-enter` and `fitbody` for exactly this reason and `pushin` was missed, so a
screen that had once pushed replayed the push over its whole body on every render afterwards.

**Fix:** cleared in `body()` with the others. Every caller of `pushAnim()` runs it immediately
after `body()`, so the push itself costs nothing.

**Prevention:** when a fix removes one animation, count the animations that actually fire
afterwards rather than assuming the number went down. A second rule setting the same property was
invisible until the first one stopped winning.

---

## [2026-08-05 18:40] - A guide layer outside the handset ended up inside the photograph

**Context:** making the camera's viewfinder see-through. The rule-of-thirds grid was moved out
of the phone and onto a layer over the whole viewport, because both capture paths grab the
screen with no crop and thirds drawn inside the handset mark the thirds of a rectangle in the
corner of the picture rather than of the picture.

**Error:** the first screenshot taken of the capture state showed the handset correctly gone
and four white hairlines still drawn across the frame. Everything the guard was written for had
worked; the guard simply could not see the new layer.

**Root cause:** `.device.capturing { opacity: 0 }` is the whole capture guard, and it is scoped
to `#device`. The grid was deliberately made a SIBLING of the handset so it could span the
viewport, which put it outside the only selector that takes the phone off screen. The two
requirements pulled in opposite directions and nothing in the code said so.

**Fix:** the capture state is now carried on `<body>` as well as on `#device`, set and cleared
by one pair of functions, with `body.capturing .camframe { display: none }`. The same pattern
already had to exist for `camlive` itself, which is also on both elements for the same reason.

**Prevention:** anything drawn outside `#device` is outside every rule that hides the phone.
When a layer is deliberately moved out of the handset, the capture guard has to be extended in
the same change, and the way to find out is to photograph the capture state rather than the
framing state. Screenshotting only the state the player looks at would have missed this
completely: the framing shot was correct in every version of this change.

---

## [2026-08-05 17:05] - A file extension used as a media subtype crashed the server

**Context:** taking a photograph on a server with `Config.Media.provider = 's3'`, minutes after
the capture path was rewritten to come back through `serverCapture` rather than being uploaded
from the client.

**Error:** the server process took a SIGSEGV. Mono's handler printed an empty managed stack
trace, followed by a 2146 ms hitch reported identically on the sync thread and the network
thread - the whole process frozen while the crash handler ran, not a workload.

**Root cause:** two changes multiplied.

`captureOptions()` sent `encoding = imageExt()`, and `imageExt()` exists to name a FILE and
normalises every JPEG spelling to `jpg`. screencapture's NUI composes the canvas type by
concatenation - `canvas.toBlob(cb, ` + backtick + `image/${encoding}` + backtick + `, quality)` -
and `image/jpg` is not a type any canvas accepts. Per the HTML spec the browser silently falls
back to `image/png` and ignores the quality argument, so every photograph came back a full-frame
lossless PNG: one to two and a half megabytes where the same picture as JPEG or WebP is one to
three hundred kilobytes, with `imageQuality = 0.7` buying nothing. The config default had just
been flipped from `webp` - whose extension and subtype happen to be the same word, which is why
the concatenation had been harmless until then - to `jpg`.

At the same time the transport changed from `remoteUpload(..., 'blob')`, where the image stayed
inside screencapture's Node process, to `serverCapture(..., 'base64')`. So that inflated string
is now marshalled JS to Lua through a function reference, held in the Lua runtime, and marshalled
Lua to JS again to the uploader - both crossings synchronous, both on the server's main thread,
with Lua reading none of it. Nothing anywhere on the path measured its length first.

The deadlines were also inverted at the layer the rework added: `server/s3.js` had a 20 s fetch
timeout with one retry and a 500 ms backoff, a 40.5 s worst case, against a 20 s Lua poll and a
35 s upload lease. A callback could be invoked up to 20 s after the Lua side stopped waiting, and
none of the four exports terminated its promise chain, so a throw out of that invocation became
an unhandled rejection.

**Fix:** `imageCaptureType()` translates the extension into the subtype a canvas accepts and is
what `captureOptions()` sends; `imageExt()` keeps naming the object. A payload ceiling refuses an
oversized or non-string capture before either export call, with its own error string. Every
numeric in the options table is clamped, and `src` is checked before it reaches an `emitNet`.
`s3.js` drops to a 9 s fetch timeout (18.5 s worst case, inside every poll above it), wraps every
callback invocation, terminates every chain, and drains response bodies. The config default is
back to `webp`.

**Prevention:** an options table handed to another resource is an interface, not a hint - read
that resource's code before writing "which of these its build reads could not be checked, and a
key it does not know is ignored". That sentence was in the file, and it was wrong in both halves.
Never derive a media subtype by concatenating a file extension: `jpg` and `jpeg` are the same
format and not the same string, and the one place that difference is invisible is the default
that made it invisible. And nothing unmeasured crosses a runtime boundary - a length check is one
line and turns a signal into a console message.

---

## [2026-08-05 16:20] - A new test passed against the bug it was written to catch

**Context:** `tools/test-camera.py` was written to lock in the camera fix, then run against a
mutant of `server/media.lua` with the old guard put back - eight seconds, disarmed by the capture
callback - to check the test could actually tell them apart.

**Error:** the mutant passed every check. Twenty-six assertions, none of which failed.

**Root cause:** the scenario was wrong, not the assertions. The case exercised was "the upload
host never answers", and `uploadCapture`'s own poll gives up at twenty seconds on both versions,
so both answered at roughly 20.3 s and both were inside the 25 s budget being asserted. What the
old arrangement could not bound was the SUM of the two phases: its guard was disarmed the moment
the capture landed, so a slow grab and then a dead host cost the grab time plus the full twenty.
The test never made the grab slow, so the two versions had no observable difference.

**Fix:** added the case that separates them - `CAPTURE_MS = 7000` with a dead host. Measured
25.0 s on the fixed file against 27.0 s on the mutant, and the mutant now fails.

**Prevention:** a regression test is not finished when it passes. Mutate the file it guards, in
the exact shape of the bug, and watch it fail - and if it does not, the scenario is wrong even
when every assertion in it is true. Two more mutants (the dropped `place`, the call app's busy
string) were run for the same reason and did fail, which is what made the first result readable
as a test problem rather than a code problem.

---

## [2026-08-05 15:40] - Comparing against `git show HEAD:` measured the wrong thing

**Context:** wanted a before-and-after for the camera work, so the new test was pointed at
`git show HEAD:server/media.lua`.

**Error:** the "before" failed checks that had nothing to do with the change - a good photograph
answered `{ error = 'noupload' }`, which no version of this path has ever done in normal use.

**Root cause:** the working tree was many commits' worth of uncommitted work ahead of HEAD.
`HEAD:server/media.lua` was 505 lines against the working tree's 919 - a different file, from
before `serverCapture` existed. It was not the code as found; it was ancient history.

**Fix:** dropped the git comparison and built the "before" by mutating the current file, one
behaviour at a time.

**Prevention:** check `git status` before treating HEAD as the baseline. On a tree with
uncommitted work, "before" means the file as found at the start of the session, and the only
reliable way to produce it is a targeted mutation of the file in hand.

---

## [2026-08-05 14:10] - The avatar fallback letter, invisible for the second time

**Context:** every avatar draws its owner's initial under the photograph so a picture that fails
to load reveals the letter. It did not: a white letter on a disc that had no colour of its own.

**Error:** measured 1.12:1 where the disc was left transparent by a `background` shorthand,
1.15:1 and 1.28:1 where it was painted `--app-fill`. WCAG AA wants 4.5:1. Four screens - the
contact card, the OnlyFruits faces, the Hush profile and the Hush match list - emitted no letter
at all in the branch that has a photograph, so those were blank discs rather than faint ones.

**Root cause, three of them stacked:**
1. `background: linear-gradient(...)` is a shorthand and resets `background-color` to
   transparent. An inline `background-image` then replaced the gradient and the disc was a hole.
2. The discs that did name a colour named `--app-fill`, a translucent grey that is nearly the
   card it sits on.
3. `watchDeadShots` repaints a photograph it has proved dead with `--app-fill` too, through
   `.deadshot.deadshot` - so the one moment the letter exists for was the one moment it was
   guaranteed to be unreadable.

**Fix:** one declared pair, `--av-bg: #545458` and `--av-label: #ffffff`, 7.54:1 measured in both
themes and not swapped with the theme because avatars are also drawn on the always-dark call
screen. Applied in a single block at the foot of style.css. The four screens that wrote their own
markup now call `socAvatar`, which writes the letter in both branches.

**Prevention:** a fallback that is only visible when something else fails is a fallback nobody
sees fail. Two rules come out of it. Never write a disc colour with the `background` shorthand
when a photograph will be laid over it - longhand `background-color`, always. And when a rule is
meant to be the last word on a property, count the specificity of everything that already sets
it: an earlier attempt at this exact bug was written with single classes and lost to
`.deadshot.deadshot` and to `.row .rav.ravimg`, which is why the block is doubled and last.

---

## [2026-08-04 05:20] - An audit finding whose fix would have opened the SDK permission gate

**Context:** the depth audit reported that the store catalogue rides in every open and refresh
payload, and proposed stripping `desc`, `developer`, `permissions`, `features` and `keywords`
from the installed-apps rows because "the home screen never reads them".

**Error:** none shipped. Caught by reading the call sites before cutting.

**Root cause of the bad advice:** the home screen indeed never reads them, and two other things
do. `sdkHasPermission` reads `app.permissions` off the OPEN app - an installed row - and its
own comment says an empty list is "the backwards-compatible legacy profile", i.e. full access.
Stripping the field would have silently granted every dropped-in app every SDK op. And
`storeDetail` is called with an installed row from an app's own action sheet ("View in the
FruitStore"), where it renders `desc`, `features`, `permissions` and `developer`.

**Outcome:** not applied. The only field genuinely unread on an installed row is `keywords`, and
that alone is not worth a change. The real fix needs a detail callback so the heavy fields can
leave BOTH lists, which is a day's work on a shipped screen.

**Prevention:** "X never reads this" is a claim about every reader, and the way to check it is to
enumerate the readers rather than to check the one the finding names. A field that gates
permissions is worth grepping for twice.

---

## [2026-08-04 04:05] - Every button in the phone was being clicked twice, for two hours

**Context:** the home indicator's tap and the photo viewer's two buttons were dead because
`#screen` captures the pointer in its edge zones, so the control never sees a pointerup and no
click is generated. The fix forwards the tap by calling `.click()` on the control the press
began on.

**Error:** pressing one emoji typed it twice.

**Root cause:** the forwarding was unconditional. It is only NEEDED when the pointer was
actually captured - and capture happens only in the top and bottom edge zones. Everywhere else
the browser generates the click itself, so forwarding as well meant two clicks on every control
in the phone: two toggles, two sends, two purchases.

**Why nothing caught it for two hours:** the input probe's existing checks are all on controls
whose second activation is invisible. A widget removed twice is one widget removed and one
no-op; a home-bar press that goes home twice is home. The emoji picker was the first check
written against a control whose effect ACCUMULATES, and it failed on the first run.

**Fix:** record whether `setPointerCapture` succeeded, and forward only then.

**Prevention:** when a fix adds a synthetic event, ask what the real one is doing at the same
moment. And prefer a test on something that accumulates: a toggle hides a double fire, a text
field shows it.

---

## [2026-08-04 02:10] - "Framework agnostic" was true of the code and false of the schema

**Context:** an audit sweep asked whether the resource is really framework agnostic rather than
whether it looks it.

**Error:** on ESX and standalone the phone opens, keeps the wallpaper and the passcode, and then
saves nothing. No contact, no message, no note, no mail, no social account.

**Root cause:** the bridge sets `citizenid` from the framework, and on ESX that is
`player.identifier` (48 characters, more with multicharacter) while on standalone it is the bare
forty-hex licence. Forty-eight columns across eleven files declared `VARCHAR(16)`. In strict mode
every insert raises; without it the id is cut on write and compared full on read.

**Why it was invisible:** the two tables the BRIDGE owns - `vphone_kv` and `vphone_characters` -
were already `VARCHAR(64)`, so the phone booted, remembered its settings and looked healthy. The
failure was confined to the feature tables, and to two of the four frameworks.

**Fix:** every CREATE corrected, plus an idempotent widening pass at boot for databases that
already exist. Keys widened in place rather than dropped and recreated.

**Prevention:** a value that crosses a framework boundary has no width you can assume. The newer
files in this resource already used 64 - the author had learned it once, in one place, and the
older files never heard. When a fact like that is discovered, the sweep is the whole repository.

---

## [2026-08-04 01:35] - An export that raises where nil was expected

**Context:** reading the ox_core money paths.

**Error:** on ox_core, a bank debit could not succeed, and the attempt could take the whole NUI
callback with it - leaving a transfer sheet spinning for ever.

**Root cause:** `elseif acc.id and exports.ox_core.RemoveAccountBalance then` reads as "if the
export exists". FiveM's export proxy does not answer nil for a name a resource does not publish:
it RAISES. Outside a pcall that is not a falsy test, it is an uncaught error. And it was reached
every time, because the method it falls back FROM cannot exist either - ox hands the account
across the export boundary as data, so its fields survive and its methods do not, which this
resource had already documented for the player object and not applied to the account.

**Fix:** call the export inside a pcall rather than testing it for truth, on both the debit and
the credit side.

**Prevention:** `exports.foo.bar` is not a lookup, it is a call into a metatable that can throw.
Anything that reaches an export defensively must do it inside a pcall, including the part that
only means to look.

---

## [2026-08-02 21:30] - The same capture, in a second place, killing two more buttons

**Context:** adding a copy-link button to the full-screen photo viewer. The new button did not
respond to a real press.

**Error:** `Input.dispatchMouseEvent` at the button's centre produced a pointerdown ON the
button and no click at all. `elementFromPoint` agreed the button was there.

**Root cause:** `#screen`'s pointerdown calls `setPointerCapture` for any press starting within
`EDGE_TOP` (56px) of the top or `EDGE` (34px) of the bottom, so the pointerup goes to `#screen`
and the button never sees one. No pointerup, no click. The same mechanism that had killed the
home indicator's tap, found in 1.6.1 - and this time it had also killed the viewer's CLOSE
button, since the day the viewer was written. Nobody noticed because a tap anywhere in that
viewer dismisses it, so the close button appeared to work while actually being a tap on the
backdrop underneath it.

**Fix:** the pointerdown records the control the press began on, and the pointerup forwards a
tap to it. The home bar is excluded, because the swipe up from it is a real gesture that starts
on a button.

**Prevention:** when a root cause is found, ask where else the same mechanism reaches. The first
fix named the home bar and stopped there; the capture covers two whole edges of the screen and
everything in them. A fix that names one instance of a general mechanism is half a fix.

---

## [2026-08-02 20:55] - A synthetic click carries no coordinates

**Context:** forwarding a tap to the control it began on, with `el.click()`.

**Error:** the forwarded click dismissed the photo viewer instead of copying the link.

**Root cause:** the viewer's delegate decided which control had been pressed by comparing the
click's `clientX/clientY` against the buttons' rectangles - correct for a real click, and wrong
for `HTMLElement.click()`, which dispatches with both at 0. The point (0,0) is not inside the
button, so the delegate fell through to "tap on the backdrop, dismiss".

**Fix:** identity first (`e.target.closest`), geometry only for a click that has a real point
behind it.

**Prevention:** a geometry test on an event is a test on `clientX/clientY`, and those are zero
for every synthetic dispatch. Ask where the event comes from before deciding by where it landed.

---

## [2026-08-02 20:10] - A test PNG that no decoder would accept

**Context:** `vphone_media_test` builds a one-pixel PNG so that "the file was too big" cannot be
the answer when the host refuses it.

**Error:** none observed. Caught by inflating the generated file in Python before trusting it:
the zlib stream failed its Adler-32 check and every chunk CRC was written as zero.

**Root cause:** the checksums were stubbed on the assumption that nothing would look at them.

**Fix:** CRC-32 and Adler-32 computed in Lua, verified against Python's `zlib` - signature,
three chunks, correct CRCs, and an IDAT that inflates to the four bytes it should.

**Prevention:** a diagnostic that can itself be wrong is worse than none: a host rejecting a
malformed file would have been reported as a rejected key, which is the exact confusion the
command exists to remove. Verify the instrument before reading it.

---

## [2026-08-02 18:40] - The home indicator's tap had never worked, and every test agreed it did

**Context:** the reachability sweep reported three controls under the home bar. Chasing them.

**Error:** a real mouse press on the home indicator did nothing at all. Only the swipe worked.

**Root cause:** `#screen`'s pointerdown calls `setPointerCapture` for any press that starts in
the bottom thirty-four pixels, and the indicator lives there. From that moment every pointer
event for that gesture belongs to `#screen`, so `#homebar`'s own `pointerup` and `click` never
fire - the counters said `down 1, up 0, click 0`. And `#screen`'s own pointerup returns early on
`a tap, not a swipe`. Neither half was wrong on its own; nothing owned the case between them.

**Fix:** the tap is decided where the events actually arrive. `#screen` records whether the
press began on the bar and, on a tap, goes home. The bar's own handlers stay as the fallback for
an input method that emits no pointer events, with a comment saying so.

**Prevention:** two handlers for one gesture, in two files, with a capture between them, is a
gap nobody reads their way to. The rule that found it: a control is only proven by real input
through the compositor. A synthetic `.click()` on that bar passes today and always would have -
the handler is fine, it simply never runs.

---

## [2026-08-02 17:55] - Padding cannot fix a band that content scrolls through

**Context:** the same three findings. The first fix raised `.appbody`'s bottom padding from 34px
to 46px so the last row would clear the indicator's forty-pixel hit target.

**Error:** the sweep still reported the same controls. The measurement said the padding had
applied.

**Root cause:** padding adds space after the LAST row. The problem is every row that passes
through the band on its way past, at every scroll position in between - which padding cannot
reach. Fixing the end of a list is not fixing the middle of it.

**Fix:** reserve the strip instead. `#appfoot` collapses to nothing on an app with no tab bar,
so the body ran to the bottom of the screen; it now has a forty-pixel floor, which is what iOS
does with its safe area. `.app:not(.hasfoot) #appfoot { height: 40px; }` and the body ends
exactly where the band begins.

**Prevention:** before writing a fix, say out loud which instances it covers. "The last row"
and "any row" are different sets, and the measurement that confirmed the padding had applied was
answering a question nobody needed answered.

---

## [2026-08-02 16:20] - A probe that reported three controls as lost, and a probe that would have missed a real one

**Context:** `tools/probe.js` asks `elementFromPoint` what is under each control's centre.

**Error:** three controls reported unreachable that one flick of the wheel reveals.

**Root cause:** the scrolled-away test asked whether an element was ENTIRELY outside its
scroller. A row straddling the fold - top inside, centre below - passed that test and was then
judged at a pixel belonging to whatever is painted under the scroller.

**Fix:** judge at the centre, since the centre is the point being asked about.

**Prevention:** a rule that is loosened has to be shown to still fail against the thing it exists
for, or it has stopped being a rule. A fixed opaque panel was dropped over the middle of the
phone and the sweep reported controls under it in twenty apps; the panel was removed and the
sweep came back clean. Only then was the change kept.

---

## [2026-07-31 15:20] - ffmpeg read and wrote the same file, and eight images went missing

**Context:** moving scratch screenshots out of the repository, so they stop being committed.

**Error:** eight shots printed ENCODE FAILED on every run. No stack, no ffmpeg output, and the
assertions in the same range kept passing - so it read as flaky rather than broken.

**Root cause:** the move sent scratch output to the temporary directory that already holds the
full-size capture, under the same file name. ffmpeg was handed one path as both input and
output and refused. It had been failing since the change, silently.

**Fix:** scratch shots encode into a `shots/` subdirectory beside the captures.

**Prevention:** when a change moves an output path, check it against the input path. And an
"ENCODE FAILED" line that carries no reason is a line that will be read as noise: the harness
prints ffmpeg's stderr when it is worth reading.

---

## [2026-07-31 15:05] - An assertion that passed alone and failed in a batch

**Context:** the same screenshot run. `crop-slider` failed with "cannot read properties of null",
then passed when run on its own.

**Root cause:** every shot shares ONE page, so module state a shot writes is state the next shot
inherits. `gallery-albums` leaves `galleryTab = 'albums'`; `crop-slider` then opened a gallery
with no thumbnails in it and its first `querySelector('.shot')` was null.

**Fix:** the shot sets the state it depends on rather than assuming a default.

**Prevention:** a shot may not rely on module state it did not set. An assertion whose result
depends on what ran before it is worse than no assertion, because it teaches everybody to
re-run the suite until it goes green.

---

## [2026-07-31 14:10] - A debug probe reached a live server, because the server IS the working tree

**Context:** a full audit of the page, run by agents that measure real rendered styles.

**Error:** the owner saw a JSON panel over their game reading `emitted_class`, `actual_color`,
`intended_rule`, with an annotation "(what `.emergencycard .uibtn` would look like)". Nothing of
the sort exists in the repository.

**Root cause:** an audit agent wrote a diagnostic probe into `html/` to read a computed style,
read it, and removed it. The test server is a junction onto this working tree, so for the few
seconds the probe existed on disk it was being served to a running game.

**Fix:** nothing to revert - the probe was already gone, confirmed by `git status` and a
repository-wide search for all four strings.

**Prevention:** a probe never goes in a file the live server serves. Measure in the preview
build under the scratchpad, or in a copy. The working tree is somebody's server.

---

## [2026-07-31 13:40] - `0` is true in Lua, so the fix for one bug was about to cause another

**Context:** the contact editor never sent `favourite`, so the Favourites tab was empty on every
phone and every save wrote a zero over the flag. The fix is one field in one payload.

**Error:** none observed. Caught by reading `server/main.lua` before shipping the page change.

**Root cause:** `local fav = (data and data.favourite) and 1 or 0`. Lua has two false values,
`nil` and `false`; every number is true. The expression reads as "one when it is set" and
answers `1` for `0`. It had been correct for as long as nothing sent the field at all - so the
dead feature was hiding the trap, and fixing the feature would have armed it. Sending
`favourite: 0` for an unstarred contact would have starred every contact anybody saved.

**Fix:** `local fav = (rawFav == true or (tonumber(rawFav) or 0) ~= 0) and 1 or 0`. Tested under
real Lua against nil, 0, 1, true, false, "0" and "1".

**Prevention:** `tools/check.py` gained a `zero is true` check: any `data.<field> and 1 or 0` in
server Lua is flagged when the page can send a number for that field. Proven to fire against the
original line before being trusted.

---

## [2026-07-31 13:05] - A search box that rebuilt the screen it was in

**Context:** the page audit, looking for redraws that cost more than they are worth.

**Error:** Notes and the trading board replayed the whole screen's entrance animation on every
keystroke, and had focus-and-caret restoration code to survive their own destruction.

**Root cause:** both called their full render from the `input` handler, and every render ends in
`body()`, which assigns `#appbody.innerHTML` and deliberately restarts `view-enter`. The
restoration hack is the tell: code that puts the caret back is code that knows the field it is
typing into is being destroyed.

**Fix:** the list under the field is its own host, repainted alone. The field is never
destroyed, so the focus code, the caret code and the `holdInput` sent per character all went
with it. The GIF picker and Music search were already doing it this way.

**Prevention:** a repaint driven by typing must not touch the element being typed into. If the
fix needs `.focus()` afterwards, the repaint is too wide.

---

## [2026-07-31 02:30] - "Sometimes clicking somewhere takes you to another page"

**Context:** a player report with no steps and no error, about Settings "and other apps".

**Error:** exactly what it says. A tap lands the player on a screen they did not choose.

**Root cause: two of them, found by pointing five agents at five different ways a handler goes
wrong and then having each finding attacked by a skeptic. Thirty candidates, twenty-four
survived, and they collapse into two.**

**A. `data-full` is the phone-wide open-a-photograph attribute, and the widget picker used it as
a boolean flag.** A capture-phase delegate on #screen matches `[data-full]` anywhere, calls
`stopPropagation` and opens the full-screen viewer. #sheet is inside #screen. So tapping a
widget row that would not fit opened a black viewer on the string "1", rotated the handset to
landscape and disabled the bezel buttons - after the delegate's `stopPropagation` had killed the
row's own "not enough room" toast. Written this session; the flag is `data-nofit` now.

The same delegate was also silently killing double-tap-to-like on a feed photograph, because the
second tap never reached the image. It is narrow now: it only fires for a value that starts
`http:` or `data:`, and only swallows the event when it is going to act on it.

**B. Every control in Settings redrew with `RENDER.settings()`, which draws the FRONT page.**
Twenty-two call sites used it as "redraw after a change", so flipping a switch on Display,
choosing a wallpaper, setting a passcode or picking a ringtone all threw the player back to the
top of Settings one tap after arriving. `settingsAt` now records which screen is open and
`settingsRedraw()` redraws that one; `RENDER.settings()` keeps its real meaning, which the back
chevron and the app launcher want.

**Six narrower ones with the same shape**, all of them a screen that draws a new body without
setting its own nav bar - and the bar lives outside #appbody, so it keeps whatever the last
screen bound to it:

- pull-to-refresh, bound to #appbody once at boot, always called the app's ROOT render, so
  pulling down inside any sub-page threw the player out of it
- Music's Favourites and Albums: the chevron closed the whole app
- Hush: leaving a conversation kept the top-right button, which unmatches - so the corner
  unmatched the person whose thread you had just left
- Bleeter/Snapmatic: a foreign profile wrote `SOC.tab = 'me'`, which made the Profile tab dead
  afterwards (the tab handler returns early when the tab is unchanged) and highlighted the wrong
  tab while a stranger's page was on screen
- Lottery: a chevron labelled "Lottery" with no closure behind it, so it closed the app
- the FruitStore's own async first render painted over the detail page "view in the FruitStore"
  had just drawn, and the Gallery replaced the photograph you were looking at with the grid,
  underneath the still-open edit sheet

**Prevention:** the `nav-stays` assertion drives both root causes - a refused widget row must
toast rather than open the viewer, a real photograph must still open, and a switch flipped on a
Settings sub-page must leave the player on that sub-page. Both halves were proven to fail
against the code as it shipped.

**The lesson worth keeping:** an attribute selector on a delegated listener is a namespace, and
`data-full` had no owner written down anywhere. The second user of a name that means something
to a listener three thousand lines away cannot know that. Where a delegate claims an attribute,
the attribute needs a comment saying so - which it now has.

---

## [2026-07-31 01:15] - "Use the code 1111" next to a text saying 2222

**Context:** signing up in Hush, and in every other app that verifies by SMS.

**Error:** the code screen offered a code that was not the one the text had just delivered.
Players with no earlier code saw no chip at all, however long they waited.

**Root cause:** the chip is built as part of the markup for the code screen, and that screen is
drawn at the moment the player ASKS for a code - before the text exists. `latestCode()` therefore
searched a conversation list without the new code in it, found an older one from a previous
sign-up or another app, and rendered that. The text landed a second later, the inbound handler
called `refresh()` and quietly updated the list, and **nothing redrew the chip**.

A second, narrower cause on top: the field is `maxlength="4"` and the detector accepted four to
eight digits, so a longer number elsewhere could be offered and then silently truncated by the
field - offered and entered would not have been the same string either.

**Fix:** `codeFillChip` emits an empty HOST, so a code arriving later has somewhere to appear.
`refreshCodeChips()` rebuilds it from the live conversation list, reading the digit count off the
real field. It is called after the body is drawn, and again from the message handler.

**Two mistakes made while fixing it, both caught by the assertion rather than by reading:**

1. The first version read `maxlength` inside `codeFillChip`. That markup is concatenated with
   the field and assigned in one go, so at that moment the field is not in the document and the
   attribute is null - the length check silently did nothing. The assertion caught it by offering
   an eight-digit number to a four-digit field.
2. The second version had `wireCodeFill` call `refreshCodeChips` and `refreshCodeChips` call
   `wireCodeFill`. With no code to show, neither ever reached a state the other accepted, and it
   recursed until the stack ran out. Wiring and refreshing are separate functions now.

**Prevention:** the `code-chip` assertion drives the whole sequence - no code, an old code, the
new one arriving, the fill, the length rule, and five refreshes in a row to prove the listener
does not stack. Every step of it failed against one of the three versions of this code.

---

## [2026-07-31 00:30] - A finished feature nobody could reach

**Context:** a player reported "something went wrong" on the Patients tab of the Health app.

**Error:** every visit to that tab drew the generic error empty state. Tapping a patient would
have done the same.

**Root cause:** `RegisterNUICallback('health')` in client/main.lua forwarded `get` and `set` to
the server and answered **every other op with `{ error = 'x' }`**. The page asks that tab for
`op = 'nearby'` and asks a patient row for `op = 'read'`, so both were refused on the player's
own machine and never left it.

Both server callbacks were complete and had been all along: `v-phone:health:nearby` and
`v-phone:health:read` check the reader's job and grade, measure the distance at the listing AND
again at the moment of reading, refuse a target who has walked away, notify the patient that
their record was read, and log it. None of that had ever run once.

**Fix:** the two ops routed through the relay, still as a closed set - the op is compared against
the two names before it is used to build the callback name, so the page cannot ask for a third.

**Prevention:** `tools/check.py` gained `relay ops`. A NUI callback that branches on `data.op` is
an allowlist whether or not the allowlist has a name; the check reads every `op` the page posts
and every op each client relay mentions, and reports the difference. Reverting the fix makes it
name both `nearby` and `read`.

`check_social_ops` already did exactly this for the one relay that has a NAMED allowlist. The
lesson is that the named one got a check and the six unnamed ones did not - a check written for
one instance of a pattern should be written for the pattern.

**Also worth recording:** nothing else was wrong behind it. This path had never executed, which
is where a nil global hides, so `coordsOf`, `healthMayRead` and `mailJobQualifies` were each
checked for scope before the fix was called done. All three are declared above their use in the
same file.

---

## [2026-07-30 22:40] - A setting that saved perfectly and vanished

**Context:** a player reported that editing My Card in Contacts did not save.

**Error:** the job, address, birthday, note and photograph were typed in, saved, and the card
came back empty. Every time, on every server.

**Root cause:** `v-phone:prefs` accepted all five fields, validated them and wrote them to the
character's metadata correctly. **`prefsOf` never returned them.** The page does
`state.prefs = res.prefs` after every save, so the fields were written to the database and wiped
off the screen in the same breath - and `v-phone:open` sends the same `prefsOf`, so they were
still absent on the next connection. Nothing was ever lost; nothing was ever sent back.

The same omission broke a second feature nobody had connected to it: AirDrop card sharing reads
`prefsOf(me)` too (server/main.lua:4374, :4386, :4419), so handing somebody your whole card sent
your name, your number and your email address and **none of the five extra lines the feature
exists for**.

**Fix:** the five keys added to the table `prefsOf` returns.

**Prevention:** `tools/check.py` gained `prefs round trip`, which compares every key
`v-phone:prefs` WRITES against every key `prefsOf` RETURNS and reports the difference. Secrets
(`passcodeHash`) are exempt by name. Reverting the fix makes it name all five.

**And a note about why no page test covers this.** The preview harness answers a prefs save with
`Object.assign(DB.prefs, body); return { ok: true, prefs: DB.prefs }` - it echoes back whatever
it was handed, so it is strictly more permissive than the real server and would have passed
against the broken code. An in-page assertion here would have been a test that cannot fail. The
static check is the honest one, and it is the one that discriminates.

---

## [2026-07-29 20:40] - A control that was drawn, was hit, and did nothing

**Context:** shipping the home-screen widget strip. The minus badge that removes a widget, the
button that adds one, and the long press that starts arranging were all reported dead by the
player, twice, after an in-page assertion said all three worked.

**Error:** pressing the minus removed nothing and silently left arrange mode. Holding the strip
did nothing. Dragging a widget did nothing.

**Root cause:** two separate faults, and the second is the interesting one.

1. The widget strip is a sibling of `#pages`, so the app grid's pointerup handler saw a press on
   it as a press on neither a tile nor a tile's page - which it reads as "tapped the wallpaper"
   and answers by leaving arrange mode. That repainted the strip and destroyed the badge before
   its own `click` could fire.
2. The fix for (1) was a flag set in the strip's own `pointerdown` handler. **The minus badge
   calls `stopPropagation()` on `pointerdown`** - it has to, or the widget underneath starts a
   drag the moment the badge is touched - so the flag was never set for the one gesture it
   existed to protect. The badge went on being treated as a tap on the wallpaper.

**Fix:** the flag is set from a CAPTURE-phase listener on the strip, which runs before any child
listener and therefore before any `stopPropagation`. The empty-strip case was fixed alongside it:
an empty Lua table serialises as a JSON object rather than an array, so removing the last widget
came back as "never arranged these" and the defaults were put straight back.

**Prevention:** **a test that dispatches an event at an element is not a test that a player can
press it.** `el.click()` and `el.dispatchEvent(new PointerEvent(...))` skip hit testing entirely:
they arrive whatever is drawn on top, whatever `pointer-events` says, and whatever the real
target under that pixel would have been. The in-page assertion passed against completely dead
controls, three times, and only stopped passing when it was pointed at a bug it had been written
to catch. `tools/probe-input.js` drives the page with `Input.dispatchMouseEvent` through the
compositor's own hit test, the same as a finger, and found both faults on its first run. Any
control whose failure mode could be "nothing happened" is checked there, not in make-shots.js.

---

## [2026-07-29 21:05] - Six syntax errors from one character

**Context:** writing shot scripts and assertions in tools/make-shots.js.

**Error:** `SyntaxError: Unexpected identifier 'fitGrid'`, and five more like it, each found by
running the file.

**Root cause:** every shot is `script: ` followed by a template literal, and the natural way to
write a comment about a function is to put its name in backticks - which CLOSES the literal and
turns the rest of the shot into JavaScript that happens to read like prose.

**Fix:** the stray backticks were stripped, and `tools/check.py` gained `check_shot_backticks`,
which reports the line rather than leaving it to be discovered by `node --check`.

**Prevention:** the checker now refuses the file. Six round trips on one character is what an
un-automated rule costs.

---

## [2026-07-29 21:30] - Three defects in code written the same hour

**Context:** the Hush Premium day pass, sent through an adversarial audit immediately after it
was written.

**Error:** (1) the pass was paid for out of the wallet of whoever was HOLDING the phone, so under
a staff phone-view session the staff member paid and the held character got the pass. (2) Two
taps on the buy button in the same second both passed the checks, were both charged, and both
wrote the same expiry - one day, paid for twice. (3) `RaiseAlert`, the export other resources use,
never invalidated the widget cache the player-facing path does.

**Root cause:** (1) every paying path in this resource resolves the actor through
`PhoneActingSource` first and this one used `src` directly. (2) reading the expiry into Lua,
adding a day and writing it back is a check-then-act across three awaits. (3) the cache was
invalidated at the two call sites that existed when it was written, and the export is a third.

**Fix:** `PhoneActingSource(src)` for the debit; an in-flight set keyed by citizen id; and the
extension done inside the UPDATE with `GREATEST(COALESCE(premium_until,0), UNIX_TIMESTAMP()) + ?`
so nothing can interleave.

**Prevention:** new code is not safer than old code. An audit that skips what was written this
session skips the part nobody has run yet - all three of these were in the newest file in the
round, and all three were found by pointing the same adversarial pass at it.

---

## [2026-07-29 20:15] — a test that could not fail, and the bug it let through

**Context:** a visual and security audit, eight lenses over the resource, every candidate handed
to a separate agent whose only job was to refute it. 47 candidates, 32 survived.

**Error:** the worst finding was about the tooling written earlier in the same session. Every
assertion added to `tools/make-shots.js` reported a broken invariant as `SKIPPED` and let the
process exit 0. Six probes, each carefully measuring something real, none of which could fail a
run. I had been reading the SKIPPED lines by eye and calling that a test.

**Root cause of the worst BUG it let through:** `storyViewer` assigned `host.innerHTML` where
`host` is `#folderview` - the shared overlay - and cleared it on close. Its three children exist
only in `html/index.html` and nothing rebuilds them. So viewing one Snapmatic story deleted the
folder overlay permanently: every folder on the home screen answered "folder gone" for the rest
of the session, and every app inside one was unreachable. One tap, total loss of a feature, and
nothing in the checks noticed.

**Fix:** the story markup is now its own `.storyview` child, created or replaced, and only that
child is removed on close. `make-shots.js` gained an `assert: true` flag: a marked shot that
throws is collected, printed as FAILED, and sets a non-zero exit code. Proven both directions -
with the old `close()` restored the assertion reports "the story viewer destroyed 3 of the folder
overlay" and node exits 1; with the fix it passes and exits 0.

**Two smaller ones, same shape.** `.hud` and `.sheet.dragging` both used `animation: none` to
suppress an animation. Removing a name from the animation list and putting it back is a NEW
animation, so both replayed their entrance at the moment they were dismissed - the volume pill
faded back in and jumped 77 pixels 1.4 seconds after being pressed, and a plain tap on a sheet's
grab bar threw it off the bottom of the screen and sprang it back. `animation-duration: 0s`
freezes without ever unsetting the name.

**Prevention:** three rules.

*A test that cannot fail is not a test.* Check the exit code, not the output. Twice in this
session I read `$?` after a pipe and got `tail`'s status instead of the program's.

*Never assign innerHTML to an element you did not create.* `#folderview`, `#app`, `#screen` and
`#device` are shared and their children come from index.html. Build a child and own that.

*`animation: none` is not a pause.* To suppress an animation while keeping it from restarting,
set its duration to zero.

---

## [2026-07-29 18:40] — an audit that killed thirty-nine of its own forty-eight findings

**Context:** a whole-resource performance pass. Six agents were sent at six dimensions - client
per-frame work, server SQL, server ticks, page rendering, CSS paint, and leaks - and every
candidate they raised was handed to a separate agent whose only instruction was to REFUTE it.

**Error:** none, in the shipped code. The interesting number is the survival rate: 48 candidates,
9 confirmed, 7 rated safe to apply. Thirty-nine plausible findings did not survive contact with
the file they described.

**Root cause of the near-misses.** Three shapes recurred, and all three are worth naming because
they are what a reading-only analysis produces:

*Code that was not there.* One report proposed deleting `ratingOf` in server/repair.lua on the
grounds that grep showed no other caller. There is one, at line 563, in the review-submit path.
Deleting it would have broken that callback outright.

*Frequency asserted rather than traced.* Several findings called a path hot without following who
calls it. The Repair 15-second poll turned out to run only on one tab; the real hot caller was an
undebounced search box in Contacts, which nobody had proposed touching.

*A fix that changes what a player sees.* One proposed reading the phone's own name projection
instead of the framework's. On ESX and standalone that projection falls back to the FiveM display
name - so the "optimisation" would have published players' Steam names on public donation pages,
bank confirmations and police lookups.

**Fix:** the seven survivors were applied by hand, each verified at its own source first rather
than on the agent's word - several agents had run without their safety classifier. Behaviour
equivalence was then PROVEN in real Lua for the three items that are pure logic: the swapped
predicates in `ensureNumber` agree on all six input combinations, the copied rounding expression
agrees on 33 value pairs, and the name cache's `false` sentinel stops a nil answer being
re-queried for ever.

**Prevention:** two rules.

*A finding is a file and a line you have opened, or it is a guess.* Every one of the three shapes
above dissolves the moment somebody reads the surrounding code. The refute pass is what forced
that reading, and it is worth more than the finders.

*Prove the equivalence, do not argue it.* "Swapping these two conditions cannot change the
outcome" is a claim with six cases, and enumerating them in real Lua takes a minute. The same
goes for a rounding expression: `math.floor(x * 10 + 0.5) / 10` and any other route to one
decimal disagree at the halfway point, and a 4.25 that redraws as 4.3 is a visible change.

---

## [2026-07-29 16:05] — a regex that rewrote one block and deleted two others

**Context:** the GIF shelf ships a starter library in `config.lua`. `tools/gif-pack.py --write`
generates it: it fetches candidates, checks each one really is a GIF, and substitutes the result
into the `packs = { }` block.

**Error:** `@v-phone/server/main.lua:96: attempt to index a nil value (field 'Calls')` on boot,
reported by the operator restarting the resource. `config.lua` still compiled cleanly.

**Root cause:** the substitution was

    re.sub(r'(packs = \{
).*?(
        \})', ...)

The opening group ends with `
`, so it consumes the newline after `packs = {`. The closing
pattern then has to find a DIFFERENT line beginning with eight spaces and a brace - and the pack
list was empty, so there was none nearby. The lazy match ran on for two hundred lines and found
one inside `Config.Calls.badSignal`. Everything in between - the close of `Config.Messages`, all
of `Config.Cipher`, and the top of `Config.Calls` - was swallowed by the substitution.

It compiled because what remained was still balanced Lua. It was simply a different file.

**Fix:** the block is now located by counting braces from `packs = {`, stepping over strings, so
the end of the list is found structurally instead of by pattern. After building the new text the
tool reassembles what lies outside the block and refuses to write unless it is byte-identical to
what was there before. The two lost sections were restored verbatim from `git show HEAD:config.lua`.

**Prevention:** two rules, and the second is the one that would have caught it.

*Never delimit a Lua or JSON block with a lazy regex.* Nested braces are not a pattern; matching
them is counting. A regex that appears to work does so until the block it is aiming at is empty.

*Verify the whole artefact, not the part that was edited.* The check run straight afterwards
counted 18 categories and 108 URLs inside the new block and passed - it was reading the one region
that was certainly correct. Loading `config.lua` in real Lua and comparing the top-level key set
against `HEAD` takes one second and says `Cipher` and `Calls` are gone. Every generator that
rewrites a file in place now has to answer for the rest of that file too.

---

## [2026-07-29 04:20] — the right measurement, taken of the wrong thing

**Context:** 1.5.5 grew the emoji picker from four categories to ten. The tab strip no longer fit,
so it was made to scroll sideways. Shipped. A player reported that the other categories could not
be reached.

**Error:** none. Every tab existed, every tab switched when clicked, and the strip scrolled.

**Root cause:** two, and only the first is about emoji.

The bug itself: this is a NUI page and the player has a MOUSE CURSOR. A horizontal scroller has no
gesture behind it - no flick, no trackpad axis, and nothing in the page was listening - so the last
categories were simply off the right edge with nothing able to bring them back. The same fault was
already in six other strips: the store's categories, the gallery's albums, the camera's filters and
crops, Zuber's tiers, the social trends. One of them had been noticed and worked around locally,
which is what a bug looks like when it is fixed one instance at a time instead of once.

The reason it shipped: I verified it, and the verification was of the wrong property. I measured
`tabsScrollable: true` and recorded that as a success. Scrolling was the SYMPTOM I had introduced,
not the outcome anybody wanted. The question a player asks is "can I get to the tenth tab", and
nothing I ran asked it.

**Fix:** the tabs shrink to fit instead - ten of them, on the narrowest phone, no scrolling at all.
And every sideways strip in the phone now answers the two gestures a cursor actually has: the wheel
turned sideways, and a press-and-drag with a threshold so a tap is still a tap. Added once, at the
screen, so a strip written next month inherits it.

`tools/probe.js` asks the question directly: for every control on every screen, could a cursor
click it? Off the screen, zero-sized, covered, or only arrivable by scrolling sideways all count as
no. It found the store's categories on its first run.

**Prevention:** measure the OUTCOME, not the mechanism. "The container scrolls" is a fact about the
implementation; "the player can reach the tenth tab" is the requirement, and the two are only
related if a gesture exists. When a fix introduces a mechanism, the test must exercise the mechanism
end to end - through the input device the user actually has - rather than confirm the mechanism is
present.

Second, smaller rule from the same day: a probe that hit-tests elements must skip anything merely
scrolled out of view, and must test the scroller before the bezel. Getting that order wrong reported
four working store chips as lost, and reported a button as "covered by the home bar" while it was
two thousand pixels above the viewport. Three separate fixes were attempted on that reading before
the measurement was questioned. **When three fixes in a row fail to move a symptom, the reading is
the thing to doubt, not the fix.**

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

## [2026-08-04 —] Module state leaked between screenshots, so a picture was of the wrong screen

**Context:** adding an assertion for the new Maps search field, using the shot harness.

**Error:** `maps-search: Error: no search field on the places screen`, on a screen that has one.

**Root cause:** the `pins` shot sets `mapsTab = 'pins'` and never puts it back. Every shot runs
against the same page and the same module state, so every later Maps shot opened on the Pins
tab. The assertion was not wrong; it was correct about a screen nobody meant to be showing.
The consequence is worse than the test failure: `29-map-places.png` in the README has been a
picture of the Pins tab for as long as both shots have existed, and nothing said so, because a
picture of the wrong screen is still a picture.

**Fix:** each Maps shot sets the tab it depends on before opening the app.

**Prevention:** this is the third time — `crop-slider` failed after `gallery-albums` left
`galleryTab` behind, and now this. A shot sets the state it depends on; the order it happens to
run in is not a fact about the phone. A shot that passes alone and fails in a batch is the
symptom, but the batch is right and the lone run is the lie.

## [2026-08-04 —] `pairs` order treated as an order

**Context:** checking the ox_core job label, found the group pick beside it.

**Error:** no error. On ox_core, a character in two non-permission groups had a job that changed
between two opens of the same app.

**Root cause:** `for group, grade in pairs(groups) do ... break end` — Lua does not define the
order `pairs` visits keys in, so "the first group" is not a thing. It survived because a
character in ONE group is stable, and one group is what anybody tests with.

**Fix:** the highest grade wins, the name breaks a tie. `tools/test-oxjob.py` runs the pick over
sixty shuffles of the same two groups and asserts one answer; the old code gives two.

**Prevention:** `pairs` plus `break` is a bug whenever the table can hold more than one match.
When a fix depends on ordering, the test has to VARY the order — a single run of an unordered
loop proves nothing, and asserting over many shuffles is what turned this from a suspicion into
a demonstrated defect.

## [2026-08-04 —] A screenshot assertion left a wrapper on the preview's post handler

**Context:** measuring the Hush match avatar against the Messages avatar. The Hush screen needs
data, so the shot wrapped `window.__VPHONE_PREVIEW_POST__` the way the existing Hush shots do.

**Error:** none observed, which is the point. The existing Hush shots wrap the same global and
never restore it, and they get away with it because they run near the END of the list. The new
shot was inserted near the front, so every one of the thirty shots after it would have inherited
a handler it never asked for.

**Fix:** the shot restores the handler on the way out, and puts the Hush tab back.

**Prevention:** the same rule as the leaked `mapsTab` logged above, one level up: a shot must not
only SET what it depends on, it must not leave anything behind that another shot could read. A
global that is wrapped gets unwrapped in the same script.

## [2026-08-04 —] Backticks in a comment closed the template literal, again

**Context:** adding a comment to a shot script inside `` script: `...` ``.

**Error:** `SyntaxError: Unexpected identifier 'flex'` at the comment line.

**Root cause:** the comment used backticks to quote a CSS property. Every shot script in
make-shots.js is a JS template literal, so a backtick inside one ends it.

**Fix:** the comment quotes nothing.

**Prevention:** already logged twice this session, in probe-input.js and anim-count.js. Inside a
template literal there is no such thing as a backtick that is "just prose". `node --check`
catches it in a second and was the thing that did.

## [2026-08-04 —] An elision rule turned a unit symbol into a pronoun

**Context:** restoring the apostrophes the French locale had dropped, 206 of them.

**Error:** `Toute personne à moins de {n} m apparaît ici` became `{n} m'apparaît ici`.

**Root cause:** the rule was "a stump letter, a space, then a vowel". The `m` there is metres.
The guard already excluded a stump preceded by `%`, `{`, `}` or a digit — because `"Reçu %s de
%s"` looks exactly like the elision `s d` — but `{n} m` puts a SPACE between the placeholder and
the unit, so the unit slipped through the one guard written for this.

**Fix:** the string is back as it was, and a sweep for `[}\d]\s+[a-z]'` over the whole file
confirmed it was the only one. That sweep found one other hit, the `1` of `911` before `n'est`,
which is correct.

**Prevention:** when a rule is written to skip false positives, enumerate the SHAPES the false
positive takes, not the one that was in front of you. `%s de` and `{n} m` are the same mistake
with different spacing, and only the first had been imagined.

## [2026-08-04 —] A checker read 119 fewer words than it claimed, and still printed ok

**Context:** after 186 strings moved from single to double quotes to carry an apostrophe.

**Error:** none visible. `check-fr.py` printed `ok  no word is spelled two ways`.

**Root cause:** its Lua-string pattern excluded BOTH quote characters from the body,
`(?:[^'"\]|\.)*`. That is correct for a single-quoted string with no apostrophe in it, and it
silently fails to match a double-quoted string that contains one. The word count dropped from
1955 to 1836 and nothing said so.

**Fix:** the body now excludes only the delimiter, `(?:(?!\2)[^\]|\.)*`. The count went to
2044 and eighteen real defects appeared immediately — in strings that had ALWAYS been double
quoted, so the check had never once looked at them.

**Prevention:** a checker's COVERAGE is a number to watch, not just its verdict. A pass over
less input looks exactly like a pass. Print how much was read, and be suspicious when it falls.

## [2026-08-04 —] A rule was written against one apostrophe, and the file has two

**Context:** deciding `a` against `à` across 140 occurrences of the French locale.

**Error:** the dry run was about to turn `Votre fiche n’a pour l’instant` into `n’à`.

**Root cause:** the guard excluded a preceding ASCII `'` so that `n'a` would be left alone. The
file also contains 76 typographic apostrophes `’` — it mixes the two — and `n’a` matched.

**Fix:** both characters are in the guard. The mixing itself is untouched and worth a pass of
its own.

**Prevention:** when a guard is written around a character, check which characters the file
actually contains rather than which one was in the example. A `grep -c` for the other form takes
five seconds and would have shown 76 of them.

## [2026-08-04 —] The dry run is the test

**Context:** the same pass. Eleven verbs were about to become prepositions: `a accepte`,
`a commence`, `a note`, `a verse`, `a cloture`, `a republie`, `a mentionne`, `a cesse`.

**Root cause:** the verb was recognised by "`a` followed by a past participle", and those
participles are still spelled like the present tense because they are homographs the accent
passes deliberately left alone. So the test for the verb could not see them.

**Fix:** each was added to the protection list after being read in place, and the ones whose
context was certain then had their accent corrected too.

**Prevention:** a bulk edit over natural language gets a dry run that PRINTS every change, and
the print gets read, not skimmed for a count. Three separate classes of error were caught this
way in one pass, and none of them would have failed a test — the file would have compiled, the
screenshots would have matched, and the French would have been wrong.

## [2026-08-04 —] The "lua compile" gate could never fail, and a syntax error shipped

**Context:** `server/media.lua` was edited through a shell heredoc. The server refused to load
it: `media.lua:633: ')' expected (to close '(' at line 632) near 's'`.

**Error:** two, and only the second one matters.

The first is the old one: a heredoc ate a backslash, so `key\'s` became `key's` and the Lua
string closed early. Fourth time this session; the rule is already logged.

The second is that `python tools/test-all.py` printed `lua compile ok` on that exact file. The
check was:

    if load(io.open(f).read(), '@' + f) is None: bad.append(f)

**Root cause:** Lua's `load` answers `nil, err` on failure, and lupa hands a multiple return
back to Python as a TUPLE. `(None, "syntax error...")` is not `None`, so the branch never ran.
The check has been reporting success unconditionally since it was written - it has never once
looked at a file's contents in a way that could produce a failure.

**Fix:** unpack the tuple, test the first element, and print the error text. Verified by putting
the exact broken line back: `lua compile FAIL - media.lua:633: ')' expected`.

**Prevention:** every gate must be shown failing before it is trusted. This one was added
alongside checks that DO fail and inherited their credibility without earning it. The tell was
available and ignored: it had never printed `does not compile:` for anything, ever - a check
that has never fired is not a check that found nothing, it is a check nobody has tested.

## [2026-08-05 —] Two more checks that could not fail: the add button, and the locale duplicates

**Context:** a sweep for assertions that pass unconditionally, in the two places a regression had
already got through.

**Error:** none at runtime. Both checks were green the whole time they were blind.

**Root cause, the input probe.** `tools/probe-input.js` asserted the add-widget control with
`!!document.getElementById('waddbtn')`, under the label "the add button appears". The button
was injected only in arrange mode when that line was written. It is now permanent markup inside
`<div class="arrangebar">` in `html/index.html`, so the expression is true before the phone has
even been unlocked, and the assertion measures the HTML file rather than the phone. That is how
the regression shipped where pressing the plus opened the picker and dropped out of arrange
mode on the same pointerup: every check around it still passed, because the picker did open and
a row did add a widget. Only the jiggling stopped.

**Root cause, the locale duplicates.** `tools/check.py` matched key declarations with
`re.match(r"\s*\[\s*'((?:ph|app)\.[a-z0-9_]+)'\s*\]\s*=", line)`. Three shapes went past it:
a capital inside the name (`ph.bankpro_e_noTarget`), the `soc.` prefix the server writes a
player's posts with, and any line declaring more than one key. Five real keys per locale file
were unwatched, in a check whose entire purpose is watching. It also had no selftest, alone
among the checks in that file.

**Fix:** the probe now reads the computed style of `#arrangebar` at rest and in arrange mode,
and after the plus is pressed it reads three things at once: `editing`, the minus badges, and
the bar's display. `check.py` gained `LOCALE_KEY` plus `locale_key_lines()` - `finditer` over
each line with its comment stripped - and a `locales` selftest.

**Verified by breaking each one on purpose.** Setting `.arrangebar` to `display: flex` failed
"the arrange bar is hidden outside arrange mode". Dropping the `!barPressed` guard from the home
screen's pointerup failed "and arrange mode is still on under it" with `editing false, 0
badge(s), bar none`, while the two checks either side of it stayed green. Adding a duplicate
`['ph.bankpro_e_noTarget']` and `['soc.match_line']` on one line reported both; the old detector
run over the same faulted file reported nothing. Every fault was removed afterwards.

**Prevention:** an assertion on `getElementById` is an assertion about the markup, not about the
screen. When a control moves from injected to permanent, every existence check on it becomes a
tautology on the same day and nothing says so. Assert the property a player would notice: the
computed style, the state the code branches on, or both. And a key-shaped regex is a claim about
every shape in the file, which is checkable: the pattern now finds 2728 keys per locale, the
same number the real Lua runtime loads.

---

## [2026-08-05 —] Camera mode ended and the app stayed open, so Backspace exited into a black rectangle

**Context:** the Camera app was drawing a viewfinder of its own - a shutter, a roll thumbnail, a
selfie flip, a mode strip, chips and a rule-of-thirds grid - over a handset that had been made
see-through so the game showed through where its screen was.

**Error:** leaving camera mode with Backspace put the player on a black screen with nothing on it.
The controls also sat over the picture being composed, and both capture paths grab the whole
viewport with no crop, so they were in the photograph as well.

**Root cause:** two, and only the second is a bug in the sense of a line being wrong.

The first is a design mistake: a NUI page is an overlay and can never show the game inside itself,
so anything the app painted was necessarily on top of the shot. GTA already draws the viewfinder
(`CreateMobilePhone` + `CellCamActivate`) and already names the keys in its own help box, so every
control the phone added was a second copy of something the engine was doing better.

The second is the black rectangle. `camModeOff` sends `camLive off`, and the page's only reaction
was to drop the `camlive` class. Nothing closed the app. The class was removed in exactly one
place that mattered - `closeApp` - so ending camera mode any other way (Backspace, the watchdog,
the phone closing) left the Camera app on screen with no interface and an opaque black surface.

**Fix:** the app draws nothing at all - `RENDER.camera` asks the client for camera mode and paints
an empty body - and the `camLive off` handler closes the app, which returns the player to the home
screen. `.device.camlive` is `opacity: 0` again, so the handset leaves the frame for the whole
session, which is the premise both capture paths were already written against.

**Verified:** driven in the real page under headless Chrome. With the app open and framing, a
screenshot taken with `#device` in the document is byte-identical to one taken with it removed -
the page is putting no pixel on screen. Posting `camLive off` then leaves `#app` without `on`,
`openApp` null, the immersive classes gone and `#home` drawn with its tiles. `test-all.py --fast`
passes 19 of 19.

**Prevention:** a message that changes what is on screen needs an owner for every state it can
leave behind. `camlive` had one raiser and one dropper in different files, and the dropper was
reachable by a single route. When the engine owns a mode, the page's job is to get out of the way
and to notice when the mode ends - not to redraw the mode's controls.

---

## [2026-08-05 —] Five tokens that were read and never declared, and one that was substituted in the wrong place

**Context:** the foundation pass of the iOS 26 restyle. Before wiring any component to a token,
every custom property the stylesheet reads was checked against every custom property it declares.

**Error:** six faults, none of which produces an error anywhere.

`--app-card2` (3 sites), `--app-fill2` (2), `--ios-ui` (4) and `--label` (1) were read and declared
nowhere. Every site carried a `var()` fallback, so nothing broke visibly; the token layer was
simply decoration and the literal beside it was doing the work.

`body.inframe.dark` restated the dark theme for dropped-in apps but omitted `--app-sub`, so a
third-party app in dark mode inherited the LIGHT secondary label from `:root`:
`rgba(60,60,67,.6)` on `#1C1C1E` is 1.36:1, which is not "hard to read", it is gone.

`--app-accent: var(--app-tint)` was declared only at `:root`. A `var()` is substituted where it is
DECLARED, not where it is read, so `html` resolved it against the LIGHT tint and every descendant
inherited that already-substituted value. On the dark chrome `--app-tint` was the dark blue while
`--app-accent`, which is meant to be the same colour, was still the light one.

`.device { z-index: var(--z-overlay) }` depended on `theme.css` loading first, with no fallback.

**Root cause:** a custom property has no failure mode. An undeclared one falls back silently, a
partially-restated theme block inherits from the wrong theme silently, and a `var()` resolved at the
root freezes there silently. Nothing in the toolchain looked for any of the three.

**Fix:** all five phantoms declared or repointed; `body.inframe.dark` given the full ladder rather
than a subset; `--app-accent` restated in `.screen.dark`; `.device` moved to `--ph-overlay-z`, which
is declared in this file and carries a fallback. The two `--app-fill2` sites kept their literals
deliberately: the real `--app-fill2` is half their strength and would have faded an empty star and
flattened a pressed state.

**Verified:** a computed-value probe over 216 element and token readings, in both themes, across 20
apps plus the home screen and both drop-in frame states, run against the page before and after. The
only element-level changes are the four that were intended. Parsed rule count identical (3113
before, 3113 after), so no comment or declaration swallowed a rule. `test-all.py --fast` 19 of 19,
including `run-probe` (every control reachable, 37 apps) and `probe-input`.

**Prevention:** two scans belong in `tools/check.py`: `var(--name)` where `--name` is declared
nowhere, and a name declared in one theme block but not in its twin. Both of these classes have now
cost two sessions.

## [2026-08-05 15:20] - a half-pixel separator does not paint at half strength

**Context:** the shared-component pass moved the list separator from `height: .5px` to the kit's
measured 1px, and the reasoning written into the stylesheet beside it claimed that a .5px box
reaches the screen at roughly half its declared alpha, so a fainter 1px paint would come out at
about the same strength.

**Error:** it does not. A six-pixel column captured across one Settings separator at device scale
1, decoded to raw RGB and read back, gives exactly one row of `#C6C6C8` - the full-strength
composite of `rgba(60,60,67,.29)` - for the .5px rule. Blink rounds the box up to a whole device
pixel and paints it at full alpha. The kit's `rgba(0,0,0,.098)` at 1px gives `#E6E6E6`. So the
swap that was described as neutral was in fact a drop in edge contrast from 1.706:1 to 1.248:1,
a 27 percent loss, on the single most repeated line in the interface.

**Root cause:** sub-pixel rendering was reasoned about instead of measured. The arithmetic was
plausible and wrong, and it had already been written into a comment as fact.

**Fix:** the thickness change stayed - 1px is the kit's measurement and it stops the line thinning
if the device scale factor ever moves - and the paint stayed on `--app-sep`. The comment now
carries the density argument that actually justifies the shipped value: Apple draws its 1.0pt
hairline on a 3x display, so it lands as three device pixels of `#E6E6E6`, and one pixel saying
the same thing needs about 0.29 alpha, which is what `--sep-nonopaque` already is.

**Prevention:** any claim about what a fractional CSS length, a blend mode or a translucent
overlay actually paints has to come from a captured pixel, not from compositing arithmetic.
`scratchpad/s2-seppix.js` is the shape of that check: capture a clip, decode it with ffmpeg, read
the rows, and print the contrast against the surface.


## [2026-08-05 15:35] - a composite custom property freezes the var() inside it

**Context:** the Liquid Glass pass declared the three inner shadows of `filter1_iii` as one
reusable list, `--lg-specular`, built from `--lg-hi` and `--lg-topshade`, so that every glass
surface could take the whole measured edge with one token. The dark block then overrode
`--lg-hi` from `rgba(255,255,255,.28)` to `.14`, which is the value the kit's own conversion
formula gives for a dark material.

**Error:** nothing changed in dark. The computed `box-shadow` on `.navact` still read
`rgba(255, 255, 255, 0.28)` under `.screen.dark`.

**Root cause:** a custom property's value is computed at the element that DECLARES it, with its
`var()` references already substituted. `--lg-specular` declared at `:root` therefore carries the
`:root` value of `--lg-hi` for ever, and overriding `--lg-hi` further down the cascade reaches
every direct use of it and none of the uses inside `--lg-specular`.

**Fix:** the five composite lists (`--lg-specular`, `--lg-specular-sm`, `--lg-ring`,
`--lg-ring-sheet`, `--lg-sides`, `--lg-sides-sm`) are restated in the dark block as well, with a
comment on each side saying they must be edited together.

**Prevention:** a token that is a LIST containing other tokens is not theme-aware by inheritance.
Either restate it in every theme block, or do not build one. Verify by reading the computed
property that consumes it, in both themes, not by reading the stylesheet.

## [2026-08-05 15:48] - the measured glass fill was fitted over a blurred backdrop

**Context:** Regular Medium/Large reduces algebraically to `rgba(246,246,246,0.73)`, fit error
0.0031, and that value was applied to the sheet as measured.

**Error:** the settings list behind the sheet was legible through it. A screenshot showed row
labels reading straight through a modal surface, which is the exact failure the "iOS 27: glass is
chrome" post-mortem in `html/style.css` was written about.

**Root cause:** the derivation fits `out = (1-A)*B + A*c` over a backdrop the real material has
already blurred. The composite average is right and the STRUCTURE is not: ported flat onto an
unblurred backdrop the fill reproduces the mean and keeps the text. Dark is four times worse than
light at the same alpha, because the ghost lands on a ground of 43 rather than 244 - the same
absolute difference is 6.5 percent of one and 1.2 percent of the other.

**Fix:** alpha raised to .96 light and .98 dark, both derived from the ghost-to-ground ratio
rather than picked, with the measured .73 and the arithmetic written beside them. The faithful
alternative is recorded in the same comment: one blur on the scrim, which is what Apple's own
Control Center export does (13 glass surfaces, 11 with no blur of their own).

**Prevention:** a composited fill measured from a kit is only valid over the backdrop it was
measured against. If the blur is not being ported, the alpha is not either.

## [2026-08-05 15:56] - a shape rule at (0,2,0) lost to a theme rule at (0,3,0), in one theme only

**Context:** `.sheet[data-shape="alert"]` was given the alert panel fill, `--lg-panel`.

**Error:** correct in light, wrong in dark. In dark the alert took `--lg-sheet`, the near-black
base surface meant for a bottom sheet, and nearly vanished against the app behind it.

**Root cause:** `.screen.dark .sheet` is (0,3,0) and `.sheet[data-shape="alert"]` is (0,2,0), so
the theme rule wins outright and source order never gets a say. The light path had no such
competitor, so the bug existed in exactly one theme and would have survived any check that only
looked at one.

**Fix:** the fill is written as four selectors - `.screen .sheet[data-shape=...]` and
`.screen.dark .sheet[data-shape=...]` for both shapes - so the dark pair is (0,4,0) and beats the
competitor on specificity rather than on position.

**Prevention:** any new rule on `.sheet` has to be checked against `.screen.dark .sheet` at
(0,3,0), and any measurement of a shared component has to be taken in both themes. This is the
fifth specificity failure recorded in this file and the first that was theme-asymmetric.

## [2026-08-05 19:40] - a Lua function returning two nils reads as a pair, not as nothing

**Context:** tools/test-verify.py drives `verifyDeskAt` in server/social.lua, which answers with
the desk AND the distance to it: `return best, bestAt`.

**Error:** three assertions of the form `g.verifyDeskAt(...) is None` failed for every position
that is genuinely nowhere near a desk, while the "no ped at all" case beside them passed.

**Root cause:** lupa is built with `unpack_returned_tuples=True`, so a Lua `return nil, nil`
arrives in Python as the tuple `(None, None)`. A tuple is not `None` and is truthy, so the test
read "no desk here" as "a desk". The passing case took the early `return nil` a few lines above,
which is a single value and does cross as `None`.

**Fix:** the test calls a one-line Lua wrapper, `function deskAt(c) return (verifyDeskAt(c)) end`.
The brackets truncate the return to one value, which is what "am I at a desk" actually asks.

**Prevention:** any lifted function with a multi-value return needs a truncating wrapper before
it is compared against `None` from Python. Checking the falsy case as well as the truthy one is
what exposed it: the wrong answer was truthy, so a suite that only asserted the success path
would have been green.
