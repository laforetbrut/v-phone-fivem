/**
 * Record the store previews: a short silent clip of each app actually running.
 *
 *   python tools/make-preview.py     # build the browser preview first
 *   node tools/make-previews.js      # then record from it
 *
 * The store used to draw its previews from CSS - little abstract shapes standing in for a
 * screen. They were honest placeholders and they read as placeholders. This records the real
 * thing instead: the same `html/` the resource ships, booted by `tools/make-preview.py`,
 * driven through each app and captured frame by frame.
 *
 * No dependency is installed for this. Node 22 has a WebSocket client built in, so it speaks
 * the Chrome DevTools Protocol directly to a headless Chrome that is already on the machine,
 * and hands the frames to ffmpeg. If any of the three is missing the tool says which one and
 * stops - it does not half-write a previews folder.
 *
 * Output is `html/previews/<id>.webm` plus `index.json`, the manifest the page reads to know
 * which apps have one. The manifest is the reason there is no directory listing at runtime: a
 * NUI page cannot ask what files exist, and a 404 per app to find out is not an answer.
 *
 * Re-run it after a UI change. A recording of an old build is worse than no recording, because
 * a placeholder does not claim to be current.
 *
 * Flags:
 *   --apps bank,notes    record only these
 *   --seconds 4          length of each loop (default 4)
 *   --fps 25             frames per second (default 25)
 *   --theme dark,light   which themes to record (default both)
 *   --posters-only       rebuild the stills and the manifest from clips already on disk
 *   --keep               leave the PNG frames on disk for inspection
 */

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.dirname(__dirname);
const PREVIEW = path.join(ROOT, 'preview', 'index.html');
const OUT = path.join(ROOT, 'html', 'previews');
const PORT = 9333;

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const ONLY = flag('apps', '').split(',').map((s) => s.trim()).filter(Boolean);
const SECONDS = Number(flag('seconds', 4)) || 4;
const FPS = Number(flag('fps', 25)) || 25;
// Both, because the phone has both and a player sees only one of them.
//
// Every recording used to be made in whatever theme the preview happened to boot in, which is
// dark - so on a light phone the whole store was dark rectangles on a white page. A store
// showing an app in a theme its owner does not use is showing them somebody else's phone.
const THEMES = String(flag('theme', 'dark,light')).split(',')
  .map((t) => t.trim()).filter((t) => t === 'dark' || t === 'light');
const KEEP = argv.includes('--keep');
const FRAMES = Math.max(2, Math.round(SECONDS * FPS));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ══════════════════════════════════════════════════════════════
// The three things that have to be there
// ══════════════════════════════════════════════════════════════

function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    path.join(process.env.LOCALAPPDATA || '', 'Google/Chrome/Application/chrome.exe'),
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ].filter(Boolean);
  return candidates.find((p) => { try { return fs.statSync(p).isFile(); } catch { return false; } });
}

function haveFfmpeg() {
  return spawnSync('ffmpeg', ['-version'], { shell: true }).status === 0;
}

// ══════════════════════════════════════════════════════════════
// A very small CDP client
// ══════════════════════════════════════════════════════════════

class CDP {
  constructor(url) {
    this.ws = new WebSocket(url);
    this.id = 0;
    this.pending = new Map();
    this.ws.addEventListener('message', (e) => {
      const msg = JSON.parse(e.data);
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error.message)); else p.resolve(msg.result);
    });
  }

  open() {
    return new Promise((resolve, reject) => {
      this.ws.addEventListener('open', resolve, { once: true });
      this.ws.addEventListener('error', () => reject(new Error('devtools socket refused')), { once: true });
    });
  }

  send(method, params) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params: params || {} }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  /// Run an expression in the page and return its value.
  ///
  /// `awaitPromise` because most of what this drives is async - entering an app renders, waits
  /// and renders again, and evaluating without waiting would capture the frame before the app.
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression: `(async () => { ${expression} })()`,
      awaitPromise: true,
      returnByValue: true,
    });
    if (r.exceptionDetails) {
      throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    }
    return r.result.value;
  }
}

// ══════════════════════════════════════════════════════════════
// What the page is put through before anything is captured
// ══════════════════════════════════════════════════════════════

