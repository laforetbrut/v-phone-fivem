# Project Rules & AI/IDE Instructions

The single source of truth for anyone — human or assistant — working on this resource.
Read it before changing anything.

## 1. Project Identity

| Field | Value |
|---|---|
| Project name | v-phone (in-game brand: **iFruit**) |
| Resource name | `v-phone` |
| Version | `1.2.5` (single source: `fxmanifest.lua`) |
| Tech stack | Lua 5.4 (`lua54 'yes'`), vanilla JS + CSS for the NUI, MySQL via oxmysql |
| Author | vyrriox |
| Licence | See `LICENSE`. Attribution in Settings › About is **required** and must not be removed. |
| Hard dependency | `oxmysql` — the only one |
| Optional, all runtime-detected | qb-core, qbx_core, ox_core, es_extended, ox_inventory, qs/ps/qb/origen/codem inventory, Renewed/qb/okok/qs/esx banking, garages, housing, pma-voice, saltychat, ox_lib, ox_target, qb-target, qtarget, screenshot-basic, screencapture |

**Framework agnosticism is the product.** Every framework, inventory, bank, garage, housing
and voice script is optional and detected at runtime. A change that only works on one stack
is not finished.

## 2. Git Workflow

- `main` is the only long-lived branch. Work goes straight to it for ordinary changes.
- Feature branches `feat/<slug>`, fixes `fix/<slug>`, when a change wants review first.
- Commit messages: `type: lowercase summary` — `feat`, `fix`, `docs`, `perf`, `refactor`,
  `chore`. Present tense, no trailing full stop.
- **Never** put AI/assistant attribution in a commit, a comment, or any file.
- **Never** commit personal information. Git identity is the GitHub noreply address.
- **Never** commit `test-procedures/`, `.claude/`, `CLAUDE.md`, or `preview/` — all gitignored.
- Releases are cut by the maintainer. A contributor never bumps the version.

## 3. Code Conventions

**Language.** All code, comments, variable names, log lines and console output in **English**.
User-facing text goes in `locales/en.lua` **and** `locales/fr.lua`, never inline.

**Naming.** Lua locals and functions `camelCase`; globals the resource exports `PascalCase`
(`Booth`, `Bridge`, `Core`, `V`). Config keys `PascalCase` sections, `camelCase` fields.
Database tables are **always** prefixed `vphone_`. JS follows the same camelCase.

**Comments.** English, minimal, and they explain *why* — a comment that restates the line
below it, or that narrates a diff ("replaced the if with a switch"), does not belong here.
The file-header block explaining what a file is for is a convention worth keeping.

**Formatting.** Match the file you are in. The NUI files use a deliberate indentation for
nested HTML string concatenation, where indent depth mirrors DOM depth. **Do not run a
formatter over this repo.** There is no `.prettierrc` or `.editorconfig` on purpose, and a
reformat of `html/app.js` is 1,400 lines of churn that destroys `git blame` for zero gain.

**Architecture rules.**
- Never write into a framework's own tables or metadata. Per-character storage goes through
  `Bridge.KvGet` / `Bridge.KvSet` into `vphone_kv`.
- Never trust the client for anything that matters. Positions come from
  `GetEntityCoords(GetPlayerPed(src))` on the server; money, credit and item removal are
  server-decided; every NUI callback re-authorises.
- New framework integration goes in `bridge/`, behind a `Bridge.*` function, with a
  `Config.Compat` entry. Never `if framework == 'qb'` scattered through a feature file.
- A missing optional dependency must **degrade cleanly**, never error. Decide the
  fail-direction deliberately: `Bridge.HasItem` fails *open* so a missing inventory cannot
  lock everyone out of the phone; `Bridge.RemoveItem` fails *closed* so nothing is ever
  granted for an item that was not spent.
- New behaviour is configurable, not hardcoded.

**What NOT to do.** No placeholders or `TODO` in committed code. No new hard dependency. No
reformatting. No version bump. No emoji in code, config, or the issue picker. No coordinate
lists where a runtime lookup will do (see `client/booth.lua`).

