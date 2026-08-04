/**
 * Drive the phone with REAL mouse input, through the browser's own hit testing.
 *
 *   python tools/make-preview.py --lang fr
 *   node tools/probe-input.js
 *
 * ── Why this exists, and why make-shots.js is not enough ───────────────────────────────
 *
 * Every assertion in tools/make-shots.js runs inside the page: it finds an element, calls
 * `.click()` on it, or dispatches a `PointerEvent` at it. That is a good test of the handler
 * and **no test at all of whether a player can reach it**, because a dispatched event skips
 * hit testing entirely. It arrives whatever is drawn on top, whatever `pointer-events` says,
 * and whatever the real target under that pixel would have been.
 *
 * The widget strip shipped with a minus badge that was drawn correctly, hit correctly, and did
 * nothing: the badge stopped propagation on pointerdown, which also stopped the flag that told
 * the home screen the press had begun inside the strip, so the pointerup read as a tap on the
 * wallpaper, left arrange mode and destroyed the badge before its own click could fire. The
 * in-page assertion passed the whole time. This probe found it on the first run.
 *
 * `Input.dispatchMouseEvent` goes through the compositor, the same as a finger. If a control
 * cannot be pressed here, it cannot be pressed by a player.
 *
 * Exit code 1 if any check fails.
 */
const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.dirname(__dirname);
const PREVIEW = path.join(ROOT, 'preview', 'index.html');
const PORT = 9391;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function chromePath() {
  const guesses = [
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    (process.env.LOCALAPPDATA || '') + '/Google/Chrome/Application/chrome.exe',
    '/usr/bin/google-chrome', '/usr/bin/chromium',
  ];
  for (const g of guesses) if (g && fs.existsSync(g)) return g;
  const w = spawnSync(process.platform === 'win32' ? 'where' : 'which', ['chrome'],
    { encoding: 'utf8' });
  if (w.status === 0) return w.stdout.trim().split(/\r?\n/)[0];
  throw new Error('no chrome on this machine');
}

class CDP {
  constructor(url) {
    this.ws = new WebSocket(url);
    this.id = 0;
    this.waiting = new Map();
    this.ready = new Promise((res) => { this.ws.onopen = res; });
    this.ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      const w = this.waiting.get(m.id);
      if (w) { this.waiting.delete(m.id); w(m); }
    };
  }
  send(method, params) {
    const id = ++this.id;
    return new Promise((res) => {
      this.waiting.set(id, res);
      this.ws.send(JSON.stringify({ id, method, params: params || {} }));
    });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression: `(async () => { ${expression} })()`,
      awaitPromise: true, returnByValue: true,
    });
    if (r.result && r.result.exceptionDetails) {
      throw new Error(r.result.exceptionDetails.exception
        ? r.result.exceptionDetails.exception.description
        : r.result.exceptionDetails.text);
    }
    return r.result && r.result.result ? r.result.result.value : undefined;
  }
  /// One real mouse event, in page coordinates.
  mouse(type, x, y) {
    return this.send('Input.dispatchMouseEvent', {
      type, x, y, button: 'left', buttons: type === 'mouseMoved' ? 0 : 1,
      clickCount: 1, pointerType: 'mouse',
    });
  }
  /// Press, hold, release. `hold` in milliseconds - past 380 the phone reads it as a long press.
  async press(x, y, hold) {
    await this.mouse('mouseMoved', x, y);
    await this.mouse('mousePressed', x, y);
    await sleep(hold || 60);
    await this.mouse('mouseReleased', x, y);
  }
  /// A real drag, in steps, because one jump from A to B is not a gesture any handler sees.
  async drag(from, to, steps) {
    steps = steps || 10;
    await this.mouse('mouseMoved', from.x, from.y);
    await this.mouse('mousePressed', from.x, from.y);
    await sleep(120);
    for (let i = 1; i <= steps; i++) {
      const k = i / steps;
      await this.send('Input.dispatchMouseEvent', {
        type: 'mouseMoved', button: 'left', buttons: 1, clickCount: 0, pointerType: 'mouse',
        x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k,
      });
      await sleep(30);
    }
    await sleep(120);
    await this.mouse('mouseReleased', to.x, to.y);
  }
}