// The preview boots the way a fresh install boots, so twelve of the apps are gated behind a
// module and simply are not there. A store that shows previews for two thirds of its catalogue
// is not the point of this.
const BOOTSTRAP = `
  try { if (typeof unlock === 'function') unlock(); } catch (e) {}
  await new Promise((r) => setTimeout(r, 400));

  const template = (state.apps || []).find((a) => a.id === 'notes') || (state.apps || [])[0];
  const have = new Set((state.apps || []).map((a) => a.id));
  for (const id of Object.keys(RENDER)) {
    if (!have.has(id)) state.apps.push(Object.assign({}, template, { id, label: 'app.' + id, dock: false }));
  }
  window.__ALL_APPS__ = (state.apps || []).slice();
  renderHome();

  // Square the screen off and hold the phone still. The tile these end up in has its own
  // rounded corners and its own shadow; a recording that brings a second set of both looks
  // like a photograph of a phone rather than a screen.
  const css = document.createElement('style');
  css.textContent = \`
    /* The radius is set TWICE - once on the screen and again on the section stacked inside it -
       so zeroing only the screen leaves the app's own corners cutting the same shape, and the
       page background shows through exactly as before. Every layer, or none of them. */
    .screen, #app, #callui, #switcher, #shade, #folderview, #cc, #scrim
      { border-radius: 0 !important; }
    .device { animation: none !important; transform: none !important;
              filter: none !important; right: 40px !important; bottom: 40px !important; }
    /* The handset's own furniture, gone. A recording that keeps the clock, the signal bars
       and the home indicator ends up inside a phone that has all three of its own, and the
       result reads as a photograph of a phone rather than a picture of an app. The island is
       hidden the same way and for the same reason. */
    #island, #homebar { display: none !important; }
    /* Nothing that ticks. A blinking caret lands on some frames and not others, and a loop
       that stutters once every three seconds reads as a broken video. */
    *, *::before, *::after { caret-color: transparent !important; }
  \`;
  document.head.appendChild(css);
  await new Promise((r) => setTimeout(r, 300));

  // Below the status bar rather than from the very top. The bar is left in place - the apps
  // lay themselves out under it and hiding it would shift every screen up by fifty pixels -
  // and the CLIP simply starts underneath.
  const r = document.getElementById('screen').getBoundingClientRect();
  const bar = document.getElementById('status');
  const drop = bar ? Math.round(bar.getBoundingClientRect().height) : 0;
  return { x: Math.round(r.left), y: Math.round(r.top) + drop,
           width: Math.round(r.width), height: Math.round(r.height) - drop,
           apps: window.__ALL_APPS__.map((a) => a.id) };
`;

/// Enter one app and settle.
///
/// `state.apps` is restored first because several renderers call `refresh()`, which replaces
/// the list with the server's own - so the twelve installed above vanish partway through and
/// the run quietly finishes on twenty-one of thirty-three.
const enter = (id) => `
  const app = (window.__ALL_APPS__ || []).find((a) => a.id === ${JSON.stringify(id)});
  if (!app) return false;
  if (!(state.apps || []).some((a) => a.id === app.id)) state.apps.push(app);
  try { goHome && goHome(); } catch (e) {}
  await new Promise((r) => setTimeout(r, 160));
  try { await enterApp(app, null); } catch (e) { return 'crash:' + (e.message || e); }
  await new Promise((r) => setTimeout(r, 620));
  const body = document.getElementById('appbody');
  return { scroll: body ? Math.max(0, body.scrollHeight - body.clientHeight) : 0 };
`;

/// Force one theme and keep it.
///
/// Set through the preference rather than by adding the class, because `applyTheme` runs again
/// on its own - on an in-game hour, on a settings change - and would put back whatever the
/// preference said. Setting the class alone holds until the first thing that repaints.
const setTheme = (theme) => `
  state.prefs = state.prefs || {};
  state.prefs.darkMode = ${JSON.stringify(theme)};
  state.prefs.dark = ${theme === 'dark'};
  state.theme = Object.assign({}, state.theme, { auto: false });
  applyTheme();
  await new Promise((r) => setTimeout(r, 260));
  return document.getElementById('screen').classList.contains('dark');
`;

/// Where the app should be scrolled to on frame `i`.
///
/// Four beats: hold, glide down, hold, glide back. The first and last frames sit at the same
/// place because this plays on `loop`, and a clip that ends somewhere other than where it
/// started jumps every time it repeats.
///
/// The first version was a plain cosine across the app's entire height in three seconds, and
/// it looked exactly like what it was - a fast mechanical sweep with no pause anywhere. Two
/// things fix that. **Smootherstep** rather than a cosine, so the ends have no velocity at all
/// instead of merely low velocity. And a **bounded distance**: about one screen and a bit,
/// wherever the app is long, because a store preview is meant to show you the top of an app
/// rather than race you to the bottom of it.
///
/// Short apps have nothing to scroll and simply sit there, which is fine - a still of the real
/// screen still beats a drawing of one.
const scrollTo = (i) => `
  const body = document.getElementById('appbody');
  if (body) {
    const max = Math.max(0, body.scrollHeight - body.clientHeight);
    const far = Math.min(max, body.clientHeight * 1.15);
    const t = ${i} / ${FRAMES};
    // Smootherstep: zero velocity AND zero acceleration at both ends, which is the difference
    // between a glide that settles and one that stops.
    const ease = (x) => { const c = Math.max(0, Math.min(1, x)); return c * c * c * (c * (c * 6 - 15) + 10); };
    let at = 0;
    if (t < 0.18) at = 0;
    else if (t < 0.50) at = far * ease((t - 0.18) / 0.32);
    else if (t < 0.68) at = far;
    else at = far * (1 - ease((t - 0.68) / 0.32));
    body.scrollTop = Math.round(at);
  }
  return true;
`;