## 4. Project Structure

```
fxmanifest.lua          Resource manifest. THE version lives here.
config.lua              Every knob, one file, heavily commented.
API.md                  Everything another resource may call.
COMPATIBILITY.md        What is detected, how, and how to wire your own.
DEVELOPERS.md           Writing a drop-in app.
CHANGELOG.md            English first, then the French mirror.
ERROR_LOG.md            Problems hit, root causes, prevention rules.
RULES.md                This file.

bridge/                 The compatibility layer. Nothing above it knows a framework name.
  shared/v.lua          `V`: callbacks, providers, settings, notify, hooks.
  shared/locale.lua     `L(key)` client/shared, `LP(src, key)` server.
  shared/compat.lua     Stubs for the upstream v-* modules, forwarded to what is installed.
  shared/booth.lua      Pure payphone number derivation. No natives — unit-testable.
  server/migrate.lua    Moves an older build's tables to the vphone_ prefix. Runs first.
  server/kv.lua         `vphone_kv`: per-character storage the phone owns.
  server/framework.lua  Detects qb/qbx/ox/esx/standalone, builds `Core` and the player.
  server/characters.lua Per-character rows.
  server/integrations.lua Inventory, banking, garages, housing, licences, jobs, status.
  client/charging.lua   Whether the player is somewhere the phone charges.

client/main.lua         The phone: open/close, prop, pose, calls, NUI relays.
client/police.lua       Forensics terminal: a map point and its relays.
client/booth.lua        Payphones: finds booth props, interaction, leash, pose.

server/main.lua         Numbers, messages, calls, battery, signal, apps, most callbacks.
server/booth.lua        Payphone credit, the prepaid card, the metered call.
server/social.lua       Bleeter, Snapmatic, Hush — player-shared data.
server/api.lua          Everything another resource calls. Loaded after what it wraps.
server/admin.lua        Staff actions and /phoneadmin.
server/police.lua       Forensics session auth and reads.
server/media.lua        Photo/video hosting with auto-deletion.

html/index.html         Three surfaces: the phone, the forensics terminal, the payphone.
html/app.js             The phone UI. Large; read the section banners to navigate.
html/sdk.js             The app SDK, served to third-party apps.
html/style.css          All styling. theme.css / theme-vars.css are the design system.

apps/_loader.lua        Defines PhoneApp(). Then apps/*/app.lua is globbed.
apps/example/           The reference drop-in app.
locales/en.lua, fr.lua  Must stay key-for-key identical.
sounds/                 Generated, not sampled. tools/make-sounds.py rebuilds them.
tools/                  make-sounds.py, new-app.ps1
test-procedures/        Local QA artefacts. GITIGNORED — never commit.
```

## 5. Adding a New Feature (Step by Step)

1. Read `ERROR_LOG.md` for anything related, and apply its prevention rules.
2. Find the closest existing feature and read it end to end. `client/police.lua` +
   `server/police.lua` is the reference for "a point in the world with its own NUI";
   `apps/example/` is the reference for a new app.
3. Branch: `git checkout -b feat/<slug>`.
4. Add the `Config.<Feature>` section, with comments explaining the *why* of each knob.
5. Put framework-touching code in `bridge/`, behind a `Bridge.*` function.
6. Write the server side first, since it owns every decision. Re-authorise in every callback.
7. Then the client, then the NUI. New NUI callback names must map only to that feature's
   server callbacks.
8. Add every string to `locales/en.lua` **and** `locales/fr.lua`.
9. Manifest: add new files in load order. Shared files that read `Config` load after it.
10. Docs: `CHANGELOG.md` (English then French), plus `README.md`, `API.md` and
    `COMPATIBILITY.md` if behaviour or the public surface changed.
11. Run the checks in section 6, then open a PR with the template filled in honestly.

## 6. Testing Checklist

There is no test runner in the repo. These are the checks that exist — run them.