const failures = [];
function check(ok, what, detail) {
  console.log(`  ${ok ? 'ok   ' : 'FAIL '}${what}${detail ? '  (' + detail + ')' : ''}`);
  if (!ok) failures.push(what + (detail ? ': ' + detail : ''));
}

/// The centre of an element, in page coordinates, or null.
const AT = (sel) => `
  const el = document.querySelector(${JSON.stringify(sel)});
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height };
`;

async function widgetStrip(cdp) {
  console.log('the widget strip');

  await cdp.eval(`
    try { if (typeof unlock === 'function') unlock(); } catch (e) {}
    await new Promise((r) => setTimeout(r, 600));
    state.prefs.gridCols = 4; state.prefs.gridRows = 4;
    state.prefs.widgets = ['weather', 'calendar'];
    if (typeof editing !== 'undefined' && editing) exitArrange();
    renderHome();
    await new Promise((r) => setTimeout(r, 900));
  `);

  const first = await cdp.eval(AT('#widgets .widget[data-w]'));
  if (!first) { check(false, 'a widget is drawn'); return; }

  // Is the widget the thing under its own middle? If something is drawn over the strip, every
  // other check below would fail for a reason no handler could explain.
  const under = await cdp.eval(`
    const el = document.elementFromPoint(${first.x}, ${first.y});
    const w = el && el.closest && el.closest('.widget[data-w]');
    return w ? w.dataset.w : (el ? el.tagName + '.' + el.className : 'nothing');
  `);
  check(under === 'weather', 'the widget is what is under its own centre', 'found ' + under);

  // Holding it must enter arrange mode. The app grid's long press is wired to #pages, and the
  // strip is a sibling of #pages - so this had to be wired separately and was not.
  await cdp.press(first.x, first.y, 700);
  await sleep(400);
  const held = await cdp.eval(`return { editing: !!editing,
    badges: document.querySelectorAll('#widgets .wrm').length,
    add: !!document.getElementById('waddbtn') };`);
  check(held.editing, 'holding a widget enters arrange mode');
  check(held.badges > 0, 'every widget gains a minus badge', held.badges + ' drawn');
  check(held.add, 'the add button appears');

  // The minus, pressed for real.
  const badge = await cdp.eval(AT('#widgets .wrm'));
  if (badge) {
    const before = await cdp.eval('return widgetIds().join(",");');
    await cdp.press(badge.x, badge.y);
    await sleep(500);
    const after = await cdp.eval('return widgetIds().join(",");');
    const still = await cdp.eval('return !!editing;');
    check(after !== before, 'the minus removes the widget', before + ' -> ' + after);
    check(still, 'removing one stays in arrange mode');
  } else {
    check(false, 'a minus badge exists to press');
  }

  // The add button opens the gallery, and a row in it adds what it names.
  const plus = await cdp.eval(AT('#waddbtn'));
  if (plus) {
    await cdp.press(plus.x, plus.y);
    await sleep(600);
    const open = await cdp.eval("return document.getElementById('sheet').classList.contains('on');");
    check(open, 'the add button opens the picker');
    const row = await cdp.eval(AT('#sheet .row[data-add]'));
    if (row) {
      const want = await cdp.eval("return document.querySelector('#sheet .row[data-add]').dataset.add;");
      await cdp.press(row.x, row.y);
      await sleep(800);
      const has = await cdp.eval(`return widgetIds().indexOf(${JSON.stringify(want)}) >= 0;`);
      check(has, 'picking a widget adds it', want);
    } else {
      check(false, 'the picker offers a row to press');
    }
  } else {
    check(false, 'an add button exists to press');
  }

  // And dragging one past the other reorders the strip.
  await cdp.eval(`
    try { closeSheet(true); } catch (e) {}
    state.prefs.widgets = ['weather', 'calendar'];
    if (!editing) enterArrange(); else paintWidgets(byId('widgets'), widgetLast);
    await new Promise((r) => setTimeout(r, 500));
  `);
  const a = await cdp.eval(AT('#widgets .widget[data-w="weather"]'));
  const b = await cdp.eval(AT('#widgets .widget[data-w="calendar"]'));
  if (a && b) {
    const order = await cdp.eval('return widgetIds().join(",");');
    await cdp.drag(a, b, 12);
    await sleep(700);
    const now = await cdp.eval('return widgetIds().join(",");');
    check(now !== order, 'dragging one past another reorders the strip', order + ' -> ' + now);
  } else {
    check(false, 'two widgets to drag between');
  }

  await cdp.eval('try { exitArrange(); } catch (e) {}');
}