// ══════════════════════════════════════════════════════════════
// Stills
// ══════════════════════════════════════════════════════════════

/// Pull one frame out of a recording and write it beside the clip.
///
/// The front page shows a dozen apps at once, and a dozen videos decoding behind a running game
/// is not a design - it is a frame-rate problem. Only the shop window at the top moves;
/// everywhere else uses this.
///
/// The frame is taken from the settled part of the loop rather than frame zero, because the
/// first frame of every clip is the same untouched top-of-app view and a shelf of those is a
/// shelf of identical headers.
function poster(id) {
  const clip = path.join(OUT, id + '.webm');
  const out = path.join(OUT, id + '.jpg');
  if (!fs.existsSync(clip)) return '';
  const r = spawnSync('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-i', clip,
    '-vf', `select=eq(n\\,${Math.round(FRAMES * 0.55)})`,
    '-vframes', '1', '-q:v', '4', out,
  ], { shell: true });
  return r.status === 0 ? 'previews/' + id + '.jpg' : '';
}

/// Rebuild the stills and the manifest from the clips already on disk.
///
/// Recording takes twenty minutes; this takes seconds, and it is what you want after changing
/// how the stills are used rather than what they show.
function postersOnly() {
  if (!haveFfmpeg()) { console.error('no ffmpeg on PATH.'); process.exit(1); }
  if (!fs.existsSync(OUT)) { console.error('no html/previews - record first.'); process.exit(1); }
  const manifest = {};
  for (const file of fs.readdirSync(OUT).filter((f) => f.endsWith('.webm')).sort()) {
    const base = file.slice(0, -5);
    // `bank` is the dark clip and `bank.light` is its light twin - the dark name is bare so
    // clips recorded before there were two themes still read correctly.
    const light = base.endsWith('.light');
    const id = light ? base.slice(0, -6) : base;
    const entry = { previews: ['previews/' + base + '.webm'], poster: poster(base) };
    manifest[id] = manifest[id] || {};
    if (light) manifest[id].light = entry;
    else Object.assign(manifest[id], entry);
    console.log(`  ${base.padEnd(20)} ${entry.poster ? 'still' : 'NO STILL'}`);
  }
  fs.writeFileSync(path.join(OUT, 'index.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(`\n${Object.keys(manifest).length} app(s) in html/previews/index.json`);
}

// ══════════════════════════════════════════════════════════════
// Run
// ══════════════════════════════════════════════════════════════

async function main() {
  if (argv.includes('--posters-only')) { postersOnly(); return; }
  if (!fs.existsSync(PREVIEW)) {
    console.error('no preview to record. Run:  python tools/make-preview.py');
    process.exit(1);
  }
  const chrome = findChrome();
  if (!chrome) { console.error('no Chrome found. Set CHROME_PATH to one.'); process.exit(1); }
  if (!haveFfmpeg()) { console.error('no ffmpeg on PATH.'); process.exit(1); }

  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'vphone-rec-'));
  const child = spawn(chrome, [
    '--headless=new',
    '--remote-debugging-port=' + PORT,
    '--user-data-dir=' + profile,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--hide-scrollbars', '--force-device-scale-factor=1',
    '--allow-file-access-from-files',
    '--window-size=1280,900',
    'file:///' + PREVIEW.replace(/\\/g, '/'),
  ], { stdio: 'ignore' });

  let cdp;
  const frameDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vphone-frames-'));
  try {
    // Chrome writes the port file before it serves, so poll rather than sleeping on a guess.
    let target = null;
    for (let i = 0; i < 60 && !target; i += 1) {
      await sleep(250);
      try {
        const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
        target = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
      } catch { /* not up yet */ }
    }
    if (!target) throw new Error('Chrome never opened its devtools port');

    cdp = new CDP(target.webSocketDebuggerUrl);
    await cdp.open();
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: 1280, height: 900, deviceScaleFactor: 2, mobile: false,
    });

    await sleep(1200);
    const box = await cdp.eval(BOOTSTRAP);
    // Even dimensions. VP9 wants them, and an odd height would be silently padded - which is
    // one row of black along an edge that nobody notices until it ships.
    box.width -= box.width % 2;
    box.height -= box.height % 2;
    const ids = ONLY.length ? box.apps.filter((id) => ONLY.includes(id)) : box.apps;
    console.log(`recording ${ids.length} app(s), ${FRAMES} frames each, screen ${box.width}x${box.height}`);

    fs.mkdirSync(OUT, { recursive: true });
    // **A partial run merges into the manifest rather than replacing it.**
    //
    // `--apps bank` used to write a manifest containing bank and nothing else, so re-recording
    // one app quietly took the other thirty-three out of the store - the clips were still on
    // disk, and the page had no way left to know they were there. Re-recording one app is the
    // ordinary reason to use the flag, which made this the ordinary outcome.
    let manifest = {};
    if (ONLY.length) {
      try {
        manifest = JSON.parse(fs.readFileSync(path.join(OUT, 'index.json'), 'utf8')) || {};
      } catch { manifest = {}; }
    }
    const skipped = [];

    for (const theme of THEMES) {
      const isDark = await cdp.eval(setTheme(theme));
      if (isDark !== (theme === 'dark')) {
        console.log(`  ! the page would not stay ${theme} - skipping that pass`);
        continue;
      }
      // `bank.webm` for dark and `bank.light.webm` for light: the dark name is left bare so
      // every clip recorded before this existed keeps working untouched.
      const suffix = theme === 'dark' ? '' : '.' + theme;
      console.log(`  ${theme}:`);

    for (const id of ids) {
      const entered = await cdp.eval(enter(id));
      if (entered === false || typeof entered === 'string') {
        skipped.push(id + ' (' + (entered || 'not in the list') + ')');
        continue;
      }

      const dir = path.join(frameDir, theme + '-' + id);
      fs.mkdirSync(dir, { recursive: true });
      for (let i = 0; i < FRAMES; i += 1) {
        await cdp.eval(scrollTo(i));
        // One frame of settle. Without it the capture races the scroll and half the frames
        // land mid-paint, which shows up as tearing in the encode.
        await sleep(25);
        const shot = await cdp.send('Page.captureScreenshot', {
          format: 'png',
          captureBeyondViewport: false,
          clip: { x: box.x, y: box.y, width: box.width, height: box.height, scale: 2 },
        });
        fs.writeFileSync(path.join(dir, String(i).padStart(4, '0') + '.png'),
                         Buffer.from(shot.data, 'base64'));
      }

      const out = path.join(OUT, id + suffix + '.webm');
      const enc = spawnSync('ffmpeg', [
        '-y', '-loglevel', 'error',
        '-framerate', String(FPS),
        '-i', path.join(dir, '%04d.png'),
        // VP9: every browser Chromium ships in FiveM plays it, and it holds flat UI colour far
        // better than VP8 at the same size. `-b:v 0 -crf` is the quality-targeted mode.
        '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '32',
        '-pix_fmt', 'yuv420p', '-row-mt', '1',
        // Slower encode, better motion. These are built once and watched many times, so time
        // spent here is the cheapest quality there is. A keyframe every second keeps the loop
        // seam clean without inflating the file.
        '-deadline', 'good', '-cpu-used', '1', '-g', String(FPS),
        // Half the source. The tile is ~170 CSS pixels wide; anything larger is bytes the
        // player downloads and never sees.
        '-vf', `scale=${box.width}:${box.height}:flags=lanczos`,
        '-an', out,
      ], { shell: true });
      if (enc.status !== 0) {
        skipped.push(id + ' (encode failed)');
        continue;
      }
      const entry = { previews: ['previews/' + id + suffix + '.webm'],
                      poster: poster(id + suffix) };
      if (theme === 'dark') manifest[id] = Object.assign(manifest[id] || {}, entry);
      else manifest[id] = Object.assign(manifest[id] || {}, { [theme]: entry });
      const kb = Math.round(fs.statSync(out).size / 1024);
      console.log(`    ${id.padEnd(14)} ${String(kb).padStart(5)} KB`);
    }
    }

    fs.writeFileSync(path.join(OUT, 'index.json'), JSON.stringify(manifest, null, 2) + '\n');
    console.log(`\n${Object.keys(manifest).length} recording(s) in html/previews/`);
    if (skipped.length) console.log('skipped: ' + skipped.join(', '));
  } finally {
    try { cdp && cdp.ws.close(); } catch { /* already gone */ }
    child.kill();
    if (!KEEP) fs.rmSync(frameDir, { recursive: true, force: true });
    else console.log('frames kept in ' + frameDir);
    // Chrome is still letting go of its own profile for a moment after the kill, and a
    // temporary directory that survives is not worth failing a finished run over.
    await sleep(500);
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* Chrome still has it */ }
  }
}

main().catch((e) => { console.error(e.message); process.exit(1); });