- [ ] **Lua parses.** `python -c "from luaparser import ast; ast.parse(open('FILE').read())"`
      for every changed `.lua` (`pip install luaparser`).
- [ ] **JS parses.** `node --check html/app.js`
- [ ] **Pure logic is unit-tested.** `pip install lupa` gives a real Lua 5.4. Anything with no
      FiveM natives in it — `bridge/shared/booth.lua`, for instance — must be loaded and
      asserted against outside the game. Stub the natives and test the server file too.
- [ ] **Locale parity.** Load both locale files and diff the key sets. Zero drift, both ways.
- [ ] **Every locale key referenced in code exists**, including keys built by concatenation
      (`'ph.booth_err_' .. code`) — enumerate the codes and check each one.
- [ ] **No stub method assumed.** Grep `bridge/shared/compat.lua` and confirm any `V.Use(...)`
      method you call is actually published. Same for fields read off `Core` and `Bridge`.
- [ ] **UI renders.** Open `html/index.html` in a browser and drive the new screen by hand.
      Cache is aggressive — fetch the file with a cache-busting query and re-inject it.
- [ ] Server boots with no console error; client F8 console clean.
- [ ] The feature degrades cleanly with every optional dependency stopped.
- [ ] Tested on at least qb-core and one other framework, or the framework-specific paths
      were read line by line and the reasoning recorded in the PR.
- [ ] Existing behaviour that shares code with the change still works (regression gate).
- [ ] Test procedure written to `test-procedures/TEST_PROCEDURE_v<version>.html` — and **not**
      staged for commit.

## 7. Environment Setup

```bash
git clone https://github.com/laforetbrut/v-phone-fivem.git v-phone
```

1. Drop `v-phone` in your `resources/` folder.
2. Install [oxmysql](https://github.com/overextended/oxmysql) — the only hard dependency.
3. `ensure v-phone` in `server.cfg`, after your framework and oxmysql.
4. Tables are created and migrated on first start; nothing to import by hand.
5. Optional convars: `set phone_locale "fr"`, `set phone_media_key "..."`.
6. There is no build step. Lua and JS are shipped as source and edited in place.

Tooling for the checks in section 6: `pip install luaparser lupa`, plus Node for
`node --check`. Nothing else is required.

## 8. AI Assistant Instructions

1. **Read this file and `ERROR_LOG.md` first.** Apply the prevention rules already recorded.
2. **Do not reformat.** Match the surrounding style exactly, including the NUI string-concat
   indentation. A formatter run over this repo is a rejected change.
3. **Never bump the version** unless explicitly asked. When asked, propagate it to
   `fxmanifest.lua`, `CHANGELOG.md`, `README.md` and any `@version` header.
4. **Never write personal information** anywhere — no email, real name, Discord tag, ID, key
   or endpoint. `vyrriox` is the only identity permitted. Existing exposure is not permission;
   report it instead. If a task seems to need personal data, **stop and ask**.
5. **Never add AI attribution** to a commit, comment, or file.
6. **Both locale files, every time.** A string in one and not the other is a bug.
7. **Never trust the client.** Positions, money, credit and item removal are server decisions.
   Every NUI callback re-authorises on the server.
8. **Framework code belongs in `bridge/`**, behind a `Bridge.*` function with a
   `Config.Compat` entry. Never branch on a framework name inside a feature file.
9. **Test before reporting done.** Run section 6. If something could not be verified, say so
   explicitly rather than implying it passed. "It should work" is not a test.
10. **Fix adjacent bugs you find**, then log them in `ERROR_LOG.md` with a prevention rule.
    Ask first if the fix needs a destructive operation or an architectural change.
11. **Prefer a runtime lookup to a maintained list.** The payphones find their props; the
    forensics terminals use a config list only because there is no prop to find.
12. **Update the docs** in the same change: `CHANGELOG.md` English-then-French, and
    `README.md` / `API.md` / `COMPATIBILITY.md` when the public surface moves.