/// Nothing a player can press may sit in the home indicator's band.
///
/// The indicator is a five pixel pill with an invisible hit target stretching twenty-six pixels
/// above it, because a swipe that starts slightly high still has to count. That band is the
/// bottom forty pixels of the screen. On an app with a tab bar it costs nothing - the footer is
/// above the indicator and wins the hit test. On an app WITHOUT one the footer used to collapse
/// to nothing, the body ran to the bottom of the screen, and every row scrolled straight
/// through the band on its way past: a tap on one went to the home screen instead, which is the
/// worst wrong destination the phone has.
///
/// The fix reserves the strip, so this asserts the property rather than any handler: Settings
/// has no tab bar, and at EVERY scroll position nothing pressable may have its centre in the
/// band. Then the bar is shown to still do its own job.
/// Copying a picture's link, pressed for real.
///
/// The viewer closes on a tap ANYWHERE inside it, so this button lives on top of a listener
/// whose whole job is to make it go away. The press has to reach the button, the button has to
/// stop the tap travelling, and the viewer has to still be there afterwards - three things a
/// synthetic click cannot tell you anything about, because it skips the hit test that decides
/// which of the two is pressed in the first place.
async function copyLink(cdp) {
  console.log('');
  console.log('copying a picture link');

  const shown = await cdp.eval(`
    try { if (typeof unlock === 'function') unlock(); } catch (e) {}
    if (typeof editing !== 'undefined' && editing) exitArrange();
    try { goHome(); } catch (e) {}
    await new Promise((r) => setTimeout(r, 400));
    window.__copied = null;
    window.__realCopy = copyText;
    copyText = (t) => { window.__copied = t; return true; };
    openPhoto('https://example.invalid/shot-9182.webp', 'a caption');
    await new Promise((r) => setTimeout(r, 500));
    const b = document.querySelector('.photoview .pvlink');
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: Math.round(r.width) };
  `);
  check(!!shown, 'an uploaded picture offers a link button', shown ? shown.w + 'px' : 'not drawn');
  if (!shown) return;

  await cdp.press(shown.x, shown.y, 80);
  await sleep(500);

  const after = await cdp.eval(`
    return { copied: window.__copied,
             open: document.getElementById('photoview').classList.contains('on') };
  `);
  check(after.copied === 'https://example.invalid/shot-9182.webp',
    'the press copied the address', String(after.copied));
  check(after.open === true, 'and the viewer did not close under it',
    after.open ? '' : 'the tap reached the backdrop');

  // A picture the phone has not uploaded has nothing to copy, and must not pretend otherwise.
  const local = await cdp.eval(`
    closePhoto();
    await new Promise((r) => setTimeout(r, 300));
    openPhoto('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg"/>');
    await new Promise((r) => setTimeout(r, 400));
    const has = !!document.querySelector('.photoview .pvlink');
    closePhoto();
    copyText = window.__realCopy;
    return has;
  `);
  check(local === false, 'a local picture offers no link', local ? 'it offered one' : '');
}

/// Picking an emoji, and picking one after changing category.
///
/// The grid used to bind a listener to every glyph - two hundred and thirty of them on one tab -
/// and rebind them all on each tab tap. It is one delegated listener on the panel now, which is
/// the kind of change that either works or silently stops emoji from being pickable at all. The
/// second half of the check is the one that matters: the panel survives a repaint and the grid
/// does not, so a listener bound to the wrong one would work exactly once.
async function emojiPicker(cdp) {
  console.log('');
  console.log('the emoji picker');

  const first = await cdp.eval(`
    try { if (typeof unlock === 'function') unlock(); } catch (e) {}
    if (typeof editing !== 'undefined' && editing) exitArrange();
    try { goHome(); } catch (e) {}
    await new Promise((r) => setTimeout(r, 400));
    // A field for the picker to type into, and the picker pointed at it.
    body('<input id="probemsg" type="text" value="">');
    emojiOpen('probemsg');
    await new Promise((r) => setTimeout(r, 500));
    const b = document.querySelector('.emojigrid [data-e]');
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, glyph: b.dataset.e };
  `);
  check(!!first, 'the grid draws pickable glyphs', first ? first.glyph : 'none');
  if (!first) return;

  await cdp.press(first.x, first.y, 70);
  await sleep(350);
  let val = await cdp.eval("return (byId('probemsg') || {}).value || '';");
  check(val === first.glyph, 'pressing one types it', JSON.stringify(val));

  // Now change category, which repaints the grid, and pick again. A listener bound to the
  // GRID rather than the panel would be gone by now.
  const second = await cdp.eval(`
    const tab = [...document.querySelectorAll('.emojitabs button')]
      .find((t) => t.dataset.c && t.dataset.c !== emojiCat);
    if (!tab) return null;
    tab.click();
    await new Promise((r) => setTimeout(r, 400));
    byId('probemsg').value = '';
    const b = document.querySelector('.emojigrid [data-e]');
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, glyph: b.dataset.e };
  `);
  check(!!second, 'another category draws its own glyphs', second ? second.glyph : 'none');
  if (!second) return;

  await cdp.press(second.x, second.y, 70);
  await sleep(350);
  val = await cdp.eval("return (byId('probemsg') || {}).value || '';");
  check(val === second.glyph, 'and one from THAT grid still types',
    JSON.stringify(val) + ' wanted ' + JSON.stringify(second.glyph));

  await cdp.eval("try { emojiClose(); } catch (e) {} return true;");
}

async function homeBand(cdp) {
  console.log('');
  console.log('the home indicator band');

  await cdp.eval(`
    try { if (typeof unlock === 'function') unlock(); } catch (e) {}
    // The grid probe above leaves the home screen in arrange mode, and the FIRST thing the
    // home indicator does in arrange mode is leave it - so without this the press below would
    // be spent on that instead of on going home, and the check would fail for the probe's own
    // reason rather than the phone's.
    if (typeof editing !== 'undefined' && editing) exitArrange();
    await new Promise((r) => setTimeout(r, 500));
    const app = (state.apps || []).find((a) => a.id === 'settings');
    await enterApp(app, null);
    await new Promise((r) => setTimeout(r, 800));
  `);

  const swept = await cdp.eval(`
    const body = document.getElementById('appbody');
    const bar = document.getElementById('homebar');
    const br = bar.getBoundingClientRect();
    const bandTop = br.top - 26, bandBottom = br.bottom + 14;
    const sel = 'button, a, input, textarea, select, .row, [role="switch"]';
    const caught = [];
    let steps = 0;
    // Smooth scrolling animates an assignment, so a value read back a few milliseconds later
    // is still the old one. Turned off for the sweep and put back after.
    const wasBehaviour = body.style.scrollBehavior;
    body.style.scrollBehavior = 'auto';
    const bodyBox = () => body.getBoundingClientRect();
    for (let at = 0; at <= body.scrollHeight; at += 11) {
      body.scrollTop = at;
      await new Promise((r) => setTimeout(r, 4));
      steps += 1;
      const bb = bodyBox();
      for (const el of body.querySelectorAll(sel)) {
        const r = el.getBoundingClientRect();
        if (!r.width || !r.height) continue;
        const cy = r.top + r.height / 2;
        // Only what is actually ON SCREEN. A row scrolled past the fold still has a layout
        // box down there; the scroller clips it, and a clipped row is not something a finger
        // can land on. Judging it would be the same mistake the reachability sweep made.
        if (cy < bb.top || cy > bb.bottom) continue;
        if (cy > bandTop && cy < bandBottom) {
          caught.push((el.textContent || el.id || el.tagName).trim().slice(0, 20));
        }
      }
      if (body.scrollTop < at - 1) break;   // reached the end
    }
    body.style.scrollBehavior = wasBehaviour;
    return { steps: steps, caught: caught.slice(0, 4), n: caught.length,
             bodyBottom: Math.round(body.getBoundingClientRect().bottom),
             bandTop: Math.round(bandTop) };
  `);
  check(swept.n === 0, 'no control ever scrolls into the band  (Settings, ' + swept.steps + ' positions)',
    swept.n ? swept.n + ' caught, e.g. ' + swept.caught.join(', ') : 'body ends at ' +
      swept.bodyBottom + ', band starts at ' + swept.bandTop);

  // And the bar still does its own job. Pressed for real, through the compositor: this is
  // the check that found the tap was dead in the first place, and a synthetic click would
  // have passed the whole time - the bar's own handler is fine, it simply never runs.
  const pill = await cdp.eval(AT('#homebar'));
  await cdp.press(pill.x, pill.y, 90);
  await sleep(700);
  const home = await cdp.eval("return openApp ? openApp.id : null;");
  check(home === null, 'a press on the pill still goes home', 'openApp is ' + String(home));
}

async function appGrid(cdp) {
  console.log('');
  console.log('the app grid');
  await cdp.eval(`
    if (editing) exitArrange();
    renderHome();
    await new Promise((r) => setTimeout(r, 800));
  `);
  const tile = await cdp.eval(AT('#pages .page .tile:not(.gap)'));
  if (!tile) { check(false, 'an app tile is drawn'); return; }

  // A long press on an icon has to enter arrange mode, and the icons must NOT resize when one
  // is dragged - the grid does not change while a tile is in the air.
  await cdp.mouse('mouseMoved', tile.x, tile.y);
  await cdp.mouse('mousePressed', tile.x, tile.y);
  await sleep(600);
  const sizeBefore = await cdp.eval(`
    const ic = document.querySelector('#pages .page .tile:not(.gap) .ic');
    return ic ? Math.round(ic.getBoundingClientRect().width) : 0;
  `);
  for (let i = 1; i <= 10; i++) {
    await cdp.send('Input.dispatchMouseEvent', {
      type: 'mouseMoved', button: 'left', buttons: 1, clickCount: 0, pointerType: 'mouse',
      x: tile.x + i * 14, y: tile.y + i * 7,
    });
    await sleep(35);
  }
  const sizeDuring = await cdp.eval(`
    const ic = document.querySelector('#pages .page .tile:not(.gap) .ic');
    return ic ? Math.round(ic.getBoundingClientRect().width) : 0;
  `);
  await cdp.mouse('mouseReleased', tile.x + 140, tile.y + 70);
  await sleep(700);

  // Two pixels of slack, not zero. `getBoundingClientRect` answers in fractions and the
  // rounding moves by one as the grid reflows around the placeholder gap - which is not a
  // resize. The bug this exists for took the icons from 60 to 30, so the threshold has plenty
  // of room to be generous and still catch it.
  check(sizeBefore > 0 && Math.abs(sizeDuring - sizeBefore) <= 2,
    'the icons keep their size while a tile is dragged',
    sizeBefore + ' -> ' + sizeDuring);
  await cdp.eval('try { exitArrange(); } catch (e) {}');
}

(async () => {
  if (!fs.existsSync(PREVIEW)) {
    console.error('no preview - run: python tools/make-preview.py --lang fr');
    process.exit(1);
  }
  const proc = spawn(chromePath(), [
    '--headless=new', `--remote-debugging-port=${PORT}`, '--window-size=900,900',
    '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--user-data-dir=' + path.join(os.tmpdir(), 'vphone-input-probe'),
    'file:///' + PREVIEW.split(path.sep).join('/'),
  ], { stdio: 'ignore' });

  let list = null;
  for (let i = 0; i < 60 && !list; i++) {
    await sleep(400);
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      list = await r.json();
    } catch (e) { /* the browser is still starting */ }
  }
  const target = (list || []).find((t) => t.type === 'page');
  if (!target) { proc.kill(); console.error('chrome never came up'); process.exit(1); }

  const cdp = new CDP(target.webSocketDebuggerUrl);
  await cdp.ready;
  await cdp.send('Runtime.enable');
  await cdp.send('Page.enable');
  await sleep(1200);

  try {
    await widgetStrip(cdp);
    await appGrid(cdp);
    await homeBand(cdp);
    await copyLink(cdp);
    await emojiPicker(cdp);
  } catch (e) {
    check(false, 'the probe ran to the end', e.message);
  }

  proc.kill();
  console.log('');
  if (failures.length) {
    console.error(`${failures.length} check(s) failed:`);
    failures.forEach((f) => console.error('  ' + f));
    process.exit(1);
  }
  console.log('every control answered real input');
  process.exit(0);
})().catch((e) => { console.error('probe failed:', e.message); process.exit(1); });
