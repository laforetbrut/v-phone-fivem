// v-phone — iFruit, Clear Glass 27 shell
//
// Every built-in app below is a VIEW. It renders what the owning module answered and
// sends actions back to that module; it never keeps a copy. The moment an app caches a
// balance or a vehicle list there are two sources of truth, and one of them is wrong.
//
// The same UI kit that draws the built-in apps is handed to third-party apps through
// sdk.js, so an app somebody else ships looks native without copying a stylesheet.

const byId = (id) => document.getElementById(id);
// The escaper, the icon set and the component kit all live in sdk.js, so the built-in
// apps and any app a third party ships are drawing themselves with the same code. Two
// copies of a design system drift the first time either side is touched.
const esc = PhoneUI.esc;
const svg = PhoneUI.svg;
const UI = PhoneUI;

// Every call into Lua goes through here. Network failures become renderable errors;
// read requests from an abandoned view are suspended so they cannot repaint its successor.
let viewController = typeof AbortController === 'function' ? new AbortController() : null;
let viewEpoch = 0;

function beginView() {
  viewEpoch += 1;
  if (!viewController) return;
  viewController.abort();
  viewController = new AbortController();
}

const RESOURCE_NAME = typeof GetParentResourceName === 'function'
  ? GetParentResourceName()
  : 'v-phone';

function isViewRead(name, payload) {
  const op = payload && payload.op;
  if (['ambient', 'calls', 'conversation', 'app', 'card', 'places', 'airdropScan', 'hospitals'].includes(name)) return true;
  if (name === 'health') return op == null || op === 'get';
  if (name === 'notes') return op === 'list';
  if (name === 'mail') return op === 'me' || op === 'list' || op === 'saved';
  if (name === 'photos' || name === 'voicemail') return op === 'list';
  if (name === 'appStorage') return op === 'get';
  if (name === 'mdt') return op === 'lookup' || op === 'warrants';
  if (name === 'social') return ['me', 'feed', 'hushMe', 'hushNext'].includes(op);
  if (name === 'cipher') return ['me', 'list', 'lookup', 'thread'].includes(op);
  return false;
}

// How long each request may take before the page stops waiting on it. Milliseconds.
const POST_TIMEOUT = {
  _default: 20000,
  // The server records for as long as it was asked to, then uploads what it recorded.
  record: 120000,
  // Capture, upload to the host, store. The server's own guard is under ten seconds.
  photo: 45000,
  camShoot: 45000,
  // The deck is asked, and a broadcast to every nearby client is waited on.
  music: 30000,
};

const post = (n, b) => {
  // The local visual harness can provide deterministic NUI replies. This hook never
  // exists in FiveM, so production traffic still follows the exact same secure path.
  if (typeof window.__VPHONE_PREVIEW_POST__ === 'function') {
    return Promise.resolve().then(() => window.__VPHONE_PREVIEW_POST__(n, b || {}))
      .catch(() => ({ error: 'x' }));
  }
  const options = {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(b || {}),
  };
  // Only read requests owned by a renderer are cancellable. Mutations, controls and
  // refreshes must finish even when the player navigates while their response is in flight.
  if (viewController && isViewRead(n, b)) options.signal = viewController.signal;
  const request = fetch(`https://${RESOURCE_NAME}/${n}`, options)
    .then((r) => r.json())
    .catch((error) => {
      if (error && error.name === 'AbortError') {
        // Keep the abandoned async renderer suspended so it cannot paint an error state
        // over the view that replaced it.
        return new Promise(() => {});
      }
      return { error: 'x' };
    });

  // **Nothing waits for ever.**
  //
  // A NUI callback that raises before it answers leaves this `fetch` unsettled - and an
  // `await` that never returns is the loading screen with no end that players report. The
  // client wraps every callback so a raise still answers (bridge/client/safety.lua), and this
  // is the other half: even a callback that vanishes for some reason nobody has thought of
  // ends as an error the caller already knows how to draw, rather than as a spinner.
  //
  // The ceiling is generous because some of these are genuinely slow - a photo upload waits on
  // a CDN, a recording waits for its own duration - and a timeout that fired during normal
  // work would be a worse bug than the one it prevents.
  const ceiling = POST_TIMEOUT[n] || POST_TIMEOUT._default;
  return Promise.race([
    request,
    new Promise((resolve) => setTimeout(() => resolve({ error: 'timeout' }), ceiling)),
  ]);
};

// Tile backgrounds come from the icon table in sdk.js (UI.appIcon).

// ══ State ══════════════════════════════════════════════════════
let S = {};             // strings
let state = {};         // number, apps, prefs, contacts, conversations
let call = null;
let callStart = 0, callTimer = null;
let openApp = null;
let thread = null;
let threadGroup = null;
let dialed = '';
let page = 0;
let notifs = [];        // the notification centre, newest first
let notifSeq = 0;       // stable ids so a card can be dismissed by hand
let notificationOwner = null;
let shadeManage = false;

// An app id from whatever the banner carried. Most callers name the app; the SDK path
// only knows an icon, so it falls back to that.
function notifApp(b) { return b.app || b.icon || 'dot'; }

// A player can silence an app from the shade. A muted app still runs; it just does not
// light the island or land in the centre. The list lives in prefs, so it survives.
function appMuted(id) { return ((state.prefs || {}).notifMuted || []).indexOf(id) !== -1; }
async function setAppMuted(id, on) {
  const cur = ((state.prefs || {}).notifMuted || []).filter((x) => x !== id);
  if (on) cur.push(id);
  const r = await post('prefs', { notifMuted: cur });
  if (r && r.ok) state.prefs = r.prefs;
}
let recents = [];       // app ids, most recently opened first
let available = [];     // what the operator permits; the store lists these
let editing = false;    // home screen in arrange mode
let navBackAction = null;
let activeAppEpoch = 0;
let appFrameTimer = null;
let cipherProfile = null;
let cipherPrivateKey = null;
let cipherThread = null;
let cipherDemo = false;
let cipherBurn = 0;

// ══ Strings ════════════════════════════════════════════════════
// `S` is filled by the client with the string table for the player's language. A key that is
// missing from it used to be rendered AS THE KEY, which is how a screen ends up reading
// `PH.BOOTH_TITLE` - and that is worse than useless, because it looks like a broken script
// rather than like a missing translation.
//
// So a missing key is humanised instead: the last segment, separators to spaces, capitalised.
// `ph.booth_title` reads `Booth Title`. Wrong language, obviously, but readable, and a player
// can still work out what a button does. The failure degrades instead of shouting.
function humaniseKey(key) {
  const tail = String(key || '').split('.').pop();
  if (!tail) return '';
  return tail.replace(/[_-]+/g, ' ')
    .replace(/(^|\s)(\S)/g, (_, lead, first) => lead + first.toUpperCase());
}

// Said once per session, not per key: forty missing strings would otherwise be forty lines and
// the useful information - that the table never arrived at all - would be buried in them.
let warnedNoStrings = false;

const L = (k) => {
  const hit = S[k];
  if (hit) return hit;
  if (!warnedNoStrings && !Object.keys(S || {}).length) {
    warnedNoStrings = true;
    console.error('[v-phone] the string table is empty, so every label is a guess at its key. '
      + 'The page asked the client for it on load; if this persists the client answered with '
      + 'nothing - check that locales/*.lua are in fxmanifest.lua shared_scripts.');
    // Ask again. The most likely reason for an empty table is that this page loaded before the
    // client was ready to answer, and one more attempt costs nothing.
    requestStrings();
  }
  return humaniseKey(k);
};
/// Is there really a string for this key?
///
/// `L()` cannot answer it: a miss comes back humanised, so `L(k) !== k` is true for every
/// missing key. Anything choosing between a translation and a fallback of its own has to ask
/// this instead - see the licence rows in the Wallet, where that mistake hid every operator's
/// configured licence names behind a tidied identifier.
const hasString = (k) => !!(k && S && S[k]);
const money = (n) => {
  const v = Number(n || 0);
  // "-$1,015", not "$-1,015". The sign goes before the symbol in every locale that puts the
  // symbol first, and the bank statement is where this is read all day.
  return (v < 0 ? '-$' : '$') + Math.abs(v).toLocaleString('en-US');
};

// ══ Clock ══════════════════════════════════════════════════════
// Real time, in the zone the server names.
//
// It used to read the player's own machine, which shows somebody connecting from another
// country their time rather than the city's - two players standing next to each other saw
// different clocks. `Config.Clock.timezone` names one zone for everybody; empty keeps the old
// behaviour. An unknown zone name makes `Intl` throw, so it is tried once and remembered.
let clockZoneChecked = '';
let clockZoneOk = false;

function clockZone() {
  const zone = String(state.clockZone || '').trim();
  if (!zone) return '';
  if (zone !== clockZoneChecked) {
    clockZoneChecked = zone;
    try {
      new Intl.DateTimeFormat('en-GB', { timeZone: zone }).format(new Date());
      clockZoneOk = true;
    } catch {
      // A typo in the config must not stop the clock. It falls back to the machine.
      clockZoneOk = false;
    }
  }
  return clockZoneOk ? zone : '';
}

// HH:MM on this phone's clock. Every surface that shows a time of day uses this one, so the
// status bar, the lock screen, the control centre and the weather widget cannot disagree.
function phoneClock(at) {
  const zone = clockZone();
  // `en-GB` for the time, so it is 24-hour whatever the player's own locale prefers - the
  // status bar of this phone has always shown 24-hour.
  return new Intl.DateTimeFormat('en-GB', Object.assign(
    { hour: '2-digit', minute: '2-digit', hour12: false },
    zone ? { timeZone: zone } : {})).format(at || new Date());
}

function tick() {
  const d = new Date();
  const zone = clockZone();
  const opts = zone ? { timeZone: zone } : {};
  const hhmm = phoneClock(d);
  byId('clock').textContent = hhmm;
  byId('lockclock').textContent = hhmm;
  const ccClock = byId('ccclock');
  if (ccClock) ccClock.textContent = hhmm;
  byId('lockdate').textContent = d.toLocaleDateString(undefined,
    Object.assign({ weekday: 'long', day: 'numeric', month: 'long' }, opts));
}
setInterval(tick, 10000);

// ══ Screens ════════════════════════════════════════════════════
// The island is the phone's face. It should react to the phone being locked and unlocked
// the way a real one does: a short pinch around a padlock, then back to a pill.
let glanceTimer = null, shutterTimer = null;
const ISLAND_MODES = ['live', 'notif', 'glance'];

// Dynamic Island modes are mutually exclusive. Calls always win: a notification or
// lock glance may be queued elsewhere, but it never paints over an active call.
function setIslandMode(mode) {
  const isl = byId('island');
  const next = call ? 'live' : (ISLAND_MODES.includes(mode) ? mode : null);
  ISLAND_MODES.forEach((name) => isl.classList.toggle(name, name === next));
  delete isl.dataset.notif;
}

function islandGlance(icon, tint) {
  if (call) return;                       // a live call owns the island outright
  const isl = byId('island');
  byId('inicon').innerHTML = '<span class="iglyph" style="color:' + (tint || '#fff') + '">' + svg(icon) + '</span>';
  byId('inTitle').textContent = '';
  byId('inBody').textContent = '';
  setIslandMode('glance');
  clearTimeout(glanceTimer);
  glanceTimer = setTimeout(() => {
    if (!call && isl.classList.contains('glance')) setIslandMode(null);
  }, 1500);
}

let pendingUnlockAction = null;
let authCode = '';
let authBusy = false;
let authTicket = 0;

function pinDotsHTML(id, value) {
  return '<div class="pindots" id="' + esc(id) + '" aria-label="' +
    esc(L('ph.passcode_progress').replace('{count}', String(value.length))) + '">' +
    [...Array(6)].map((_, i) => '<i class="' + (i < value.length ? 'on' : '') + '"></i>').join('') +
    '</div>';
}

function pinPadHTML() {
  return '<div class="pinpad">' +
    ['1','2','3','4','5','6','7','8','9','','0','del'].map((digit) => {
      if (!digit) return '<span></span>';
      return '<button type="button" data-pin="' + digit + '" aria-label="' +
        esc(digit === 'del' ? L('ph.delete_digit') : digit) + '">' +
        (digit === 'del' ? svg('del') : '<strong>' + digit + '</strong>') + '</button>';
    }).join('') + '</div>';
}

function paintPinDots(id, value) {
  const dots = byId(id);
  if (!dots) return;
  [...dots.children].forEach((dot, i) => dot.classList.toggle('on', i < value.length));
  dots.setAttribute('aria-label', L('ph.passcode_progress').replace('{count}', String(value.length)));
}

function wirePinPad(host, getValue, setValue, onComplete) {
  [...host.querySelectorAll('[data-pin]')].forEach((button) =>
    button.addEventListener('click', () => {
      if (authBusy) return;
      let value = String(getValue() || '');
      if (button.dataset.pin === 'del') { value = value.slice(0, -1); ui('keyback'); }
      else if (value.length < 6) { value += button.dataset.pin; ui('key'); }
      setValue(value);
      if (value.length === 6 && onComplete) onComplete(value);
    }));
}

function hideAuth() {
  authTicket += 1;
  authBusy = false;
  authCode = '';
  pendingUnlockAction = null;
  const auth = byId('auth');
  auth.classList.remove('on');
  auth.setAttribute('aria-hidden', 'true');
  if (!byId('lock').classList.contains('out')) byId('lockquick').classList.remove('hidden');
}

function completeUnlock() {
  const after = pendingUnlockAction;
  authTicket += 1;
  authBusy = false;
  authCode = '';
  pendingUnlockAction = null;
  byId('auth').classList.remove('on', 'success');
  byId('auth').setAttribute('aria-hidden', 'true');
  byId('lock').classList.add('out');
  byId('lockquick').classList.add('hidden');
  byId('home').classList.remove('behind');
  islandGlance('lockopen', '#30D158');
  ui('unlock');
  renderHome();
  if (typeof after === 'function') setTimeout(after, 260);
}

function renderAuthCode(message) {
  authTicket += 1; // invalidate an in-flight Face ID scan when fallback is chosen
  authCode = '';
  authBusy = false;
  const host = byId('authstage');
  host.innerHTML =
    '<div class="authcode">' +
      '<button class="authcancel" id="authcancel" type="button">' + esc(L('ph.cancel')) + '</button>' +
      '<div class="authlockicon">' + svg('lockshut') + '</div>' +
      '<h2>' + esc(L('ph.enter_passcode')) + '</h2>' +
      '<p class="authmessage' + (message ? ' error' : '') + '" id="authmessage">' +
        esc(message || L('ph.passcode_unlock_hint')) + '</p>' +
      pinDotsHTML('authdots', authCode) + pinPadHTML() +
      ((state.prefs || {}).faceId
        ? '<button class="authswitch" id="authface" type="button">' +
          svg('faceid') + esc(L('ph.use_faceid')) + '</button>' : '') +
    '</div>';
  byId('authcancel').addEventListener('click', hideAuth);
  const face = byId('authface');
  if (face) face.addEventListener('click', renderAuthFace);
  wirePinPad(host, () => authCode, (value) => {
    authCode = value;
    paintPinDots('authdots', value);
    const msg = byId('authmessage');
    if (msg && msg.classList.contains('error')) {
      msg.classList.remove('error');
      msg.textContent = L('ph.passcode_unlock_hint');
    }
  }, async (value) => {
    if (authBusy) return;
    authBusy = true;
    host.classList.add('checking');
    const result = await post('unlock', { passcode: value });
    host.classList.remove('checking');
    if (result && result.ok) {
      byId('auth').classList.add('success');
      islandGlance('lockopen', '#30D158');
      setTimeout(completeUnlock, 260);
      return;
    }
    authBusy = false;
    const text = result && result.error === 'locked'
      ? L('ph.passcode_locked').replace('{seconds}', String(result.retryAfter || 30))
      : L('ph.wrong_passcode');
    host.classList.add('wrong');
    ui('error');
    setTimeout(() => host.classList.remove('wrong'), 460);
    renderAuthCode(text);
  });
}

async function renderAuthFace() {
  const ticket = ++authTicket;
  authBusy = true;
  const host = byId('authstage');
  host.innerHTML =
    '<div class="authface">' +
      '<button class="authcancel" id="authcancel" type="button">' + esc(L('ph.cancel')) + '</button>' +
      '<div class="facescan scanning">' + svg('faceid') + '<i></i></div>' +
      '<h2>' + esc(L('ph.faceid')) + '</h2>' +
      '<p id="facestatus">' + esc(L('ph.faceid_recognising')) + '</p>' +
      '<button class="authswitch" id="authpass" type="button">' +
        svg('keypad') + esc(L('ph.use_passcode')) + '</button>' +
    '</div>';
  byId('authcancel').addEventListener('click', hideAuth);
  byId('authpass').addEventListener('click', () => renderAuthCode());
  const [result] = await Promise.all([
    post('unlock', { faceId: true }),
    new Promise((resolve) => setTimeout(resolve, 1150)),
  ]);
  if (ticket !== authTicket || !byId('auth').classList.contains('on')) return;
  authBusy = false;
  if (result && result.ok) {
    const scan = host.querySelector('.facescan');
    scan.classList.remove('scanning');
    scan.classList.add('recognised');
    byId('facestatus').textContent = L('ph.faceid_recognised');
    byId('auth').classList.add('success');
    islandGlance('faceid', '#30D158');
    ui('faceid');
    setTimeout(completeUnlock, 430);
  } else {
    host.querySelector('.facescan').classList.remove('scanning');
    host.querySelector('.facescan').classList.add('failed');
    byId('facestatus').textContent = L('ph.faceid_failed');
    byId('authpass').innerHTML = svg('keypad') + esc(L('ph.use_passcode'));
  }
}

// ── Changing the passcode, and Face ID, after setup ─────────────
// Both were set once in the first-run assistant and then had no route back. The keypad here
// is the same `pinPadHTML`/`wirePinPad` the lock screen uses, so a code entered in Settings
// looks and behaves exactly like a code entered to unlock.

/// Ask for one six-digit code. `onDone(code)` returns true to close the sheet.
function passcodeAsk(title, hint, onDone) {
  let value = '';
  sheet(title,
    '<div class="authcode insheet">' +
      '<p class="authmessage" id="pcmsg">' + esc(hint) + '</p>' +
      pinDotsHTML('pcdots', '') + pinPadHTML() +
    '</div>',
    () => {
      const host = byId('sheet');
      const epoch = sheetEpoch;
      wirePinPad(host, () => value, (v) => {
        value = v;
        paintPinDots('pcdots', v);
      }, async (code) => {
        const done = await onDone(code);
        if (epoch !== sheetEpoch) return;
        if (done) { closeSheet(false, epoch); return; }
        // Wrong, or refused. Clear and let them try again rather than closing the sheet
        // out from under them with nothing said.
        value = '';
        paintPinDots('pcdots', '');
        host.classList.add('wrong');
        ui('error');
        setTimeout(() => host.classList.remove('wrong'), 460);
      });
    });
}

/// Set a code, or change one. An existing code has to be given first.
function passcodeSheet() {
  const p = state.prefs || {};
  const setNew = () => passcodeAsk(L('ph.sec_passcode_new'), L('ph.sec_passcode_new_hint'),
    (first) => new Promise((resolve) => {
      // Twice, because a mistyped code that nobody confirms locks the phone for good.
      setTimeout(() => passcodeAsk(L('ph.sec_passcode_again'), L('ph.sec_passcode_again_hint'),
        async (second) => {
          if (second !== first) { toast(L('ph.setup_passcode_mismatch')); return false; }
          const res = await post('prefs', { passcode: second, securityEnabled: true });
          if (!res || !res.ok) { toast(L('ph.err_' + ((res && res.error) || 'x'))); return false; }
          state.prefs = res.prefs;
          RENDER.settings();
          toast(L('ph.sec_passcode_done'));
          return true;
        }), 120);
      resolve(true);
    }));

  if (!p.securityEnabled) { setNew(); return; }
  passcodeAsk(L('ph.sec_passcode_change'), L('ph.sec_passcode_current'), async (current) => {
    const check = await post('unlock', { passcode: current });
    if (!check || !check.ok) { toast(L('ph.wrong_passcode')); return false; }
    setTimeout(setNew, 120);
    return true;
  });
}

/// Re-enrol Face ID: the same scan the assistant runs, from Settings.
function faceIdSheet() {
  sheet(L('ph.faceid'),
    '<div class="authface insheet">' +
      '<div class="facescan scanning" id="secface">' + svg('faceid') + '<i></i></div>' +
      '<p id="secfacestatus">' + esc(L('ph.faceid_recognising')) + '</p>' +
    '</div>',
    () => {
      const epoch = sheetEpoch;
      setTimeout(async () => {
        if (epoch !== sheetEpoch) return;
        const res = await post('prefs', { faceId: true });
        if (epoch !== sheetEpoch) return;
        const scan = byId('secface');
        if (!scan) return;
        scan.classList.remove('scanning');
        if (res && res.ok) {
          scan.classList.add('recognised');
          byId('secfacestatus').textContent = L('ph.setup_faceid_ready');
          state.prefs = res.prefs;
          ui('faceid');
          setTimeout(() => { if (closeSheet(false, epoch)) RENDER.settings(); }, 700);
        } else {
          scan.classList.add('failed');
          byId('secfacestatus').textContent = L('ph.faceid_failed');
        }
      }, 1150);
    });
}

function unlock(after) {
  if (byId('setup').classList.contains('on')) return;
  if (byId('lock').classList.contains('out')) {
    if (typeof after === 'function') after();
    return;
  }
  if (!(state.prefs || {}).securityEnabled) {
    pendingUnlockAction = after || null;
    completeUnlock();
    return;
  }
  // Already asking. A second call restarts the Face ID scan, which is what a fast series of
  // taps produced: each `unlock()` bumped `authTicket`, every scan but the last aborted at its
  // own guard, and the one that survived finished with no animation ever having been drawn -
  // the phone appeared to open by itself a second later. The action is still carried over, so
  // a tap that meant "open the camera" is not lost.
  if (byId('auth').classList.contains('on')) {
    if (typeof after === 'function') pendingUnlockAction = after;
    return;
  }
  pendingUnlockAction = after || null;
  byId('lockquick').classList.add('hidden');
  byId('auth').classList.add('on');
  byId('auth').setAttribute('aria-hidden', 'false');
  if ((state.prefs || {}).faceId) renderAuthFace();
  else renderAuthCode();
}

function lockScreen() {
  hideAuth();
  closeApp(true);
  byId('lock').classList.remove('out');
  byId('lockquick').classList.remove('hidden');
  byId('home').classList.add('behind');
  islandGlance('lockshut', '#fff');
  ui('lock');
}

function goHome() {
  if (byId('setup').classList.contains('on')) return;
  const systemPanel = activeSystemPanel();
  if (systemPanel) { hideSystemPanel(systemPanel); return; }
  if (byId('emojipanel').classList.contains('on')) { emojiClose(); return; }
  if (byId('sheet').classList.contains('on')) { closeSheet(); return; }
  if (byId('switcher').classList.contains('on')) {
    byId('switcher').classList.remove('on');
    if (byId('app').classList.contains('on')) closeApp();
    return;
  }
  if (byId('folderview').classList.contains('on')) {
    byId('folderview').classList.remove('on', 'arranging');
    return;
  }
  if (editing) { exitArrange(); return; }
  if (byId('app').classList.contains('on')) { closeApp(); return; }
  // The Home indicator returns to Home; locking belongs to the power button.
}

// ══ Home ═══════════════════════════════════════════════════════
// First-run setup -------------------------------------------------------
// A new character receives a real activation flow before the lock screen. The draft is
// local until the last confirmation; one incomplete wizard can never half-save a phone.
let setupStep = 0;
let setupDraft = null;
let setupSaving = false;
let setupLastAdvance = 0;
let setupFaceTicket = 0;

function setupDeviceName(owner) {
  const first = String(owner || '').trim().split(/\s+/)[0];
  return first
    ? L('ph.setup_device_pattern').replace('{name}', first)
    : L('ph.setup_default_device');
}

function setupProgress() {
  if (setupStep <= 0) return '';
  const max = 7;
  return '<div class="setupprogress" aria-hidden="true">' +
    [...Array(max)].map((_, i) => '<i class="' + (i < setupStep ? 'on' : '') + '"></i>').join('') +
  '</div>';
}

function setupHeader(title, subtitle) {
  return '<div class="setupnav">' +
      (setupStep > 0 ? '<button id="setupback" type="button" aria-label="' + esc(L('ph.back')) + '">' +
        svg('chevron') + '</button>' : '<span></span>') +
      setupProgress() + '<span></span>' +
    '</div>' +
    '<div class="setuptitle">' + esc(title) + '</div>' +
    '<div class="setupsubtitle">' + esc(subtitle) + '</div>';
}

function renderSetup() {
  const host = byId('setupstage');
  if (!setupDraft) return;
  byId('setup').dataset.step = String(setupStep);

  if (setupStep === 0) {
    host.innerHTML =
      '<div class="setuphello">' +
        '<div class="setuphalo"><span>' + svg('fruit') + '</span></div>' +
        '<div class="setupbonjour">' + esc(L('ph.setup_hello')) + '</div>' +
        '<div class="setupintro">' + esc(L('ph.setup_intro')) + '</div>' +
        '<button class="setupprimary" id="setupnext" type="button">' +
          esc(L('ph.setup_start')) + svg('chevron') + '</button>' +
      '</div>';
  } else if (setupStep === 1) {
    host.innerHTML = setupHeader(L('ph.setup_identity'), L('ph.setup_identity_hint')) +
      '<div class="setupform">' +
        '<label><span>' + esc(L('ph.setup_your_name')) + '</span>' +
          '<input id="setupowner" maxlength="40" autocomplete="off" value="' +
            esc(setupDraft.ownerName) + '" placeholder="' + esc(L('ph.setup_name_placeholder')) + '"></label>' +
        '<label><span>' + esc(L('ph.setup_phone_name')) + '</span>' +
          '<input id="setupname" maxlength="32" autocomplete="off" value="' +
            esc(setupDraft.deviceName) + '" placeholder="' + esc(L('ph.setup_default_device')) + '"></label>' +
        '<div class="setuperror hidden" id="setuperror">' + esc(L('ph.setup_name_required')) + '</div>' +
      '</div>' +
      '<button class="setupprimary setupbottom" id="setupnext" type="button">' +
        esc(L('ph.continue')) + '</button>';
  } else if (setupStep === 2) {
    const themes = [
      ['light', 'sun', 'ph.theme_light'],
      ['dark', 'moon', 'ph.theme_dark'],
      ['auto', 'sparkles', 'ph.theme_auto'],
    ];
    host.innerHTML = setupHeader(L('ph.setup_appearance'), L('ph.setup_appearance_hint')) +
      '<div class="setupthemes">' + themes.map(([id, icon, label]) =>
        '<button class="' + (setupDraft.darkMode === id ? 'on' : '') +
          '" data-setup-theme="' + id + '" type="button">' +
          '<span class="themedemo ' + id + '">' + svg(icon) + '</span>' +
          '<strong>' + esc(L(label)) + '</strong><i>' + svg('check') + '</i></button>').join('') +
      '</div>' +
      '<button class="setupprimary setupbottom" id="setupnext" type="button">' +
        esc(L('ph.continue')) + '</button>';
  } else if (setupStep === 3) {
    const walls = state.wallpapers || ['ifruit'];
    host.innerHTML = setupHeader(L('ph.setup_personalise'), L('ph.setup_personalise_hint')) +
      '<div class="setupwalls">' + walls.map((wall) =>
        '<button class="wall-' + esc(wall) + (setupDraft.wallpaper === wall ? ' on' : '') +
          '" data-setup-wall="' + esc(wall) + '" type="button"><i>' + svg('check') + '</i>' +
          '<span>' + esc(L('ph.wall_' + wall)) + '</span></button>').join('') + '</div>' +
      '<div class="setupglass">' +
        '<div><span>' + esc(L('ph.glass_clear')) + '</span><strong id="setupglassvalue">' +
          Math.round(setupDraft.glass) + '%</strong><span>' + esc(L('ph.glass_tinted')) + '</span></div>' +
        '<input id="setupglass" type="range" min="0" max="100" step="1" aria-label="' +
          esc(L('ph.transparency')) + '" value="' + Math.round(setupDraft.glass) + '">' +
      '</div>' +
      '<button class="setupprimary setupbottom" id="setupnext" type="button">' +
        esc(L('ph.continue')) + '</button>';
  } else if (setupStep === 4 || setupStep === 5) {
    const confirming = setupStep === 5;
    const value = confirming ? setupDraft.passcodeConfirm : setupDraft.passcode;
    host.innerHTML = setupHeader(
      L(confirming ? 'ph.setup_passcode_confirm' : 'ph.setup_passcode'),
      L(confirming ? 'ph.setup_passcode_confirm_hint' : 'ph.setup_passcode_hint')
    ) +
      '<div class="setuppasscode">' +
        '<div class="setupshield">' + svg('lockshut') + '</div>' +
        pinDotsHTML('setupdots', value) +
        '<div class="setuperror hidden" id="setuperror"></div>' +
        pinPadHTML() +
      '</div>' +
      '<button class="setupprimary setupbottom" id="setupnext" type="button" ' +
        (value.length === 6 ? '' : 'disabled') + '>' + esc(L('ph.continue')) + '</button>';
  } else if (setupStep === 6) {
    host.innerHTML = setupHeader(L('ph.setup_faceid'), L('ph.setup_faceid_hint')) +
      '<div class="setupface">' +
        '<div class="facescan' + (setupDraft.faceId ? ' recognised' : '') + '" id="setupfacescan">' +
          svg('faceid') + '<i></i></div>' +
        '<strong id="setupfacestatus">' +
          esc(L(setupDraft.faceId ? 'ph.setup_faceid_ready' : 'ph.setup_faceid_private')) + '</strong>' +
        '<button class="setupfacebutton" id="setupfacebutton" type="button">' +
          esc(L(setupDraft.faceId ? 'ph.setup_faceid_redo' : 'ph.setup_faceid_enrol')) + '</button>' +
      '</div>' +
      '<button class="setupprimary setupbottom" id="setupnext" type="button">' +
        esc(L(setupDraft.faceId ? 'ph.continue' : 'ph.setup_code_only')) + '</button>';
  } else {
    host.innerHTML =
      '<div class="setupready">' +
        '<div class="readycheck">' + svg('check') + '</div>' +
        '<div class="setuptitle">' + esc(L('ph.setup_ready')) + '</div>' +
        '<div class="setupsubtitle">' +
          esc(L('ph.setup_ready_hint').replace('{device}', setupDraft.deviceName)) + '</div>' +
        '<div class="setupsummary">' +
          '<span>' + svg('phone') + '</span><div><strong>' + esc(setupDraft.deviceName) +
          '</strong><small>' + esc(setupDraft.ownerName) + '</small></div></div>' +
        '<div class="setupsummary security">' +
          '<span>' + svg(setupDraft.faceId ? 'faceid' : 'lockshut') + '</span><div><strong>' +
          esc(L(setupDraft.faceId ? 'ph.faceid_and_passcode' : 'ph.passcode_enabled')) +
          '</strong><small>' + esc(L('ph.security_ready')) + '</small></div></div>' +
        '<button class="setupprimary" id="setupfinish" type="button">' +
          esc(L('ph.setup_finish')) + '</button>' +
      '</div>';
  }

  const back = byId('setupback');
  if (back) back.addEventListener('click', () => { setupStep -= 1; renderSetup(); });

  [...host.querySelectorAll('[data-setup-theme]')].forEach((button) =>
    button.addEventListener('click', () => {
      setupDraft.darkMode = button.dataset.setupTheme;
      state.prefs.darkMode = setupDraft.darkMode;
      if (setupDraft.darkMode !== 'auto') state.prefs.dark = setupDraft.darkMode === 'dark';
      applyTheme();
      renderSetup();
    }));

  [...host.querySelectorAll('[data-setup-wall]')].forEach((button) =>
    button.addEventListener('click', () => {
      setupDraft.wallpaper = button.dataset.setupWall;
      state.prefs.wallpaper = setupDraft.wallpaper;
      applyWallpaper();
      renderSetup();
    }));

  const glass = byId('setupglass');
  if (glass) glass.addEventListener('input', () => {
    setupDraft.glass = Number(glass.value);
    byId('setupglassvalue').textContent = glass.value + '%';
    applyGlass(setupDraft.glass);
  });

  if (setupStep === 4 || setupStep === 5) {
    const confirming = setupStep === 5;
    wirePinPad(host,
      () => confirming ? setupDraft.passcodeConfirm : setupDraft.passcode,
      (value) => {
        if (confirming) setupDraft.passcodeConfirm = value;
        else setupDraft.passcode = value;
        paintPinDots('setupdots', value);
        const button = byId('setupnext');
        if (button) button.disabled = value.length !== 6;
        const error = byId('setuperror');
        if (error) error.classList.add('hidden');
      });
  }

  const faceButton = byId('setupfacebutton');
  if (faceButton) faceButton.addEventListener('click', () => {
    const ticket = ++setupFaceTicket;
    const scan = byId('setupfacescan');
    setupDraft.faceId = false;
    scan.classList.remove('recognised', 'failed');
    scan.classList.add('scanning');
    faceButton.disabled = true;
    faceButton.textContent = L('ph.setup_faceid_scanning');
    byId('setupfacestatus').textContent = L('ph.faceid_recognising');
    setTimeout(() => {
      if (ticket !== setupFaceTicket || setupStep !== 6) return;
      setupDraft.faceId = true;
      scan.classList.remove('scanning');
      scan.classList.add('recognised');
      faceButton.disabled = false;
      faceButton.textContent = L('ph.setup_faceid_redo');
      byId('setupfacestatus').textContent = L('ph.setup_faceid_ready');
      byId('setupnext').textContent = L('ph.continue');
      islandGlance('faceid', '#30D158');
    }, 1650);
  });

  const next = byId('setupnext');
  if (next) next.addEventListener('click', () => {
    const now = Date.now();
    if (now - setupLastAdvance < 320) return;
    setupLastAdvance = now;
    if (setupStep === 1) {
      const owner = byId('setupowner').value.trim();
      const device = byId('setupname').value.trim();
      if (!owner || !device) {
        byId('setuperror').classList.remove('hidden');
        return;
      }
      setupDraft.ownerName = owner;
      setupDraft.deviceName = device;
    }
    if (setupStep === 4 && setupDraft.passcode.length !== 6) return;
    if (setupStep === 5) {
      if (setupDraft.passcodeConfirm !== setupDraft.passcode) {
        setupDraft.passcodeConfirm = '';
        paintPinDots('setupdots', '');
        next.disabled = true;
        const error = byId('setuperror');
        error.textContent = L('ph.setup_passcode_mismatch');
        error.classList.remove('hidden');
        host.querySelector('.setuppasscode').classList.add('wrong');
        setTimeout(() => host.querySelector('.setuppasscode')?.classList.remove('wrong'), 460);
        return;
      }
    }
    setupStep = Math.min(7, setupStep + 1);
    renderSetup();
  });

  const owner = byId('setupowner');
  if (owner) owner.addEventListener('input', () => {
    const name = byId('setupname');
    if (!name.dataset.edited) name.value = setupDeviceName(owner.value);
    byId('setuperror').classList.add('hidden');
  });
  const device = byId('setupname');
  if (device) device.addEventListener('input', () => {
    device.dataset.edited = '1';
    byId('setuperror').classList.add('hidden');
  });

  const finish = byId('setupfinish');
  if (finish) finish.addEventListener('click', finishSetup);
}

function openSetup(startStep) {
  const p = state.prefs || {};
  const ownerName = String(p.ownerName || state.playerName || '').trim();
  setupDraft = {
    ownerName,
    deviceName: String(p.deviceName || setupDeviceName(ownerName)).trim(),
    darkMode: p.darkMode || 'auto',
    wallpaper: p.wallpaper || (state.wallpapers || [])[0] || 'ifruit',
    glass: Number.isFinite(Number(p.glass)) ? Number(p.glass) : 28,
    passcode: '',
    passcodeConfirm: '',
    faceId: p.faceId == true,
  };
  setupStep = Math.max(0, Math.min(7, Number(startStep) || 0));
  setupSaving = false;
  setupLastAdvance = 0;
  closeApp(true);
  hideSystemPanels(true);
  closeSheet(true);
  byId('lock').classList.add('out');
  byId('lockquick').classList.add('hidden');
  byId('home').classList.add('behind');
  byId('setup').classList.add('on');
  byId('setup').setAttribute('aria-hidden', 'false');
  setIslandMode(null);
  renderSetup();
}

async function finishSetup() {
  if (setupSaving || !setupDraft) return;
  setupSaving = true;
  const button = byId('setupfinish');
  if (button) {
    button.disabled = true;
    button.textContent = L('ph.setup_saving');
  }
  const res = await post('prefs', {
    setupComplete: true,
    setupVersion: 2,
    ownerName: setupDraft.ownerName,
    deviceName: setupDraft.deviceName,
    darkMode: setupDraft.darkMode,
    wallpaper: setupDraft.wallpaper,
    glass: setupDraft.glass,
    securityEnabled: true,
    passcode: setupDraft.passcode,
    faceId: setupDraft.faceId,
  });
  setupSaving = false;
  if (!res || !res.ok) {
    if (button) {
      button.disabled = false;
      button.textContent = L('ph.setup_retry');
    }
    return;
  }

  state.prefs = res.prefs;
  applyWallpaper();
  applyTheme();
  applyGlass(state.prefs.glass);
  applyDevice();
  const setup = byId('setup');
  setup.classList.add('complete');
  setTimeout(() => {
    setup.classList.remove('on', 'complete');
    setup.setAttribute('aria-hidden', 'true');
    byId('home').classList.remove('behind');
    renderHome();
    islandGlance('check', '#30D158');
    toast(L('ph.setup_complete'));
  }, 520);
}

function unreadTotal() {
  return (state.conversations || []).reduce((n, c) => n + (c.unread || 0), 0);
}

function tileHTML(a, i) {
  const badge = a.id === 'messages' ? unreadTotal()
    : a.id === 'phone' ? Number(state.vmUnread || 0)
    : a.id === 'cipher' ? Number(state.cipherUnread || 0)
    : (a.badge || 0);
  return `<button class="tile" type="button" data-app="${esc(a.id)}" style="--i:${i}" ` +
    `aria-label="${esc(L(a.label))}">` +
    `<span class="wrap">${appTile(a)}` +
    (badge > 0 ? `<span class="badge">${badge > 99 ? '99+' : badge}</span>` : '') +
    `</span><span class="nm">${esc(L(a.label))}</span></button>`;
}

function renderHome() {
  byId('pages').classList.remove('jiggle');
  const apps = (state.apps || []).slice();
  // The last four go in the dock, the way iOS ships: the apps you reach for without
  // thinking stay put while the grid pages move.
  const dockApps = apps.filter((a) => a.dock).slice(0, 4);

  const items = layoutItems();
  paintPages(items);
  byId('dock').innerHTML = dockApps.map((a, i) => tileHTML(a, i)).join('');
  // The dock lives outside #pages, so paintPages does not reach it - it needs its own
  // click wiring or the four apps at the bottom stop opening (which they did).
  [...byId('dock').querySelectorAll('.tile')].forEach((t) => {
    t.addEventListener('click', () => {
      if (editing) return;
      const a = (state.apps || []).find((x) => x.id === t.dataset.app);
      if (a) enterApp(a, t);
    });
  });


  // Arrange mode survives a re-render: a drop stays in the jiggle until Done.
  byId('home').classList.toggle('arrange', editing);
  byId('pages').classList.toggle('jiggle', editing);

  initArrange();
  renderWidgets();
}

// Four rows is what fits beneath the widgets. Splitting 17 icons as 16 + 1 strands a
// single app on page two, which reads as "the rest did not load"; so on overflow the
// pages are BALANCED - nine and eight both look like pages, sixteen and one does not.
let arrPerPage = 16;

function fitGrid(cols, rows) {
  const pg = byId('pages');
  const page = pg.querySelector('.page');
  if (!page) return;
  const cs = getComputedStyle(page);
  const h = page.clientHeight - parseFloat(cs.paddingTop || 0) - parseFloat(cs.paddingBottom || 0);
  const w = page.clientWidth - parseFloat(cs.paddingLeft || 0) - parseFloat(cs.paddingRight || 0);
  if (h <= 0 || w <= 0) return;

  const apply = (size) => {
    pg.style.setProperty('--isz', size + 'px');
    pg.style.setProperty('--iradius', Math.round(size * 0.225) + 'px');
    pg.style.setProperty('--ilabel', (size >= 52 ? 11.5 : size >= 42 ? 10.5 : 9.5) + 'px');
    // The spacing has to give way with the icon, or a tight grid stays too tall to fit
    // however small the icons get.
    pg.style.setProperty('--tgap', (size >= 50 ? 6 : size >= 38 ? 4 : 2) + 'px');
    pg.style.setProperty('--rgap', (size >= 50 ? 8 : size >= 38 ? 5 : 3) + 'px');
  };

  // Start from an estimate, then check it against the real thing. Arithmetic about
  // padding, gaps and label height is exactly the sort of guess that ends up one row
  // short, so the estimate is only a starting point: what settles it is measuring.
  const cellH = h / rows, cellW = w / cols;
  let size = Math.max(22, Math.min(60, Math.floor(Math.min(cellH - 24, cellW - 8))));
  apply(size);

  // Whether it overflows is a question about the page, not about the last tile: in a grid
  // that exactly fills its rows the last row's bottom IS the page's bottom, and comparing
  // those two was a tie the loop could never win - it shrank the icons to the floor.
  for (let i = 0; i < 14 && size > 22; i++) {
    // A row that genuinely does not fit is tens of pixels tall. A handful of pixels is
    // chrome - a badge sitting proud of its icon - and shrinking for that collapsed the
    // icons to nothing on grids that were actually fine.
    if (page.scrollHeight <= page.clientHeight + 18) break;
    size -= 3;
    apply(size);
  }
}

// The track is what slides; the pager around it is a fixed window that clips.
function slideTrack() {
  const t = byId('pages').querySelector('.ptrack');
  if (t) t.style.transform = 'translateX(' + (-page * 100) + '%)';
}
function paintPages(items) {
  // A FIXED page size, not a balanced one. Balancing spread the icons evenly across
  // however many pages were needed, which meant installing a single app re-flowed every
  // page and threw away an arrangement the player had made. A page holds what a page
  // holds; anything past that starts a new one, and the pages before it never move.
  // How much that is, is the player's own choice of grid.
  const gp = state.prefs || {};
  const gCols = Math.max(3, Math.min(6, Number(gp.gridCols) || 4));
  const gRows = Math.max(3, Math.min(7, Number(gp.gridRows) || 4));
  byId('pages').style.setProperty('--gcols', String(gCols));
  byId('pages').style.setProperty('--grows', String(gRows));
  arrPerPage = gCols * gRows;

  // Pages end for two reasons: the page is full, or the player said so.
  //
  // A page used to end ONLY when it was full, because pages were a flat list sliced by
  // capacity. That meant a second page could not exist until the first held sixteen apps -
  // there was nothing in the model that could mean "start a new page here". A `break` item is
  // that something, and it is the player's own arrangement rather than a consequence of how
  // many apps they happen to have installed.
  const pages = [];
  let current = [];
  items.forEach((it) => {
    if (it && it.t === 'break') {
      // An empty page is a real thing to want: somewhere to drop the next app.
      pages.push(current);
      current = [];
      return;
    }
    if (current.length >= arrPerPage) { pages.push(current); current = []; }
    current.push(it);
  });
  pages.push(current);
  if (!pages.length) pages.push([]);
  page = Math.max(0, Math.min(pages.length - 1, page));

  byId('pages').innerHTML = '<div class="ptrack">' + pages.map((pg) =>
    '<div class="page">' + pg.map((it, i) => {
      if (it.t === 'gap') return '<div class="tile gap"></div>';
      return it.t === 'folder' ? folderTile(it, i)
                               : tileHTML(appById(it.id) || { id: it.id, icon: 'dot', label: it.id }, i);
    }).join('') + '</div>').join('') + '</div>';
  // data-idx is the position in `items`, counting only real tiles, so a drop can read it.
  // Breaks are not tiles and are not counted - `itemIndexOfTile` maps back the other way.
  let k = -1;
  [...byId('pages').querySelectorAll('.tile')].forEach((t) => {
    if (t.classList.contains('gap')) return;
    k += 1; t.dataset.idx = k;
  });
  slideTrack();
  byId('dots').innerHTML = pages.map((_, i) => `<i class="${i === page ? 'on' : ''}"></i>`).join('');

  // The grid only "works" if it fits. Rows share the page height, so the icon has to be
  // sized from what a cell actually gets - otherwise six rows of 60px icons simply spill
  // past the bottom of the screen and the last rows look like they were never drawn.
  fitGrid(gCols, gRows);

  [...byId('pages').querySelectorAll('.tile:not(.gap)')].forEach((t) => {
    t.addEventListener('click', () => {
      // A long press already acted on this gesture. Swallow the click it produced, or the folder
      // view opens over the sheet the press just raised.
      if (arrSwallowClick) { arrSwallowClick = false; return; }
      if (editing) return;   // a tap in arrange mode never launches
      const gi = itemsIndexOfTileEl(t);
      if (t.classList.contains('isfolder')) { if (gi >= 0) openFolder(gi); return; }
      const a = (state.apps || []).find((x) => x.id === t.dataset.app);
      if (a) enterApp(a, t);
    });
  });
}

// ══ Home layout ════════════════════════════════════════════════
// The player's arrangement is a list of ITEMS, each an app or a folder. Anything
// installed but not in the list is appended, so an app added next month appears at the
// end rather than vanishing because it was not in a saved layout.
function layoutItems() {
  const apps = (state.apps || []).filter((a) => !a.dock);
  const byId2 = {};
  apps.forEach((a) => { byId2[a.id] = a; });

  const saved = ((state.prefs || {}).layout || {}).items;
  const items = [];
  const seen = new Set();

  (Array.isArray(saved) ? saved : []).forEach((it) => {
    if (!it) return;
    if (it.t === 'break') {
      // Kept, but never at the very start and never twice in a row: either would make a page
      // that holds nothing and can never be reached past, and the player would have no way to
      // get rid of it. A break at the END is allowed - that IS the empty new page.
      const last = items[items.length - 1];
      if (items.length && !(last && last.t === 'break')) items.push({ t: 'break' });
      return;
    }
    if (it.t === 'folder') {
      const inside = (it.apps || []).filter((id) => byId2[id] && !seen.has(id));
      inside.forEach((id) => seen.add(id));
      // A folder that lost every app it held is not a folder any more.
      if (inside.length) items.push({ t: 'folder', name: it.name || L('ph.folder'), apps: inside });
    } else if (byId2[it.id] && !seen.has(it.id)) {
      seen.add(it.id);
      items.push({ t: 'app', id: it.id });
    }
  });

  apps.forEach((a) => { if (!seen.has(a.id)) items.push({ t: 'app', id: a.id }); });
  return items;
}

function saveLayout(items) {
  state.prefs = state.prefs || {};
  state.prefs.layout = { items };
  return post('prefs', { layout: state.prefs.layout });
}

function appById(id) { return (state.apps || []).find((a) => a.id === id); }

function folderTile(it, i) {
  const four = it.apps.slice(0, 4).map((id) => {
    const a = appById(id);
    return '<span>' + (a ? appTile(a) : '') + '</span>';
  }).join('');
  return '<button class="tile isfolder" type="button" data-folder="1" style="--i:' + i + '">' +
    '<span class="wrap"><span class="folder glass">' + four + '</span></span>' +
    '<span class="nm">' + esc(it.name) + '</span></button>';
}

// A folder, and - in arrange mode - the way back OUT of one.
//
// An app put into a folder had no route out: this view wired a tap to OPEN the app and nothing
// else, so a folder was a one-way door. Arrange mode now puts a corner badge on each tile
// inside, and tapping it lifts that app back onto the home screen. Deliberately the same idiom
// as removing an app from the home screen, rather than a drag: dragging out of a modal sheet
// onto a grid behind it is a lot of machinery, and this is the thing that was actually missing.
function openFolder(i) {
  const it = layoutItems()[i];
  if (!it || it.t !== 'folder') return;

  // Every element read here is checked for, and the folder still opens without any one of
  // them. Not defensiveness for its own sake: a player whose page is a build behind - the
  // markup is served from disk and a client that loaded it earlier keeps what it loaded -
  // hit `byId('foldername').textContent` on a null and the exception took the whole handler
  // with it, so no folder on that phone would open at all. One missing label is a cosmetic
  // problem; a folder that cannot be opened is the report that arrives.
  const host = byId('folderview');
  if (!host) { toast(L('ph.folder_gone')); return; }
  const nameEl = byId('foldername');
  if (nameEl) nameEl.textContent = it.name;
  const appsEl = byId('folderapps');
  if (!appsEl) { toast(L('ph.folder_gone')); return; }
  appsEl.innerHTML = it.apps.map((id, k) => {
    const a = appById(id);
    if (!a) return '';
    return editing
      ? tileHTML(a, k).replace('<span class="wrap">',
          '<span class="unfolder" data-out="' + esc(a.id) + '">' + svg('xmark')
          + '</span><span class="wrap">')
      : tileHTML(a, k);
  }).join('');
  host.classList.toggle('arranging', editing);
  host.classList.add('on');
  ui('folder');

  // The way out, as a button rather than a gesture.
  //
  // `onclick` rather than `addEventListener`: openFolder runs every time a folder is opened and
  // listeners would stack, so the same folder would raise the sheet several times over.
  const leave = () => host.classList.remove('on', 'arranging');
  const manage = byId('foldermanage');
  if (manage) {
    manage.textContent = L('ph.folder_manage');
    manage.onclick = () => { leave(); folderManageSheet(i); };
  }

  const rename = byId('folderrename');
  if (rename) {
    rename.textContent = L('ph.folder_rename');
    rename.onclick = () => { leave(); folderRenameSheet(i); };
  }

  // And the title itself, which is where a phone puts this. The button above is what makes it
  // reachable; this is the gesture people will try first.
  const title = byId('foldername');
  if (title) title.onclick = () => { leave(); folderRenameSheet(i); };

  // Out of the folder, onto the home screen, in the position the folder occupies.
  const takeOut = (id) => {
    const items = layoutItems();
    const folder = items[i];
    if (!folder || folder.t !== 'folder') return;
    folder.apps = folder.apps.filter((x) => x !== id);
    // A folder holding one app is a folder for no reason: it becomes that app again. Emptying
    // it entirely is already handled by `layoutItems`, which drops a folder with nothing in it.
    if (folder.apps.length === 1) {
      items[i] = { t: 'app', id: folder.apps[0] };
    } else if (!folder.apps.length) {
      items.splice(i, 1);
    }
    items.splice(i + 1, 0, { t: 'app', id });
    saveLayout(items).then(() => {
      renderHome();
      // Re-open only while there is still a folder here to look at.
      const now = layoutItems()[i];
      if (editing && now && now.t === 'folder') openFolder(i);
      else host.classList.remove('on');
    });
    ui('toggleoff');
  };

  [...appsEl.querySelectorAll('.unfolder')].forEach((x) =>
    x.addEventListener('click', (e) => {
      // The badge sits on the tile, so its click must not also open the app.
      e.stopPropagation();
      takeOut(x.dataset.out);
    }));

  [...appsEl.querySelectorAll('.tile')].forEach((t) =>
    t.addEventListener('click', () => {
      // In arrange mode a tap is not "open": the whole screen is being rearranged.
      if (editing) return;
      host.classList.remove('on');
      const a = appById(t.dataset.app);
      if (a) enterApp(a, t);
    }));
}

// Taking an app out of a folder, by pressing and holding the folder itself.
//
// There is already a badge inside the folder view while arrange mode is on, and it draws
// correctly - but reaching it means opening a folder DURING a drag, and that path has now failed
// three times in players' hands for reasons that do not reproduce off the game. So this is a
// second route that cannot depend on any of it: a long press on the folder, no arrange mode, no
// drag, a plain list with a button per app.
//
// Two ways to do one thing is usually a smell. Here it is the honest answer: the gesture-based
// one is nicer when it works, and a player whose apps are stuck in a folder needs a way out that
// is not conditional on a gesture behaving.
// Renaming a folder.
//
// A folder is created with the default name and there was no way to change it, so a player with
// three folders had three called "Folder". The name lives on the layout item, so this is one
// field and a save - and clearing the field is a reset, because `layoutItems` falls back to the
// default name for a folder that has none.
function folderRenameSheet(i) {
  const it = (i >= 0) ? layoutItems()[i] : null;
  if (!it || it.t !== 'folder') { toast(L('ph.folder_gone')); return; }

  sheet(L('ph.folder_rename'),
    UI.field('frname', L('ph.folder_name'), it.name || '', 'maxlength="24"') +
    UI.button(L('ph.save'), 'frgo') +
    '<div class="groupfoot">' + esc(L('ph.folder_rename_hint')) + '</div>',
    () => {
      const epoch = sheetEpoch;
      const go = async () => {
        const name = byId('frname').value.trim();
        const items = layoutItems();
        const folder = items[i];
        // The layout can have changed under an open sheet - the folder may have been emptied by
        // its last app being taken out - so this is checked again rather than assumed.
        if (!folder || folder.t !== 'folder') {
          if (closeSheet(false, epoch)) toast(L('ph.folder_gone'));
          return;
        }
        folder.name = name;
        await saveLayout(items);
        renderHome();
        if (!closeSheet(false, epoch)) return;
        ui('success');
        toast(L('ph.folder_renamed'));
      };
      byId('frgo').addEventListener('click', go);
      // Enter saves. A one-field sheet where the keyboard cannot finish the job is a sheet that
      // makes the player hunt for a button they are already done with.
      byId('frname').addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
      byId('frname').focus();
    });
}

function folderManageSheet(i) {
  const it = (i >= 0) ? layoutItems()[i] : null;
  // Says so rather than doing nothing. Four reports of "nothing happens" is the argument for
  // never letting a path end in a silent return where a player is watching.
  if (!it || it.t !== 'folder') { toast(L('ph.folder_gone')); return; }

  sheet(it.name || L('ph.folder'),
    UI.group([UI.row({
      icon: 'note',
      title: L('ph.folder_rename'),
      subtitle: it.name || L('ph.folder'),
      chevron: true,
      data: { rename: '1' },
    })]) +
    UI.group(it.apps.map((id) => {
      const a = appById(id);
      return UI.row({
        icon: a ? a.icon : 'dot',
        title: a ? L(a.label) : id,
        value: L('ph.folder_take_out'),
        tone: 'neg',
        data: { out: id },
      });
    })) +
    '<div class="groupfoot">' + esc(L('ph.folder_manage_hint')) + '</div>',
    () => {
      const epoch = sheetEpoch;
      const ren = byId('sheet').querySelector('[data-rename]');
      if (ren) ren.addEventListener('click', () => {
        if (closeSheet(false, epoch)) folderRenameSheet(i);
      });
      [...byId('sheet').querySelectorAll('[data-out]')].forEach((el) =>
        el.addEventListener('click', async () => {
          const id = el.dataset.out;
          const items = layoutItems();
          const folder = items[i];
          if (!folder || folder.t !== 'folder') return;

          folder.apps = folder.apps.filter((x) => x !== id);
          // A folder holding one app is a folder for no reason: it becomes that app again.
          if (folder.apps.length === 1) items[i] = { t: 'app', id: folder.apps[0] };
          else if (!folder.apps.length) items.splice(i, 1);
          items.splice(i + 1, 0, { t: 'app', id });

          await saveLayout(items);
          renderHome();
          ui('folder');
          if (!closeSheet(false, epoch)) return;
          // Still a folder with something in it? Stay on it, so several apps can be taken out
          // in a row without hunting for the folder again.
          const now = layoutItems()[i];
          if (now && now.t === 'folder') folderManageSheet(i);
        }));
    });
}

byId('folderview').addEventListener('click', (e) => {
  if (e.target.id === 'folderview') byId('folderview').classList.remove('on');
});

// ══ Arrange mode ═══════════════════════════════════════════════
// A real drag: the tile lifts into a clone that follows the finger, the grid opens a gap
// where it will land, and it stays in arrange mode until Done - a drop no longer kicks
// you out. Hold a tile to enter; drag onto another app to make a folder.
let arr = null;          // the live drag session, or null
let arrWired = false;

function enterArrange() {
  editing = true;
  byId('arrangedone').textContent = L('ph.arrange_done');
  byId('home').classList.add('arrange');
  byId('pages').classList.add('jiggle');
}
function exitArrange() {
  editing = false;
  endDrag(true);
  byId('home').classList.remove('arrange');
  byId('pages').classList.remove('jiggle');
}

function ptOf(e) {
  const r = byId('screen').getBoundingClientRect();
  return { x: e.clientX - r.left, y: e.clientY - r.top };
}
function moveGhost(e) {
  const p = ptOf(e), g = byId('dragghost');
  g.style.left = p.x + 'px'; g.style.top = p.y + 'px';
}

// Where the drag started, so a tap can be told from a drag. A tap on a FOLDER in arrange mode
// has to open it: that is the only way to reach the badges that take an app back out, and
// without this the 1.2.9 "remove from folder" work was unreachable code - `paintPages` returns
// early on any tap while editing, so a folder could not be opened at all in the one mode where
// its contents can be changed.
let arrDownAt = null;

// Set when a long press has already acted, so the `click` that follows the same pointerup does
// not act again. Without it, a press that opens a sheet is immediately covered by the tap
// behaviour of the very tile that was pressed.
let arrSwallowClick = false;

// The position in `items` of a rendered tile ELEMENT.
//
// `data-idx` counts real tiles; `layoutItems()` also holds page breaks. Anything that takes a
// `data-idx` and indexes the item list with it is wrong the moment one break exists - and this
// has now been got wrong in three separate places, so it is one function.
function itemsIndexOfTileEl(tile) {
  const list = layoutItems();
  const want = Number(tile && tile.dataset && tile.dataset.idx);
  if (!Number.isFinite(want)) return -1;
  let tiles = 0;
  for (let i = 0; i < list.length; i += 1) {
    if (list[i] && list[i].t === 'break') continue;
    if (tiles === want) return i;
    tiles += 1;
  }
  return -1;
}

function beginDrag(tile, e) {
  arrDownAt = { x: e.clientX, y: e.clientY };
  const items = layoutItems();
  // `data-idx` counts real TILES; `items` also holds page breaks. Reading `items[idx]` was
  // correct until breaks existed and picks the wrong entry the moment one does - which would
  // lift the item next to the one under the finger.
  const idx = Number(tile.dataset.idx);
  if (Number.isNaN(idx)) return;
  let real = -1, at = -1;
  for (let i = 0; i < items.length; i += 1) {
    if (items[i] && items[i].t === 'break') continue;
    real += 1;
    if (real === idx) { at = i; break; }
  }
  if (at < 0) return;
  const item = items[at];
  arr = { item, items: items.filter((_, i) => i !== at), insert: at,
          hoverEl: null, since: 0, folderIdx: null, folderTimer: null, edgeTimer: null };

  const g = byId('dragghost');
  const ic = tile.querySelector('.ic, .folder');
  const nm = tile.querySelector('.nm');
  g.innerHTML = (ic ? ic.outerHTML : '') + (nm ? nm.outerHTML : '');
  g.classList.add('on');
  moveGhost(e);
  paintArrange();
}

// The position in `arr.items` of a painted tile.
//
// `data-idx` is a count of real tiles, which is what a drop reads. `arr.items` also holds
// `break` entries, so the same tile has two different indices depending on which list you mean -
// and mixing them up moves an app to the wrong place rather than failing visibly.
function itemsIndexOfTile(tile) {
  const list = (arr && arr.items) || layoutItems();
  if (!tile) {
    // No tiles on this page at all: it is an empty page, so the insertion point is just past
    // the break that made it.
    let seen = 0;
    for (let i = 0; i < list.length; i += 1) {
      if (list[i] && list[i].t === 'break') seen += 1;
      if (seen > page - 1 && page > 0) return i + 1;
    }
    return list.length;
  }
  const want = Number(tile.dataset.idx);
  if (!Number.isFinite(want)) return 0;
  let tiles = 0;
  for (let i = 0; i < list.length; i += 1) {
    if (list[i] && list[i].t === 'break') continue;
    if (tiles === want) return i;
    tiles += 1;
  }
  return list.length;
}

function paintArrange() {
  const withGap = arr.items.slice();
  withGap.splice(Math.max(0, Math.min(withGap.length, arr.insert)), 0, { t: 'gap' });
  paintPages(withGap);
  byId('pages').classList.add('jiggle');
}

function clearFolder() {
  if (arr.folderTimer) { clearTimeout(arr.folderTimer); arr.folderTimer = null; }
  arr.folderIdx = null;
  [...byId('pages').querySelectorAll('.tile.folderready')].forEach((t) => t.classList.remove('folderready'));
}

function onDragMove(e) {
  if (!arr) return;
  moveGhost(e);

  const pages = byId('pages').querySelectorAll('.page');
  const cur = pages[page];
  if (!cur) return;

  // Edge of the screen, held: flip to the next page, so a drag can cross pages.
  //
  // On the LAST page, the right edge makes a NEW one. A second page used to require sixteen
  // apps on the first, because pages were a flat list sliced by capacity and nothing could mean
  // "start a page here" - so a player who wanted two tidy pages of six had no way to ask.
  const p = ptOf(e), w = byId('screen').clientWidth;
  const atLast = page >= pages.length - 1;
  const edge = (p.x < 24 && page > 0) ? -1
    : (p.x > w - 24) ? 1
    : 0;
  if (edge && !arr.edgeTimer) {
    arr.edgeTimer = setTimeout(() => {
      arr.edgeTimer = null;
      if (edge === 1 && atLast) newPageDuringDrag();
      else flipPage(edge);
    }, 420);
  } else if (!edge && arr.edgeTimer) { clearTimeout(arr.edgeTimer); arr.edgeTimer = null; }

  // **Not `page * arrPerPage` any more.**
  //
  // That arithmetic assumed pages were a flat list sliced by capacity, so the first item on page
  // n was always at n * perPage. A `break` breaks that: a page can hold six apps and end, and
  // then every index past it is wrong - which would land a dropped app several positions away
  // from where the finger let go.
  //
  // So the mapping is walked instead of computed. `data-idx` counts real TILES; `arr.items`
  // holds tiles and breaks, and the two spaces differ by however many breaks came first.
  const base = itemsIndexOfTile(cur.querySelector('.tile'));

  // Nearest real tile, worked out first: if the finger is deep inside one, that is a
  // folder gesture and the grid must HOLD STILL - the reorder gap only opens in the seams
  // between tiles. Chasing the finger into the centre of a tile is exactly what made the
  // old version feel broken, because the target kept fleeing the drop.
  let near = null, best = 1e9;
  const tiles = [...cur.querySelectorAll('.tile:not(.gap)')];
  tiles.forEach((t) => {
    const r = t.getBoundingClientRect();
    const d = Math.hypot(e.clientX - (r.left + r.width / 2), e.clientY - (r.top + r.height / 2));
    if (d < best) { best = d; near = t; }
  });
  const deep = near && best < near.getBoundingClientRect().width * 0.34;

  if (deep && arr.item.t === 'app') {
    // Fold zone: leave the layout alone, arm the folder after a short dwell.
    if (near !== arr.hoverEl) {
      clearFolder();
      arr.hoverEl = near;
      const oi = Number(near.dataset.idx);
      arr.folderTimer = setTimeout(() => { arr.folderIdx = oi; near.classList.add('folderready'); }, 300);
    }
    return;
  }

  // Seam: a plain reorder. Drop before the first tile the pointer is above-or-left of.
  if (arr.hoverEl) { arr.hoverEl = null; clearFolder(); }
  // Past the last tile on this page by default, then walked back to the first seam the pointer
  // is above-or-left of. Each candidate asks the tile for ITS own items index rather than
  // counting from `base`, so a break earlier in the list cannot shift the answer.
  let ins = tiles.length
    ? itemsIndexOfTile(tiles[tiles.length - 1]) + 1
    : base;
  for (let i = 0; i < tiles.length; i++) {
    const r = tiles[i].getBoundingClientRect();
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    if (e.clientY < cy - 6 || (Math.abs(e.clientY - cy) <= r.height / 2 && e.clientX < cx)) {
      ins = itemsIndexOfTile(tiles[i]);
      break;
    }
  }
  if (ins !== arr.insert) { arr.insert = ins; paintArrange(); }
}

function onDragEnd(e) {
  if (!arr) return;
  const a = arr;
  if (a.edgeTimer) clearTimeout(a.edgeTimer);
  if (a.folderTimer) clearTimeout(a.folderTimer);
  byId('dragghost').classList.remove('on');

  // A tap, not a drag, and on a folder: open it rather than dropping it back where it was.
  // The layout is put back untouched, because nothing was actually moved.
  const moved = (e && arrDownAt)
    ? Math.hypot(e.clientX - arrDownAt.x, e.clientY - arrDownAt.y) : 99;
  arrDownAt = null;
  if (moved < 8 && a.item && a.item.t === 'folder') {
    arr = null;
    const items = layoutItems();
    paintPages(items);
    byId('pages').classList.toggle('jiggle', editing);
    // Its index in the restored layout, which is where it was before the drag lifted it out.
    const at = items.findIndex((it) => it && it.t === 'folder' && it.name === a.item.name
      && (it.apps || []).join(',') === (a.item.apps || []).join(','));
    if (at >= 0) openFolder(at);
    return;
  }

  if (a.folderIdx != null && a.item.t === 'app') {
    const tgt = a.items[a.folderIdx];
    if (tgt && tgt.t === 'folder') tgt.apps.push(a.item.id);
    else if (tgt && tgt.t === 'app') a.items[a.folderIdx] = { t: 'folder', name: L('ph.folder'), apps: [tgt.id, a.item.id] };
    else a.items.splice(a.insert, 0, a.item);
  } else {
    a.items.splice(Math.max(0, Math.min(a.items.length, a.insert)), 0, a.item);
  }
  arr = null;
  saveLayout(a.items).then(() => renderHome());
}

function endDrag(cancel) {
  if (!arr) return;
  if (arr.edgeTimer) clearTimeout(arr.edgeTimer);
  if (arr.folderTimer) clearTimeout(arr.folderTimer);
  byId('dragghost').classList.remove('on');
  const items = cancel ? layoutItems() : arr.items;
  arr = null;
  paintPages(items);
  byId('pages').classList.toggle('jiggle', editing);
}

// Attached once to the stable #pages container, so it survives every re-render.
function initArrange() {
  if (arrWired) return;
  arrWired = true;
  const pagesEl = byId('pages');
  let hold = null, downTile = null, downXY = null;

  pagesEl.addEventListener('pointerdown', (e) => {
    const tile = e.target.closest ? e.target.closest('.tile:not(.gap)') : null;
    downXY = { x: e.clientX, y: e.clientY };
    if (editing) { downTile = tile; if (tile) beginDrag(tile, e); return; }
    if (!tile) return;
    downTile = tile;
    hold = setTimeout(() => {
      hold = null;
      // A held FOLDER opens its contents to be managed.
      if (tile.classList.contains('isfolder')) {
        // **And the click that follows this press must not run.**
        //
        // A pointerup after a long press still fires `click` on the tile, and that handler opens
        // the folder view - straight over the sheet this just opened. The player saw a folder
        // with no badges in it and concluded the press had done nothing, which is exactly the
        // report. One flag, cleared by the click it suppresses.
        arrSwallowClick = true;
        ui('folder');
        folderManageSheet(itemsIndexOfTileEl(tile));
        return;
      }
      enterArrange();
      beginDrag(tile, e);
    }, 380);
  });

  window.addEventListener('pointermove', (e) => {
    if (hold && downXY && Math.hypot(e.clientX - downXY.x, e.clientY - downXY.y) > 10) {
      clearTimeout(hold); hold = null;   // a swipe, not a hold
    }
    if (arr) { e.preventDefault(); onDragMove(e); }
  }, { passive: false });

  window.addEventListener('pointerup', (e) => {
    if (hold) { clearTimeout(hold); hold = null; }
    if (arr) { onDragEnd(e); downTile = null; return; }
    // A tap on empty space in arrange mode leaves it, the way iOS does.
    if (editing && !downTile) exitArrange();
    downTile = null;
  });

  byId('arrangedone').addEventListener('click', exitArrange);
}

// A new page, made mid-drag by holding at the right edge of the last one.
//
// The break goes at the END of the working list, so the page being built is empty and the tile
// in hand is the first thing on it. `layoutItems` drops a break that would leave an unreachable
// empty page, so letting go without dropping anything here cannot leave a stray page behind.
function newPageDuringDrag() {
  if (!arr) return;
  const last = arr.items[arr.items.length - 1];
  if (last && last.t === 'break') {
    // Already on a fresh empty page: nothing to add, just go there.
    flipPage(1);
    return;
  }
  arr.items.push({ t: 'break' });
  arr.insert = arr.items.length;
  paintArrange();
  // paintArrange repaints from `arr.items`, so the new page exists by now.
  page = byId('pages').querySelectorAll('.page').length - 1;
  slideTrack();
  const n = byId('pages').querySelectorAll('.page').length;
  byId('dots').innerHTML = [...Array(n)].map((_, i) => `<i class="${i === page ? 'on' : ''}"></i>`).join('');
  ui('folder');
}

function flipPage(dir) {
  // Clamped to the pages that exist, so flipping past the end cannot slide the grid off
  // the screen and leave nothing showing.
  const n = byId('pages').querySelectorAll('.page').length;
  page = Math.max(0, Math.min(n - 1, page + dir));
  slideTrack();
  byId('dots').innerHTML = [...Array(n)].map((_, i) => `<i class="${i === page ? 'on' : ''}"></i>`).join('');
}

// ══ Widgets ════════════════════════════════════════════════════
// Both show something true: the weather the server is running, and the in-game date.
// A widget showing the player's real-world clock would be showing the wrong clock.
const WEATHER_ICON = {
  EXTRASUNNY: 'sun', CLEAR: 'sun', CLOUDS: 'cloud', OVERCAST: 'cloud', SMOG: 'cloud',
  FOGGY: 'cloud', RAIN: 'rain', THUNDER: 'rain', CLEARING: 'cloud', NEUTRAL: 'sun',
  SNOW: 'snow', BLIZZARD: 'snow', SNOWLIGHT: 'snow', XMAS: 'snow', HALLOWEEN: 'cloud',
};
const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

async function renderWidgets() {
  const host = byId('widgets');
  if (!host) return;
  const d = await post('ambient');
  if (!d || !d.ok) { host.innerHTML = ''; return; }
  gameHour = Number(d.hours);
  applyTheme();
  const w = String(d.weather || 'CLEAR').toUpperCase();
  const icon = WEATHER_ICON[w] || 'sun';
  // The same clock as the status bar, six centimetres above it.
  //
  // This used to show the GAME's hour on the grounds that a weather tile for Los Santos wants
  // Los Santos time. That reasoning does not survive contact with the screen: the status bar
  // said 19:59 and the tile under it said 09:10, and a phone showing two different times at
  // once is a phone that is wrong about one of them. The game hour is still read - it is what
  // drives automatic dark mode, where it belongs, because the sun in the sky is a game fact.
  host.innerHTML =
    '<div class="widget weather"><div class="wtop"><span>' + esc(L('ph.los_santos')) + '</span>' +
      '<span class="wicon">' + svg(icon) + '</span></div>' +
      '<div><div class="wbig">' + esc(phoneClock()) + '</div>' +
      '<div class="wsub">' + esc(L('ph.weather_' + icon)) + '</div></div></div>' +
    // The real date, not the game's. GTA's clock runs at its own pace and its calendar is
    // scenery; a player reading "2" off their phone wants to know what day it actually is.
    calendarWidget();
}

// Returns markup. It must not touch the DOM itself: it is concatenated into the widget
// strip above, and a version of this that wrote `innerHTML` from inside was overwritten by
// the assignment it was part of - leaving the word "undefined" on the home screen where the
// date should have been.
function calendarWidget() {
  const now = new Date();
  const weekday = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'][now.getDay()];
  return '<div class="widget cal">' +
      '<div class="wday">' + esc(L('ph.month_' + MONTHS[now.getMonth()])) + '</div>' +
      '<div class="wnum">' + esc(now.getDate()) + '</div>' +
      '<div class="wsub">' + esc(L('ph.day_' + weekday)) + '</div></div>';
}

// ══ App shell ══════════════════════════════════════════════════
// The zoom origin is taken from the icon that launched it. That one detail is most of
// what makes opening an app feel like iOS rather than a page swap.
function clearActiveApp() {
  const epoch = ++activeAppEpoch;
  return post('activeApp', { app: '', epoch });
}

function frameEvent(name, payload, frameWindow) {
  const frame = byId('appframe');
  const target = frameWindow || (frame && frame.contentWindow);
  if (!target) return;
  target.postMessage({ __phone: 'event', name, payload: payload || {} }, '*');
}

function clearAppVisualState() {
  const app = byId('app');
  clearTimeout(appFrameTimer);
  appFrameTimer = null;
  byId('appbody').classList.remove('frame-loading');
  app.classList.remove('black', 'camfull');
  byId('screen').classList.remove('appblack', 'cipher-open');
  byId('navbar').classList.remove('hidden');
  // Leaving the camera drops the selfie camera, or it would follow the player out.
  if (camFront) { camFront = false; post('camFacing', { front: false }); }
}

function enterApp(a, tile) {
  beginView();
  resetTransientUI();
  openApp = a; thread = null;
  threadGroup = null;
  navBackAction = null;
  // Most recent first, no duplicates. This is the switcher's whole model.
  recents = [a.id].concat(recents.filter((id) => id !== a.id)).slice(0, 8);
  const app = byId('app');
  // Leaving the camera for anywhere else drops its immersive chrome and unrotates.
  clearAppVisualState();
  app.dataset.app = a.id;
  byId('screen').classList.toggle('cipher-open', a.id === 'cipher');
  if (landscape) setLandscape(false);
  if (tile) {
    const r = tile.getBoundingClientRect();
    const s = byId('screen').getBoundingClientRect();
    app.style.transformOrigin = `${r.left + r.width / 2 - s.left}px ${r.top + r.height / 2 - s.top}px`;
  }
  app.classList.remove('closing');
  app.classList.add('on');
  ui('appopen');
  byId('screen').classList.add('app-open');
  setNav(L(a.label), null);
  byId('appfoot').innerHTML = '';

  if (a.page) {
    // A third-party app only receives a URL after Lua has bound this exact app id to
    // the current NUI session. The opaque sandbox prevents same-origin parent access.
    const epoch = ++activeAppEpoch;
    byId('appbody').innerHTML =
      `<iframe class="appframe" id="appframe" sandbox="allow-scripts" ` +
      `title="${esc(L(a.label))}" aria-busy="true"></iframe>`;
    byId('appbody').style.padding = '0';
    byId('appbody').classList.add('frame-loading');
    byId('navbar').classList.add('hidden');
    const frame = byId('appframe');
    const frameFailed = () => {
      if (epoch !== activeAppEpoch || openApp !== a || byId('appframe') !== frame) return;
      clearTimeout(appFrameTimer);
      appFrameTimer = null;
      clearActiveApp();
      byId('navbar').classList.remove('hidden');
      byId('appbody').style.padding = '';
      byId('appbody').classList.remove('frame-loading');
      body(UI.empty(L('ph.app_load_failed'), a.icon || 'dot'));
    };
    frame.addEventListener('load', () => {
      if (epoch !== activeAppEpoch || openApp !== a || byId('appframe') !== frame) return;
      // An iframe appended without a source first loads about:blank. Ignore that internal
      // load: the app is ready only after the authorised URL has actually been assigned.
      if (frame.dataset.requested !== '1') return;
      clearTimeout(appFrameTimer);
      appFrameTimer = null;
      byId('appbody').classList.remove('frame-loading');
      frame.setAttribute('aria-busy', 'false');
      frameEvent('resume', { app: a.id }, frame.contentWindow);
    });
    frame.addEventListener('error', frameFailed);
    post('activeApp', { app: a.id, epoch }).then((r) => {
      if (epoch !== activeAppEpoch || openApp !== a || byId('appframe') !== frame) return;
      if (!r || !r.ok) {
        frameFailed();
        return;
      }
      frame.dataset.requested = '1';
      frame.src = String(a.page || '');
      clearTimeout(appFrameTimer);
      appFrameTimer = setTimeout(frameFailed, 10000);
    });
    return;
  }
  clearActiveApp();
  byId('appbody').style.padding = '';
  const fn = RENDER[a.id];
  if (fn) fn(); else body(UI.empty(L('ph.no_app')));
}

function closeApp(instant) {
  // Whatever route out of an app is taken, the camera's first-person hold and hidden HUD
  // must not survive it. Cheap to call when no camera was open.
  if (camAppOpen) {
    camAppOpen = false;
    byId('device').classList.remove('camlive');
    post('camMode', { on: false });
    // `landscape` is module state and survived the visit, so a phone turned sideways in the
    // camera stayed sideways everywhere afterwards with no control left to turn it back.
    if (landscape) setLandscape(false);
  }
  beginView();
  const app = byId('app');
  const wasOpen = app.classList.contains('on');
  if (wasOpen && openApp && openApp.page) frameEvent('pause', { app: openApp.id });
  resetTransientUI();
  clearActiveApp();
  clearAppVisualState();
  if (landscape) setLandscape(false);
  byId('screen').classList.remove('app-open');
  navBackAction = null;
  foot('');
  if (!wasOpen || instant) {
    app.classList.remove('on', 'closing');
    delete app.dataset.app;
    openApp = null; thread = null; threadGroup = null;
    clearSocialAccounts();
    return;
  }
  app.classList.remove('on');
  app.classList.add('closing');
  ui('appclose');
  // `data-app` stays on until the animation has finished.
  //
  // Every app's colour comes from `.app[data-app="mail"] { --app-tint: ... }`, and this line
  // used to run before the closing animation started - so for those 300ms the rule stopped
  // matching, `--app-accent` fell back to its default, and every tinted word and control in
  // the app turned blue on the way out. The attribute is what the tint is keyed on, so it has
  // to outlive the frame that is still drawing it.
  const closingId = app.dataset.app;
  setTimeout(() => {
    app.classList.remove('closing');
    // Only if nothing has opened in the meantime. Three hundred milliseconds is easily
    // enough to tap another icon, and `enterApp` sets `data-app` again - deleting it blind
    // would strip the tint off the app that is now on screen, which is the same bug one
    // step further along.
    if (app.dataset.app === closingId && !app.classList.contains('on')) delete app.dataset.app;
  }, 300);
  openApp = null; thread = null; threadGroup = null; clearSocialAccounts();
}

function setNav(title, backLabel, action, onBack) {
  navBackAction = typeof onBack === 'function' ? onBack : null;
  byId('navtitle').textContent = title || '';
  byId('navtitlesm').textContent = title || '';
  const backText = backLabel || L('ph.home');
  byId('navbacktxt').textContent = backText;
  byId('navback').setAttribute('aria-label', backText);
  const act = byId('navact');
  if (!action && openApp && !openApp.page) {
    action = {
      icon: 'more',
      label: L('ph.app_actions'),
      onClick: () => appActions(openApp),
    };
  }
  if (action) {
    act.classList.remove('hidden');
    act.className = 'navact' + (action.icon ? ' round' : '');
    act.innerHTML = action.icon ? svg(action.icon) : esc(action.label);
    act.setAttribute('aria-label', action.label || (action.icon === 'phone' ? L('ph.call') : title) || 'Action');
    act.onclick = action.onClick;
  } else {
    act.classList.add('hidden');
    act.onclick = null;
  }
  byId('navbar').classList.remove('collapsed');
}

function appActions(app) {
  if (!app || !openApp) return;
  const searchInput = byId('appbody').querySelector(
    'input[type="search"], .search input, .uisearch input, #q'
  );
  const muted = appMuted(app.id);
  const store = (state.apps || []).find((entry) => entry.id === 'store');
  const actionRows = [];
  if (searchInput) {
    actionRows.push(UI.row({
      icon: 'search', tint: '#0A84FF', title: L('ph.search_in_app'),
      data: { tool: 'search' },
    }));
  }
  actionRows.push(
    UI.row({ icon: 'refresh', tint: '#30B0C7', title: L('ph.refresh_app'), data: { tool: 'refresh' } }),
    UI.row({
      icon: 'sparkles', tint: '#AF52DE', title: L('ph.set_action_app'),
      value: (state.prefs || {}).actionApp === app.id ? L('ph.selected') : '',
      data: { tool: 'action' },
    }),
    UI.row({
      icon: muted ? 'belloff' : 'bell', tint: muted ? '#8E8E93' : '#FF9500',
      title: muted ? L('ph.enable_notifications') : L('ph.mute_notifications'),
      data: { tool: 'notifications' },
    })
  );
  if (store && app.id !== 'store') {
    actionRows.push(UI.row({
      icon: 'store', tint: '#0A84FF', title: L('ph.view_in_store'),
      chevron: true, data: { tool: 'store' },
    }));
  }

  sheet(L(app.label), UI.group(actionRows, { footer: L('ph.app_actions_hint') }), () => {
    [...byId('sheet').querySelectorAll('[data-tool]')].forEach((row) => {
      row.addEventListener('click', async () => {
        const tool = row.dataset.tool;
        closeSheet();
        if (tool === 'search' && searchInput) {
          requestAnimationFrame(() => searchInput.focus());
        } else if (tool === 'refresh') {
          const render = RENDER[app.id];
          if (render) render();
        } else if (tool === 'action') {
          const response = await post('prefs', { actionApp: app.id });
          if (response && response.ok) {
            state.prefs = response.prefs;
            toast(L('ph.action_app_saved'));
          }
        } else if (tool === 'notifications') {
          await setAppMuted(app.id, !muted);
          toast(L(muted ? 'ph.notifications_enabled' : 'ph.notifications_muted'));
        } else if (tool === 'store' && store) {
          enterApp(store, null);
          storeDetail(app);
        }
      });
    });
  }, 'app-actions');
}

// Apps that already use the top-right button (new contact, new message, call…) keep that
// fast action. Holding it opens the shared app menu, so the common tools remain available
// without replacing the action a player reaches for most.
let navActionHold = 0;
let navActionHeld = false;
byId('navact').addEventListener('pointerdown', () => {
  navActionHeld = false;
  clearTimeout(navActionHold);
  if (!openApp || openApp.page) return;
  navActionHold = setTimeout(() => {
    navActionHeld = true;
    appActions(openApp);
  }, 520);
});
['pointerup', 'pointercancel', 'pointerleave'].forEach((eventName) => {
  byId('navact').addEventListener(eventName, () => {
    clearTimeout(navActionHold);
    navActionHold = 0;
  });
});
byId('navact').addEventListener('click', (event) => {
  if (!navActionHeld) return;
  navActionHeld = false;
  event.preventDefault();
  event.stopImmediatePropagation();
}, true);

const body = (html) => {
  const host = byId('appbody');
  clearTimeout(appFrameTimer);
  appFrameTimer = null;
  host.classList.remove('frame-loading');
  host.classList.remove('view-enter');
  host.innerHTML = html;
  // Chromium may scroll an overflow-hidden ancestor when a focused control near the
  // bottom disappears during navigation. Pinning the screen prevents the mysterious
  // wallpaper/black strip that otherwise appears below an app after such a transition.
  byId('screen').scrollTop = 0;
  byId('screen').scrollLeft = 0;
  // Restart a short native transition for view-to-view navigation. A forced layout is
  // intentional here: without it, two renders in the same frame collapse into one state.
  void host.offsetWidth;
  host.classList.add('view-enter');
};
const foot = (html) => { byId('appfoot').innerHTML = html || ''; };
const loading = () => body(UI.empty(L('ph.loading')));
const rows = (sel, fn) => [...byId('appbody').querySelectorAll(sel)].forEach(fn);
const qrows = (root, sel, fn) => [...byId(root).querySelectorAll(sel)].forEach(fn);

/// The tile for an app, by the app itself rather than by whatever its config row says.
///
/// **An operator's `config.lua` is the one file an update does not replace**, and that is
/// correct - it is theirs. But it means a change of identity shipped in the config never
/// reaches a server that already had the app: Bank Pro kept the green `bank` tile on every
/// server that updated, because their row still said `icon = 'bank'`.
///
/// So when this phone ships a tile named after the app id, that tile wins. An app the phone
/// knows about looks like itself; anything else falls back to the row's icon, which is what an
/// operator's own store app relies on.
function appTile(a, cls) {
  if (!a) return UI.appIcon('dot', cls);
  return UI.appIcon(UI.hasTile && UI.hasTile(a.id) ? a.id : (a.icon || 'dot'), cls);
}

// The iOS push: new content slides in from the right. A swap with no motion reads as a
// refresh rather than a step deeper.
const pushAnim = () => {
  const b = byId('appbody');
  b.classList.remove('pushin');
  void b.offsetWidth;
  b.classList.add('pushin');
};

// The large title collapses into the bar on scroll, as it does on iOS.
byId('appbody').addEventListener('scroll', (e) => {
  byId('navbar').classList.toggle('collapsed', e.target.scrollTop > 22);
});

// Pull to refresh on every native app. The renderer remains the owner of its data; this
// gesture simply asks it to read again, exactly like the Refresh action in the nav menu.
let appPull = null;
byId('appbody').addEventListener('pointerdown', (event) => {
  if (!openApp || openApp.page || byId('appbody').scrollTop > 0 ||
      (event.target.closest && event.target.closest('input,textarea,button,select'))) {
    appPull = null;
    return;
  }
  appPull = { y: event.clientY, x: event.clientX, pointerId: event.pointerId };
});
byId('appbody').addEventListener('pointermove', (event) => {
  if (!appPull || appPull.pointerId !== event.pointerId) return;
  const dy = event.clientY - appPull.y;
  const dx = Math.abs(event.clientX - appPull.x);
  byId('appbody').classList.toggle('pull-ready', dy > 68 && dx < 45);
});
byId('appbody').addEventListener('pointerup', (event) => {
  if (!appPull || appPull.pointerId !== event.pointerId) return;
  const dy = event.clientY - appPull.y;
  const dx = Math.abs(event.clientX - appPull.x);
  appPull = null;
  byId('appbody').classList.remove('pull-ready');
  if (dy <= 68 || dx >= 45 || !openApp || openApp.page) return;
  const render = RENDER[openApp.id];
  if (!render) return;
  byId('appbody').classList.add('refreshing');
  render();
  setTimeout(() => byId('appbody').classList.remove('refreshing'), 620);
});
byId('appbody').addEventListener('pointercancel', () => {
  appPull = null;
  byId('appbody').classList.remove('pull-ready');
});
byId('screen').addEventListener('scroll', (event) => {
  if (!event.currentTarget.scrollTop && !event.currentTarget.scrollLeft) return;
  event.currentTarget.scrollTop = 0;
  event.currentTarget.scrollLeft = 0;
});

// ══ Built-in apps ══════════════════════════════════════════════
const RENDER = new Proxy({}, {
  set(target, key, render) {
    target[key] = (...args) => {
      if (!openApp || openApp.id !== String(key)) return;
      beginView();
      return render(...args);
    };
    return true;
  },
});

// ── Phone ──────────────────────────────────────────────────────
const KEYS = [['1', ''], ['2', 'ABC'], ['3', 'DEF'], ['4', 'GHI'], ['5', 'JKL'], ['6', 'MNO'],
  ['7', 'PQRS'], ['8', 'TUV'], ['9', 'WXYZ'], ['*', ''], ['0', '+'], ['#', '']];

let phoneTab = 'keypad';

RENDER.phone = () => {
  tabbar([
    { id: 'favourites', icon: 'star', label: 'ph.favourites' },
    { id: 'recents', icon: 'phone', label: 'ph.recents' },
    { id: 'voicemail', icon: 'voicemail', label: 'ph.voicemail' },
    { id: 'contacts', icon: 'contacts', label: 'app.contacts' },
    { id: 'keypad', icon: 'keypad', label: 'ph.keypad_tab' },
  ], phoneTab, (t) => { phoneTab = t; RENDER.phone(); });

  if (phoneTab === 'voicemail') { renderVoicemail(); return; }

  if (phoneTab === 'recents') {
    body('<div id="recents">' + UI.empty(L('ph.loading'), 'phone') + '</div>');
    post('calls').then((r) => {
      const host = byId('recents');
      if (!host) return;
      const calls = (r && r.calls) || [];
      if (!calls.length) { host.innerHTML = UI.empty(L('ph.no_recents_call'), 'phone'); return; }
      // A visible way to wipe the log. Press and hold one row to forget just that call - the
      // same gesture the conversation list uses, so there is one thing to learn, not two.
      host.innerHTML = UI.button(L('ph.calls_clear'), 'callsclear', 'plain') +
        UI.group(calls.map((c) => {
        const missed = c.direction === 'in' && !Number(c.answered);
        const dir = missed ? 'missed' : c.direction;
        const name = c.number ? nameOfNumber(c.number) : L('ph.unknown');
        return UI.row({
          icon: dir === 'out' ? 'callout' : (missed ? 'callmissed' : 'callin'),
          tint: missed ? '#FF453A' : '#34C759',
          title: name,
          subtitle: (L('ph.call_' + dir) + '  ') + shortWhen(c.at),
          value: maskNum(c.number), chevron: true,
          data: { n: c.number || '', cid: c.id || '' },
        });
      }));
      qrows('recents', '.row', (el) => el.addEventListener('click', () => {
        if (el.dataset.n) placeCall(el.dataset.n);
      }));
      byId('callsclear').addEventListener('click', () => {
        confirmSheet(L('ph.calls_clear_ask'), L('ph.calls_clear'), async () => {
          await post('callsDelete', { all: true });
          toast(L('ph.calls_cleared'));
          RENDER.phone();
        });
      });
      // One call, held rather than tapped: a tap on a recent call rings it back, and losing
      // a number because a finger landed on the wrong row would be worse than no delete.
      qrows('recents', '.row', (el) => {
        let timer = null;
        const cancel = () => { clearTimeout(timer); timer = null; };
        el.addEventListener('pointerdown', () => {
          timer = setTimeout(() => {
            timer = null;
            const id = el.dataset.cid;
            if (!id) return;
            confirmSheet(L('ph.call_delete_ask'), L('ph.delete'), async () => {
              await post('callsDelete', { id: Number(id) });
              toast(L('ph.call_deleted'));
              RENDER.phone();
            });
          }, 550);
        });
        ['pointerup', 'pointerleave', 'pointercancel'].forEach((e) => el.addEventListener(e, cancel));
      });
    });
    return;
  }

  if (phoneTab !== 'keypad') {
    // Favourites is the contacts the player marked, not a second address book.
    const list = (state.contacts || []).filter((c) => phoneTab === 'contacts' || Number(c.favourite) === 1);
    body(list.length
      ? UI.group(list.map((c) => UI.row({
          avatar: c.name, title: c.name, subtitle: maskNum(c.number), chevron: true, data: { n: c.number },
        })))
      : UI.empty(L(phoneTab === 'contacts' ? 'ph.no_contacts' : 'ph.no_favourites'), 'contacts'));
    rows('.row[data-n]', (r) => r.addEventListener('click', () => placeCall(r.dataset.n)));
    return;
  }

  const known = (state.contacts || []).find((c) => c.number === dialed);
  body(
    `<div class="dialed" id="dialed">${esc(dialed)}</div>` +
    `<div class="dialsub" id="dialsub">${esc(known ? known.name : '')}</div>` +
    `<div class="keypad">${KEYS.map(([k, l]) =>
      `<button class="key" data-k="${k}" type="button" aria-label="${k}"><b>${k}</b><i>${l}</i></button>`).join('')}</div>` +
    `<div class="dialrow">` +
      `<span class="dialspace"></span>` +
      `<button class="callbtn" id="dial" type="button" aria-label="${esc(L('ph.call'))}">${svg('answer')}</button>` +
      `<button class="delbtn ${dialed ? '' : 'hidden'}" id="delkey" type="button" aria-label="${esc(L('ph.delete_digit'))}">${svg('del')}</button>` +
    `</div>`
  );
  const paint = () => {
    byId('dialed').textContent = dialed;
    const c = (state.contacts || []).find((x) => x.number === dialed);
    byId('dialsub').textContent = c ? c.name : '';
    byId('delkey').classList.toggle('hidden', !dialed);
  };
  rows('.key', (b) => b.addEventListener('click', () => {
    dialed = (dialed + b.dataset.k).slice(0, 20); paint();
  }));
  byId('delkey').addEventListener('click', () => { dialed = dialed.slice(0, -1); paint(); });
  byId('dial').addEventListener('click', () => { if (dialed) placeCall(dialed); });
};

// ── Health record ──────────────────────────────────────────────
// The half of a Health app the game cannot work out for itself: blood type, allergies,
// what you are on, who to call. It rides on the character, so it survives the handset.
function healthRecord() {
  if (!openApp || openApp.id !== 'health') return;
  beginView();
  setNav(L('app.health'), L('app.health'), null, () => {
    healthTab = 'today';
    RENDER.health();
  });
  loading();
  post('health', { op: 'get' }).then((d) => {
    const r = (d && d.record) || {};
    body(
      UI.hero({
        appicon: 'heart',
        eyebrow: L('ph.steps'),
        value: String(r.steps || 0),
        subtitle: L('ph.steps_today'),
      }) +
      UI.field('hblood', L('ph.blood'), r.blood || '', 'maxlength="6"') +
      UI.field('hallerg', L('ph.allergies'), r.allergies || '', 'maxlength="300"') +
      UI.field('hcond', L('ph.conditions'), r.conditions || '', 'maxlength="300"') +
      UI.field('hmeds', L('ph.meds'), r.meds || '', 'maxlength="300"') +
      UI.field('hice', L('ph.ice'), r.ice || '', 'maxlength="60"') +
      UI.group([UI.row({ icon: 'heart', tint: '#FF2D55', title: L('ph.donor'),
        toggle: r.donor === true, data: { t: 'donor' } })]) +
      UI.button(L('ph.save'), 'hsave', 'tinted') +
      // Hand it to somebody standing next to you. Useful exactly when it matters: a medic who
      // needs a blood group from a player who is conscious enough to send it.
      UI.button(L('ph.health_share'), 'hshare', 'plain') +
      '<div class="groupfoot">' + esc(L('ph.health_hint')) + '</div>'
    );
    if (byId('hshare')) byId('hshare').addEventListener('click', () => airdropShare('health', {}));
    healthReader = d && d.reader === true;
    let donor = r.donor === true;
    rows('.row', (el) => el.addEventListener('click', () => {
      donor = !donor;
      el.querySelector('.sw').classList.toggle('on', donor);
      el.setAttribute('aria-checked', donor ? 'true' : 'false');
    }));
    byId('hsave').addEventListener('click', async () => {
      const res = await post('health', { op: 'set', blood: byId('hblood').value,
        allergies: byId('hallerg').value, conditions: byId('hcond').value,
        meds: byId('hmeds').value, ice: byId('hice').value, donor });
      toast(res && res.ok ? L('ph.saved') : L('ph.err_x'));
    });
  });
}

// ── Notes ──────────────────────────────────────────────────────
// Part of the phone rather than a sample resource: notes are the one thing people expect
// to survive everything else, so they live with the phone's own data.
RENDER.notes = async () => {
  setNav(L('app.notes'), null, { icon: 'add', onClick: () => noteEdit({}) });
  loading();
  const d = await post('notes', { op: 'list' });
  const list = (d && d.notes) || [];
  if (!list.length) { body(UI.empty(L('ph.no_notes'), 'note')); return; }
  body(UI.group(list.map((n) => UI.row({
    icon: 'note', tint: '#FFCC00', title: n.title || L('ph.untitled'),
    subtitle: shortWhen(n.at), chevron: true, data: { id: n.id },
  }))));
  rows('.row', (el) => el.addEventListener('click', () => {
    const n = list.find((x) => String(x.id) === el.dataset.id);
    if (n) noteEdit(n);
  }));
};

function noteEdit(n) {
  if (!openApp || openApp.id !== 'notes') return;
  beginView();
  setNav(n.id ? (n.title || L('ph.untitled')) : L('ph.note_new'), L('app.notes'), null,
    () => RENDER.notes());
  body(
    UI.field('ntitle', L('ph.note_title'), n.title || '', 'maxlength="80"') +
    '<textarea class="mailedit" id="nbody" maxlength="4000" placeholder="' + esc(L('ph.note_body')) + '">' +
      esc(n.body || '') + '</textarea>' +
    UI.button(L('ph.save'), 'nsave', 'tinted') +
    (n.id ? UI.button(L('ph.delete'), 'ndel', 'destructive') : '')
  );
  byId('nsave').addEventListener('click', async () => {
    const r = await post('notes', { op: 'save', id: n.id, title: byId('ntitle').value, body: byId('nbody').value });
    if (r && r.ok) { toast(L('ph.saved')); RENDER.notes(); }
    else toast(L('ph.err_' + ((r && r.error) || 'x')));
  });
  const del = byId('ndel');
  if (del) del.addEventListener('click', async () => {
    await post('notes', { op: 'del', id: n.id });
    toast(L('ph.deleted')); RENDER.notes();
  });
}

// A timestamp out of the database, as milliseconds. NaN when there is nothing usable.
//
// **oxmysql hands every DATETIME and TIMESTAMP column back as a millisecond epoch NUMBER**, not
// as the `2026-07-26 14:21:33` string the SQL suggests. Its type cast is explicit about it:
//
//     case "DATETIME": case "TIMESTAMP": ... return value ? new Date(value).getTime() : null
//
// Anything that treats one as a string therefore prints a raw clock value. This was fixed once,
// here, for the mail list - and left as a local fix, so the same digits then turned up beside
// every social post, in Cipher and on a bank statement line. One helper now, and every screen
// that shows a time goes through it.
//
// Both shapes are accepted regardless: a column an older schema declared as text still arrives
// as a string, and there is no reason for a display helper to care which.
function whenMs(at) {
  if (at == null || at === '') return NaN;
  const asNumber = (typeof at === 'number') ? at
    : (/^\d{10,}$/.test(String(at).trim()) ? Number(at) : null);
  if (asNumber !== null) {
    // Ten digits is seconds, thirteen is milliseconds. Guessing wrong puts the date in 1970 or
    // in the year 57000, so it is worth the one comparison.
    return asNumber < 1e11 ? asNumber * 1000 : asNumber;
  }
  // '2026-07-26 14:21:33' - the T is what makes it parse the same way in every engine.
  return Date.parse(String(at).replace(' ', 'T'));
}

// A time, as a person would write it: 26 Jul 14:21.
function shortWhen(at) {
  const ms = whenMs(at);
  if (!Number.isFinite(ms)) return '';
  const d = new Date(ms);
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })
    + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// ── Mail ───────────────────────────────────────────────────────
// A mail client, not a second Messages: an address you own, folders, group recipients,
// drafts you can come back to, replies that quote who they answer, and a keep flag that
// works from any folder.
let mailFolder = 'inbox';
let mailAcc = null;

let mailImages = true;      // whether the server allows an attachment at all

// Every mail request names which of the player's addresses it is acting as.
//
// One wrapper rather than the field repeated at nine call sites: a request that forgets it
// would silently act as the FIRST address instead of the open one, which is the kind of bug
// that reads as "my mail went from the wrong account" and is impossible to spot in a diff.
const mailPost = (op, extra) => post('mail', Object.assign({ op, address: mailAcc }, extra || {}));
let mailMe = null;          // the last `me` answer, for the domain sheet

// Buying a domain of your own.
//
// The price and whether it is allowed at all are the server's to state; this only asks. The
// name is checked there too - a player must not be able to buy something that reads like a
// public service, and a list the page was shown is not a rule.
function mailBuyDomain() {
  const buy = (mailMe && mailMe.buy) || {};
  sheet(L('ph.mail_buy_title'),
    '<div class="groupfoot">' + esc(L('ph.mail_buy_hint').replace('{price}', money(buy.price))) + '</div>' +
    UI.field('mdomname', L('ph.mail_buy_name'), '', 'maxlength="30"') +
    UI.button(L('ph.mail_buy_go'), 'mdomgo', 'tinted'),
    () => {
      const epoch = sheetEpoch;
      byId('mdomgo').addEventListener('click', async () => {
        const r = await post('mail', { op: 'buyDomain', domain: byId('mdomname').value.trim() });
        if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
        if (!closeSheet(false, epoch)) return;
        ui('success');
        toast(L('ph.mail_buy_done').replace('{domain}', r.domain));
        RENDER.mail();
      });
    });
}

RENDER.mail = async () => {
  setNav(L('app.mail'), null);
  loading();
  // `address` so the server answers with the account the player was last reading, rather than
  // silently snapping back to their first one every time the app is opened.
  const me = await post('mail', { op: 'me', address: mailAcc });
  if (!me || me.error) { body(UI.empty(L('ph.err_' + ((me && me.error) || 'off')), 'mail')); return; }
  mailImages = me.images !== false;
  mailMe = me;
  if (!me.address) {
    mailSignup(me.domains || [], me.reserved || {}, me.owned || {}, me.buy || {});
    return;
  }
  mailAcc = me.address;
  mailList();
};

// The address is chosen once and is what people write to, which is why it cannot be
// edited away afterwards.
function mailSignup(domains, reserved, owned, buy) {
  if (!openApp || openApp.id !== 'mail') return;
  setNav(L('app.mail'), null);
  reserved = reserved || {};
  owned = owned || {};
  let domain = domains[0] || 'eyefind.info';
  // A reserved domain is only in this list because the reader's job qualifies for it, which is
  // worth saying: it is also the only explanation for why an officer's list is longer than
  // everybody else's.
  const anyReserved = domains.some((d) => reserved[d]);
  body(
    '<div class="accthead">' + UI.appIcon('mail') +
      '<div class="acctname">' + esc(L('app.mail')) + '</div>' +
      '<div class="acctsub">' + esc(L('ph.mail_pick_sub')) + '</div></div>' +
    UI.field('mlocal', L('ph.mail_localpart'), '', 'maxlength="20"') +
    // Chips that WRAP, not a scrolling segmented control.
    //
    // `.seg.scroll` hides its scrollbar, so a fourth domain simply disappeared off the right
    // edge with nothing to say it was there - and this list gets longer, not shorter: a
    // reserved domain per public service, plus whatever a player has bought. A control that
    // hides options is worse than a taller one.
    '<div class="domlist" id="mdoms">' + domains.map((d, i) =>
      '<button class="' + (i === 0 ? 'on' : '') + (reserved[d] ? ' gov' : '') +
      (owned[d] ? ' mine' : '') +
      '" data-d="' + esc(d) + '" type="button">@' + esc(d) + '</button>').join('') + '</div>' +
    UI.button(L('ph.mail_create'), 'mmake', 'tinted') +
    '<div class="groupfoot">' + esc(L('ph.mail_pick_hint')) + '</div>' +
    (anyReserved ? '<div class="groupfoot">' + esc(L('ph.mail_reserved_hint')) + '</div>' : '') +
    (buy && buy.enabled
      ? UI.button(L('ph.mail_buy').replace('{price}', money(buy.price)), 'mbuy', 'plain')
      : '')
  );
  qrows('mdoms', 'button', (b) => b.addEventListener('click', () => {
    domain = b.dataset.d;
    [...byId('mdoms').querySelectorAll('button')].forEach((x) => x.classList.toggle('on', x === b));
  }));
  if (byId('mbuy')) byId('mbuy').addEventListener('click', () => mailBuyDomain());
  byId('mmake').addEventListener('click', async () => {
    const r = await post('mail', { op: 'create', localpart: byId('mlocal').value.trim(), domain });
    if (r && r.ok) { mailAcc = r.address; toast(L('ph.mail_made')); mailList(); }
    else toast(L('ph.err_' + ((r && r.error) || 'x')));
  });
}

const MAIL_TABS = [
  { id: 'inbox', icon: 'mail', label: 'ph.mail_inbox' },
  { id: 'sent', icon: 'send', label: 'ph.mail_sent' },
  { id: 'draft', icon: 'note', label: 'ph.mail_drafts' },
  { id: 'saved', icon: 'star', label: 'ph.mail_saved' },
];

async function mailList() {
  if (!openApp || openApp.id !== 'mail') return;
  beginView();
  setNav(L('app.mail'), null, { icon: 'add', onClick: () => mailCompose({}) });
  tabbar(MAIL_TABS, mailFolder, (t) => { mailFolder = t; mailList(); });
  // The address you are reading, and the way to the others. Already on screen; now it is the
  // control too, which is where somebody would look for it.
  const many = ((mailMe && mailMe.accounts) || []).length > 1
    || ((mailMe && mailMe.accounts) || []).length < (Number(mailMe && mailMe.maxAccounts) || 1);
  body('<button class="mailaddr' + (many ? ' pick' : '') + '" id="maddr" type="button">'
    + esc(mailAcc || '') + (many ? svg('chevron') : '') + '</button><div id="mlist"></div>');
  if (many) byId('maddr').addEventListener('click', () => mailAccountSheet());
  else byId('maddr').addEventListener('click', () => airdropShare('email', { address: mailAcc }));

  const r = mailFolder === 'saved'
    ? await mailPost('saved')
    : await mailPost('list', { folder: mailFolder });
  const host = byId('mlist');
  if (!host) return;
  const list = (r && r.mail) || [];
  if (!list.length) { host.innerHTML = UI.empty(L('ph.mail_empty'), 'mail'); return; }

  host.innerHTML = UI.group(list.map((m) => {
    // Inbox shows who wrote; everywhere else, who it went to.
    const who = (m.folder === 'inbox') ? m.from_addr : (m.to_addr || L('ph.mail_noto'));
    return UI.row({
      avatar: who, title: who,
      subtitle: (m.subject || L('ph.mail_nosubject')) + '  -  ' + shortWhen(m.at),
      badge: (m.folder === 'inbox' && !Number(m.seen)) ? L('ph.vm_new_short') : undefined,
      value: Number(m.saved) ? '\u2605' : '',
      chevron: true, data: { b: m.box_id },
    });
  }));
  qrows('mlist', '.row', (el) => el.addEventListener('click', () => {
    const m = list.find((x) => String(x.box_id) === el.dataset.b);
    if (m) mailRead(m);
  }));
}

function mailRead(m) {
  if (!openApp || openApp.id !== 'mail') return;
  beginView();
  // A draft is not something you read; it is something you carry on writing.
  if (m.folder === 'draft') { mailCompose({ draft: m }); return; }
  if (m.folder === 'inbox' && !Number(m.seen)) mailPost('seen', { boxId: m.box_id });

  setNav(m.subject || L('ph.mail_nosubject'), L('app.mail'), {
    icon: 'star', onClick: async () => {
      const saved = !Number(m.saved);
      await mailPost('save', { boxId: m.box_id, saved });
      m.saved = saved ? 1 : 0;
      toast(L(saved ? 'ph.mail_kept' : 'ph.mail_unkept'));
    },
  }, () => mailList());
  body(
    '<div class="mailhead">' +
      '<div class="mailsubj">' + esc(m.subject || L('ph.mail_nosubject')) + '</div>' +
      '<div class="mailmeta"><b>' + esc(m.from_addr) + '</b></div>' +
      '<div class="mailmeta">' + esc(L('ph.mail_to')) + ' ' + esc(m.to_addr || '') + '</div>' +
      '<div class="mailmeta">' + esc(shortWhen(m.at)) + '</div>' +
    '</div>' +
    '<div class="mailbody">' + esc(m.body || '') + '</div>' +
    (m.image ? '<button class="mailimg" id="mimg" type="button" style="'
      + photoStyle(m.image) + '"></button>' : '') +
    UI.button(L('ph.mail_reply'), 'mreply', 'tinted') +
    UI.button(L('ph.mail_forward'), 'mfwd', 'plain') +
    ((m.to_addr || '').indexOf(',') !== -1 ? UI.button(L('ph.mail_reply_all'), 'mreplyall', 'plain') : '') +
    UI.button(L('ph.delete'), 'mdel', 'destructive')
  );
  byId('mreply').addEventListener('click', () => mailCompose({ reply: m, all: false }));
  // Forward keeps the message and clears the recipients: the point is to send it on.
  byId('mfwd').addEventListener('click', () => mailCompose({ forward: m }));
  // Tapping the attachment opens the photo viewer, so it can be looked at properly rather
  // than at reading-column width.
  if (byId('mimg')) byId('mimg').addEventListener('click', () => photoSheet([m.image], 0, []));
  const ra = byId('mreplyall');
  if (ra) ra.addEventListener('click', () => mailCompose({ reply: m, all: true }));
  byId('mdel').addEventListener('click', async () => {
    await mailPost('del', { boxId: m.box_id });
    toast(L('ph.mail_deleted')); mailList();
  });
}

// Which address you are reading, and the way to the others.
//
// A sheet rather than a segmented control: the number of accounts is small but the addresses
// are long, and three of them side by side would be three unreadable stubs.
function mailAccountSheet() {
  const me = mailMe || {};
  const accounts = me.accounts || [];
  const cap = Number(me.maxAccounts) || 1;
  sheet(L('ph.mail_accounts'),
    UI.group(accounts.map((a) => UI.row({
      icon: 'mail', tint: '#0A84FF', title: a,
      value: a === mailAcc ? L('ph.mail_reading') : '',
      data: { acc: a },
    }))) +
    UI.button(L('ph.mail_share'), 'macc_share', 'plain') +
    (accounts.length < cap
      ? UI.button(L('ph.mail_add_account'), 'macc_add', 'tinted')
      : '<div class="groupfoot">' + esc(L('ph.mail_account_cap').replace('{max}', String(cap))) + '</div>'),
    () => {
      const epoch = sheetEpoch;
      rows('.row[data-acc]', () => {});
      [...byId('sheet').querySelectorAll('[data-acc]')].forEach((el) =>
        el.addEventListener('click', () => {
          if (!closeSheet(false, epoch)) return;
          if (el.dataset.acc === mailAcc) return;
          mailAcc = el.dataset.acc;
          mailFolder = 'inbox';
          RENDER.mail();
        }));
      byId('macc_share').addEventListener('click', () => {
        if (!closeSheet(false, epoch)) return;
        // Which address is shared is this page's choice; WHAT it says is the server's, checked
        // against the addresses this character actually holds.
        airdropShare('email', { address: mailAcc });
      });
      if (byId('macc_add')) byId('macc_add').addEventListener('click', () => {
        if (!closeSheet(false, epoch)) return;
        // The same screen that creates the first address creates the next one.
        mailSignup(me.domains || [], me.reserved || {}, me.owned || {}, me.buy || {});
      });
    });
}

// One composer for a new mail, a reply, a reply-all and an unfinished draft.
function mailCompose(o) {
  if (!openApp || openApp.id !== 'mail') return;
  beginView();
  o = o || {};
  const d = o.draft, r = o.reply;
  let to = '', subject = '', bodyTxt = '', replyTo = 0, boxId = 0;

  if (d) {
    to = d.to_addr || ''; subject = d.subject || ''; bodyTxt = d.body || '';
    replyTo = Number(d.reply_to || 0); boxId = Number(d.box_id || 0);
  } else if (o.to) {
    // Opened from somewhere that already knows who this is for - a contact card, a tapped
    // address - so the recipient is filled in and the cursor belongs in the subject.
    to = String(o.to);
  } else if (o.forward) {
    const f = o.forward;
    subject = /^(fwd|tr):/i.test(f.subject || '') ? f.subject : ('Fwd: ' + (f.subject || ''));
    bodyTxt = '\n\n--- ' + (f.from_addr || '') + ' ---\n' + (f.body || '');
  } else if (r) {
    // Reply goes to the writer; reply-all adds everyone it was addressed to but you.
    const others = o.all
      ? (r.to_addr || '').split(',').map((x) => x.trim()).filter((x) => x && x !== mailAcc)
      : [];
    to = [r.from_addr].concat(others).filter(Boolean).join(', ');
    subject = /^re:/i.test(r.subject || '') ? r.subject : ('Re: ' + (r.subject || ''));
    bodyTxt = '\n\n--- ' + (r.from_addr || '') + ' ---\n' + (r.body || '');
    replyTo = Number(r.mail_id || 0);
  }

  // An attachment survives a redraw of the preview, so it lives here rather than in the DOM.
  // A forward keeps the picture it is forwarding - dropping it was silent, and "forward" of a
  // mail that was mostly a photo forwarded nothing. A reply does not: you are answering, not
  // re-sending their attachment back to them.
  let image = (d && d.image) || (o.forward && o.forward.image) || '';

  setNav(L('ph.mail_new'), L('app.mail'), null, () => mailList());
  body(
    UI.field('mto', L('ph.mail_to_ph'), to, 'maxlength="400"') +
    UI.field('msubj', L('ph.mail_subject'), subject, 'maxlength="80"') +
    '<textarea class="mailedit" id="mbody" maxlength="2000" placeholder="' + esc(L('ph.mail_body_ph')) + '">' + esc(bodyTxt) + '</textarea>' +
    (mailImages ? '<div id="mattach"></div>' + UI.button(L('ph.mail_attach'), 'mpick', 'plain') : '') +
    UI.button(L('ph.mail_send'), 'msend', 'tinted') +
    UI.button(L('ph.mail_savedraft'), 'msave', 'plain') +
    '<div class="groupfoot">' + esc(L('ph.mail_group_hint')) + '</div>'
  );

  // The attachment, drawn above the buttons with an x on it. Repainted in place so the
  // recipients and the body already typed survive picking - and re-picking - an image.
  const paintAttach = () => {
    const host = byId('mattach');
    if (!host) return;
    host.innerHTML = image
      ? '<div class="socattached" style="' + photoStyle(image) + '">' +
          '<button class="socattachx" id="mdrop" type="button" aria-label="' +
            esc(L('ph.remove')) + '">' + svg('xmark') + '</button></div>'
      : '';
    if (image) byId('mdrop').addEventListener('click', () => {
      image = '';
      paintAttach();
      ui('detach');
    });
  };

  if (byId('mpick')) byId('mpick').addEventListener('click', () => {
    // From the phone, or a link - a link is the only route for anybody whose gallery is
    // empty, and for an image that was never taken on this phone.
    sheet(L('ph.mail_attach'),
      UI.button(L('ph.pick_photo'), 'mfrom_roll', 'plain') +
      UI.field('mfrom_url', L('ph.mail_attach_url'), image, 'maxlength="300"') +
      UI.button(L('ph.mail_attach_use'), 'mfrom_use', 'tinted'),
      () => {
        const epoch = sheetEpoch;
        byId('mfrom_roll').addEventListener('click', () => pickPhoto((url) => {
          image = url;
          // Picking a photo IS the choice - dismiss the attach sheet rather than leaving it
          // open. `pickPhoto` restores this sheet by default, and the empty URL field it comes
          // back with was a trap: tapping "Use" next read that empty field and wiped the photo
          // just picked, so the mail sent with no attachment. Nobody, sender included, saw it.
          closeSheet(true);
          paintAttach();
          ui('shutter');
        }));
        byId('mfrom_use').addEventListener('click', () => {
          const url = byId('mfrom_url').value.trim();
          if (!closeSheet(false, epoch)) return;
          // An empty field must not clear a photo already chosen from the roll: "Use" with
          // nothing typed means "keep what I have", not "attach nothing".
          if (url) image = url;
          paintAttach();
        });
      });
  });
  paintAttach();

  const payload = () => ({ to: byId('mto').value, subject: byId('msubj').value,
    body: byId('mbody').value, image, replyTo, boxId });

  byId('msend').addEventListener('click', async () => {
    const res = await mailPost('send', payload());
    if (res && res.ok) { ui('send'); toast(L('ph.mail_sent')); mailFolder = 'sent'; mailList(); }
    else if (res && res.error === 'noaddr') toast(L('ph.err_noaddr') + ' ' + (res.address || ''));
    else toast(L('ph.err_' + ((res && res.error) || 'x')));
  });
  byId('msave').addEventListener('click', async () => {
    const res = await mailPost('draft', payload());
    if (res && res.ok) { toast(L('ph.mail_drafted')); mailFolder = 'draft'; mailList(); }
    else toast(L('ph.err_' + ((res && res.error) || 'x')));
  });
}

// ── Photos: filters, albums, and a picker every app can raise ──
// A filter is a stored name drawn with CSS, never a re-encoded image: the phone holds a
// link and how to draw it, which is the only thing it can honestly hold.
const FILTERS = ['none', 'mono', 'noir', 'fade', 'warm', 'cool', 'vivid'];

// ══ Shapes ═════════════════════════════════════════════════════
// A screenshot is the game window, so every photograph arrives 16:9 however the player
// wanted it framed. Recropping is a stored shape plus a vertical framing point, drawn with
// `object-fit: cover` - the file is never re-encoded, exactly like the filters above.
const CROPS = ['none', 'portrait', 'square', 'tall'];
function cropRatio(c) {
  return ({ portrait: 3 / 4, square: 1, tall: 9 / 16 })[c] || null;
}
function focusOf(v) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.max(0, Math.min(100, n)) : 50;
}
function filterCss(f) {
  return ({
    mono:  'grayscale(1)',
    noir:  'grayscale(1) contrast(1.5) brightness(.9)',
    fade:  'saturate(.7) contrast(.88) brightness(1.08)',
    warm:  'sepia(.35) saturate(1.25) hue-rotate(-12deg)',
    cool:  'saturate(1.1) hue-rotate(14deg) brightness(1.03)',
    vivid: 'saturate(1.6) contrast(1.12)',
  })[f] || 'none';
}

// Photos arrive as rows now; older saves were bare strings.
// ══ A photo's edits, carried by its URL ════════════════════════
// A retouch in the Gallery is a RECIPE, not a new image: a filter name, a crop shape and where
// the crop sits. The comment on the server says so outright - "the phone never holds pixels,
// only the link and how to draw it" - and that is a good decision, because re-encoding a
// screenshot in a browser and re-uploading it would be a lot of machinery for a colour wash.
//
// But the recipe lived only on the gallery ROW. Post that photo to Bleeter and only the URL
// travelled, so the picture came back untouched, and the edit looked like it had not saved.
//
// So the recipe rides along in the URL FRAGMENT. A fragment is never sent to the host - the
// browser strips it before the request - so the image still loads from exactly the same place,
// and every column, payload and table that already carries a URL string now carries the edit
// too, with no schema change anywhere.
const PHOTO_TAG = '#vp=';

function photoEncode(url, row) {
  const base = String(url || '').split(PHOTO_TAG)[0];
  if (!base || !row) return base;
  const parts = [];
  if (row.filter) parts.push('f' + row.filter);
  if (row.crop) parts.push('c' + row.crop);
  // 50 is the default band, so it is only worth carrying when it is not.
  if (row.focus !== undefined && row.focus !== null && Number(row.focus) !== 50) {
    parts.push('y' + Math.round(Number(row.focus)));
  }
  return parts.length ? base + PHOTO_TAG + parts.join('.') : base;
}

// The other direction. Tolerant on purpose: an unknown letter is ignored rather than throwing,
// because this string travels through other people's databases and comes back years later.
function photoDecode(url) {
  const text = String(url || '');
  const at = text.indexOf(PHOTO_TAG);
  if (at === -1) return { url: text, filter: '', crop: '', focus: 50 };
  const out = { url: text.slice(0, at), filter: '', crop: '', focus: 50 };
  text.slice(at + PHOTO_TAG.length).split('.').forEach((token) => {
    const value = token.slice(1);
    if (token[0] === 'f') out.filter = value.replace(/[^a-z0-9_-]/gi, '').slice(0, 20);
    else if (token[0] === 'c') out.crop = ['portrait', 'square', 'tall'].includes(value) ? value : '';
    else if (token[0] === 'y') out.focus = Math.max(0, Math.min(100, Number(value) || 50));
  });
  return out;
}

// A row, whether it arrived as a row or as a URL carrying its own recipe.
function photoRow(v) {
  if (typeof v === 'string') {
    const r = photoDecode(v);
    return { url: r.url, album: '', filter: r.filter, crop: r.crop, focus: r.focus };
  }
  if (!v) return {};
  // A row whose url carries a recipe: the row's own fields win, since they are the live ones.
  if (typeof v.url === 'string' && v.url.indexOf(PHOTO_TAG) !== -1) {
    const r = photoDecode(v.url);
    return Object.assign({}, v, {
      url: r.url,
      filter: v.filter || r.filter,
      crop: v.crop || r.crop,
      focus: (v.focus === undefined || v.focus === null) ? r.focus : v.focus,
    });
  }
  return v;
}

// An <img> that honours the recipe, for the places that use a real element rather than a
// background: a post, a message bubble. Same output as `photoStyle` produces for a background.
function photoImg(value, cls) {
  const r = photoRow(value);
  const ratio = { portrait: '4 / 5', square: '1 / 1', tall: '9 / 16' }[r.crop || ''] || '';
  const style = 'filter:' + filterCss(r.filter)
    + (ratio ? ';aspect-ratio:' + ratio + ';object-fit:cover;object-position:50% '
      + focusOf(r.focus) + '%' : '');
  return '<img class="' + esc(cls || '') + '" src="' + esc(r.url)
    + '" style="' + style + '" alt="" />';
}
function inlineBackground(url) {
  const clean = Array.from(String(url || '')).filter((char) => {
    const code = char.charCodeAt(0);
    return code >= 32 && code !== 127;
  }).join('');
  const safe = clean
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"');
  return 'background-image:url(&quot;' + esc(safe) + '&quot;)';
}
function photoStyle(v) {
  const r = photoRow(v);
  // The grid stays square, as a photo grid does, but it shows the band the player framed
  // rather than the middle of the picture.
  return inlineBackground(r.url) + ';filter:' + filterCss(r.filter) +
    ';background-position:50% ' + focusOf(r.focus) + '%';
}

// The shared picker: any composer can ask for a photo from the phone rather than making
// the player paste a link they do not have.
function pickPhoto(onPick) {
  const host = byId('sheet');
  const sourceOpen = host.classList.contains('on');
  const sourceNode = host.firstChild;
  post('photos', { op: 'list' }).then((d) => {
    if (sourceOpen
      ? (!host.classList.contains('on') || host.firstChild !== sourceNode)
      : host.classList.contains('on')) return;
    const shots = (d && d.photos) || [];
    if (!shots.length) { toast(L('ph.no_photos')); return; }
    // A picker may be raised from a composer sheet. Detach that sheet instead of
    // destroying it, so its fields and listeners are intact when a photo is chosen.
    const restore = host.classList.contains('on') ? document.createDocumentFragment() : null;
    if (restore) while (host.firstChild) restore.appendChild(host.firstChild);
    const restoreComposer = restore ? () => {
      sheetEpoch += 1;
      sheetReturn = null;
      emojiClose();
      host.replaceChildren(restore);
      host.classList.add('on');
      byId('scrim').classList.add('on');
    } : null;
    sheet(L('ph.pick_photo'),
      '<div class="shots">' + shots.map((v, i) =>
        '<div class="shot" data-i="' + i + '" style="' + photoStyle(v) + '"></div>').join('') + '</div>',
      () => [...byId('sheet').querySelectorAll('.shot')].forEach((el) => el.addEventListener('click', () => {
        const r = photoRow(shots[Number(el.dataset.i)]);
        if (restoreComposer) restoreComposer();
        else closeSheet();
        // The URL carries the edit. Every caller stores a URL and nothing else, which is why
        // the edit used to be lost the moment a photo left the Gallery.
        onPick(photoEncode(r.url, r), r);
      })));
    sheetReturn = restoreComposer;
  });
}

// Forwarding a message: the same text, sent on to somebody else. Picked from contacts,
// or typed, because the person you want may not be in the book.
function forwardSms(m) {
  const all = state.contacts || [];
  sheet(L('ph.forward'),
    '<div class="mailbody">' + esc(m.body || L('ph.attach')) + '</div>' +
    UI.field('fwdnum', L('ph.number'), '', 'maxlength="20"') +
    UI.button(L('ph.send'), 'fwdgo', 'tinted') +
    (all.length ? UI.group(all.map((c) => UI.row({
      avatar: c.name, title: c.name, subtitle: maskNum(c.number), data: { n: c.number },
    })), { header: L('app.contacts') }) : ''),
    () => {
      const go = async (number) => {
        if (!number) return;
        const epoch = sheetEpoch;
        const r = await post('send', { number, body: m.body || '', kind: m.kind || 'text',
                                       attachment: m.attachment || '' });
        if (!closeSheet(false, epoch)) return;
        toast(r && r.ok ? L('ph.forwarded') : L('ph.err_' + ((r && r.error) || 'x')));
      };
      byId('fwdgo').addEventListener('click', () => go(byId('fwdnum').value.trim()));
      [...byId('sheet').querySelectorAll('.row')].forEach((el) =>
        el.addEventListener('click', () => go(el.dataset.n)));
    });
}

function messageActions(m) {
  const value = String((m && (m.body || m.attachment)) || '');
  sheet(L('ph.message_actions'),
    '<div class="msgactionpreview">' + bubbleHtml(Object.assign({}, m, { mine: false })) + '</div>' +
    '<div class="msgactiongrid">' +
      UI.button(L('ph.copy'), 'msgcopy', 'plain') +
      UI.button(L('ph.forward'), 'msgforward', 'tinted') +
    '</div>' +
    '<div class="sheethint">' + esc(L('ph.message_actions_hint')) + '</div>',
    () => {
      byId('msgcopy').addEventListener('click', () => {
        closeSheet();
        if (value) copyText(value);
      });
      byId('msgforward').addEventListener('click', () => {
        closeSheet();
        requestAnimationFrame(() => forwardSms(m));
      });
    },
    'message-actions');
}

// ── Voicemail ──────────────────────────────────────────────────
// A missed call leaves a written message rather than a recording: nothing here can hold
// audio, and a note you can actually read beats a fake tape.
function renderVoicemail() {
  if (!openApp || openApp.id !== 'phone' || phoneTab !== 'voicemail') return;
  beginView();
  body('<div id="vmlist">' + UI.empty(L('ph.loading'), 'phone') + '</div>');
  post('voicemail', { op: 'list' }).then((r) => {
    const host = byId('vmlist');
    if (!host) return;
    const list = (r && r.voicemail) || [];
    if (!list.length) { host.innerHTML = UI.empty(L('ph.no_voicemail'), 'phone'); return; }
    host.innerHTML = UI.group(list.map((v) => UI.row({
      icon: 'voicemail', tint: Number(v.seen) ? '#8E8E93' : '#0A84FF',
      title: v.number ? nameOfNumber(v.number) : L('ph.unknown'),
      subtitle: shortWhen(v.at),
      badge: Number(v.seen) ? undefined : L('ph.vm_new_short'),
      chevron: true, data: { id: v.id },
    })));
    qrows('vmlist', '.row', (el) => el.addEventListener('click', () => {
      const v = list.find((x) => String(x.id) === el.dataset.id);
      if (v) voicemailSheet(v);
    }));
    // Opening the list is hearing them: the unread mark is gone from here on.
    if (list.some((v) => !Number(v.seen))) {
      post('voicemail', { op: 'seen' }).then(() => { state.vmUnread = 0; });
    }
  });
}

function voicemailSheet(v) {
  const who = v.number ? nameOfNumber(v.number) : L('ph.unknown');
  sheet(who,
    '<div class="vmbody">' + esc(v.body || '') + '</div>' +
    '<div class="vmwhen">' + esc(shortWhen(v.at)) + '</div>' +
    (v.number ? UI.button(L('ph.call'), 'vmcall', 'tinted') : '') +
    UI.button(L('ph.delete'), 'vmdel', 'destructive'),
    () => {
      const c = byId('vmcall');
      if (c) c.addEventListener('click', () => { closeSheet(); placeCall(v.number); });
      byId('vmdel').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        await post('voicemail', { op: 'del', id: v.id });
        if (closeSheet(false, epoch)) renderVoicemail();
      });
    });
}

// Offered to the CALLER when nobody picked up.
function voicemailOffer(number) {
  sheet(L('ph.vm_leave'),
    '<div class="groupfoot">' + esc(L('ph.vm_leave_hint')) + ' ' + esc(nameOfNumber(number)) + '</div>' +
    UI.field('vmtext', L('ph.vm_placeholder'), '', 'maxlength="200"') +
    UI.button(L('ph.vm_send'), 'vmgo', 'tinted'),
    () => byId('vmgo').addEventListener('click', async () => {
      const txt = byId('vmtext').value.trim();
      if (!txt) return;
      closeSheet();
      const r = await post('voicemail', { op: 'leave', number, body: txt });
      toast(r && r.ok ? L('ph.vm_sent') : L('ph.err_' + ((r && r.error) || 'x')));
    }));
}

// ── Messages ───────────────────────────────────────────────────
// How far away, in words. The server rounds to ten metres and sends nil for somebody who is
// not connected, so this only ever formats a number it was actually given.
function hushDistanceText(metres) {
  const m = Number(metres) || 0;
  if (m < 100) return L('ph.hush_very_close');
  if (m < 1000) return L('ph.hush_metres').replace('{n}', String(m));
  return L('ph.hush_km').replace('{n}', (m / 1000).toFixed(1));
}

// ══ Emergency alert ════════════════════════════════════════════
// The one thing on this phone that is meant to be alarming. Full-screen, loud, and it has to be
// dismissed rather than fading on its own - a warning that disappears while somebody is reading
// it is a warning they did not get.
let emergencyOpen = false;

function emergencyAlert(a) {
  a = a || {};

  // A notification, not a takeover.
  //
  // This drew a card over the entire screen, and a screen-filling warning triangle is a lot of
  // screen for something a phone announces. What an alert has to do is be impossible to miss -
  // which is the buzz and the sound below, not the square footage. The full-screen card is
  // still here for a server that wants it, behind `Config.Admin.emergencyFullScreen`.
  //
  // It goes into the notification centre through the ordinary path, so it can be read again
  // later, muted per app like anything else, and tapped to open the app it came from.
  const kind = a.kind || L('ph.emergency_default');
  banner({
    app: 'settings',
    icon: 'warning',
    title: kind,
    body: [a.title, a.body].filter(Boolean).join(' - '),
  });

  if (a.fullScreen) {
    const host = byId('emergency');
    if (host) {
      host.innerHTML =
        '<div class="emergencycard">' +
          '<div class="emergencyicon">' + svg('warning') + '</div>' +
          '<div class="emergencykind">' + esc(kind) + '</div>' +
          '<div class="emergencytitle">' + esc(a.title || '') + '</div>' +
          (a.body ? '<div class="emergencybody">' + esc(a.body) + '</div>' : '') +
          UI.button(L('ph.emergency_ack'), 'emok', 'tinted') +
        '</div>';
      host.classList.add('on');
      emergencyOpen = true;

      byId('emok').addEventListener('click', () => {
        host.classList.remove('on');
        host.innerHTML = '';
        emergencyOpen = false;
      });
    }
  }

  // **Louder than anything else, and it ignores the volume preference.**
  //
  // `ui()` returns immediately when the player has set their ring volume to zero, which is
  // right for every other sound and wrong for this one: a silenced phone still sounds an
  // emergency alert on a real handset, and a staff broadcast that a muted player never hears
  // is a broadcast that did not happen. So this plays the file directly rather than going
  // through `ui()`, at full volume, with the synthesised score as the fallback.
  const src = soundUrl('ui', 'emergency');
  let played = false;
  if (src) {
    try {
      const el = new Audio(src);
      el.volume = 1;
      el.play().catch(() => {});
      played = true;
    } catch { /* fall through to the oscillators */ }
  }
  // `note()` is the oscillator primitive the rest of the sound code uses. Louder here than
  // anywhere else: 0.045 is the gain every other tone gets.
  if (!played) UI_TONES.emergency.forEach(([f, t, d]) => note(f, t, d, 0.14, 'square'));
}

// ══ Streamer mode ══════════════════════════════════════════════
// A phone number on screen is a phone number in the stream, and viewers use those to call, to
// text and to pretend to be somebody. This masks them wherever they are DISPLAYED.
//
// Display only, deliberately. Nothing is hidden from the server, calls and messages work
// exactly as before, and a copy still yields the real number - the problem being solved is
// what sits on camera, not what the phone knows.
// ══ Asking for the strings ═════════════════════════════════════
// The client sends the string table with every `open`, which is right and is not enough: this
// page can be drawn before an `open` ever arrives - a payphone panel, an incoming call, a
// notification banner - and a message sent to a page that has not finished loading is dropped
// silently by NUI, with no error anywhere. That is what "restart the resource and it works"
// means: the restart reloads the page and re-sends.
//
// So the page asks. On load, and again if it ever finds itself rendering with nothing.
let strungAt = 0;
async function requestStrings() {
  // Once every two seconds at most: `L` calls this on a miss, and a view full of misses would
  // otherwise ask once per label.
  const now = Date.now();
  if (now - strungAt < 2000) return;
  strungAt = now;
  const r = await post('strings');
  if (r && r.strings && Object.keys(r.strings).length) {
    S = r.strings;
    warnedNoStrings = false;
    if (r.locale) state.locale = r.locale;
    // Repaint whatever is on screen, or the labels drawn before the table arrived stay wrong.
    if (openApp && RENDER[openApp.id]) RENDER[openApp.id]();
    else if (typeof paintLockMeta === 'function') paintLockMeta();
  }
}

// As early as the page can ask. `post` needs nothing but the resource name, which is available
// from the first line of this file.
requestStrings();

// ══ Reading a number ═══════════════════════════════════════════
// A number minted as `##########` is stored as `4155550142`, and that is right - it is what
// every script reading it gets. But ten digits in a row is not something a person can read
// back over voice, so a separator goes in for the eye only.
//
// Nothing here touches the stored value. The clipboard, the dialler, the outgoing call and
// every export still carry the real number; this is the last step before text reaches a screen.
function groupNum(value) {
  const nd = state.numberDisplay || {};
  const every = Math.floor(Number(nd.every) || 0);
  const text = String(value == null ? '' : value);
  // Under two would put a separator between every character, which is not grouping.
  if (every < 2 || !text) return text;

  const sep = String(nd.separator == null ? '-' : nd.separator);
  const plain = /^[0-9A-Za-z]+$/.test(text);
  if (!plain) {
    // The operator already chose what this number looks like - `555-####` means `555-0142`,
    // and regrouping that gives `555--01-42`. Leave it, unless told to regroup regardless.
    if (nd.onlyWhenPlain !== false) return text;
  }
  const bare = plain ? text : text.replace(/[^0-9A-Za-z]/g, '');
  if (bare.length <= every) return bare;

  const parts = [];
  for (let i = 0; i < bare.length; i += every) parts.push(bare.slice(i, i + every));
  // A trailing group of one reads as a mistake rather than as a convention, so it joins the
  // group before it: ten digits at three give 415-555-0142, not 415-555-014-2.
  if (parts.length > 1 && parts[parts.length - 1].length === 1) {
    parts[parts.length - 2] += parts.pop();
  }
  return parts.join(sep);
}

// Your own number, ready for a screen: grouped, then masked if streamer mode is on. Grouped
// FIRST so the bullets keep the shape - `•••-•••-••••` still reads as a phone number, which is
// the whole point of masking rather than blanking.
function myNum(value) {
  return maskNum(groupNum(value));
}

// Any number the phone draws. Grouping applies here only when the operator asked for `all`;
// `own` is the default, because a contact's number is text somebody typed and regrouping it
// would silently disagree with what they entered.
function anyNum(value) {
  const nd = state.numberDisplay || {};
  return maskNum(nd.scope === 'all' ? groupNum(value) : value);
}

function maskNum(value) {
  const text = String(value == null ? '' : value);
  if (!text || !(state.prefs || {}).streamer) return text;
  // The digits go, the shape stays: a masked number still reads as a number rather than as a
  // blob, so a layout built around one does not jump.
  return text.replace(/\d/g, '•');
}

function nameOfNumber(number) {
  const c = (state.contacts || []).find((x) => x.number === number);
  // A contact's NAME is not masked: "Bob" is not a phone number, and hiding it would make the
  // phone unusable on stream rather than safer. Only the bare number is.
  return c ? c.name : (anyNum(number) || L('ph.unknown'));
}

RENDER.messages = async () => {
  threadGroup = null;
  setNav(L('app.messages'), null, { icon: 'add', onClick: newMessageSheet });

  // Re-read before drawing. `state.conversations` is a snapshot taken when the phone was
  // OPENED, so anything that arrived since - a text from another player, a verification code
  // from one of the apps - was simply not in the list. Opening Messages and seeing nothing
  // new while the message sat in the database is what that looked like.
  const epoch = viewEpoch;
  await refresh();
  if (epoch !== viewEpoch || !openApp || openApp.id !== 'messages') return;

  const list = state.conversations || [];
  const groups = state.groups || [];
  if (!list.length && !groups.length) { body(UI.empty(L('ph.no_messages'), 'messages')); return; }
  body(
    (groups.length ? UI.group(groups.map((g) => UI.row({
      icon: 'contacts', tint: '#34C759', title: g.name, chevron: true, data: { g: g.id, gn: g.name },
    })), { header: L('ph.groups') }) : '') +
    (list.length ? UI.group(list.map((c) => {
      // A service thread - a verification code, a receipt - has no citizen behind it, so it
      // is addressed by name and opened by its own key. Passing its label through
      // nameOfNumber would try to resolve "Bleeter" as a phone number and come back empty.
      const title = c.service ? (c.name || c.number) : nameOfNumber(c.number);
      return UI.row({
        avatar: title, title, subtitle: c.body,
        badge: c.unread > 0 ? c.unread : null, chevron: true,
        data: { n: c.service ? c.other : c.number },
      });
    // A gesture nobody is told about is a gesture nobody uses: the long press to delete a
    // conversation has been here all along and was reported as missing.
    }), { footer: L('ph.thread_delete_hint') }) : '')
  );
  rows('.row[data-n]', (r) => r.addEventListener('click', () => openThread(r.dataset.n)));
  // Press and hold a thread to delete it. A swipe would be more iOS, but a long press is
  // the one gesture that cannot be confused with scrolling the list.
  rows('.row[data-n]', (r) => {
    let timer = null;
    const cancel = () => { clearTimeout(timer); timer = null; };
    r.addEventListener('pointerdown', () => {
      timer = setTimeout(() => {
        timer = null;
        const key = r.dataset.n;
        confirmSheet(L('ph.thread_delete'), L('ph.delete'), async () => {
          const res = await post('threadDelete', { other: key });
          if (res && res.ok) { await refresh(); RENDER.messages(); }
        });
      }, 550);
    });
    ['pointerup', 'pointerleave', 'pointercancel'].forEach((e) => r.addEventListener(e, cancel));
  });
  rows('.row[data-g]', (r) => r.addEventListener('click', () =>
    openGroup(Number(r.dataset.g), r.dataset.gn)));
};

async function openGroup(id, name) {
  if (!openApp || openApp.id !== 'messages') return;
  beginView();
  thread = null;
  threadGroup = { id, name };
  setNav(name, L('app.messages'), null, () => {
    threadGroup = null;
    foot('');
    RENDER.messages();
  });
  loading();
  const res = await post('conversation', { group: id });
  if (!res || res.error) { body(UI.empty(L('ph.err_' + ((res && res.error) || 'x')))); return; }
  paintThread(res.messages || []);
}

// Write to a number from ANYWHERE: a contact card, a notification, another app.
//
// `openThread` opens with a guard that returns unless the Messages app is the open one -
// correct, since it draws into that app's body and has nowhere to draw otherwise. But it meant
// every caller outside Messages did nothing at all, which is exactly what "I press Message on a
// contact and nothing happens" was. Two callers entered the app first by hand; the rest did not,
// and nothing told them they had to.
function messageTo(number, draft) {
  const to = String(number || '').trim();
  if (!to) return;
  if (!openApp || openApp.id !== 'messages') {
    const app = (state.apps || []).find((a) => a.id === 'messages');
    if (!app) { toast(L('ph.err_notinstalled')); return; }
    enterApp(app, null);
  }
  openThread(to, draft);
}

async function openThread(number, draft) {
  if (!openApp || openApp.id !== 'messages') return;
  beginView();
  thread = number;
  threadGroup = null;
  // A service thread is opened by its `svc:Label` key rather than by a number. Show the
  // label, and offer no call button: there is nobody on the other end to ring.
  const isService = String(number || '').slice(0, 4) === 'svc:';
  setNav(isService ? String(number).slice(4) : nameOfNumber(number), L('app.messages'),
    isService ? null : { icon: 'phone', onClick: () => placeCall(number) },
  () => {
    thread = null;
    foot('');
    RENDER.messages();
  });
  loading();
  const res = await post('conversation', { number });
  if (!res || res.error) { body(UI.empty(L('ph.err_' + ((res && res.error) || 'x')))); return; }
  paintThread(res.messages || [], res.service === true || isService);
  if (draft && byId('msg')) byId('msg').value = String(draft).slice(0, 250);
  pushAnim();
  // Match on `other` as well: a service row's `number` is its label, while the key used to
  // open it is `svc:Label`, so matching on number alone never cleared the badge.
  const c = (state.conversations || []).find((x) => x.number === number || x.other === number);
  if (c) c.unread = 0;
}

function bubbleHtml(m) {
  let inner;
  if (m.kind === 'image') {
    inner = photoImg(m.attachment, 'mimg') +
      (m.body ? '<div class="mcap">' + esc(m.body) + '</div>' : '');
  } else if (m.kind === 'location') {
    // A shared position opens in Maps, which here means: it sets your waypoint.
    inner = '<button class="locbtn" type="button" data-loc="' + esc(m.attachment) + '">' +
      svg('map') + esc(L('ph.msg_location')) + '</button>';
  } else {
    inner = esc(m.body);
  }
  const sender = (!m.mine && threadGroup && m.from)
    ? '<div class="gsender">' + esc(nameOfNumber(m.from)) + '</div>' : '';
  // Copying a code out of a message is the one action anybody ever takes on one, so it gets
  // a button rather than a long press. Incoming only: there is no point offering to copy a
  // code back out of something you sent yourself.
  const code = (!m.mine && m.kind !== 'image') ? codeInText(m.body) : null;
  const copy = code
    ? '<button class="codecopy" type="button" data-code="' + esc(code) + '">' +
        svg('copy') + esc(L('ph.copy_code')) + '</button>'
    : '';
  return sender + '<div class="bub ' + (m.mine ? 'me' : 'them') +
    (m.kind === 'image' ? ' imgb' : '') + '">' + inner + '</div>' + copy;
}

function wireLocButtons() {
  rows('.locbtn', (b) => b.addEventListener('click', async () => {
    const parts = String(b.dataset.loc || '').split(';');
    const r = await post('waypoint', { x: Number(parts[0]), y: Number(parts[1]) });
    if (r && r.ok) toast(L('ph.waypoint_set'));
  }));
}

function paintThread(messages, service) {
  body(`<div class="thread" id="thread">${messages.map(bubbleHtml).join('')}</div>`);
  wireLocButtons();
  rows('.codecopy', (b) => b.addEventListener('click', (e) => {
    e.stopPropagation();
    copyText(b.dataset.code, L('ph.code_copied'));
  }));
  // A tap remains a tap. Message actions use the familiar mobile long-press gesture,
  // with a short horizontal swipe as a faster alternative.
  [...byId('thread').querySelectorAll('.bub')].forEach((b, i) => {
    let hold = 0, sx = 0, sy = 0, active = false, opened = false;
    const cancelHold = () => { if (hold) clearTimeout(hold); hold = 0; };
    b.addEventListener('pointerdown', (e) => {
      if (e.target.closest('button') || e.target.closest('.locbtn')) return;
      sx = e.clientX;
      sy = e.clientY;
      active = true;
      opened = false;
      b.classList.add('pressing');
      hold = setTimeout(() => {
        if (!active) return;
        opened = true;
        b.classList.remove('pressing');
        messageActions(messages[i]);
      }, 440);
    });
    b.addEventListener('pointermove', (e) => {
      if (!active) return;
      const dx = e.clientX - sx;
      const dy = e.clientY - sy;
      b.style.setProperty('--msg-drag', Math.max(-8, Math.min(34, dx * .26)) + 'px');
      if (Math.abs(dx) > 11 || Math.abs(dy) > 11) cancelHold();
    });
    b.addEventListener('pointerup', (e) => {
      if (!active) return;
      const dx = e.clientX - sx;
      const dy = e.clientY - sy;
      active = false;
      cancelHold();
      b.classList.remove('pressing');
      b.style.removeProperty('--msg-drag');
      if (!opened && dx > 52 && Math.abs(dy) < 28) messageActions(messages[i]);
    });
    b.addEventListener('pointercancel', () => {
      active = false;
      cancelHold();
      b.classList.remove('pressing');
      b.style.removeProperty('--msg-drag');
    });
  });
  // No composer on a service thread. `svc:Bleeter` is not a line anybody answers, and a
  // send box that can only fail is worse than no send box.
  if (service) { foot(''); return; }
  foot(`<div class="compose">` +
    `<button class="attach" id="attach" type="button" aria-label="${esc(L('ph.attach'))}">+</button>` +
    `<button class="emoji" id="msgemoji" type="button" aria-label="${esc(L('ph.emoji'))}">😊</button>` +
    UI.field('msg', L('ph.write'), '', 'maxlength="250"') +
    `<button class="sendbtn" id="sendmsg" type="button" aria-label="${esc(L('ph.send'))}">${svg('send')}</button></div>`);
  byId('attach').addEventListener('click', () => attachSheet());
  byId('msgemoji').addEventListener('click', () => emojiOpen('msg'));
  byId('msg').addEventListener('focus', emojiClose);
  const el = byId('thread');
  el.scrollTop = el.scrollHeight;
  byId('appbody').scrollTop = byId('appbody').scrollHeight;

  const target = () => threadGroup ? { group: threadGroup.id } : { number: thread };
  const send = async () => {
    const input = byId('msg');
    const text = input.value.trim();
    if (!text) return;
    input.value = '';
    const res = await post('send', Object.assign({ body: text }, target()));
    if (res && res.ok) {
      el.insertAdjacentHTML('beforeend', bubbleHtml({ mine: true, body: res.body, kind: res.kind, attachment: res.attachment }));
      ui('sent');
      byId('appbody').scrollTop = byId('appbody').scrollHeight;
    } else {
      ui('error');
      toast(L('ph.err_' + ((res && res.error) || 'x')));
    }
  };

  // Anything that is not typed: a photo from the gallery, an image or GIF by link, or
  // where you are standing. All of it lands as a message like any other.
  window.attachSheet = () => {
    const shots = state.photos || [];
    sheet(L('ph.attach'),
      (shots.length
        ? '<div class="grouphead">' + esc(L('ph.attach_photo')) + '</div>' +
          '<div class="shots" style="margin-bottom:12px">' + shots.map((v, i) =>
            '<div class="shot" data-i="' + i + '" style="' + photoStyle(v) + '"></div>').join('') + '</div>'
        : '') +
      UI.button(L('ph.pick_photo'), 'atpick', 'plain') +
      UI.field('aturl', L('ph.attach_url'), '', 'maxlength="300"') +
      UI.button(L('ph.attach_send'), 'atgo') +
      UI.button(L('ph.attach_loc'), 'atloc', 'plain'),
      () => {
        const sendMedia = async (payload) => {
          const epoch = sheetEpoch;
          const res = await post('send', Object.assign(payload, target()));
          if (!closeSheet(false, epoch)) return;
          if (res && res.ok) {
            el.insertAdjacentHTML('beforeend', bubbleHtml({ mine: true, body: res.body, kind: res.kind, attachment: res.attachment }));
            wireLocButtons();
            byId('appbody').scrollTop = byId('appbody').scrollHeight;
          } else toast(L('ph.err_' + ((res && res.error) || 'x')));
        };
        [...byId('sheet').querySelectorAll('.shot')].forEach((sh) =>
          sh.addEventListener('click', () => sendMedia({
            kind: 'image', attachment: photoRow(shots[Number(sh.dataset.i)]).url, body: '',
          })));
        byId('atpick').addEventListener('click', () =>
          pickPhoto((url) => sendMedia({ body: '', kind: 'image', attachment: url })));
        byId('atgo').addEventListener('click', () => {
          const u = byId('aturl').value.trim();
          if (u) sendMedia({ kind: 'image', attachment: u, body: '' });
        });
        byId('atloc').addEventListener('click', async () => {
          const epoch = sheetEpoch;
          const res = await post('sendloc', target());
          if (!closeSheet(false, epoch)) return;
          if (res && res.ok) {
            el.insertAdjacentHTML('beforeend', bubbleHtml({ mine: true, kind: 'location', attachment: res.attachment || '0;0', body: '' }));
            wireLocButtons();
            byId('appbody').scrollTop = byId('appbody').scrollHeight;
          } else toast(L('ph.err_' + ((res && res.error) || 'x')));
        });
      });
  };
  byId('sendmsg').addEventListener('click', send);
  byId('msg').addEventListener('keydown', (e) => { if (e.key === 'Enter') send(); });
}

function newMessageSheet() {
  // The contact book, not only a number field.
  //
  // Typing a number was the one way in, which is the wrong way round: the people somebody writes
  // to are almost always already in their contacts, and reading a number off one screen to type
  // it into another is the small daily annoyance a phone exists to remove. The field stays, for
  // the number that is not in the book yet.
  const picks = (state.contacts || []).filter((c) => c && c.number);
  sheet(L('ph.new_message_to'),
    UI.field('nmnum', L('ph.number')) + UI.button(L('ph.write'), 'nmgo') +
    (picks.length
      ? UI.group(picks.map((c) => UI.row({
          avatar: c.name, title: c.name, subtitle: maskNum(c.number),
          chevron: true, data: { n: c.number },
        })), { header: L('app.contacts') })
      : '<div class="groupfoot">' + esc(L('ph.no_contacts')) + '</div>') +
    UI.button(L('ph.new_group'), 'nggo', 'plain'),
    () => {
      const epoch = sheetEpoch;
      byId('nmgo').addEventListener('click', () => {
        const n = byId('nmnum').value.trim();
        if (!closeSheet(false, epoch)) return;
        if (n) messageTo(n);
      });
      [...byId('sheet').querySelectorAll('.row[data-n]')].forEach((r) =>
        r.addEventListener('click', () => {
          const n = r.dataset.n;
          if (!closeSheet(false, epoch)) return;
          messageTo(n);
        }));
      byId('nggo').addEventListener('click', newGroupSheet);
    });
}

// A group is a name and some contacts. Every number must be somebody real - the server
// refuses ghosts - and you are a member by construction.
function newGroupSheet() {
  const contacts = state.contacts || [];
  sheet(L('ph.new_group'),
    UI.field('gname', L('ph.group_name'), '', 'maxlength="40"') +
    (contacts.length
      ? contacts.map((c) => '<label class="gpick"><input type="checkbox" value="' + esc(c.number) + '" />' +
          esc(c.name) + '</label>').join('')
      : UI.empty(L('ph.no_contacts'))) +
    UI.button(L('ph.group_make'), 'ggo'),
    () => byId('ggo').addEventListener('click', async () => {
      const numbers = [...byId('sheet').querySelectorAll('input:checked')].map((i) => i.value);
      const name = byId('gname').value.trim();
      const epoch = sheetEpoch;
      const r = await post('groupCreate', { name, numbers });
      if (!closeSheet(false, epoch)) return;
      if (r && r.ok) { await refresh(); RENDER.messages(); openGroup(r.id, r.name); }
      else toast(L('ph.err_' + ((r && r.error) || 'x')));
    }));
}

// ── Contacts ───────────────────────────────────────────────────
RENDER.contacts = () => {
  setNav(L('app.contacts'), null, { icon: 'add', onClick: () => contactSheet({}) });
  const all = state.contacts || [];
  const draw = (q) => {
    const list = q ? all.filter((c) => (c.name + ' ' + c.number).toLowerCase().includes(q)) : all;
    byId('clist').innerHTML = list.length
      ? UI.group(list.map((c) => UI.row({
          avatar: c.name, title: c.name, subtitle: maskNum(c.number), chevron: true,
          value: c.system ? L('ph.required_contact') : '',
          data: { id: c.id, n: c.number },
        })))
      : UI.empty(L('ph.no_contacts'), 'contacts');
    wire();
  };
  const wire = () => rows('.row', (r) => r.addEventListener('click', () => {
    const c = (state.contacts || []).find((x) => String(x.id) === r.dataset.id);
    if (c) contactSheet(c);
  }));
  body(searchHtml(L('ph.search_contacts')) +
    UI.group([UI.row({ icon: 'airdrop', tint: '#0A84FF', title: L('ph.share_my_number'),
      subtitle: myNum(state.number), chevron: true, data: { me: '1' } })]) +
    '<div id="clist"></div>');
  rows('.row', (r) => { if (r.dataset.me) r.addEventListener('click',
    // No name sent: the SERVER labels this one, from the name the player typed during setup.
    // Sending one here would be a value the server ignores, which is worse than sending none.
    () => airdropShare('number', { number: state.number })); });
  draw('');
  onSearch(draw);
};

function contactSheet(c) {
  if (c.system) {
    const details = [
      UI.row({ icon: 'phone', tint: '#34C759', title: L('ph.number'), value: maskNum(c.number) }),
      c.email ? UI.row({ icon: 'mail', tint: '#0A84FF', title: L('ph.c_email'), value: c.email,
                         chevron: true, data: { mailto: c.email } }) : '',
      c.address ? UI.row({ icon: 'map', tint: '#FF9500', title: L('ph.c_address'), subtitle: c.address }) : '',
      c.note ? UI.row({ icon: 'note', tint: '#8E8E93', title: L('ph.c_note'), subtitle: c.note }) : '',
    ].filter(Boolean);
    sheet(c.name,
      '<div class="requiredcontact">' +
        '<span class="requiredavatar">' + esc(String(c.name || '?').trim().charAt(0).toUpperCase()) + '</span>' +
        '<strong>' + esc(c.name) + '</strong>' +
        '<small>' + svg('lockshut') + esc(L('ph.required_contact_hint')) + '</small>' +
      '</div>' +
      UI.group(details) +
      UI.button(L('ph.call'), 'ccall', 'tinted') +
      UI.button(L('ph.facetime'), 'cface', 'plain') +
      UI.button(L('ph.message'), 'cmsg', 'plain') +
      UI.button(L('ph.airdrop_share'), 'cshare', 'plain'),
      () => {
        byId('ccall').addEventListener('click', () => { closeSheet(); placeCall(c.number); });
        byId('cface').addEventListener('click', () => { closeSheet(); placeCall(c.number, { video: true }); });
        byId('cmsg').addEventListener('click', () => { closeSheet(); messageTo(c.number); });
        byId('cshare').addEventListener('click', () =>
          airdropShare('contact', { name: c.name, number: c.number }));
        wireMailto();
      });
    return;
  }
  const isNew = !c.id;
  sheet(isNew ? L('ph.new_contact') : c.name,
    // The card, not just a name and a number: a face, a way to write, where they are,
    // when it is their birthday, and whatever you needed to remember about them.
    (c.photo ? '<div class="cardphoto" style="' + inlineBackground(c.photo) + '"></div>' : '') +
    UI.field('cname', L('ph.name'), c.name, 'maxlength="40"') +
    UI.field('cnum', L('ph.number'), c.number, 'maxlength="20"') +
    UI.field('cphoto', L('ph.c_photo'), c.photo || '', 'maxlength="400"') +
    UI.field('cmail_field', L('ph.c_email'), c.email || '', 'maxlength="64"') +
    UI.field('caddr', L('ph.c_address'), c.address || '', 'maxlength="120"') +
    UI.field('cbday', L('ph.c_birthday'), c.birthday || '', 'maxlength="20"') +
    UI.field('cnote', L('ph.c_note'), c.note || '', 'maxlength="300"') +
    UI.button(L('ph.pick_photo'), 'cpick', 'plain') +
    UI.button(L('ph.save'), 'csave') +
    (isNew ? '' : UI.button(L('ph.call'), 'ccall', 'tinted')) +
    (isNew ? '' : UI.button(L('ph.message'), 'cmsg', 'plain')) +
    // Writing to them is only offered when there is an address to write to. A button that
    // opens an empty composer would be a worse answer than no button.
    ((isNew || !c.email) ? '' : UI.button(L('ph.c_email_send'), 'cmail', 'plain')) +
    (isNew ? '' : UI.button(L('ph.airdrop_share'), 'cshare', 'plain')) +
    (isNew ? '' : UI.button(L('ph.delete'), 'cdel', 'destructive')),
    () => {
      byId('cpick').addEventListener('click', () => pickPhoto((url) => { byId('cphoto').value = url; }));
      byId('csave').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        const payload = { id: c.id, name: byId('cname').value, number: byId('cnum').value,
          photo: byId('cphoto').value.trim(), email: byId('cmail_field').value.trim(),
          address: byId('caddr').value.trim(), birthday: byId('cbday').value.trim(),
          note: byId('cnote').value.trim() };
        const res = await post('contactSave', payload);
        if (res && res.ok) {
          if (closeSheet(false, epoch)) { await refresh(); RENDER.contacts(); }
        } else toast(L('ph.err_' + ((res && res.error) || 'x')));
      });
      if (isNew) return;
      byId('ccall').addEventListener('click', () => { closeSheet(); placeCall(c.number); });
      byId('cshare').addEventListener('click', () => airdropShare('contact', { name: c.name, number: c.number }));
      byId('cmsg').addEventListener('click', () => { closeSheet(); messageTo(c.number); });
      // The address as it stands in the field, not as it was when the sheet opened: somebody
      // who has just typed one expects the button to use it.
      if (byId('cmail')) byId('cmail').addEventListener('click', () => {
        const to = (byId('cmail_field') && byId('cmail_field').value.trim()) || c.email || '';
        closeSheet();
        mailTo(to);
      });
      byId('cdel').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        await post('contactDelete', { id: c.id });
        if (closeSheet(false, epoch)) { await refresh(); RENDER.contacts(); }
      });
    });
}

// Write to an address from anywhere: a contact card, a tapped row.
//
// The Mail app has to be OPEN before its composer can draw, and it needs an account of its own
// first - so a player with no address is sent to the sign-up rather than to a composer that
// could not send anything.
async function mailTo(address) {
  const to = String(address || '').trim();
  if (!to) { toast(L('ph.c_email_none')); return; }
  const app = (state.apps || []).find((a) => a.id === 'mail');
  if (!app) { toast(L('ph.err_notinstalled')); return; }

  enterApp(app, null);
  const me = await post('mail', { op: 'me', address: mailAcc });
  if (!me || me.error) { toast(L('ph.err_' + ((me && me.error) || 'off'))); return; }
  mailImages = me.images !== false;
  mailMe = me;
  if (!me.address) {
    // No address of their own yet. Sending needs one, so this is the honest next step.
    mailSignup(me.domains || [], me.reserved || {}, me.owned || {}, me.buy || {});
    toast(L('ph.mail_need_account'));
    return;
  }
  mailAcc = me.address;
  mailCompose({ to });
}

// A tapped row carrying an address, wherever one is drawn.
function wireMailto() {
  [...byId('sheet').querySelectorAll('[data-mailto]')].forEach((el) =>
    el.addEventListener('click', () => {
      const to = el.dataset.mailto;
      closeSheet();
      mailTo(to);
    }));
}

// ── Bank ───────────────────────────────────────────────────────
// A statement line's date. The phone's own lines carry a unix timestamp; a banking script
// that hands back a preformatted string keeps its string, because reformatting something
// whose format is unknown is how dates end up wrong.
/// A statement timestamp, whatever unit it arrived in.
///
/// The units cannot be told apart by type - a banking script stores `os.time() * 1000`, another
/// stores `os.time()`, and oxmysql turns a DATETIME into a millisecond epoch - so they are told
/// apart by MAGNITUDE. 1e11 is the dividing line: 1e11 seconds is the year 5138 and 1e11
/// milliseconds is 1973, and no statement on a live server sits between them.
///
/// Both directions have now been seen on real servers. A seconds value read as milliseconds put
/// "Jan 21" and "Nov 15" on one statement - both in 1970, which is why they were out of order
/// and why the year was not shown. The server normalises what it can; this is what makes the
/// page right for a provider it has never met.
function txEpochMs(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return NaN;
  return n > 100000000000 ? n : n * 1000;
}

function txWhen(t) {
  if (t.at) {
    // `String(t.at)` was printing the raw value, which for a DATETIME column oxmysql has
    // already turned into a millisecond epoch is thirteen digits on a statement. A value that
    // parses as a time is formatted; anything else is a banking script's own wording and is
    // passed through untouched, which is the point of this branch.
    // A number here is an epoch in one unit or the other; a string is either a date a banking
    // script formatted itself or one oxmysql handed over.
    const ms = typeof t.at === 'number' ? txEpochMs(t.at) : whenMs(t.at);
    if (!Number.isFinite(ms)) return String(t.at);
    const d = new Date(ms);
    return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' }) + ' ' +
      d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }
  if (!t.ts) return '';
  const ms2 = txEpochMs(t.ts);
  if (!Number.isFinite(ms2)) return '';
  const d = new Date(ms2);
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' }) + ' ' +
    d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// What a statement line is called. The server stores the sender's note and who it was
// with, never a sentence: composing it here means a row written on an English server still
// reads in French for whoever is looking at it.
function txTitle(t) {
  if (t.kind === 'fee') return L('ph.bank_fee');
  if (t.kind === 'salary') return L('ph.salary');
  if (t.label) return String(t.label);
  if (t.with) {
    return L(Number(t.amount) < 0 ? 'ph.bank_to_name' : 'ph.bank_from_name')
      .replace('{name}', t.with);
  }
  // A framework money movement with no reason given is still a deposit or a withdrawal;
  // calling it a transfer would be a guess about something the phone did not do.
  if (t.kind === 'account') {
    return L(Number(t.amount) < 0 ? 'ph.bank_withdrawal' : 'ph.bank_deposit');
  }
  return L('ph.bank_transfer');
}

RENDER.bank = async () => {
  loading();
  const d = await post('app', { app: 'bank' });
  if (!d || d.error) { body(UI.empty(L('ph.err_' + ((d && d.error) || 'off')), 'bank')); return; }

  const tx = d.transactions || [];
  const favs = d.favourites || [];
  const fee = Number(d.fee) || 0;

  body(
    UI.hero({
      appicon: 'bank',
      eyebrow: L('ph.balance'),
      value: money(d.bank),
      subtitle: `${L('ph.cash')} ${money(d.cash)}`,
    }) +
    (d.transfers ? UI.button(L('ph.bank_transfer'), 'bxfer', 'tinted') : '') +
    // Only drawn when there is something to say: a server with no fee and no daily limit
    // gets no row about either.
    ((fee > 0 || d.remaining !== undefined || d.number)
      ? UI.group([
          d.number ? UI.row({ icon: 'phone', title: L('ph.bank_my_number'), value: maskNum(d.number), mono: true }) : '',
          fee > 0 ? UI.row({ icon: 'bank', title: L('ph.bank_fee'), value: fee + '%', mono: true }) : '',
          d.remaining !== undefined
            ? UI.row({ icon: 'timer', title: L('ph.bank_daily_left'), value: money(d.remaining), mono: true })
            : '',
        ].filter(Boolean))
      : '') +
    (d.transfers
      ? UI.group(
          (favs.length
            ? favs.map((f) => UI.row({
                avatar: f.name || f.number, title: f.name || f.number,
                // No second line when it would just repeat the first.
                subtitle: f.name ? f.number : '', chevron: true,
                data: { fav: f.number, favname: f.name || '' },
              }))
            : [UI.row({ icon: 'contacts', title: L('ph.bank_no_favs') })]
          ).concat([UI.row({ icon: 'add', title: L('ph.bank_add_fav'), data: { addfav: '1' } })]),
          { header: L('ph.bank_beneficiaries') })
      : '') +
    (tx.length
      ? UI.group(tx.map((t) => UI.row({
          title: txTitle(t),
          subtitle: txWhen(t),
          value: money(t.amount), mono: true, tone: Number(t.amount) < 0 ? 'neg' : 'pos',
        })), { header: L('ph.history') })
      : UI.empty(L('ph.no_history')))
  );

  if (byId('bxfer')) byId('bxfer').addEventListener('click', () => transferSheet(d));
  // A saved beneficiary is a shortcut to the same transfer sheet, prefilled.
  rows('[data-fav]', (el) => el.addEventListener('click', () =>
    favouriteSheet(d, el.dataset.fav, el.dataset.favname)));
  rows('[data-addfav]', (el) => el.addEventListener('click', () => addFavouriteSheet()));
};

// ── 911 ────────────────────────────────────────────────────────
// Two apps in one, and which one you get is decided on the server: a caller picks a service
// and a reason, and somebody working that service sees the queue instead.
//
// Nothing here decides anything. Which services exist, whether this player answers for one,
// where an alert happened and who may act on it are all the server's - the page draws what it
// is given and sends back a choice. See server/emergency.lua.

let emergencyService = null;   // the service being called, while choosing a reason
let emergencyView = null;      // 'call' or 'dispatch'; null until we know whether there is one
let emergencyTab = null;       // which service's queue, inside Dispatch

RENDER.emergency = async () => {
  loading();
  const d = await post('emergency', {});
  if (!d || d.error) { body(UI.empty(L('ph.911_e_' + ((d && d.error) || 'off')), 'warning')); return; }

  const queues = d.queues || [];
  // Somebody who answers for a service opens on Dispatch the first time - it is what they
  // opened the app for. After that the bar remembers where they were. Anybody who is not on
  // duty has no Dispatch to be on, whatever they were looking at when they clocked off.
  if (emergencyView === null) emergencyView = queues.length ? 'dispatch' : 'call';
  if (!queues.length) emergencyView = 'call';

  if (emergencyView === 'dispatch') {
    const active = queues.find((q) => q.id === emergencyTab) || queues[0];
    emergencyTab = active.id;
    emergencyQueue(d, queues, active);
    return;
  }
  emergencyCaller(d, queues);
};

/// The bar along the bottom. Only drawn for somebody who answers for a service - a civilian
/// has one screen and a tab bar over a single tab is furniture.
///
/// It replaced a small icon in the top right that switched between the two. Nobody found it,
/// which is the ordinary fate of a mode switch hidden in a corner: the two sides of this app
/// are two places, and two places on a phone are a bar along the bottom.
function emergencyFoot(d, queues) {
  if (!queues.length) { foot(''); return; }
  // Only what is still waiting. A number that counts alerts somebody already took is a number
  // that never reaches zero, and a badge that never clears is a badge people stop seeing.
  const waiting = queues.reduce((n, q) =>
    n + (q.live || []).filter((a) => a.state === 'open').length, 0);
  tabbar([
    { id: 'call', icon: 'warning', label: 'ph.911_tab_call' },
    { id: 'dispatch', icon: 'shield', label: 'ph.911_tab_dispatch', badge: waiting },
  ], emergencyView, (t) => { emergencyView = t; RENDER.emergency(); });
}

/// The caller's side: pick a service. Reachable by everybody, including a responder - being on
/// duty does not stop you being the one who needs the other service.
function emergencyCaller(d, queues) {
  setNav(L('app.emergency'), null, null);
  emergencyFoot(d, queues);

  const mine = d.mine || [];
  body(
    '<div class="e911head">' + svg('warning') +
      '<b>' + esc(L('ph.911_title')) + '</b>' +
      '<span>' + esc(L('ph.911_hint')) + '</span></div>' +
    (d.cooldown
      ? '<div class="groupfoot">' +
          esc(L('ph.911_cooldown').replace('{s}', String(d.cooldown))) + '</div>'
      : '') +
    UI.group((d.services || []).map((s) => UI.row({
      icon: s.icon || 'warning', tint: s.wait ? '#8E8E93' : (s.tint || '#FF453A'),
      title: L(s.label),
      // Per service, because the cooldown is: having just called the police does not stop you
      // needing an ambulance, and a list greyed out as a whole would say that it did.
      subtitle: s.wait
        ? L('ph.911_wait').replace('{s}', String(s.wait))
        : L('ph.911_pick_reason'),
      chevron: !s.wait,
      data: { e911: s.id },
    })), { header: L('ph.911_services') }) +
    (mine.length
      ? UI.group(mine.map((a) => UI.row({
          icon: 'warning', tint: '#8E8E93',
          title: L(a.reason) + (a.detail ? ' - ' + a.detail : ''),
          subtitle: shortWhen(a.at * 1000) + '  ' + L('ph.911_st_' + (a.state || 'open')) +
            (a.takenBy ? ' - ' + a.takenBy : ''),
        })), { header: L('ph.911_mine'), footer: L('ph.911_mine_hint') })
      : '')
  );

  rows('[data-e911]', (r) => r.addEventListener('click', () => {
    const s = (d.services || []).find((x) => x.id === r.dataset.e911) || null;
    if (!s) return;
    // The server refuses it anyway; this is so the refusal is not the first thing the player
    // learns after picking a reason and pressing send.
    if (s.wait) { toast(L('ph.911_e_cooldown').replace('{s}', String(s.wait))); return; }
    emergencyService = s;
    emergencyReasonSheet(d);
  }));
}

/// Pick a reason, optionally write one, optionally stay anonymous, send.
function emergencyReasonSheet(d) {
  const s = emergencyService;
  let anonymous = false;
  // Each service answers for itself and falls back to the server's global defaults: a fire
  // brigade can take free text and refuse anonymity while the police line does the opposite.
  const allowOther = s.allowOther !== undefined ? s.allowOther : d.allowOther;
  const allowAnon = s.anonymous !== undefined ? s.anonymous : d.anonymous;

  sheet(L(s.label),
    UI.group((s.reasons || []).map((key) => UI.row({
      icon: s.icon || 'warning', tint: s.tint || '#FF453A',
      title: L(key), chevron: true, data: { e911r: key },
    })).concat(allowOther
      ? [UI.row({ icon: 'note', tint: '#8E8E93', title: L('ph.911_other'),
                  chevron: true, data: { e911r: '' } })]
      : []), { header: L('ph.911_pick_reason') }) +
    (allowAnon
      ? UI.group([UI.row({ icon: 'lockshut', tint: '#5E5CE6', title: L('ph.911_anon'),
                           subtitle: L('ph.911_anon_hint'), toggle: false,
                           data: { e911anon: '1' } })])
      : '') +
    '<div class="groupfoot">' + esc(L('ph.911_where')) + '</div>',
    () => {
      const epoch = sheetEpoch;
      const anon = byId('sheet').querySelector('[data-e911anon]');
      if (anon) anon.addEventListener('click', () => {
        anonymous = !anonymous;
        // The row draws its own switch from a class, so the state has to be shown here as
        // well as remembered - a toggle that does not move is a toggle nobody trusts.
        anon.classList.toggle('on', anonymous);
        const knob = anon.querySelector('.sw');
        if (knob) knob.classList.toggle('on', anonymous);
      });

      [...byId('sheet').querySelectorAll('[data-e911r]')].forEach((row) =>
        row.addEventListener('click', () => {
          const key = row.dataset.e911r;
          if (key === '') {
            if (!closeSheet(false, epoch)) return;
            emergencyOtherSheet(d, anonymous);
            return;
          }
          emergencySend({ reason: key, anonymous, epoch });
        }));
    });
}

/// A reason of the caller's own.
function emergencyOtherSheet(d, anonymous) {
  sheet(L('ph.911_other'),
    UI.field('e911text', L('ph.911_other_field'), '',
             'maxlength="' + (Number(emergencyService && emergencyService.maxText) ||
                              Number(d.maxText) || 200) + '"') +
    '<div class="groupfoot">' + esc(L('ph.911_where')) + '</div>' +
    UI.button(L('ph.911_send'), 'e911go', 'tinted'),
    () => {
      const epoch = sheetEpoch;
      const go = () => {
        const text = byId('e911text').value.trim();
        if (!text) return;
        emergencySend({ reason: L('ph.911_other'), detail: text, anonymous, epoch });
      };
      byId('e911go').addEventListener('click', go);
      byId('e911text').addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
      byId('e911text').focus();
    });
}

async function emergencySend(o) {
  const r = await post('emergencySend', {
    service: emergencyService && emergencyService.id,
    reason: o.reason,
    detail: o.detail,
    anonymous: o.anonymous === true,
  });
  if (!r || !r.ok) {
    const code = (r && r.error) || 'x';
    toast(code === 'cooldown'
      ? L('ph.911_e_cooldown').replace('{s}', String((r && r.wait) || 0))
      : L('ph.911_e_' + code));
    return;
  }
  if (!closeSheet(false, o.epoch)) return;
  ui('success');
  // How many people it reached, because "nobody is on duty" is something the person in
  // trouble should be told rather than left to work out from the silence.
  toast(r.responders > 0
    ? L('ph.911_sent').replace('{n}', String(r.responders))
    : L('ph.911_sent_nobody'));
  RENDER.emergency();
}

/// An alert landing on a responder's phone. The client sends this whether or not the handset
/// is out - somebody on duty with their phone in their pocket is exactly who it is for.
///
/// Three separate things, and they are separate on purpose: the sound (which a responder needs
/// even when they are not looking), the card in the notification centre (which is how they find
/// it again ten seconds later), and the repaint (only when they are already in the app).
function emergency911Alert(d) {
  const a = d.alert || {};
  const s = d.service || {};
  const what = L(a.reason || '') || '';

  if (d.sound !== false) {
    // Straight to the file at the volume the config named rather than through `ui()`, which
    // stands down at ring volume zero. Being on duty is a promise to be reachable; a silenced
    // phone still pages. It is quieter than the citywide alert, which cannot be silenced.
    const vol = Math.max(0, Math.min(1, Number(d.volume) >= 0 ? Number(d.volume) : .85));
    const src = soundUrl('ui', d.file || 'alert911');
    let played = false;
    if (src && vol > 0) {
      try {
        const el = new Audio(src);
        el.volume = vol;
        el.play().catch(() => {});
        played = true;
      } catch { /* fall through to the oscillators */ }
    }
    // The fallback is the tone for whatever file was asked for if the page knows one, and the
    // dispatch pair otherwise - a server that renamed the sound still gets a sound.
    if (!played && vol > 0) {
      (UI_TONES[d.file] || UI_TONES.alert911)
        .forEach(([f, t, len]) => note(f, t, len, .1 * vol, 'square'));
    }
  }

  // The card. `archivePeek` is what every other push files through, so this one sorts, groups
  // and clears with the rest instead of being a special case nobody can dismiss.
  archivePeek('notif', {
    app: 'emergency',
    icon: 'warning',
    title: L('ph.911_new') + (s.label ? ' - ' + L(s.label) : ''),
    body: [what, a.detail, a.street].filter(Boolean).join(' - '),
  });

  // And if they are looking at the queue, it appears in it.
  if (openApp && openApp.id === 'emergency') RENDER.emergency();
}

/// The other end of it: the caller being told that somebody picked their alert up, or closed
/// it. The one thing a person who shouted for help cannot work out on their own.
function emergency911Status(d) {
  const s = d.service || {};
  const key = d.state === 'closed' ? 'ph.911_c_closed' : 'ph.911_c_taken';
  const line = d.by ? L(key + '_by').replace('{n}', d.by) : L(key);

  if (d.sound !== false) ui(d.state === 'closed' ? 'received' : 'success');

  archivePeek('notif', {
    app: 'emergency',
    icon: 'shield',
    title: s.label ? L(s.label) : L('app.emergency'),
    body: line,
  });
  // A toast as well when they are holding the phone: the card is where it is FOUND, the toast
  // is what is seen. Only when they are looking, so it is never a second copy of the banner.
  if (!byId('device').classList.contains('hidden')) toast(line);

  if (openApp && openApp.id === 'emergency') RENDER.emergency();
}

/// The responder's side: the queue for one service.
function emergencyQueue(d, queues, active) {
  setNav(queues.length > 1 ? L('ph.911_tab_dispatch') : L(active.label), null, null);
  emergencyFoot(d, queues);

  const row = (a, live) => UI.row({
    icon: active.icon || 'warning',
    tint: live ? (active.tint || '#FF453A') : '#8E8E93',
    title: L(a.reason) + (a.detail ? ' - ' + a.detail : ''),
    subtitle: [
      shortWhen(a.at * 1000),
      a.anonymous ? L('ph.911_anon_caller') : (a.caller || ''),
      a.state !== 'open' ? L('ph.911_st_' + a.state) + (a.takenBy ? ' - ' + a.takenBy : '') : '',
    ].filter(Boolean).join('  '),
    chevron: true,
    data: { e911a: String(a.id) },
  });

  const live = active.live || [];
  const past = active.past || [];
  // One tab per service this player answers for, at the top of the queue itself. Most hold
  // one and see nothing; a volunteer firefighter who is also an EMT holds two, and switching
  // should not mean leaving the app. Each carries its own waiting count, so the other service
  // does not have to be opened to find out whether anything is happening there.
  const switcher = queues.length > 1
    ? '<div class="e911tabs">' + queues.map((q) => {
        const n = (q.live || []).filter((a) => a.state === 'open').length;
        return '<button class="' + (q.id === active.id ? 'on' : '') +
          '" data-e911tab="' + esc(q.id) + '" type="button">' + esc(L(q.label)) +
          (n ? ' <i>' + n + '</i>' : '') + '</button>';
      }).join('') + '</div>'
    : '';

  body(
    switcher +
    (live.length
      ? UI.group(live.map((a) => row(a, true)), { header: L('ph.911_live') })
      : UI.empty(L('ph.911_none'), 'shield')) +
    (past.length
      ? UI.group(past.map((a) => row(a, false)), { header: L('ph.911_past') })
      : '')
  );

  rows('[data-e911tab]', (b) =>
    b.addEventListener('click', () => { emergencyTab = b.dataset.e911tab; RENDER.emergency(); }));

  rows('[data-e911a]', (r) => r.addEventListener('click', () => {
    const id = Number(r.dataset.e911a);
    const a = live.concat(past).find((x) => x.id === id);
    if (a) emergencyAlertSheet(a, active);
  }));
}

/// One alert: who, what, where, and the three things a responder does with it.
function emergencyAlertSheet(a, service) {
  sheet(L(a.reason),
    UI.group([
      a.detail ? UI.row({ icon: 'note', title: L('ph.911_detail'), subtitle: a.detail }) : '',
      UI.row({ icon: 'timer', title: L('ph.911_when'), value: shortWhen(a.at * 1000) }),
      // Anonymous means no name, always. A number appears only when the server chose to send
      // one - which, for an anonymous alert, happens only if the operator turned
      // `anonymousCallback` on. The page never has to know that rule: it draws whatever it was
      // given, so a withheld number is a number it never received.
      a.anonymous
        ? UI.row({ icon: 'lockshut', title: L('ph.911_caller'),
                   subtitle: L('ph.911_anon_caller'),
                   value: a.number ? maskNum(a.number) : '' })
        : UI.row({ icon: 'contacts', title: L('ph.911_caller'), subtitle: a.caller || '',
                   value: a.number ? maskNum(a.number) : '' }),
      a.state !== 'open'
        ? UI.row({ icon: 'check', title: L('ph.911_st_' + a.state), subtitle: a.takenBy || '' })
        : '',
    ].filter(Boolean)) +
    UI.button(L('ph.911_locate'), 'e911loc', 'tinted') +
    // Ringing back is the point of the number travelling with the alert. Keyed on the number,
    // not on anonymity: an anonymous alert has one exactly when the operator allowed it.
    (a.number ? UI.button(L('ph.911_callback'), 'e911call', 'plain') : '') +
    (a.state === 'open' ? UI.button(L('ph.911_take'), 'e911take', 'plain') : '') +
    (a.state !== 'closed' ? UI.button(L('ph.911_done'), 'e911done', 'destructive') : ''),
    () => {
      const epoch = sheetEpoch;
      byId('e911loc').addEventListener('click', async () => {
        const r = await post('emergencyLocate', { id: a.id });
        if (!r || !r.ok) { toast(L('ph.911_e_' + ((r && r.error) || 'x'))); return; }
        if (!closeSheet(false, epoch)) return;
        ui('waypoint');
        toast(L('ph.911_located'));
      });
      const back = byId('e911call');
      if (back) back.addEventListener('click', () => {
        if (!closeSheet(false, epoch)) return;
        // `placeCall` is what every other screen uses to ring a number; there is no `dial`.
        placeCall(a.number);
      });
      const take = byId('e911take');
      if (take) take.addEventListener('click', async () => {
        const r = await post('emergencyTake', { id: a.id });
        if (!r || !r.ok) { toast(L('ph.911_e_' + ((r && r.error) || 'x'))); return; }
        if (!closeSheet(false, epoch)) return;
        ui('success');
        RENDER.emergency();
      });
      const done = byId('e911done');
      if (done) done.addEventListener('click', async () => {
        const r = await post('emergencyClose', { id: a.id });
        if (!r || !r.ok) { toast(L('ph.911_e_' + ((r && r.error) || 'x'))); return; }
        if (!closeSheet(false, epoch)) return;
        RENDER.emergency();
      });
    });
}

// ── Bank Pro: the company account ──────────────────────────────
// The Bank app is a person's money; this is a business's, for the character who runs it.
//
// **No phone numbers anywhere in it.** A company is paid by account and an employee by who
// they are, and that is a deliberate difference from the Bank app rather than an omission: a
// business transfer addressed by number is one that can go to a stranger with a SIM.
//
// Everything is decided on the server - which account this is, whether this character may
// reach it, whether the money moved. See server/bankpro.lua.
RENDER.bankpro = async () => {
  loading();
  const d = await post('app', { app: 'bankpro' });
  if (!d || d.error) {
    // Named refusals, because "you cannot use this" tells a business owner nothing about
    // whether they are in the wrong job, the wrong grade, or looking at a switched-off app.
    body(UI.empty(L('ph.bankpro_e_' + ((d && d.error) || 'off')), 'bank'));
    return;
  }

  const limits = d.limits || {};
  const job = d.job || {};
  const history = d.history || [];

  body(
    UI.hero({
      // The purple company tile, not the green personal one - a boss glancing at the two apps
      // must never mistake which account is on screen.
      appicon: 'bankpro',
      eyebrow: job.label || job.name || '',
      // A balance that cannot be read says so instead of showing zero. Telling somebody
      // their company has nothing, when the truth is that the banking script does not
      // expose it, is worse than saying nothing.
      value: d.readable ? money(d.balance) : L('ph.bankpro_unreadable'),
      subtitle: d.readable
        ? (L('ph.bankpro_account') + ' ' + (d.account || ''))
        : L('ph.bankpro_unreadable_hint'),
    }) +
    '<div class="bankproacts">' +
      (d.deposit === false ? '' : UI.button(L('ph.bankpro_deposit'), 'bpdep', 'tinted')) +
      (d.readable === false ? '' : UI.button(L('ph.bankpro_pay'), 'bppay', 'plain')) +
    '</div>' +
    // Pay is the payroll: your own staff. Transfer is money OUT of the business to somebody
    // else - a private individual or another company - which is a different intent and a
    // different list, so it is its own button rather than a third section inside Pay.
    (d.readable === false ? '' : UI.button(L('ph.bankpro_transfer'), 'bpxfer', 'plain')) +
    // The boss's own bank balance, so a deposit can be judged before it is made. No cash:
    // Bank Pro moves money between accounts, never in or out of a pocket.
    UI.group([
      UI.row({ icon: 'wallet', title: L('ph.balance'),
               value: money((d.mine || {}).bank), mono: true }),
      UI.row({ icon: 'jobs', title: L('ph.bankpro_grade'),
               value: job.gradeLabel || String(job.grade || 0) }),
    ], { header: L('ph.bankpro_you') }) +
    (d.withdraw === false ? '' : UI.button(L('ph.bankpro_withdraw'), 'bpwd', 'plain')) +
    // The account's movements in general, signed on the server: positive arrived, negative
    // left. The label already carries who or what it was, so the row just draws it.
    (history.length
      ? UI.group(history.map((h) => UI.row({
          title: h.label || '',
          subtitle: [h.who, shortWhen(h.at), h.note].filter(Boolean).join('  '),
          value: money(Number(h.amount) || 0),
          mono: true,
          tone: (Number(h.amount) || 0) >= 0 ? 'pos' : 'neg',
        })), { header: L('ph.bankpro_history'), footer: L('ph.bankpro_history_hint') })
      : UI.empty(L('ph.bankpro_no_history')))
  );

  const again = () => RENDER.bankpro();

  if (byId('bpdep')) byId('bpdep').addEventListener('click', () => bankproAmountSheet({
    title: L('ph.bankpro_deposit'), limits, action: 'bankproDeposit', after: again,
  }));
  if (byId('bpwd')) byId('bpwd').addEventListener('click', () => bankproAmountSheet({
    title: L('ph.bankpro_withdraw'), limits, action: 'bankproWithdraw', after: again,
  }));
  if (byId('bppay')) byId('bppay').addEventListener('click', () => bankproPaySheet(d, again));
  if (byId('bpxfer')) byId('bpxfer').addEventListener('click', () => bankproTransferSheet(d, again));
};

/// One amount sheet for deposit, withdrawal and payment. Bank accounts only - there is no
/// cash choice, because Bank Pro never moves money in or out of a pocket.
function bankproAmountSheet(o) {
  sheet(o.title,
    UI.field('bpamount', L('ph.bank_amount'), '', 'type="number" inputmode="numeric" min="' +
      (o.limits.min || 1) + '"' + (o.limits.max > 0 ? ' max="' + o.limits.max + '"' : '')) +
    UI.field('bpnote', L('ph.bank_note'), '', 'maxlength="40"') +
    UI.button(L('ph.confirm'), 'bpgo', 'tinted'),
    () => {
      byId('bpgo').addEventListener('click', async () => {
        const go = byId('bpgo');
        if (go.disabled) return;      // double-tapping send must not send twice
        go.disabled = true;
        const epoch = sheetEpoch;
        const r = await post(o.action, {
          amount: Math.floor(Number(byId('bpamount').value) || 0),
          note: byId('bpnote').value.trim(),
          // Only a payment has one. The server re-checks it either way: an employee must
          // hold the job, and an account must be one the operator listed.
          to: o.to,
        });
        if (!r || !r.ok) {
          go.disabled = false;
          toast(L('ph.bankpro_e_' + ((r && r.error) || 'x')));
          return;
        }
        if (!closeSheet(false, epoch)) return;
        ui('money');
        toast(L('ph.bankpro_done') + ' ' + money(r.amount));
        o.after();
      });
    });
}

/// The shared machinery behind Pay and Transfer. Both pick a destination from a list the
/// server produced and then ask for an amount; only which lists are offered differs, so the
/// picking, the searching and the wiring live here once.
async function bankproPickSheet(d, after, o) {
  const r = await post('bankproStaff', {});
  const staff = (r && r.staff) || [];
  const others = (r && r.others) || [];
  const payees = d.payees || [];

  const personRow = (s, kind) => UI.row({
    avatar: s.name, title: s.name, subtitle: s.grade || '', chevron: true,
    data: { bpto: kind + ':' + s.citizenid, bpname: s.name },
  });

  // Which lists this sheet is about. Pay is the payroll; Transfer is everybody who is not on it.
  const people = o.staff ? staff : others;
  const draw = (query) => {
    const q = String(query || '').trim().toLowerCase();
    const match = (s) => !q || String(s.name || '').toLowerCase().includes(q);
    const hits = people.filter(match);
    return (hits.length
        ? UI.group(hits.map((s) => personRow(s, o.staff ? 'staff' : 'person')),
                   { header: L(o.peopleHeader) })
        : (q ? '' : '<div class="groupfoot">' + esc(L(o.emptyHint)) + '</div>')) +
      // Company accounts, on the Transfer side only: paying a business is a transfer, not
      // payroll.
      (o.companies && payees.length && !q
        ? UI.group(payees.map((a) => {
            // Either shape: a plain account name from an older payload, or the named pair the
            // server sends now. A raw list of keys is what this used to draw.
            const account = typeof a === 'string' ? a : a.account;
            const label = typeof a === 'string' ? placeName(a) : (a.label || placeName(account));
            return UI.row({
              icon: 'bank', tint: '#5E5CE6', title: label,
              // The key, under the name, so a boss can still tell two similar companies apart.
              subtitle: label.toLowerCase() === String(account).toLowerCase() ? '' : account,
              chevron: true, data: { bpto: 'account:' + account, bpname: label },
            });
          }), { header: L('ph.bankpro_companies') })
        : '');
  };

  const wire = (epoch) => {
    [...byId('sheet').querySelectorAll('[data-bpto]')].forEach((row) =>
      row.addEventListener('click', () => {
        const to = row.dataset.bpto;
        const name = row.dataset.bpname;
        if (!closeSheet(false, epoch)) return;
        bankproAmountSheet({
          title: L(o.title) + ' - ' + name,
          limits: d.limits || {},
          action: 'bankproPay',
          after,
          to,
        });
      }));
  };

  sheet(L(o.title),
    // A search, because "anybody connected" on a busy server is a list nobody scrolls.
    (people.length > 6 ? UI.field('bpfind', L('ph.search'), '', 'autocomplete="off"') : '') +
    '<div id="bplist">' + draw('') + '</div>' +
    (o.foot ? '<div class="groupfoot">' + esc(L(o.foot)) + '</div>' : ''),
    () => {
      const epoch = sheetEpoch;
      wire(epoch);
      const find = byId('bpfind');
      if (find) find.addEventListener('input', () => {
        byId('bplist').innerHTML = draw(find.value);
        wire(epoch);
      });
    });
}

/// Pay: the payroll. Only people who hold this job.
function bankproPaySheet(d, after) {
  return bankproPickSheet(d, after, {
    title: 'ph.bankpro_pay',
    staff: true,
    companies: false,
    peopleHeader: 'ph.bankpro_staff',
    emptyHint: 'ph.bankpro_no_staff',
    foot: 'ph.bankpro_pay_hint',
  });
}

/// Transfer: money out of the business to somebody who is not on its payroll - a private
/// individual, or another company's account. Same money path, different intent, and worth its
/// own button: paying an employee and wiring a stranger are not the same decision.
function bankproTransferSheet(d, after) {
  return bankproPickSheet(d, after, {
    title: 'ph.bankpro_transfer',
    staff: false,
    companies: true,
    peopleHeader: 'ph.bankpro_anyone',
    emptyHint: 'ph.bankpro_no_others',
    foot: 'ph.bankpro_transfer_hint',
  });
}

// ── Sending money ──────────────────────────────────────────────
// Everything below only draws and asks. The amount, the limits, the fee and who the number
// belongs to are all decided on the server, so a player editing this page changes nothing
// except what they see.
function transferSheet(d, prefillNumber, prefillName) {
  const fee = Number(d.fee) || 0;
  const min = Number(d.min) || 1;
  const max = Number(d.max) || 0;

  // The contact book, as well as the number field.
  //
  // A transfer is addressed by phone number, and the people somebody sends money to are almost
  // always in their contacts already - so reading a number off one screen to type it into
  // another was the same daily annoyance the message composer had. The field stays for a number
  // that is not in the book, and picking a contact fills it in rather than replacing the sheet:
  // the amount somebody has already typed must survive choosing who to send it to.
  const picks = (state.contacts || []).filter((c) => c && c.number);
  sheet(L('ph.bank_transfer'),
    UI.field('bamount', L('ph.bank_amount'), '', 'type="number" inputmode="numeric" min="' +
      min + '"' + (max > 0 ? ' max="' + max + '"' : '')) +
    UI.field('bnumber', L('ph.bank_to'), prefillNumber || '', 'maxlength="20"') +
    (picks.length ? UI.button(L('ph.bank_pick_contact'), 'bpick', 'plain') : '') +
    UI.field('bnote', L('ph.bank_note'), '', 'maxlength="40"') +
    '<div class="bankcalc" id="bcalc"></div>' +
    UI.button(L('ph.bank_send'), 'bgo', 'tinted'),
    () => {
      const amount = byId('bamount'), calc = byId('bcalc');

      const pick = byId('bpick');
      if (pick) pick.addEventListener('click', () => {
        // Everything typed so far, carried through the picker and back. Losing an amount
        // because you looked up who to send it to is the bug this feature would otherwise be.
        const carried = {
          amount: byId('bamount').value,
          note: byId('bnote').value,
        };
        sheet(L('ph.pick_contact'),
          UI.group(picks.map((c) => UI.row({
            avatar: c.name, title: c.name, subtitle: maskNum(c.number),
            chevron: true, data: { n: c.number },
          }))),
          () => {
            const epoch = sheetEpoch;
            [...byId('sheet').querySelectorAll('.row[data-n]')].forEach((row) =>
              row.addEventListener('click', () => {
                const chosen = picks.find((c) => c.number === row.dataset.n);
                if (!closeSheet(false, epoch)) return;
                transferSheet(d, row.dataset.n, chosen && chosen.name);
                // Put back what was already typed. `transferSheet` has just redrawn the
                // sheet, so these elements are new ones.
                if (carried.amount) {
                  byId('bamount').value = carried.amount;
                  byId('bamount').dispatchEvent(new Event('input'));
                }
                if (carried.note) byId('bnote').value = carried.note;
              }));
          });
      });
      // What this will actually cost, updated as it is typed. A fee discovered after the
      // fact is the kind of thing a player reports as theft.
      const repaint = () => {
        const n = Math.floor(Number(amount.value) || 0);
        if (n <= 0) {
          calc.textContent = max > 0
            ? L('ph.bank_limits').replace('{min}', money(min)).replace('{max}', money(max))
            : '';
          return;
        }
        const f = Math.floor(n * fee / 100);
        calc.textContent = f > 0
          ? L('ph.bank_total') + ' ' + money(n + f) + '  (' + L('ph.bank_fee') + ' ' + money(f) + ')'
          : L('ph.bank_total') + ' ' + money(n);
      };
      amount.addEventListener('input', repaint);
      repaint();
      if (prefillName) byId('bnote').setAttribute('placeholder', prefillName);

      byId('bgo').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        const go = byId('bgo');
        // Double-tapping send must not send twice.
        if (go.disabled) return;
        go.disabled = true;
        const r = await post('bankTransfer', {
          amount: Math.floor(Number(byId('bamount').value) || 0),
          number: byId('bnumber').value.trim(),
          note: byId('bnote').value.trim(),
        });
        if (!r || !r.ok) {
          go.disabled = false;
          toast(L('ph.err_' + ((r && r.error) || 'x')));
          return;
        }
        if (!closeSheet(false, epoch)) return;
        toast(L(r.held ? 'ph.bank_held' : 'ph.bank_sent') + ' ' + money(r.amount) +
          (r.to ? ' - ' + r.to : ''));
        RENDER.bank();
      });
    });
}

function favouriteSheet(d, number, name) {
  sheet(name || number,
    UI.group([UI.row({ icon: 'phone', title: number, mono: true })]) +
    UI.button(L('ph.bank_send'), 'bfsend', 'tinted') +
    UI.button(L('ph.bank_remove'), 'bfdel', 'destructive'),
    () => {
      byId('bfsend').addEventListener('click', () => transferSheet(d, number, name));
      byId('bfdel').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        await post('bankFavourite', { op: 'del', number });
        if (!closeSheet(false, epoch)) return;
        toast(L('ph.bank_fav_removed'));
        RENDER.bank();
      });
    });
}

function addFavouriteSheet() {
  sheet(L('ph.bank_add_fav'),
    UI.field('bfnum', L('ph.bank_to'), '', 'maxlength="20"') +
    UI.field('bfname', L('ph.bank_fav_name'), '', 'maxlength="40"') +
    UI.button(L('ph.save'), 'bfadd', 'tinted'),
    () => {
      byId('bfadd').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        const r = await post('bankFavourite', {
          op: 'add',
          number: byId('bfnum').value.trim(),
          name: byId('bfname').value.trim(),
        });
        if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
        if (!closeSheet(false, epoch)) return;
        toast(L('ph.bank_fav_saved'));
        RENDER.bank();
      });
    });
}

// ── Garage ─────────────────────────────────────────────────────
// Where a car is, not how to spawn one: taking it out is the garage's job and needs the
// player standing at one.
RENDER.garage = async () => {
  loading();
  const d = await post('app', { app: 'garage' });
  // The server's own reason, not a blanket "unavailable": "no garage script here" and "you
  // own no cars" are different things and used to read identically.
  if (!d || d.error) { body(UI.empty(L('ph.err_' + ((d && d.error) || 'off')), 'garage')); return; }
  const list = Array.isArray(d) ? d : (d.vehicles || []);
  if (!list.length) { body(UI.empty(L('ph.no_vehicles'), 'garage')); return; }
  body(UI.group(list.map((v, i) => UI.row({
    // What it is called, not what it is keyed by. `label` is resolved on the server from the
    // framework's own vehicle list - `daemon` is a spawn code, `Bravado Bison` is a name -
    // and the model is kept as the fallback for a server whose list has no entry.
    icon: 'garage', tint: '#0A84FF', title: v.label || v.model || '',
    // The garage's real name when the server could resolve it, its key when it could not,
    // and "out" when the car is not in one at all.
    subtitle: `${v.plate || ''}  ${placeName(v.garageLabel || v.garage) || L('ph.out')}`,
    value: v.live ? L('ph.veh_out') : L('ph.veh_stored'),
    chevron: true, data: { veh: String(i) },
  }))));
  rows('.row', (r) => {
    if (!r.dataset.veh) return;
    r.addEventListener('click', () => vehicleRemote(list[Number(r.dataset.veh)]));
  });
};

// ── The remote ─────────────────────────────────────────────────
// Lights, underglow, doors and locks for a car you own and are standing near. Every button
// is re-checked on the server - ownership, distance and whether the operator enabled that
// control at all - so this sheet is a convenience, never a permission.
const VEH_LIGHT_MODES = [
  { v: 'flash', label: 'ph.veh_flash' },
  { v: 'on', label: 'ph.veh_lights_on' },
  { v: 'off', label: 'ph.veh_lights_off' },
];

async function vehicleSend(plate, action, value) {
  const r = await post('vehicleControl', { plate, action, value });
  if (!r || !r.ok) {
    const key = (r && r.error) || 'x';
    const message = L('ph.veh_err_' + key);
    toast(message === 'ph.veh_err_' + key ? L('ph.veh_err_x') : message);
    return false;
  }
  ui('key');
  return true;
}

async function vehicleRemote(v) {
  if (!v || !v.plate) return;
  const plate = v.plate;
  // Ask the client where the car is first: a remote for a vehicle three districts away is a
  // row of buttons that can only fail, and saying so up front is kinder than five refusals.
  const found = await post('vehicleFind', { plate });
  const near = !!(found && found.ok);
  const controls = (state.vehicleControls || {});

  const group = [];
  // First, and outside the `controls` gates: finding your own car is not a remote command,
  // it needs no proximity and no operator switch. Only offered when the server actually
  // knows where it is - a button that cannot answer is worse than no button.
  if (v.x && v.y) {
    group.push(UI.row({
      icon: 'location', tint: '#FF9500',
      title: L('ph.veh_locate'),
      subtitle: v.live ? L('ph.veh_locate_out') : (placeName(v.garageLabel || v.garage) || ''),
      data: { a: 'locate' },
    }));
  }
  if (controls.locks) {
    group.push(UI.row({ icon: 'lockshut', tint: '#8E8E93', title: L('ph.veh_lock'), data: { a: 'lock' } }));
    group.push(UI.row({ icon: 'lockopen', tint: '#34C759', title: L('ph.veh_unlock'), data: { a: 'unlock' } }));
  }
  if (controls.lights) group.push(UI.row({ icon: 'sun', tint: '#FFD60A', title: L('ph.veh_lights'), chevron: true, data: { a: 'lights' } }));
  if (controls.neon) group.push(UI.row({ icon: 'sparkles', tint: '#AF52DE', title: L('ph.veh_neon'), chevron: true, data: { a: 'neon' } }));
  if (controls.doors) group.push(UI.row({ icon: 'garage', tint: '#0A84FF', title: L('ph.veh_doors'), chevron: true, data: { a: 'doors' } }));
  if (controls.horn) group.push(UI.row({ icon: 'speaker', tint: '#FF9500', title: L('ph.veh_horn'), data: { a: 'horn' } }));
  if (controls.engine) group.push(UI.row({ icon: 'fuel', tint: '#FF453A', title: L('ph.veh_engine'), chevron: true, data: { a: 'engine' } }));
  if (controls.alarm) group.push(UI.row({ icon: 'bell', tint: '#FF2D55', title: L('ph.veh_alarm'), data: { a: 'alarm' } }));

  sheet(v.label || v.model || plate,
    '<div class="groupfoot">' + esc(plate) + ' · ' +
    esc(near ? L('ph.veh_near').replace('{m}', String(found.distance))
             : L('ph.veh_far')) + '</div>' +
    (group.length ? UI.group(group) : UI.empty(L('ph.veh_no_controls'), 'garage')),
    () => {
      qrows('sheet', '.row', (r) => {
        const a = r.dataset.a;
        if (!a) return;
        r.addEventListener('click', async () => {
          if (a === 'locate') {
            // Straight to the existing waypoint callback: it moves this player's own map
            // marker and touches nothing else.
            const set = await post('waypoint', { x: v.x, y: v.y });
            toast(L(set && set.ok ? 'ph.veh_located' : 'ph.err_x'));
            ui('key');
          } else if (a === 'lock' || a === 'unlock') {
            await vehicleSend(plate, 'locks', a === 'lock' ? 'lock' : 'unlock');
          } else if (a === 'horn' || a === 'alarm') {
            await vehicleSend(plate, a);
          } else if (a === 'lights') {
            sheet(L('ph.veh_lights'), UI.group(VEH_LIGHT_MODES.map((m) =>
              UI.row({ icon: 'sun', tint: '#FFD60A', title: L(m.label), data: { m: m.v } }))), () => {
                qrows('sheet', '.row', (x) => x.addEventListener('click',
                  () => vehicleSend(plate, 'lights', x.dataset.m)));
              });
          } else if (a === 'doors') {
            const doors = [0, 1, 2, 3, 4, 5];
            sheet(L('ph.veh_doors'),
              UI.button(L('ph.veh_doors_shut'), 'vshut', 'plain') +
              UI.group(doors.map((d) => UI.row({
                icon: 'garage', tint: '#0A84FF', title: L('ph.veh_door_' + d), data: { d: String(d) },
              }))), () => {
                byId('vshut').addEventListener('click',
                  () => vehicleSend(plate, 'doors', { door: -1, open: false }));
                qrows('sheet', '.row', (x) => x.addEventListener('click',
                  () => vehicleSend(plate, 'doors', { door: Number(x.dataset.d), open: true })));
              });
          } else if (a === 'engine') {
            sheet(L('ph.veh_engine'), UI.group([
              UI.row({ icon: 'fuel', tint: '#34C759', title: L('ph.veh_engine_on'), data: { e: 'on' } }),
              UI.row({ icon: 'fuel', tint: '#FF453A', title: L('ph.veh_engine_off'), data: { e: 'off' } }),
            ]), () => {
              qrows('sheet', '.row', (x) => x.addEventListener('click',
                () => vehicleSend(plate, 'engine', x.dataset.e)));
            });
          } else if (a === 'neon') {
            const palette = state.vehicleNeons || [];
            sheet(L('ph.veh_neon'),
              UI.button(L('ph.veh_neon_off'), 'vneonoff', 'plain') +
              '<div class="neongrid">' + palette.map((c, i) =>
                '<button type="button" data-n="' + i + '" style="--c:rgb(' +
                c.rgb.join(',') + ')"><span></span>' + esc(c.name) + '</button>').join('') +
              '</div>', () => {
                byId('vneonoff').addEventListener('click', () => vehicleSend(plate, 'neon', false));
                [...byId('sheet').querySelectorAll('[data-n]')].forEach((b) =>
                  b.addEventListener('click',
                    () => vehicleSend(plate, 'neon', palette[Number(b.dataset.n)].rgb)));
              });
          }
        });
      });
    });
}

// ── Wallet ─────────────────────────────────────────────────────
RENDER.wallet = async () => {
  loading();
  // The card is v-banking's, not the phone's: it mints the number and it is the thing
  // one player hands another instead of a citizen id.
  const card = await post('card');
  const d = await post('app', { app: 'wallet' });
  if (!d || d.error) { body(UI.empty(L('ph.err_' + ((d && d.error) || 'off')), 'wallet')); return; }
  const list = Array.isArray(d) ? d : (d.licenses || []);
  // No card until one has been ordered from the bank, so say where to get one rather
  // than drawing an empty rectangle.
  const cardHtml = (card && card.ok && card.card)
    ? '<div class="bankcard"><div class="brand"><span>FLEECA</span><span class="chip"></span></div>' +
      '<div class="num">' + esc(maskNum(card.card)) + '</div>' +
      '<div class="foot"><span>' + esc(card.holder || '') + '</span>' +
      '<span class="bal">' + esc(money(card.bank)) + '</span></div></div>'
    : (card && card.ok ? UI.group([UI.row({ icon: 'bank', title: L('ph.no_card'), subtitle: L('ph.no_card_hint') })]) : '');
  // The identity card: the facts the framework keeps about this character. Drawn above the
  // licences because it is the thing a wallet is actually opened for.
  const id = d.identity;
  const idHtml = id ? UI.group([
    UI.row({ icon: 'id', tint: '#0A84FF', title: L('ph.id_name'), value: id.name || '' }),
    id.dob ? UI.row({ icon: 'timer', tint: '#5E5CE6', title: L('ph.id_dob'), value: id.dob, mono: true }) : '',
    id.sex ? UI.row({ icon: 'contacts', tint: '#FF9F0A', title: L('ph.id_sex'),
                      value: L('ph.id_sex_' + id.sex) }) : '',
    id.nationality ? UI.row({ icon: 'map', tint: '#30D158', title: L('ph.id_nationality'),
                              value: id.nationality }) : '',
    id.height ? UI.row({ icon: 'focus', tint: '#64D2FF', title: L('ph.id_height'),
                         value: id.height + ' cm', mono: true }) : '',
    // The citizen id is deliberately NOT here. It is an internal database key, it is what
    // every other script uses to identify a character, and putting it on a screen a player
    // can be asked to show is a privacy problem, not a feature.
  ].filter(Boolean), { header: L('ph.id_card') }) : '';

  if (!list.length) {
    body(cardHtml + idHtml +
      UI.empty(L(d.readable === false ? 'ph.err_nolicences' : 'ph.no_licenses'), 'wallet'));
    wireCard();
    return;
  }
  const wireCard = () => {
    const el = document.querySelector('.bankcard');
    if (el && card && card.card) {
      el.style.cursor = 'pointer';
      el.addEventListener('click', () => copyText(card.card, L('ph.card_copied')));
    }
  };
  body(cardHtml + idHtml + UI.group(list.map((l) => UI.row({
    // A translation if there is one, then the label the server resolved, and last the bare
    // identifier with its separators tidied - `weapon_license` reads as `Weapon License`
    // rather than as a column value, even on a server that has configured nothing.
    icon: 'wallet', tint: '#5856D6',
    // A translation if one really exists, then the label the server resolved from
    // `Config.Licences`, and last the bare identifier tidied.
    //
    // **`L()` never returns its own key** - a miss comes back HUMANISED, so `ph.lic_weapon`
    // became "Lic Weapon". The old test here was `L(key) !== key`, which is true for every
    // missing key, so the configured label was unreachable and every server saw the tidied
    // identifier instead of the name it had written in the config. Ask the string table
    // directly: present means translate, absent means fall through.
    title: hasString(l.i18n) ? L(l.i18n)
      : (l.label && l.label !== l.key ? l.label : placeName(l.key)),
    subtitle: l.issuer || '',
    value: l.held ? L('ph.lic_status_held') : L('ph.lic_status_none'),
    tone: l.held ? 'pos' : '',
  }))));
  wireCard();
};

// ── Jobs ───────────────────────────────────────────────────────
// Read only, and deliberately: signing on happens at a desk.
let jobsTab = 'me';

RENDER.jobs = async () => {
  tabbar([
    { id: 'me', icon: 'id', label: 'ph.my_job' },
    { id: 'open', icon: 'jobs', label: 'ph.openings' },
  ], jobsTab, (t) => { jobsTab = t; RENDER.jobs(); });
  loading();
  const d = await post('app', { app: 'jobs' });
  if (!d || d.error) { body(UI.empty(L('ph.err_' + ((d && d.error) || 'off')), 'jobs')); return; }

  if (jobsTab === 'open') {
    const list = d.jobs || [];
    body(list.length
      ? UI.group(list.map((j) => UI.row({
          icon: 'jobs', tint: '#5856D6', title: j.label || j.name,
          subtitle: (j.grade || '') + (j.ranks ? '  -  ' + j.ranks + ' ' + L('ph.ranks') : ''),
          value: money(j.salary), mono: true,
        })), { header: L('ph.openings'), footer: L('ph.jobs_hint') })
      : UI.empty(L('ph.no_jobs'), 'jobs'));
    return;
  }

  // The employment card: the job, the rank held inside it, and the whole ladder, so a
  // player can see where they stand rather than only what they are called.
  const me = d.me || {};
  const unemployed = !me.name || me.name === 'unemployed';
  if (unemployed) {
    body(UI.empty(L('ph.unemployed'), 'jobs') +
      '<div class="groupfoot">' + esc(L('ph.unemployed_hint')) + '</div>');
    return;
  }

  const ladder = me.ladder || [];
  const top = ladder.length ? ladder[ladder.length - 1].grade : me.grade;
  const pct = top > 0 ? Math.round((Number(me.grade) / top) * 100) : 100;

  body(
    // Who you are at work, in the shape a payslip uses.
    '<div class="jobcard">' +
      '<div class="jobname">' + esc(me.label || me.name) + '</div>' +
      '<div class="jobgrade">' + esc(me.gradeLabel || (L('ph.grade') + ' ' + me.grade)) + '</div>' +
      '<div class="jobpay">' + esc(money(me.salary)) + ' <span>' + esc(L('ph.per_pay')) + '</span></div>' +
    '</div>' +
    UI.group([
      UI.row({ icon: 'jobs', tint: '#5856D6', title: L('ph.employer'), value: me.label || me.name }),
      UI.row({ icon: 'id', tint: '#8E8E93', title: L('ph.rank'),
               value: (Number(me.grade) + 1) + ' / ' + (me.ranks || ladder.length || 1) }),
      UI.row({ icon: 'bank', tint: '#34C759', title: L('ph.salary'), value: money(me.salary), mono: true }),
    ]) +
    // Progress through the ladder, because a rank means nothing without the rungs.
    '<div class="grouphead">' + esc(L('ph.progression')) + '</div>' +
    '<div class="jobbar"><i style="width:' + pct + '%"></i></div>' +
    (ladder.length
      ? UI.group(ladder.map((g) => UI.row({
          icon: Number(g.grade) === Number(me.grade) ? 'check' : 'chevron',
          tint: Number(g.grade) === Number(me.grade) ? '#34C759' : '#48484A',
          title: g.name || (L('ph.grade') + ' ' + g.grade),
          subtitle: Number(g.grade) === Number(me.grade) ? L('ph.you_are_here') : '',
          value: money(g.salary), mono: true,
        })), { header: L('ph.ladder') })
      : '')
  );
};

// ── Settings ───────────────────────────────────────────────────
// The Settings rows that are nothing more than a stored boolean. `defaultOn` says which way
// an unset preference reads, so a row the player has never touched still shows the truth.
const SETTING_TOGGLES = {
  hidenumber:     { key: 'hideNumber' },
  streamer:       { key: 'streamer' },
  serverid:       { key: 'showServerId', defaultOn: true },
  silenceunknown: { key: 'silenceUnknown' },
  previews:       { key: 'previews', defaultOn: true },
  peek:           { key: 'peek', defaultOn: true },
};

RENDER.settings = () => {
  const p = state.prefs || {};
  body(
    UI.group([
      UI.row({ icon: 'phone', tint: '#0A84FF', title: p.deviceName || L('ph.setup_default_device'),
        subtitle: p.ownerName || '', chevron: true, data: { t: 'device_name' } }),
      // The copy still carries the real number: masking is about the screen.
      // The copy carries the REAL number, ungrouped: grouping is for the eye, and pasting
      // `415-555-0142` where `4155550142` was expected would be a bug this created.
      UI.row({ icon: 'phone', tint: '#34C759', title: L('ph.my_number'), value: myNum(state.number),
               data: { copy: state.number || '' } }),
      UI.row({ icon: 'folder', tint: '#5AC8FA', title: L('ph.grid'),
        value: (p.gridCols || 4) + ' x ' + (p.gridRows || 4), chevron: true, data: { t: 'grid' } }),
      UI.row({ icon: 'moon', tint: '#5856D6', title: L('ph.dark_mode'),
        value: L('ph.theme_' + (p.darkMode || (p.dark ? 'dark' : 'light'))), chevron: true, data: { t: 'theme' } }),
      UI.row({ icon: 'phone', tint: '#34C759', title: L('ph.vibrate'), toggle: p.vibrate !== false, data: { t: 'vibrate' } }),
      UI.row({ icon: 'speaker', tint: '#FF9500', title: L('ph.ringer'),
        value: Math.round((p.ringVolume ?? 0.7) * 100) + '%', chevron: true, data: { t: 'ringer' } }),
      UI.row({ icon: 'music', tint: '#FF2D55', title: L('ph.ringtone'),
        value: p.ringUrl ? L('ph.tone_custom') : L('ph.tone_' + (p.ringtone || 'classic')),
        chevron: true, data: { t: 'ringtone' } }),
      UI.row({ icon: 'bell', tint: '#FF9F0A', title: L('ph.alerttone'),
        value: p.alertUrl ? L('ph.tone_custom') : L('ph.tone_' + (p.alertTone || 'ping')),
        chevron: true, data: { t: 'alerttone' } }),
    ]) +
    (p.wallpaperUrl ? '<div class="wallpreview" style="' + inlineBackground(p.wallpaperUrl) + '"></div>' : '') +
    (state.customWallpaper === false ? '' :
      UI.field('wurl', L('ph.wall_url'), p.wallpaperUrl || '') +
      '<div class="seg">' +
        '<button class="' + (p.wallFit !== 'contain' ? 'on' : '') + '" data-fit="cover">' + esc(L('ph.fit_cover')) + '</button>' +
        '<button class="' + (p.wallFit === 'contain' ? 'on' : '') + '" data-fit="contain">' + esc(L('ph.fit_contain')) + '</button>' +
      '</div>' +
      UI.button(L('ph.wall_apply'), 'wapply') +
      (p.wallpaperUrl ? UI.button(L('ph.wall_clear'), 'wclear', 'plain') : '') +
      '<div class="groupfoot">' + esc(L('ph.wall_hint')) + '</div>') +
    UI.group((state.wallpapers || []).map((w) => UI.row({
      icon: 'wall', tint: '#007AFF', title: L('ph.wall_' + w),
      value: (!p.wallpaperUrl && p.wallpaper === w) ? L('ph.on') : '',
      data: { w },
    })), { header: L('ph.wallpaper') }) +
    // The device itself: how big, and which side it sits on.
    '<div class="grouphead">' + esc(L('ph.device')) + '</div>' +
    // No size slider, on purpose. The phone is laid out in pixels at 372x784, so any size
    // other than 100% is a `transform: scale()` over an already-rasterised image and every
    // glyph goes soft. Locking it to 100% is the only setting that renders exactly, and a
    // crisp phone at one size beats a fuzzy one at five. `Config.DeviceSize` is still there
    // for an operator who wants a different fixed size and will accept the softness.
    '<div class="sliderow">' +
      '<div class="seg">' +
        '<button class="' + (p.side !== 'left' ? 'on' : '') + '" data-side="right">' + esc(L('ph.side_right')) + '</button>' +
        '<button class="' + (p.side === 'left' ? 'on' : '') + '" data-side="left">' + esc(L('ph.side_left')) + '</button>' +
      '</div>' +
    '</div>' +
    UI.group([UI.row({ icon: 'moon', tint: '#5856D6', title: L('ph.dnd'), toggle: !!p.dnd, data: { t: 'dnd' } })],
      { footer: L('ph.dnd_hint') }) +
    // Calls and privacy. Withholding your number is only offered when the operator allows
    // it at all — a row that cannot do anything is worse than no row.
    UI.group([
      ...(state.allowAnonymous ? [UI.row({
        icon: 'lockshut', tint: '#8E8E93', title: L('ph.hide_number'),
        toggle: !!p.hideNumber, data: { t: 'hidenumber' },
      })] : []),
      UI.row({ icon: 'phone', tint: '#FF9500', title: L('ph.silence_unknown'),
        toggle: !!p.silenceUnknown, data: { t: 'silenceunknown' } }),
      UI.row({ icon: 'shield', tint: '#BF5AF2', title: L('ph.streamer'),
        subtitle: L('ph.streamer_sub'), toggle: !!p.streamer, data: { t: 'streamer' } }),
      UI.row({ icon: 'id', tint: '#64D2FF', title: L('ph.show_server_id'),
        subtitle: L('ph.show_server_id_sub'), toggle: p.showServerId !== false,
        data: { t: 'serverid' } }),
    ], { header: L('ph.calls_privacy'),
         footer: L(state.allowAnonymous ? 'ph.calls_privacy_hint' : 'ph.silence_unknown_hint') }) +
    // Security. The passcode and Face ID were set once during setup and then unreachable
    // for the life of the character - a phone whose code cannot be changed is a phone whose
    // code is shared the first time somebody looks over a shoulder.
    UI.group([
      UI.row({ icon: 'lockshut', tint: '#FF3B30', title: L('ph.sec_passcode'),
        subtitle: p.securityEnabled ? L('ph.sec_passcode_on') : L('ph.sec_passcode_off'),
        chevron: true, data: { t: 'passcode' } }),
      ...(p.securityEnabled ? [UI.row({
        icon: 'faceid', tint: '#30D158', title: L('ph.faceid'),
        subtitle: L('ph.sec_faceid_hint'),
        toggle: !!p.faceId, data: { t: 'faceid' },
      })] : []),
      ...(p.securityEnabled ? [UI.row({
        icon: 'lockopen', tint: '#8E8E93', title: L('ph.sec_off'),
        subtitle: L('ph.sec_off_hint'), chevron: true, data: { t: 'securityoff' },
      })] : []),
    ], { header: L('ph.sec_header'), footer: L('ph.sec_footer') }) +
    UI.group([
      UI.row({ icon: 'bell', tint: '#FF2D55', title: L('ph.previews'),
        toggle: p.previews !== false, data: { t: 'previews' } }),
      UI.row({ icon: 'phone', tint: '#0A84FF', title: L('ph.peek'),
        toggle: p.peek !== false, data: { t: 'peek' } }),
    ], { header: L('ph.notifications'), footer: L('ph.previews_hint') }) +
    // iOS 27's headline user-facing change. It is a stored preference every layer of
    // the glass derives from, not a fade on one overlay.
    '<div class="grouphead">' + esc(L('ph.transparency')) + '</div>' +
    '<div class="sliderow">' +
      '<div class="sl"><span>' + esc(L('ph.glass_clear')) + '</span>' +
      '<span>' + esc(L('ph.glass_tinted')) + '</span></div>' +
      '<input type="range" id="glass" min="0" max="100" step="1" aria-label="' +
        esc(L('ph.transparency')) + '" value="' + (p.glass ?? 55) + '" />' +
    '</div>' +
    '<div class="groupfoot">' + esc(L('ph.glass_hint')) + '</div>' +
    UI.group((state.apps || []).map((a) => UI.row({
      appicon: (UI.hasTile && UI.hasTile(a.id)) ? a.id : a.icon, title: L(a.label),
      value: p.actionApp === a.id ? L('ph.on') : '', data: { act: a.id },
    })), { header: L('ph.action_button'), footer: L('ph.action_hint') }) +
    // About, where a phone puts it: the last thing in Settings.
    UI.group([
      UI.row({ icon: 'phone', tint: '#8E8E93', title: L('ph.about_device'), value: 'iFruit' }),
      UI.row({ icon: 'id', tint: '#8E8E93', title: L('ph.about_dev'), value: 'vyrriox' }),
    ], { header: L('ph.about_title'), footer: L('ph.about_foot') })
  );
  const wa = byId('wapply');
  if (wa) wa.addEventListener('click', async () => {
    const res = await post('prefs', { wallpaperUrl: byId('wurl').value.trim() });
    if (res && res.ok) { state.prefs = res.prefs; applyWallpaper(); RENDER.settings(); }
    else toast(L('ph.err_' + ((res && res.error) || 'x')));
  });
  const wc = byId('wclear');
  if (wc) wc.addEventListener('click', async () => {
    const res = await post('prefs', { wallpaperUrl: '' });
    if (res && res.ok) { state.prefs = res.prefs; applyWallpaper(); RENDER.settings(); }
  });
  [...byId('appbody').querySelectorAll('[data-fit]')].forEach((b) =>
    b.addEventListener('click', async () => {
      const res = await post('prefs', { wallFit: b.dataset.fit });
      if (res && res.ok) { state.prefs = res.prefs; applyWallpaper(); RENDER.settings(); }
    }));
  [...byId('appbody').querySelectorAll('[data-side]')].forEach((b) =>
    b.addEventListener('click', async () => {
      const res = await post('prefs', { side: b.dataset.side });
      if (res && res.ok) { state.prefs = res.prefs; applyDevice(); RENDER.settings(); }
    }));
  const gl = byId('glass');
  if (gl) {
    // Repaint live while dragging so the value is judged by looking at it, and only
    // persist on release: one write per adjustment, not one per pixel.
    gl.addEventListener('input', () => {
      applyGlass(Number(gl.value));
      gl.style.setProperty('--fill-pct', gl.value + '%');
    });
    gl.addEventListener('change', async () => {
      const res = await post('prefs', { glass: Number(gl.value) });
      if (res && res.ok) state.prefs = res.prefs;
    });
    gl.style.setProperty('--fill-pct', (p.glass ?? 55) + '%');
  }

  rows('.row', (r) => r.addEventListener('click', async () => {
    if (r.dataset.w) {
      const res = await post('prefs', { wallpaper: r.dataset.w });
      if (res && res.ok) { state.prefs = res.prefs; applyWallpaper(); RENDER.settings(); }
    } else if (r.dataset.copy) {
      copyText(r.dataset.copy);
    } else if (r.dataset.t === 'device_name') {
      sheet(L('ph.setup_phone_name'),
        UI.field('settingsowner', L('ph.setup_your_name'), p.ownerName || '', 'maxlength="40"') +
        UI.field('settingsdevice', L('ph.setup_phone_name'), p.deviceName || '', 'maxlength="32"') +
        UI.button(L('ph.save'), 'settingsdevicesave', 'tinted'),
        () => byId('settingsdevicesave').addEventListener('click', async () => {
          const ownerName = byId('settingsowner').value.trim();
          const deviceName = byId('settingsdevice').value.trim();
          if (!ownerName || !deviceName) { toast(L('ph.setup_name_required')); return; }
          const epoch = sheetEpoch;
          const res = await post('prefs', { ownerName, deviceName });
          if (!closeSheet(false, epoch)) return;
          if (res && res.ok) { state.prefs = res.prefs; RENDER.settings(); }
        }));
      return;
    } else if (r.dataset.t === 'passcode') {
      passcodeSheet();
      return;
    } else if (r.dataset.t === 'securityoff') {
      // Turning it off needs the current code, for the obvious reason: otherwise anybody
      // holding an unlocked phone can remove the lock on it.
      passcodeAsk(L('ph.sec_off'), L('ph.sec_off_ask'), async (current) => {
        const check = await post('unlock', { passcode: current });
        if (!check || !check.ok) { toast(L('ph.wrong_passcode')); return false; }
        const res = await post('prefs', { securityEnabled: false, faceId: false });
        if (res && res.ok) { state.prefs = res.prefs; RENDER.settings(); toast(L('ph.sec_off_done')); }
        return true;
      });
      return;
    } else if (r.dataset.t === 'grid') {
      // The layouts a phone actually offers: fewer, larger icons or more, smaller ones.
      const opts = [[4, 4], [4, 5], [4, 6], [5, 5], [5, 6], [6, 6], [3, 4]];
      sheet(L('ph.grid'),
        UI.group(opts.map(([c, rw]) => UI.row({
          title: c + ' x ' + rw, subtitle: (c * rw) + ' ' + L('ph.grid_per_page'),
          value: ((p.gridCols || 4) === c && (p.gridRows || 4) === rw) ? '✓' : '',
          data: { gc: String(c), gr: String(rw) },
        }))) + '<div class="groupfoot">' + esc(L('ph.grid_hint')) + '</div>',
        () => [...byId('sheet').querySelectorAll('.row')].forEach((el) => el.addEventListener('click', async () => {
          const epoch = sheetEpoch;
          const res = await post('prefs', { gridCols: Number(el.dataset.gc), gridRows: Number(el.dataset.gr) });
          if (!closeSheet(false, epoch)) return;
          if (res && res.ok) { state.prefs = res.prefs; renderHome(); RENDER.settings(); }
        })));
      return;
    } else if (r.dataset.t === 'theme') {
      const t = state.theme || {};
      const opts = [['light', 'ph.theme_light'], ['dark', 'ph.theme_dark']];
      if (t.auto) opts.push(['auto', 'ph.theme_auto']);
      sheet(L('ph.dark_mode'),
        UI.group(opts.map(([k, lbl]) => UI.row({
          title: L(lbl), value: (state.prefs || {}).darkMode === k ? '\u2713' : '', data: { m: k },
        }))) + (t.auto ? '<div class="groupfoot">' + esc(L('ph.theme_auto_hint')) + '</div>' : ''),
        () => [...byId('sheet').querySelectorAll('.row')].forEach((el) => el.addEventListener('click', async () => {
          const epoch = sheetEpoch;
          const res2 = await post('prefs', { darkMode: el.dataset.m });
          if (!closeSheet(false, epoch)) return;
          if (res2 && res2.ok) { state.prefs = res2.prefs; applyTheme(); RENDER.settings(); }
        })));
      return;
    } else if (r.dataset.t === 'vibrate') {
      const res2 = await post('prefs', { vibrate: !((state.prefs || {}).vibrate !== false) });
      if (res2 && res2.ok) { state.prefs = res2.prefs; RENDER.settings(); }
      return;
    } else if (r.dataset.t === 'faceid') {
      // Turning it ON is an enrolment, not a boolean: the same scan the first-run assistant
      // runs, so the phone behaves the same way whichever screen it was set up from. Turning
      // it off is just the flag.
      if ((state.prefs || {}).faceId) {
        const res2 = await post('prefs', { faceId: false });
        if (res2 && res2.ok) { state.prefs = res2.prefs; RENDER.settings(); }
      } else {
        faceIdSheet();
      }
      return;
    } else if (SETTING_TOGGLES[r.dataset.t]) {
      // The plain on/off rows, which all behave identically: flip, save, redraw.
      const spec = SETTING_TOGGLES[r.dataset.t];
      const now = spec.defaultOn
        ? (state.prefs || {})[spec.key] !== false
        : !!(state.prefs || {})[spec.key];
      const res2 = await post('prefs', { [spec.key]: !now });
      if (res2 && res2.ok) {
        state.prefs = res2.prefs;
        RENDER.settings();
        // The lock screen is drawn on open, so a switch that changes what it says - the
        // server id, or streamer mode masking the number - has to repaint it now.
        paintLockMeta();
      }
      return;
    } else if (r.dataset.t === 'ringtone' || r.dataset.t === 'alerttone') {
      const isRing = r.dataset.t === 'ringtone';
      const sc = (state.sounds || {});
      const list = (isRing ? sc.ringtones : sc.alerts) || (isRing ? ['classic'] : ['ping']);
      const curTone = isRing ? (p.ringtone || 'classic') : (p.alertTone || 'ping');
      const curUrl = (isRing ? p.ringUrl : p.alertUrl) || '';
      sheet(L(isRing ? 'ph.ringtone' : 'ph.alerttone'),
        UI.group(list.map((t) => UI.row({
          icon: 'music', title: L('ph.tone_' + t),
          value: (!curUrl && curTone === t) ? '\u2713' : '', data: { tone: t },
        }))) +
        (sc.allowCustom === false ? '' :
          '<div class="grouphead">' + esc(L('ph.tone_link')) + '</div>' +
          UI.field('toneurl', L('ph.tone_link_ph'), curUrl, 'maxlength="400"') +
          UI.button(L('ph.tone_use'), 'toneset', 'tinted') +
          (curUrl ? UI.button(L('ph.tone_clear'), 'tonedel', 'plain') : '') +
          '<div class="groupfoot">' + esc(L('ph.tone_hint')) + '</div>'),
        () => {
          // Tapping a tone previews it, then saves - you hear what you picked.
          [...byId('sheet').querySelectorAll('.row')].forEach((el) => el.addEventListener('click', async () => {
            const tone = el.dataset.tone;
            const epoch = sheetEpoch;
            playTone(tone, null, (state.prefs || {}).ringVolume, false);
            const res = await post('prefs', isRing ? { ringtone: tone, ringUrl: '' } : { alertTone: tone, alertUrl: '' });
            if (res && res.ok && closeSheet(false, epoch)) { state.prefs = res.prefs; RENDER.settings(); }
          }));
          const setBtn = byId('toneset');
          if (setBtn) setBtn.addEventListener('click', async () => {
            const url = byId('toneurl').value.trim();
            const epoch = sheetEpoch;
            const res = await post('prefs', isRing ? { ringUrl: url } : { alertUrl: url });
            if (res && res.ok) {
              if (closeSheet(false, epoch)) {
                state.prefs = res.prefs;
                playTone(null, url, (state.prefs || {}).ringVolume, false);
                toast(L('ph.tone_saved'));
              }
            } else toast(L('ph.err_' + ((res && res.error) || 'x')));
          });
          const delBtn = byId('tonedel');
          if (delBtn) delBtn.addEventListener('click', async () => {
            const epoch = sheetEpoch;
            const res = await post('prefs', isRing ? { ringUrl: '' } : { alertUrl: '' });
            if (res && res.ok && closeSheet(false, epoch)) { state.prefs = res.prefs; RENDER.settings(); }
          });
        });
      return;
    } else if (r.dataset.t === 'ringer') {
      sheet(L('ph.ringer'),
        UI.group([0, 0.3, 0.7, 1].map((v) => UI.row({
          title: Math.round(v * 100) + '%', subtitle: v === 0 ? L('ph.ringer_off') : '',
          value: Math.abs(((state.prefs || {}).ringVolume ?? 0.7) - v) < 0.01 ? '\u2713' : '', data: { v: String(v) },
        }))),
        () => [...byId('sheet').querySelectorAll('.row')].forEach((el) => el.addEventListener('click', async () => {
          const epoch = sheetEpoch;
          const res2 = await post('prefs', { ringVolume: Number(el.dataset.v) });
          if (!closeSheet(false, epoch)) return;
          if (res2 && res2.ok) { state.prefs = res2.prefs; RENDER.settings(); }
        })));
      return;
    } else if (r.dataset.t === 'dark') {
      const res = await post('prefs', { dark: !(state.prefs || {}).dark });
      if (res && res.ok) { state.prefs = res.prefs; applyTheme(); RENDER.settings(); }
    } else if (r.dataset.act) {
      // Tapping the app already chosen clears it, so there is a way back to "nothing".
      const next = (state.prefs || {}).actionApp === r.dataset.act ? '' : r.dataset.act;
      const res = await post('prefs', { actionApp: next });
      if (res && res.ok) { state.prefs = res.prefs; RENDER.settings(); }
    } else if (r.dataset.t === 'dnd') {
      const res = await post('prefs', { dnd: !(state.prefs || {}).dnd });
      if (res && res.ok) {
        state.prefs = res.prefs;
        syncDndAudio();
        RENDER.settings();
      }
    }
  }));
};

// 0 is ultra clear, 100 fully tinted. Every material alpha is resolved from this value.
function applyGlass(v) {
  const k = Math.max(0, Math.min(100, Number(v) || 0)) / 100;
  const screen = byId('screen');
  screen.style.setProperty('--gk', String(k));
  // CEF is inconsistent with multiplication inside calc() when the factor comes from a
  // custom property. Resolve the material alphas here into plain numeric channels.
  screen.style.setProperty('--tint-a', (0.10 + k * 0.46).toFixed(3));
  screen.style.setProperty('--sheen-a', (0.12 + k * 0.10).toFixed(3));
  screen.style.setProperty('--rim-a', (0.22 + k * 0.18).toFixed(3));
}

function applyWallpaper() {
  const w = byId('wallpaper');
  const screen = byId('screen');
  const p = state.prefs || {};
  (state.wallpapers || []).forEach((x) => {
    w.classList.remove('wall-' + x);
    screen.classList.remove('wall-' + x);
  });
  if (p.wallpaperUrl) {
    // A linked image replaces the gradient rather than sitting on top of it, so the
    // class list cannot leave a stripe of the old one showing at the edges.
    w.style.backgroundImage = 'url("' + p.wallpaperUrl + '")';
    w.style.backgroundSize = (p.wallFit === 'contain') ? 'contain' : 'cover';
    // The band chosen when the photo was framed in the gallery, not blindly the middle.
    w.style.backgroundPosition = (p.wallFocus === undefined || p.wallFocus === null)
      ? 'center' : ('50% ' + focusOf(p.wallFocus) + '%');
    w.style.backgroundRepeat = 'no-repeat';
    w.style.backgroundColor = '#000';
    screen.style.backgroundImage = 'url("' + p.wallpaperUrl + '")';
    screen.style.backgroundSize = (p.wallFit === 'contain') ? 'contain' : 'cover';
    screen.style.backgroundPosition = (p.wallFocus === undefined || p.wallFocus === null)
      ? 'center' : ('50% ' + focusOf(p.wallFocus) + '%');
    screen.style.backgroundRepeat = 'no-repeat';
    screen.style.backgroundColor = '#000';
  } else {
    w.style.backgroundImage = '';
    w.style.backgroundSize = '';
    w.style.backgroundColor = '';
    screen.style.backgroundImage = '';
    screen.style.backgroundSize = '';
    screen.style.backgroundColor = '';
    const selected = p.wallpaper || 'ifruit';
    w.classList.add('wall-' + selected);
    // The screen itself carries the same material. During app/setup transforms this
    // prevents its old black fallback from flashing as a strip along the bottom edge.
    screen.classList.add('wall-' + selected);
  }
}

// The device's own shape. Both are per character, because a small screen and a
// left-handed player are not the same person's problem.
// An app is light by default, as it is on iOS. The chrome around it stays dark glass
// over the wallpaper, which is also how iOS behaves: the two are different surfaces.
// The status bar tells the truth about both. Neither number is the client's to invent:
// the server works them out from where the player actually is.
function applyPower(p) {
  if (!p) return;
  // A payload without a level (an old server, a fixture, a race at open) must fall
  // back to full rather than to NaN: Math.round(undefined) is the word NaN drawn in
  // the status bar, and it was.
  const raw = Number(p.battery);
  const b = Number.isFinite(raw) ? Math.max(0, Math.min(100, raw)) : 100;
  const el = byId('battery');
  el.style.setProperty('--batt', String(b / 100));
  el.style.setProperty('--batt-col', p.charging ? '#34C759' : (b <= 5 ? '#FF3B30' : (b <= 20 ? '#FF9500' : 'var(--sb-ink, #fff)')));
  byId('battpct').textContent = Math.round(b);

  state._power = p;
  const pr = state.prefs || {};
  // Airplane and a cellular kill-switch both mean no service, whatever the tower says.
  const off = pr.airplane || pr.cellular === false;
  const bars = off ? 0 : Math.max(0, Math.min(4, Number(p.signal ?? 4)));
  [...byId('bars').querySelectorAll('rect')].forEach((r) =>
    r.classList.toggle('off', Number(r.dataset.b) > bars));
  // No service is worth saying in words: an icon of four empty bars reads as a glitch.
  byId('nosvc').classList.toggle('hidden', bars > 0 || pr.airplane);
  applyStatusFlags();
}

// Airplane replaces the bars with its own glyph; wifi hides when switched off.
function applyStatusFlags() {
  const p = state.prefs || {};
  byId('apmode').classList.toggle('hidden', !p.airplane);
  byId('bars').classList.toggle('hidden', !!p.airplane);
  const wifi = byId('status').querySelector('.sright > svg:not(#bars):not(#apmode)');
  if (wifi) wifi.style.opacity = p.wifi === false ? '0' : '';
}

// Brightness is a real dimming veil, 0.35 to 1 of the wallpaper's light.
function applyBrightness() {
  const b = Math.max(0.35, Math.min(1, (state.prefs || {}).brightness ?? 1));
  byId('screen').style.setProperty('--dim', String(1 - b));
}

// Light, dark, or follow the in-game clock. Automatic is only offered if the operator
// left it on; the hours it flips at are theirs to set too.
let gameHour = null;      // last in-game hour we were told about

function darkNow() {
  const p = state.prefs || {}, t = state.theme || {};
  const mode = p.darkMode || (p.dark ? 'dark' : 'light');
  if (mode !== 'auto' || !t.auto) return mode === 'dark';
  if (gameHour == null) return p.dark === true;
  const from = Number(t.from ?? 20), to = Number(t.to ?? 6);
  // A start later than the end wraps over midnight, which is the normal case.
  return from <= to ? (gameHour >= from && gameHour < to)
                    : (gameHour >= from || gameHour < to);
}

function applyTheme() {
  const dark = darkNow();
  byId('screen').classList.toggle('dark', dark);
  if (openApp && openApp.page) frameEvent('theme', { dark, mode: (state.prefs || {}).darkMode || 'auto' });
}

let landscape = false;
// Whose phone is on screen, when it is not the player's own.
//
// Staff can hold another character's handset (see server/adminview.lua). Everything on the
// phone is then that character's, which is the point - and which is exactly why it has to be
// said out loud somewhere the phone's own UI cannot cover. The one failure mode this exists to
// prevent is a staff member forgetting and typing a message that goes out as somebody else.
function applyAdminView() {
  const host = byId('adminview');
  if (!host) return;
  const name = String(state.adminView || '').trim();
  host.classList.toggle('hidden', !name);
  if (name) host.textContent = L('ph.admin_holding').replace('{name}', name);
}

function applyDevice() {
  applyAdminView();
  const p = state.prefs || {};
  const d = byId('device');
  const size = Math.max(0.75, Math.min(1.15, Number(p.size) || 1));
  const viewport = window.visualViewport;
  const vw = (viewport && viewport.width) || window.innerWidth || 1280;
  const vh = (viewport && viewport.height) || window.innerHeight || 720;
  const rawW = d.offsetWidth || 372;
  const rawH = d.offsetHeight || 784;
  const footprintW = landscape ? rawH : rawW;
  const footprintH = landscape ? rawW : rawH;
  const fit = Math.max(0.10, Math.min(1,
    (vw - 24) / (footprintW * size),
    (vh - 24) / (footprintH * size)));
  const scale = size * fit;
  d.style.setProperty('--device-fit', String(fit));
  d.style.setProperty('--device-scale', String(scale));
  if (landscape) {
    // The phone lies on its side, centred so it cannot swing off-screen.
    d.style.left = '50%'; d.style.right = 'auto'; d.style.top = '50%'; d.style.bottom = 'auto';
    d.style.transformOrigin = 'center center';
    d.style.transform = 'translate(-50%, -50%) rotate(-90deg) scale(' + scale + ')';
  } else {
    d.style.top = 'auto'; d.style.bottom = '2.5vh';
    d.style.transformOrigin = (p.side === 'left') ? 'left bottom' : 'right bottom';
    d.style.transform = 'scale(' + scale + ')';
    d.style.right = (p.side === 'left') ? 'auto' : '3vw';
    d.style.left = (p.side === 'left') ? '3vw' : 'auto';
  }
}
function setLandscape(on) { landscape = on === true; applyDevice(); }

// -- Maps -------------------------------------------------------
// Everywhere the map already shows, turned into a waypoint. A phone map that could not
// set a waypoint would be a list of place names.
let placeFilter = 'all';

RENDER.maps = async () => {
  loading();
  const d = await post('places');
  if (!d || d.error) { body(UI.empty(L('ph.err_off'), 'map')); return; }
  const all = d.places || [];
  const kinds = [...new Set(all.map((p) => p.kind))];
  const shown = placeFilter === 'all' ? all : all.filter((p) => p.kind === placeFilter);

  body(
    '<div class="seg">' +
      '<button class="' + (placeFilter === 'all' ? 'on' : '') + '" data-k="all">' + esc(L('ph.all')) + '</button>' +
      kinds.map((k) => '<button class="' + (placeFilter === k ? 'on' : '') + '" data-k="' + esc(k) + '">' + esc(L('ph.place_' + k)) + '</button>').join('') +
    '</div>' +
    (shown.length
      ? UI.group(shown.map((pl, i) => UI.row({
          icon: pl.icon, title: pl.label, subtitle: L('ph.place_' + pl.kind),
          chevron: true, data: { i },
        })), { footer: L('ph.maps_hint') })
      : UI.empty(L('ph.no_places'), 'map'))
  );
  [...byId('appbody').querySelectorAll('.seg button')].forEach((b) =>
    b.addEventListener('click', () => { placeFilter = b.dataset.k; RENDER.maps(); }));
  rows('.row[data-i]', (r) => r.addEventListener('click', async () => {
    const pl = shown[Number(r.dataset.i)];
    if (!pl) return;
    await post('waypoint', { x: pl.x, y: pl.y, label: pl.label });
    toast(L('ph.waypoint_set'));
  }));
};

// -- Music ------------------------------------------------------
// v-music remains the authority for audible sources. The phone supplies the personal
// library, queue, favourites and listening history around those real controls.
let musicTab = 'listen';
let musicPlayerOpen = false;
let musicOutput = 'headphones';
let musicNow = null;
let musicQueue = [];
let musicQueueIndex = -1;
let musicSearch = '';

const MUSIC_TABS = [
  { id: 'listen', icon: 'play', label: 'ph.music_home' },
  { id: 'playlists', icon: 'folder', label: 'ph.playlists' },
  { id: 'radio', icon: 'speaker', label: 'ph.music_radio' },
  { id: 'library', icon: 'music', label: 'ph.library' },
  { id: 'search', icon: 'search', label: 'ph.search' },
];

// ── Playlists ──────────────────────────────────────────────────
// Two kinds, shown in one list. The operator's come from Config.Music.defaultPlaylists and
// are read-only: a player may play them and copy a track out, but not edit or delete them,
// so a server's own selections survive contact with its players. Theirs live in the same
// per-character phone storage the library uses, so no new table and no migration.
let musicPlaylistOpen = null;   // the id being viewed, or null for the list

async function musicPlaylists() {
  const mine = await musicStorage('playlists', []);
  return (Array.isArray(mine) ? mine : [])
    .filter((p) => p && p.id && p.name)
    .map((p) => ({
      id: String(p.id), name: String(p.name), icon: p.icon || 'music', tint: p.tint || null,
      tracks: (Array.isArray(p.tracks) ? p.tracks : []).filter((t) => t && t.url).map(musicNormalise),
      readonly: false,
    }));
}

async function musicSavePlaylists(list, limits) {
  const cap = bnum((limits || {}).playlists, 20);
  const perList = bnum((limits || {}).tracks, 100);
  const clean = list.filter((p) => !p.readonly).slice(0, cap).map((p) => ({
    id: p.id, name: String(p.name).slice(0, 40), icon: p.icon || 'music', tint: p.tint || null,
    tracks: p.tracks.slice(0, perList).map((t) => ({
      title: t.title, artist: t.artist, album: t.album, url: t.url, art: t.art,
    })),
  }));
  await post('appStorage', { app: 'music', op: 'set', key: 'playlists', value: JSON.stringify(clean) });
  return clean;
}

/** A playlist id that cannot collide with an operator's. */
function musicPlaylistId() {
  return 'p' + Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);
}
const MUSIC_PALETTES = [
  ['#ff4365', '#811848'], ['#ae63ff', '#45238c'], ['#ff9c45', '#a72841'],
  ['#4fc7ff', '#2450a4'], ['#54d8a0', '#126b68'], ['#f3d45b', '#bf4864'],
];

function musicNormalise(track, index) {
  const row = track && typeof track === 'object' ? track : {};
  return {
    title: String(row.title || L('ph.untitled')).slice(0, 80),
    artist: String(row.artist || L('ph.unknown_artist')).slice(0, 60),
    album: String(row.album || L('ph.single')).slice(0, 60),
    url: String(row.url || '').slice(0, 400),
    art: String(row.art || '').slice(0, 400),
    favorite: row.favorite === true,
    id: row.id,
    kind: row.kind,
    paused: row.paused === true,
    volume: Math.max(0, Math.min(1, Number(row.volume == null ? .65 : row.volume))),
    _libraryIndex: row._libraryIndex == null ? index : row._libraryIndex,
  };
}

function musicSeed(track) {
  const value = String((track && (track.title || track.url || track.id)) || 'music');
  let hash = 0;
  for (let i = 0; i < value.length; i += 1) hash = ((hash << 5) - hash + value.charCodeAt(i)) | 0;
  return Math.abs(hash) % MUSIC_PALETTES.length;
}

function musicArt(track, cls) {
  const palette = MUSIC_PALETTES[musicSeed(track)];
  const image = track && track.art ? inlineBackground(track.art) + ';' : '';
  return '<span class="musicart ' + esc(cls || '') + '" style="' + image +
    '--ma:' + palette[0] + ';--mb:' + palette[1] + '">' +
    '<i></i>' + svg('music') + '</span>';
}

// A playlist's own artwork.
//
// `musicArt` seeds a palette from a TRACK; a playlist has a name, an icon and sometimes a tint
// of its own, so this is the same span with those three instead. It exists because the playlist
// header used to roll its own markup with classes nothing styled - see the header below.
function musicPlaylistArt(playlist, cls) {
  const pl = playlist || {};
  // Only a hex colour reaches the style attribute. The tint round-trips through app storage,
  // which this page writes, so anything else is dropped rather than interpolated into CSS.
  const raw = String(pl.tint || '').trim();
  const tint = /^#[0-9a-fA-F]{3,8}$/.test(raw) ? raw : '';
  const palette = MUSIC_PALETTES[musicSeed({ title: pl.name || 'music' })];
  return '<span class="musicart ' + esc(cls || '') + '" style="--ma:' + (tint || palette[0]) +
    ';--mb:' + (tint || palette[1]) + '">' + '<i></i>' + svg(pl.icon || 'music') + '</span>';
}

async function musicStorage(key, fallback) {
  const r = await post('appStorage', { app: 'music', op: 'get', key });
  try {
    const value = JSON.parse((r && r.value) || '');
    return value == null ? fallback : value;
  } catch { return fallback; }
}

async function musicLibrary() {
  const manifest = await musicStorage('library_manifest', null);
  if (manifest && manifest.v === 2 && Number(manifest.chunks) > 0) {
    const parts = await Promise.all([...Array(Math.min(30, Number(manifest.chunks)))].map((_, i) =>
      musicStorage('library_' + i, [])));
    return parts.flat().filter((row) => row && row.url).slice(0, 120).map(musicNormalise);
  }
  const legacy = await musicStorage('library', []);
  return (Array.isArray(legacy) ? legacy : []).filter((row) => row && row.url).map(musicNormalise);
}

async function musicSaveLibrary(library) {
  const clean = library.slice(0, 120).map((row) => {
    const track = musicNormalise(row);
    return {
      title: track.title, artist: track.artist, album: track.album, url: track.url,
      art: track.art, favorite: track.favorite,
    };
  });
  const chunks = [];
  let current = [];
  clean.forEach((track) => {
    const next = current.concat(track);
    if (current.length && JSON.stringify(next).length > 3400) {
      chunks.push(current);
      current = [track];
    } else current = next;
  });
  if (current.length || !chunks.length) chunks.push(current);
  for (let i = 0; i < chunks.length; i += 1) {
    const r = await post('appStorage', {
      app: 'music', op: 'set', key: 'library_' + i, value: JSON.stringify(chunks[i]),
    });
    if (!r || r.error) return r || { error: 'x' };
  }
  return post('appStorage', {
    app: 'music', op: 'set', key: 'library_manifest',
    value: JSON.stringify({ v: 2, chunks: chunks.length }),
  });
}

async function musicRemember(track) {
  if (!track || !track.url) return;
  const recent = await musicStorage('recent', []);
  const keys = [track.url].concat((Array.isArray(recent) ? recent : []).filter((url) => url !== track.url)).slice(0, 18);
  await post('appStorage', { app: 'music', op: 'set', key: 'recent', value: JSON.stringify(keys) });
}

function musicKind(kind) {
  const key = 'ph.music_' + String(kind || 'headphones');
  // Same trap as the licence rows: `L()` humanises a miss instead of returning the key, so
  // `L(key) === key` was never true and an unknown speaker kind printed a tidied identifier
  // rather than the generic "device" label this line exists to reach.
  return hasString(key) ? L(key) : L('ph.music_device');
}

async function musicModel() {
  const [library, service, recentKeys, mine] = await Promise.all([
    musicLibrary(),
    post('app', { app: 'music' }),
    musicStorage('recent', []),
    musicPlaylists(),
  ]);
  // The operator's read-only playlists first, then the player's own.
  const playlists = ((service && service.playlists) || [])
    .map((p) => Object.assign({}, p, { tracks: (p.tracks || []).map(musicNormalise), readonly: true }))
    .concat(mine);
  const limits = (service && service.limits) || {};
  const sources = ((service && service.sources) || []).map((source, index) => {
    const saved = library.find((track) => track.url && track.url === source.url);
    return musicNormalise(Object.assign({}, saved || {}, source, {
      artist: (saved && saved.artist) || musicKind(source.kind),
      album: (saved && saved.album) || L('ph.music_live_source'),
      _libraryIndex: saved ? saved._libraryIndex : null,
    }), library.length + index);
  });
  const recent = (Array.isArray(recentKeys) ? recentKeys : [])
    .map((url) => library.find((track) => track.url === url)).filter(Boolean);
  let current = null;
  if (musicNow) current = sources.find((source) => source.id === musicNow.id || (source.url && source.url === musicNow.url));
  current = current || sources.find((source) => !source.paused) || sources[0] || musicNow;
  if (current) musicNow = Object.assign({}, musicNow || {}, current);
  return {
    library, sources, recent, playlists, limits,
    current: current ? musicNormalise(current) : null,
    enabled: !service || (!service.error && service.enabled !== false),
    // True when the deck cannot be driven and the track has to be pasted. The app says so
    // once, on the playlists screen, rather than leaving the player guessing.
    handoff: !!(service && service.handoff),
    provider: (service && service.provider) || null,
  };
}

function musicSection(title, action) {
  return '<div class="musicsection"><h2>' + esc(title) + '</h2>' +
    (action ? '<button type="button" data-msection="' + esc(action.id) + '">' + esc(action.label) + '</button>' : '') +
    '</div>';
}

function musicCard(track, index, wide) {
  return '<button class="musiccard' + (wide ? ' wide' : '') + '" data-mtrack="' + index + '" type="button">' +
    musicArt(track, 'cardart') +
    '<span class="musiccardcopy"><b>' + esc(track.title) + '</b><small>' + esc(track.artist) + '</small></span></button>';
}

function musicTrackRow(track, index, live) {
  return '<div class="musictrackrow' + (live && !track.paused ? ' live' : '') + '">' +
    '<button class="musictrackmain" data-mtrack="' + index + '" type="button">' +
      musicArt(track, 'rowart') +
      '<span><b>' + esc(track.title) + '</b><small>' +
        esc(live ? musicKind(track.kind) : track.artist + ' · ' + track.album) + '</small></span>' +
      (live ? '<em>' + esc(track.paused ? L('ph.paused') : L('ph.live')) + '</em>' : '') +
    '</button>' +
    '<button class="musicmore" data-maction="' + index + '" type="button" aria-label="' + esc(L('ph.more')) + '">' +
      '<i></i><i></i><i></i></button></div>';
}

function musicHero(track) {
  if (!track) {
    return '<div class="musichero emptyhero"><div class="musicorbits">' + svg('music') + '</div>' +
      '<span>' + esc(L('ph.music_welcome')) + '</span><h2>' + esc(L('ph.music_yours')) + '</h2>' +
      '<p>' + esc(L('ph.music_welcome_hint')) + '</p>' +
      '<button id="musicemptyadd" type="button">' + svg('add') + esc(L('ph.track_add')) + '</button></div>';
  }
  return '<div class="musichero" style="--hero-a:' + MUSIC_PALETTES[musicSeed(track)][0] +
    ';--hero-b:' + MUSIC_PALETTES[musicSeed(track)][1] + '">' +
    '<div class="musicheroart">' + musicArt(track, 'heroart') + '</div>' +
    '<div class="musicherocopy"><span>' + esc(L('ph.music_top_pick')) + '</span>' +
      '<h2>' + esc(track.title) + '</h2><p>' + esc(track.artist + ' · ' + track.album) + '</p>' +
      '<div><button id="musicheroplay" type="button">' + svg('play') + esc(L('ph.play')) + '</button>' +
      '<button id="musicheromore" type="button" aria-label="' + esc(L('ph.more')) + '">•••</button></div></div></div>';
}

function musicTabHTML(current) {
  return '<div class="tabbar musictabs">' + MUSIC_TABS.map((tab) =>
    '<button class="' + (tab.id === current ? 'on' : '') + '" data-mtab="' + tab.id + '" type="button" ' +
      'aria-current="' + (tab.id === current ? 'page' : 'false') + '">' +
      svg(tab.icon) + '<span>' + esc(L(tab.label)) + '</span></button>').join('') + '</div>';
}

function musicMiniHTML(current) {
  if (!current) return '';
  return '<div class="musicmini">' +
    '<button class="musicminiopen" id="musicminiopen" type="button">' + musicArt(current, 'miniart') +
      '<span><b>' + esc(current.title) + '</b><small>' + esc(current.artist || musicKind(current.kind)) + '</small></span></button>' +
    '<button id="musicminiplay" type="button" aria-label="' + esc(current.paused ? L('ph.resume') : L('ph.pause')) + '">' +
      svg(current.paused ? 'play' : 'pause') + '</button>' +
    '<button id="musicmininext" type="button" aria-label="' + esc(L('ph.next')) + '">' + svg('chevron') + '</button>' +
    // A way out, always.
    //
    // Whatever put the phone in a state where this bar is showing something it should not, the
    // player has to be able to close it. That is the whole lesson of the folder that could not be
    // emptied: a screen with no exit is a bug report waiting to happen.
    '<button class="musiministop" id="musiministop" type="button" aria-label="' +
      esc(L('ph.music_stop')) + '">' + svg('xmark') + '</button></div>';
}

function musicFoot(model) {
  foot('<div class="musicfoot">' + musicMiniHTML(model.current) + musicTabHTML(musicTab) + '</div>');
  [...byId('appfoot').querySelectorAll('[data-mtab]')].forEach((button) =>
    button.addEventListener('click', () => {
      musicTab = button.dataset.mtab;
      musicPlayerOpen = false;
      musicSearch = '';
      RENDER.music();
    }));
  const open = byId('musicminiopen');
  if (open) open.addEventListener('click', () => { musicPlayerOpen = true; RENDER.music(); });
  const toggle = byId('musicminiplay');
  if (toggle) toggle.addEventListener('click', () => musicToggle(model.current));
  const next = byId('musicmininext');
  if (next) next.addEventListener('click', () => musicStep(1));
  const stop = byId('musiministop');
  if (stop) stop.addEventListener('click', () => musicStop());
}

function musicWireTracks(tracks, queue) {
  rows('[data-mtrack]', (button) => button.addEventListener('click', () => {
    const index = Number(button.dataset.mtrack);
    musicPlay(tracks[index], queue || tracks);
  }));
  rows('[data-maction]', (button) => button.addEventListener('click', () => {
    const track = tracks[Number(button.dataset.maction)];
    musicTrackSheet(track, track && track._libraryIndex);
  }));
}

// No deck installed. The app still works - a library is a library - so this is a line rather
// than an empty screen, and it names what is actually missing.
//
// A FUNCTION taking the model, not a local. It was a `const` in `RENDER.music` and used in
// `musicRenderPlaylists`, which is a different function - so opening the playlists tab threw
// `noDeck is not defined` and left the view half drawn. Derived from the argument every one of
// these functions already has, so it cannot be out of scope anywhere.
function musicNoDeckHint(model) {
  if (!model || model.provider) return '';
  return '<div class="groupfoot">' + esc(L('ph.music_nodeck_hint')) + '</div>';
}

async function musicPlay(track, queue, output) {
  if (!track || !track.url) { toast(L('ph.track_nourl')); return; }
  const kind = output || musicOutput;
  const result = await post('music', {
    action: 'play', kind, url: track.url, title: track.title, volume: track.volume || .65,
  });
  if (!result || !result.ok) {
    toast(L('ph.err_' + ((result && result.error) || 'x')));
    return;
  }
  // A deck that cannot be driven gets the URL on the clipboard and opens itself; the player
  // pastes. Lua has no clipboard, so the copy has to happen here.
  if (result.copy) {
    copySdkText(result.copy);
    toast(L('ph.music_copied'));
  }
  musicOutput = kind;
  musicQueue = (queue && queue.length ? queue : [track]).map(musicNormalise);
  musicQueueIndex = Math.max(0, musicQueue.findIndex((row) => row.url === track.url));
  // `result.id` was never sent by anything. A phone plays ONE track, so "the current track"
  // needs no identifier at all - and requiring one is what broke pause and the volume slider:
  // both were guarded on `current.id`, which was always undefined, so pause silently replayed
  // the track from the start and the slider posted nothing.
  musicNow = Object.assign({}, musicNormalise(track), {
    kind, paused: false, volume: track.volume || .65,
  });
  // The control centre's media tile reads this rather than asking the deck, because a deck
  // that plays a URL has no idea what a phone considers to be "now playing".
  ccNow = musicNow;
  await musicRemember(track);
  toast(kind === 'headphones' ? L('ph.playing_ear') : L('ph.playing'));
  if (openApp && openApp.id === 'music') RENDER.music(true);
}

// Stop, and forget what was playing.
//
// `musicNow` is what draws the mini player, and nothing ever cleared it: `model.current` ends in
// `|| musicNow`, so a track deleted from the library came back as the current one and the bar at
// the bottom of the Music app could not be got rid of. Stopping has to be a real state change,
// not just a pause.
async function musicStop() {
  await post('music', { action: 'stop' });
  musicNow = null;
  ccNow = null;
  musicQueue = [];
  musicQueueIndex = 0;
  musicPlayerOpen = false;
  if (openApp && openApp.id === 'music') RENDER.music(true);
}

/// Repaint only what pausing changes: the two play buttons and the status line.
///
/// Pausing used to call `RENDER.music()`, which begins with `loading()` - so the whole app
/// blanked to "Loading..." and rebuilt itself, fetching the library, the playlists and the
/// deck again, every single time somebody pressed pause. It looked like the app reloading
/// because it was. Nothing about the library changed; one glyph did.
function musicPaintPlaying() {
  const paused = !!(musicNow && musicNow.paused);
  const icon = paused ? 'play' : 'pause';
  const label = L(paused ? 'ph.resume' : 'ph.pause');

  for (const id of ['musicminiplay', 'mplaymain']) {
    const button = byId(id);
    if (!button) continue;
    button.innerHTML = svg(icon);
    button.setAttribute('aria-label', label);
  }
  // The full player also says what the deck is doing, in words.
  const status = byId('appbody').querySelector('.musicactivity em');
  if (status) status.textContent = paused ? L('ph.paused') : L('ph.music_synced');
  const wave = byId('appbody').querySelector('.musicactivity');
  if (wave) wave.classList.toggle('ispaused', paused);
}

async function musicToggle(track) {
  const current = track || musicNow;
  if (!current) return;
  // Nothing is playing yet: the button is a play button, so play.
  if (!musicNow || musicNow.url !== current.url) {
    await musicPlay(current, musicQueue.length ? musicQueue : [current]);
    return;
  }
  const action = current.paused ? 'resume' : 'pause';
  const result = await post('music', { action });
  if (!result || result.error) { toast(L('ph.err_' + ((result && result.error) || 'x'))); return; }
  musicNow.paused = action === 'pause';
  // `current` may be the model's copy rather than `musicNow`, and the buttons are drawn from
  // whichever the view is holding. Both, or the icon flips back on the next repaint.
  current.paused = musicNow.paused;
  ccNow = musicNow;
  if (openApp && openApp.id === 'music') musicPaintPlaying();
}

async function musicStep(direction) {
  if (!musicQueue.length) return;
  musicQueueIndex = (musicQueueIndex + direction + musicQueue.length) % musicQueue.length;
  await musicPlay(musicQueue[musicQueueIndex], musicQueue, musicOutput);
}

async function musicFavourite(track) {
  if (!track || !track.url) return;
  const library = await musicLibrary();
  let index = library.findIndex((row) => row.url === track.url);
  if (index < 0) {
    library.unshift(Object.assign({}, musicNormalise(track), { favorite: true }));
  } else {
    library[index].favorite = !library[index].favorite;
  }
  await musicSaveLibrary(library);
  toast(L(index < 0 || library[index].favorite ? 'ph.music_favorited' : 'ph.music_unfavorited'));
  RENDER.music(true);
}

function musicAdd(existing, index) {
  const track = existing ? musicNormalise(existing) : null;
  sheet(L(track ? 'ph.track_edit' : 'ph.track_add'),
    '<div class="musicedithead">' + musicArt(track || { title: L('ph.new_track') }, 'editart') +
      '<div><b>' + esc(track ? track.title : L('ph.new_track')) + '</b><small>' + esc(L('ph.music_metadata')) + '</small></div></div>' +
    UI.field('mtitle', L('ph.track_title'), (track && track.title) || '', 'maxlength="80"') +
    UI.field('martist', L('ph.track_artist'), (track && track.artist) || '', 'maxlength="60"') +
    UI.field('malbum', L('ph.track_album'), (track && track.album) || '', 'maxlength="60"') +
    UI.field('murl', L('ph.track_url'), (track && track.url) || '', 'maxlength="400"') +
    UI.field('mart', L('ph.track_art'), (track && track.art) || '', 'maxlength="400"') +
    UI.button(L('ph.save'), 'mtsave', 'tinted') +
    '<div class="groupfoot">' + esc(L('ph.track_hint')) + '</div>',
    () => byId('mtsave').addEventListener('click', async () => {
      const url = byId('murl').value.trim();
      if (!url) { toast(L('ph.track_nourl')); return; }
      const epoch = sheetEpoch;
      const library = await musicLibrary();
      if (epoch !== sheetEpoch) return;
      const next = musicNormalise({
        title: byId('mtitle').value.trim() || L('ph.untitled'),
        artist: byId('martist').value.trim() || L('ph.unknown_artist'),
        album: byId('malbum').value.trim() || L('ph.single'),
        url, art: byId('mart').value.trim(),
        favorite: track && track.favorite,
      });
      if (index != null && library[index]) library[index] = next; else library.unshift(next);
      const result = await musicSaveLibrary(library);
      if (!result || result.error) { toast(L('ph.err_' + ((result && result.error) || 'x'))); return; }
      if (closeSheet(false, epoch)) RENDER.music(true);
    }), 'music-edit');
}

function musicTrackSheet(track, index) {
  if (!track) return;
  const saved = index != null;
  sheet(track.title,
    '<div class="musictrackdetail">' + musicArt(track, 'sheetart') +
      '<div><h2>' + esc(track.title) + '</h2><p>' + esc(track.artist + ' · ' + track.album) + '</p></div></div>' +
    '<div class="musicquickactions">' +
      '<button id="mquickplay" type="button">' + svg('play') + '<span>' + esc(L('ph.play')) + '</span></button>' +
      '<button id="mquickfav" type="button">' + svg(track.favorite ? 'heart' : 'star') + '<span>' +
        esc(track.favorite ? L('ph.favorited') : L('ph.favorite')) + '</span></button>' +
      '<button id="mquickqueue" type="button">' + svg('add') + '<span>' + esc(L('ph.add_queue')) + '</span></button></div>' +
    UI.button(L('ph.choose_output'), 'moutput', 'plain') +
    UI.button(L('ph.airdrop_share'), 'mshare', 'plain') +
    (saved ? UI.button(L('ph.track_edit'), 'medit', 'plain') : '') +
    (saved ? UI.button(L('ph.delete'), 'mdelt', 'destructive') : ''),
    () => {
      byId('mquickplay').addEventListener('click', () => { closeSheet(); musicPlay(track, musicQueue.length ? musicQueue : [track]); });
      byId('mquickfav').addEventListener('click', () => { closeSheet(); musicFavourite(track); });
      byId('mquickqueue').addEventListener('click', () => {
        if (!musicQueue.some((row) => row.url === track.url)) musicQueue.push(musicNormalise(track));
        closeSheet(); toast(L('ph.added_queue'));
      });
      byId('moutput').addEventListener('click', () => musicOutputSheet(track));
      // Pass the track to somebody standing next to you. A link and two labels, which is
      // exactly what a track is on this phone - so the person receiving it gets a library
      // entry they can play, not a copy of a file.
      byId('mshare').addEventListener('click', () => airdropShare('track', {
        url: track.url, title: track.title, artist: track.artist,
      }));
      if (saved) byId('medit').addEventListener('click', () => { closeSheet(); musicAdd(track, index); });
      if (saved) byId('mdelt').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        const library = await musicLibrary();
        if (epoch !== sheetEpoch) return;
        library.splice(index, 1);
        await musicSaveLibrary(library);
        // Deleting what is playing stops it. Anything else leaves a track playing that the
        // player has just thrown away, with a mini player they cannot dismiss because the
        // library no longer holds the row it was drawn from.
        if (musicNow && track && musicNow.url === track.url) {
          await musicStop();
          closeSheet(false, epoch);
          return;
        }
        if (closeSheet(false, epoch)) RENDER.music(true);
      });
    }, 'music-actions');
}

function musicOutputSheet(track) {
  const source = track || musicNow;
  const returnToTrack = byId('sheet').classList.contains('on');
  const outputs = [
    { id: 'headphones', icon: 'bt', label: L('ph.music_headphones'), hint: L('ph.output_private') },
    { id: 'phone', icon: 'speaker', label: L('ph.music_phone'), hint: L('ph.output_nearby') },
    { id: 'vehicle', icon: 'garage', label: L('ph.music_vehicle'), hint: L('ph.output_vehicle') },
  ];
  sheet(L('ph.choose_output'),
    '<div class="musicoutputs">' + outputs.map((output) =>
      '<button data-moutput="' + output.id + '" type="button"><span>' + svg(output.icon) + '</span><div><b>' +
        esc(output.label) + '</b><small>' + esc(output.hint) + '</small></div>' +
        (musicOutput === output.id ? svg('check') : '') + '</button>').join('') + '</div>',
    () => [...byId('sheet').querySelectorAll('[data-moutput]')].forEach((button) =>
      button.addEventListener('click', () => {
        musicOutput = button.dataset.moutput;
        closeSheet(true);
        if (source && source.url) musicPlay(source, musicQueue.length ? musicQueue : [source], musicOutput);
      })), 'music-output');
  if (returnToTrack) sheetReturn = () => musicTrackSheet(source, source && source._libraryIndex);
}

function musicQueueSheet() {
  sheet(L('ph.up_next'),
    musicQueue.length
      ? '<div class="musicqueue">' + musicQueue.map((track, index) =>
        '<button data-mqueue="' + index + '" type="button">' + musicArt(track, 'queueart') +
          '<span><b>' + esc(track.title) + '</b><small>' + esc(track.artist) + '</small></span>' +
          (index === musicQueueIndex ? '<em>' + svg('speaker') + '</em>' : '<i>≡</i>') + '</button>').join('') + '</div>' +
        UI.button(L('ph.clear_queue'), 'mclearqueue', 'destructive')
      : UI.empty(L('ph.queue_empty'), 'music'),
    () => {
      [...byId('sheet').querySelectorAll('[data-mqueue]')].forEach((button) =>
        button.addEventListener('click', () => {
          musicQueueIndex = Number(button.dataset.mqueue);
          closeSheet(); musicPlay(musicQueue[musicQueueIndex], musicQueue);
        }));
      const clear = byId('mclearqueue');
      if (clear) clear.addEventListener('click', () => { musicQueue = []; musicQueueIndex = -1; closeSheet(); });
    }, 'music-queue');
}

function musicRenderPlayer(model) {
  const current = model.current || musicNow;
  if (!current) { musicPlayerOpen = false; RENDER.music(); return; }
  setNav(L('ph.nowplaying'), L('app.music'), null, () => {
    musicPlayerOpen = false;
    RENDER.music();
  });
  foot('');
  body('<div class="musicplayer" style="--player-a:' + MUSIC_PALETTES[musicSeed(current)][0] +
      ';--player-b:' + MUSIC_PALETTES[musicSeed(current)][1] + '">' +
    '<div class="musicplayerglow"></div>' +
    '<div class="musicplayerhead">' + musicArt(current, 'playerart') + '</div>' +
    '<div class="musicplayercopy"><span>' + esc(musicKind(current.kind || musicOutput)) + '</span>' +
      '<h1>' + esc(current.title) + '</h1><p>' + esc(current.artist) + '</p></div>' +
    '<div class="musicactivity"><span><i></i><i></i><i></i><i></i><i></i></span><em>' +
      esc(current.paused ? L('ph.paused') : L('ph.music_synced')) + '</em></div>' +
    '<div class="musiccontrols">' +
      '<button id="mprevious" type="button" aria-label="' + esc(L('ph.previous')) + '">' +
        '<span class="musicprevicon">' + svg('play') + '</span></button>' +
      '<button class="musicplaymain" id="mplaymain" type="button" aria-label="' +
        esc(current.paused ? L('ph.resume') : L('ph.pause')) + '">' + svg(current.paused ? 'play' : 'pause') + '</button>' +
      '<button id="mnext" type="button" aria-label="' + esc(L('ph.next')) + '">' + svg('play') + '</button></div>' +
    '<div class="musicvolume">' + svg('speaker') +
      '<input id="mvolume" type="range" min="0" max="100" value="' + Math.round(current.volume * 100) +
        '" aria-label="' + esc(L('ph.volume')) + '" />' + svg('speaker') + '</div>' +
    '<div class="musicplayeractions">' +
      '<button id="mplayerfav" type="button">' + svg(current.favorite ? 'heart' : 'star') + '<span>' + esc(L('ph.favorite')) + '</span></button>' +
      '<button id="mplayerout" type="button">' + svg('airdrop') + '<span>' + esc(L('ph.output')) + '</span></button>' +
      '<button id="mplayerqueue" type="button">' + svg('note') + '<span>' + esc(L('ph.queue')) + '</span></button></div>' +
    UI.button(L('ph.music_stop'), 'mplayerstop', 'plain') + '</div>');
  byId('mplaymain').addEventListener('click', () => musicToggle(current));
  byId('mprevious').addEventListener('click', () => musicStep(-1));
  byId('mnext').addEventListener('click', () => musicStep(1));
  byId('mplayerfav').addEventListener('click', () => musicFavourite(current));
  byId('mplayerout').addEventListener('click', () => musicOutputSheet(current));
  byId('mplayerqueue').addEventListener('click', musicQueueSheet);
  if (byId('mplayerstop')) byId('mplayerstop').addEventListener('click', () => musicStop());
  const slider = byId('mvolume');
  // Set once at render, not only on the first drag: the filled part of the track is drawn from
  // this, so without it the slider opens looking empty whatever the volume actually is.
  slider.style.setProperty('--volume', slider.value + '%');
  slider.addEventListener('input', () => slider.style.setProperty('--volume', slider.value + '%'));
  slider.addEventListener('change', async () => {
    const value = Number(slider.value) / 100;
    if (musicNow) musicNow.volume = value;
    // No id guard. There never was an id, so this line never ran and the slider moved a
    // handle and changed nothing.
    const r = await post('music', { action: 'volume', volume: value });
    if (r && r.error) toast(L('ph.err_' + r.error));
  });
  let swipe = null;
  const player = byId('appbody').querySelector('.musicplayer');
  player.addEventListener('pointerdown', (event) => {
    if (event.target.closest('button,input')) return;
    swipe = { y: event.clientY, id: event.pointerId };
    player.setPointerCapture(event.pointerId);
  });
  player.addEventListener('pointermove', (event) => {
    if (!swipe || event.pointerId !== swipe.id) return;
    const dy = Math.max(0, event.clientY - swipe.y);
    player.style.setProperty('--player-y', Math.min(120, dy) + 'px');
  });
  player.addEventListener('pointerup', (event) => {
    if (!swipe || event.pointerId !== swipe.id) return;
    const dy = Math.max(0, event.clientY - swipe.y);
    swipe = null;
    player.style.removeProperty('--player-y');
    if (dy > 74) { musicPlayerOpen = false; RENDER.music(); }
  });
}

function musicRenderSearch(model) {
  const draw = () => {
    const query = musicSearch.trim().toLowerCase();
    const all = model.library.concat(model.sources.filter((source) =>
      !model.library.some((track) => track.url && track.url === source.url)));
    const shown = query ? all.filter((track) =>
      [track.title, track.artist, track.album].some((value) => String(value || '').toLowerCase().includes(query))) : model.recent;
    const host = byId('musicsearchresults');
    if (!host) return;
    host.innerHTML = shown.length
      ? musicSection(query ? L('ph.results') : L('ph.recently_played')) +
        '<div class="musictracklist">' + shown.map((track, index) => musicTrackRow(track, index, !!track.id)).join('') + '</div>'
      : '<div class="musicsearchempty">' + svg('search') + '<b>' +
        esc(query ? L('ph.no_results') : L('ph.music_search_hint')) + '</b><span>' +
        esc(query ? L('ph.music_try_search') : L('ph.music_search_everything')) + '</span></div>';
    musicWireTracks(shown, model.library);
  };
  body('<div class="musicsearchbox">' + svg('search') +
    '<input id="musicq" value="' + esc(musicSearch) + '" placeholder="' + esc(L('ph.music_search_placeholder')) +
      '" autocomplete="off" /><button id="musicqclear" type="button" aria-label="' + esc(L('ph.clear')) + '">' +
      svg('xmark') + '</button></div><div id="musicsearchresults"></div>');
  draw();
  const input = byId('musicq');
  input.addEventListener('input', () => {
    musicSearch = input.value;
    byId('musicqclear').classList.toggle('visible', !!musicSearch);
    draw();
  });
  byId('musicqclear').classList.toggle('visible', !!musicSearch);
  byId('musicqclear').addEventListener('click', () => {
    musicSearch = ''; input.value = ''; input.focus();
    byId('musicqclear').classList.remove('visible'); draw();
  });
}

/** The playlist list, or one playlist opened. */
async function musicRenderPlaylists(model) {
  const open = musicPlaylistOpen
    && model.playlists.find((p) => p.id === musicPlaylistOpen);

  // ── One playlist ────────────────────────────────────────────
  if (open) {
    // `setNav(title, backLabel, action, onBack)`.
    //
    // The closure was passed as the LABEL, so the back button rendered its own source code as
    // its text - `() => { musicPlaylistOpen = null; RENDER.music(); }` across two lines of the
    // nav bar - and, because the fourth argument was missing, pressing it left the app entirely
    // instead of going back to the list of playlists.
    setNav(open.name, L('ph.playlists'),
      open.readonly ? null : { icon: 'add', label: L('ph.playlist_add_track'),
        onClick: () => musicAddToPlaylist(model, open) },
      () => { musicPlaylistOpen = null; RENDER.music(); });
    body(
      // The header uses `musictrackdetail`, which is the styled one.
      //
      // It used to use `musicplhead` and `musicplart` - two class names that appear nowhere in
      // the stylesheet. An unstyled div around an unstyled svg is a picture at its intrinsic
      // size, so the playlist icon filled the screen and the name ran straight into the track
      // count with no space between them.
      '<div class="musictrackdetail">' + musicPlaylistArt(open, 'sheetart') +
      '<div><h2>' + esc(open.name) + '</h2><p>' +
      esc(L('ph.playlist_count').replace('{n}', String(open.tracks.length)) +
          (open.readonly ? ' · ' + L('ph.playlist_locked') : '')) + '</p></div></div>' +
      (open.tracks.length
        ? UI.button(L('ph.play_all'), 'plplay', 'tinted') +
          '<div class="musictracklist">' +
          open.tracks.map((t, i) => musicTrackRow(t, i, true)).join('') + '</div>'
        : UI.empty(L('ph.playlist_empty'), 'music')));

    const play = byId('plplay');
    if (play) play.addEventListener('click', () => musicPlay(open.tracks[0], open.tracks));
    musicWireTracks(open.tracks, model.library);
    return;
  }

  // ── The list ────────────────────────────────────────────────
  musicPlaylistOpen = null;
  setNav(L('app.music'), null,
    { icon: 'add', label: L('ph.playlist_new'), onClick: () => musicNewPlaylist(model) });
  musicFoot(model);

  // NOT `rows`: that is the global row-wiring helper, and shadowing it here would break the
  // call below in a way only a click would reveal.
  const items = model.playlists.map((p) => UI.row({
    icon: p.icon || 'music', tint: p.tint || '#FF2D55', title: p.name,
    subtitle: L('ph.playlist_count').replace('{n}', String(p.tracks.length)),
    chevron: true, data: { pl: p.id },
  }));

  body(
    // Said once, where it matters: on a server whose deck cannot be driven, playing a track
    // opens that deck with the URL copied. Better here than as a surprise every time.
    (model.handoff ? '<div class="groupfoot">' + esc(L('ph.music_handoff_hint')) + '</div>' : '') +
    musicNoDeckHint(model) +
    (items.length ? UI.group(items, { header: L('ph.playlists') })
                  : UI.empty(L('ph.playlist_none'), 'folder')) +
    '<div class="groupfoot">' + esc(L('ph.playlist_hint')) + '</div>');

  rows('.row', (r) => {
    if (!r.dataset.pl) return;
    r.addEventListener('click', () => { musicPlaylistOpen = r.dataset.pl; RENDER.music(); });
  });
}

/** Create one, from a name the player types. */
async function musicNewPlaylist(model) {
  const mine = model.playlists.filter((p) => !p.readonly);
  if (mine.length >= bnum(model.limits.playlists, 20)) { toast(L('ph.playlist_full')); return; }
  sheet(L('ph.playlist_new'),
    UI.field('plname', L('ph.playlist_name'), '', 'maxlength="40"') +
    UI.button(L('ph.save'), 'plsave', 'tinted'), () => {
      byId('plsave').addEventListener('click', async () => {
        const name = String(byId('plname').value || '').trim();
        if (!name) return;
        const epoch = sheetEpoch;
        await musicSavePlaylists(
          mine.concat([{ id: musicPlaylistId(), name, icon: 'music', tint: null, tracks: [] }]),
          model.limits);
        if (closeSheet(false, epoch)) RENDER.music(true);
      });
    });
}

/** Put a library track into a playlist. */
async function musicAddToPlaylist(model, playlist) {
  if (!model.library.length) { toast(L('ph.playlist_nolibrary')); return; }
  sheet(L('ph.playlist_add_track'),
    '<div class="musictracklist">' +
    model.library.map((t, i) => musicTrackRow(t, i, true)).join('') + '</div>', () => {
      [...byId('sheet').querySelectorAll('[data-mtrack]')].forEach((row, i) =>
        row.addEventListener('click', async () => {
          const track = model.library[i];
          if (!track) return;
          if (playlist.tracks.some((t) => t.url === track.url)) { toast(L('ph.playlist_dupe')); return; }
          if (playlist.tracks.length >= bnum(model.limits.tracks, 100)) { toast(L('ph.playlist_full')); return; }
          const epoch = sheetEpoch;
          const mine = model.playlists.filter((p) => !p.readonly);
          const target = mine.find((p) => p.id === playlist.id);
          if (target) target.tracks = target.tracks.concat([track]);
          await musicSavePlaylists(mine, model.limits);
          if (closeSheet(false, epoch)) RENDER.music(true);
        }));
    });
}

/// `quiet` repaints without blanking the screen first.
///
/// `loading()` replaces the whole body with one word, which is right when the app is being
/// entered and there is nothing on screen yet - and wrong for every repaint after that. A
/// favourite, a deleted track, a queue change: the view is already drawn, the data takes a few
/// round trips to re-read, and blanking it in between is the app appearing to reload.
RENDER.music = async (quiet) => {
  setNav(L('app.music'), null, musicTab === 'library'
    ? { icon: 'add', label: L('ph.track_add'), onClick: () => musicAdd() } : null);
  if (!quiet) loading();
  const model = await musicModel();
  if (!model.enabled) { foot(''); body(UI.empty(L('ph.err_off'), 'music')); return; }
  if (musicPlayerOpen) { musicRenderPlayer(model); return; }
  musicFoot(model);

  if (musicTab === 'listen') {
    const pick = model.current || model.recent[0] || model.library[0];
    const recent = model.recent.length ? model.recent : model.library.slice(0, 8);
    const favourites = model.library.filter((track) => track.favorite);
    body(musicHero(pick) +
      (recent.length ? musicSection(L('ph.recently_played'), { id: 'library', label: L('ph.see_all') }) +
        '<div class="musiccarousel">' + recent.slice(0, 8).map((track, index) => musicCard(track, index)).join('') + '</div>' : '') +
      (favourites.length ? musicSection(L('ph.made_for_you')) +
        '<div class="musicmix"><div class="musicmixart">' + favourites.slice(0, 4).map((track) => musicArt(track, 'mixart')).join('') +
        '</div><div><span>' + esc(L('ph.personal_mix')) + '</span><b>' + esc(L('ph.favorites_mix')) +
        '</b><small>' + esc(L('ph.favorites_mix_hint')) + '</small><button id="musicmixplay" type="button">' +
        svg('play') + esc(L('ph.play')) + '</button></div></div>' : ''));
    if (pick) {
      byId('musicheroplay').addEventListener('click', () => musicPlay(pick, model.library.length ? model.library : [pick]));
      byId('musicheromore').addEventListener('click', () => musicTrackSheet(pick, pick._libraryIndex));
    } else byId('musicemptyadd').addEventListener('click', () => musicAdd());
    const section = byId('appbody').querySelector('[data-msection="library"]');
    if (section) section.addEventListener('click', () => { musicTab = 'library'; RENDER.music(); });
    musicWireTracks(recent, model.library);
    const mix = byId('musicmixplay');
    if (mix) mix.addEventListener('click', () => musicPlay(favourites[0], favourites));
    return;
  }

  if (musicTab === 'playlists') {
    await musicRenderPlaylists(model);
    return;
  }

  if (musicTab === 'browse') {
    const albums = [];
    model.library.forEach((track) => {
      if (!albums.some((row) => row.album === track.album)) albums.push(track);
    });
    const picks = model.library.slice().reverse();
    body('<div class="musicfeature"><span>' + esc(L('ph.music_featured')) + '</span><h2>' +
      esc(L('ph.los_santos_sound')) + '</h2><p>' + esc(L('ph.music_featured_hint')) + '</p>' +
      '<div class="musicfeaturewaves"><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div></div>' +
      musicSection(L('ph.new_releases')) +
      (picks.length ? '<div class="musiccarousel">' + picks.slice(0, 8).map((track, index) => musicCard(track, index)).join('') + '</div>'
        : UI.empty(L('ph.library_empty'), 'music')) +
      (albums.length ? musicSection(L('ph.albums')) + '<div class="musicalbums">' +
        albums.slice(0, 6).map((track) => musicCard(track, picks.indexOf(track), true)).join('') + '</div>' : '') +
      '<div class="musicgenres">' + musicSection(L('ph.browse_categories')) +
        ['urban', 'electronic', 'rock', 'chill'].map((genre, index) =>
          '<button type="button" style="--genre:' + index + '"><span>' + esc(L('ph.genre_' + genre)) +
          '</span>' + svg('chevron') + '</button>').join('') + '</div>');
    musicWireTracks(picks, model.library);
    return;
  }

  if (musicTab === 'radio') {
    body('<div class="musicradiohero"><span class="musiclivepill"><i></i>' + esc(L('ph.live')) + '</span>' +
      '<div>' + svg('speaker') + '</div><h2>' + esc(L('ph.music_radio_title')) + '</h2><p>' +
      esc(L('ph.music_radio_hint')) + '</p></div>' +
      musicSection(L('ph.on_air')) +
      (model.sources.length ? '<div class="musictracklist">' +
        model.sources.map((track, index) => musicTrackRow(track, index, true)).join('') + '</div>'
        : '<div class="musicairglass">' + svg('speaker') + '<div><b>' + esc(L('ph.no_music')) +
          '</b><span>' + esc(L('ph.music_air_hint')) + '</span></div></div>') +
      (model.library.length ? musicSection(L('ph.start_station')) +
        '<div class="musicstationcards">' + model.library.slice(0, 3).map((track, index) =>
          '<button data-mstation="' + index + '" type="button">' + musicArt(track, 'stationart') +
          '<span><b>' + esc(track.artist) + '</b><small>' + esc(L('ph.artist_station')) + '</small></span>' +
          svg('play') + '</button>').join('') + '</div>' : ''));
    musicWireTracks(model.sources, model.library);
    rows('[data-mstation]', (button) => button.addEventListener('click', () => {
      const track = model.library[Number(button.dataset.mstation)];
      const station = model.library.filter((row) => row.artist === track.artist);
      musicPlay(track, station.length ? station : model.library);
    }));
    return;
  }

  if (musicTab === 'search') {
    musicRenderSearch(model);
    return;
  }

  const favourites = model.library.filter((track) => track.favorite);
  body('<div class="musiclibrarytiles">' +
    '<button id="mlibfav" type="button"><span>' + svg('heart') + '</span><div><b>' + esc(L('ph.favourites')) +
      '</b><small>' + esc(String(favourites.length)) + '</small></div>' + svg('chevron') + '</button>' +
    '<button id="mlibalbums" type="button"><span>' + svg('music') + '</span><div><b>' + esc(L('ph.albums')) +
      '</b><small>' + esc(String(new Set(model.library.map((track) => track.album)).size)) + '</small></div>' + svg('chevron') + '</button></div>' +
    musicSection(L('ph.songs'), { id: 'add', label: L('ph.add') }) +
    (model.library.length ? '<div class="musictracklist">' +
      model.library.map((track, index) => musicTrackRow(track, index)).join('') + '</div>'
      : '<div class="musiclibraryempty">' + musicArt({ title: 'iFruit Music' }, 'emptyart') +
        '<h2>' + esc(L('ph.library_empty')) + '</h2><p>' + esc(L('ph.library_hint')) + '</p>' +
        '<button id="mlibemptyadd" type="button">' + svg('add') + esc(L('ph.track_add')) + '</button></div>'));
  musicWireTracks(model.library, model.library);
  const add = byId('appbody').querySelector('[data-msection="add"]');
  if (add) add.addEventListener('click', () => musicAdd());
  const emptyAdd = byId('mlibemptyadd');
  if (emptyAdd) emptyAdd.addEventListener('click', () => musicAdd());
  byId('mlibfav').addEventListener('click', () => {
    body(musicSection(L('ph.favourites')) +
      (favourites.length ? '<div class="musictracklist">' +
        favourites.map((track, index) => musicTrackRow(track, index)).join('') + '</div>'
        : UI.empty(L('ph.no_favorites'), 'heart')));
    musicWireTracks(favourites, favourites);
  });
  byId('mlibalbums').addEventListener('click', () => {
    const albums = [];
    model.library.forEach((track) => {
      if (!albums.some((row) => row.album === track.album)) albums.push(track);
    });
    body(musicSection(L('ph.albums')) + '<div class="musicalbums">' +
      albums.map((track, index) => musicCard(track, index, true)).join('') + '</div>');
    musicWireTracks(albums, model.library);
  });
};

// -- Property ---------------------------------------------------
// A failed rent locks a door rather than deleting a property, so the one thing this app
// has to be able to do is pay it off from anywhere.
// Which tab of the Property app is showing. Two: what you own, and where to get one.
let propertyTab = 'mine';

RENDER.property = async () => {
  tabbar([
    { id: 'mine', icon: 'house', label: 'ph.my_property' },
    { id: 'buy', icon: 'store', label: 'ph.buy_property' },
  ], propertyTab, (t) => { propertyTab = t; RENDER.property(); });
  loading();
  const d = await post('app', { app: 'property' });
  if (!d || d.error) { body(UI.empty(L('ph.err_' + ((d && d.error) || 'off')), 'house')); return; }

  const list = d.rows || [];
  const agent = d.agent || {};

  // ── Where to buy one ──────────────────────────────────────────
  // Its own tab, and it works on a server with no housing script at all: the phone cannot
  // sell a house, but it can tell you who does and put a marker on their door.
  if (propertyTab === 'buy') {
    body(
      UI.hero({
        icon: 'house',
        eyebrow: L('ph.buy_property'),
        title: agent.label || 'Dynasty 8',
        subtitle: agent.address || '',
      }) +
      '<div class="groupfoot">' + esc(L('ph.buy_property_hint').replace('{name}', agent.label || 'Dynasty 8')) + '</div>' +
      (agent.x && agent.y ? UI.button(L('ph.buy_property_go'), 'pgo', 'tinted') : '') +
      (agent.x && agent.y ? '' : '<div class="groupfoot">' + esc(L('ph.buy_property_noplace')) + '</div>')
    );
    if (byId('pgo')) {
      byId('pgo').addEventListener('click', async () => {
        const set = await post('waypoint', { x: agent.x, y: agent.y });
        toast(L(set && set.ok ? 'ph.veh_located' : 'ph.err_x'));
        ui('key');
      });
    }
    return;
  }

  // ── What you own ──────────────────────────────────────────────
  if (!list.length) {
    // Two different nothings: no house, or no housing script the phone can read. Saying
    // which one is the difference between "go buy one" and "tell your server owner".
    body(UI.empty(L(d.readable === false ? 'ph.err_nohousing' : 'ph.no_property'), 'house') +
      '<div class="groupfoot">' + esc(L('ph.buy_property_where')) + '</div>');
    return;
  }

  body(UI.group(list.map((pr, i) => UI.row({
    icon: 'house', tint: '#12A5BC', title: placeName(pr.label),
    subtitle: L('ph.tenancy_' + (pr.tenancy || 'own')) +
      // Only when it says something the title does not: the bridge falls back to the key for
      // both, so an unnamed house was repeating itself in two lines.
      (pr.address && placeName(pr.address) !== placeName(pr.label)
        ? '  ·  ' + placeName(pr.address) : '') +
      (Number(pr.arrears) > 0 ? '  ' + String(L('ph.arrears')).replace('%s', pr.arrears) : ''),
    value: pr.locked ? L('ph.locked') : (pr.x && pr.y ? L('ph.locate_short') : ''),
    tone: pr.locked ? 'neg' : '',
    chevron: true, data: { i },
  })), { footer: L('ph.property_hint') }));

  rows('.row[data-i]', (r) => r.addEventListener('click', async () => {
    const pr = list[Number(r.dataset.i)];
    if (!pr) return;
    // Tapping your own house routes you to it, there and then. That is what somebody opening
    // this app is almost always here for - "where is my house" - and making them open a sheet
    // and find a second button first was a step with no purpose.
    //
    // The sheet still opens behind it, because the rent and the details live there. Only when
    // the server actually knows where the house is: no coordinates means no waypoint and no
    // claim to have set one.
    if (pr.x && pr.y) {
      const set = await post('waypoint', { x: pr.x, y: pr.y });
      if (set && set.ok) {
        ui('waypoint');
        toast(L('ph.property_located').replace('{n}', placeName(pr.label) || ''));
      }
    }
    propertySheet(pr);
  }));
};

// A housing script's own key, made readable.
//
// `Bridge.Properties.Owned` uses the script's label when there is one and falls back to the
// key, because a house with no name at all is worse than a house with an ugly one. Quasar
// hands back nothing BUT a key - its labels live behind an escrowed core - so on those servers
// the app was showing `2_grappeseed_main_street` in both the title and the address.
//
// Only ever applied to something that LOOKS like a key: underscores or dashes, and no spaces.
// A label somebody actually wrote is left exactly as it is, because title-casing real prose is
// how `Rue de la Paix` becomes `Rue De La Paix` - the same instinct as leaving an
// already-punctuated phone number alone.
function placeName(value) {
  const text = String(value == null ? '' : value).trim();
  if (!text) return text;
  // A space means a human wrote this. Nothing to fix.
  if (/\s/.test(text)) return text;
  if (!/[_-]/.test(text)) return text;

  return text
    .replace(/[_-]+/g, ' ')
    .trim()
    // Each word gets a capital, and the rest of the word is left as it was: an operator who
    // wrote `2_grappeseed_MAIN_street` meant that, and lowercasing it would be a second
    // opinion nobody asked for.
    .replace(/(^|\s)(\S)/g, (_, lead, first) => lead + first.toUpperCase());
}

// One house: where it is, and the rent if the script says it is owed.
function propertySheet(pr) {
  sheet(placeName(pr.label) || '',
    UI.group([
      pr.address && placeName(pr.address) !== placeName(pr.label)
        ? UI.row({ icon: 'map', title: placeName(pr.address) }) : '',
      pr.tier !== undefined && pr.tier !== null
        ? UI.row({ icon: 'star', title: L('ph.property_tier'), value: String(pr.tier), mono: true }) : '',
      pr.price ? UI.row({ icon: 'bank', title: L('ph.property_price'), value: money(pr.price), mono: true }) : '',
      UI.row({ icon: 'house', title: L('ph.tenancy_' + (pr.tenancy || 'own')) }),
    ].filter(Boolean)) +
    // Only when the server actually knows where it is: a button that cannot answer is worse
    // than no button.
    (pr.x && pr.y ? UI.button(L('ph.property_locate'), 'plocate', 'tinted') : '') +
    (pr.locked ? UI.button(L('ph.pay_rent'), 'prent') : ''),
    () => {
      if (byId('plocate')) {
        byId('plocate').addEventListener('click', async () => {
          ui('waypoint');
        const set = await post('waypoint', { x: pr.x, y: pr.y });
          toast(L(set && set.ok ? 'ph.veh_located' : 'ph.err_x'));
          ui('key');
        });
      }
      if (byId('prent')) {
        byId('prent').addEventListener('click', async () => {
          const epoch = sheetEpoch;
          const res = await post('payRent', { id: pr.property });
          if (!res || !res.ok) { toast(L('ph.err_' + ((res && res.error) || 'x'))); return; }
          if (!closeSheet(false, epoch)) return;
          toast(L('ph.rent_paid'));
          RENDER.property();
        });
      }
    });
}

// -- MDT --------------------------------------------------------
// Police only by default, and the server re-checks that on every call: the app gate only
// decides whether the icon is drawn.
let mdtTab = 'warrants';
let mdtLookupSeq = 0;

RENDER.mdt = async () => {
  mdtLookupSeq += 1;
  const seg =
    '<div class="seg">' +
      '<button class="' + (mdtTab === 'warrants' ? 'on' : '') + '" data-t="warrants">' + esc(L('ph.warrants')) + '</button>' +
      '<button class="' + (mdtTab === 'lookup' ? 'on' : '') + '" data-t="lookup">' + esc(L('ph.lookup')) + '</button>' +
    '</div>';
  const wire = () => [...byId('appbody').querySelectorAll('.seg button')].forEach((b) =>
    b.addEventListener('click', () => { mdtTab = b.dataset.t; RENDER.mdt(); }));

  if (mdtTab === 'lookup') {
    body(seg + UI.field('mq', L('ph.lookup_ph')) + UI.button(L('ph.search'), 'mgo') + '<div id="mres"></div>');
    wire();
    byId('mgo').addEventListener('click', async () => {
      const seq = ++mdtLookupSeq;
      const host = byId('mres');
      const query = byId('mq').value.trim();
      const res = await post('mdt', { op: 'lookup', query });
      if (seq !== mdtLookupSeq || byId('mres') !== host) return;
      if (!res || res.error) { host.innerHTML = UI.empty(L('ph.err_' + ((res && res.error) || 'x'))); return; }
      host.innerHTML =
        UI.group([UI.row({ icon: 'id', title: res.name || '', subtitle: res.cid || '' })]) +
        ((res.records || []).length
          ? UI.group(res.records.map((r) => UI.row({
              title: r.charges || '', subtitle: r.at || '',
              value: r.paid ? L('ph.paid') : L('ph.unpaid'), tone: r.paid ? 'pos' : 'neg',
            })), { header: L('ph.record') })
          : UI.empty(L('ph.no_record')));
    });
    return;
  }

  loading();
  const d = await post('mdt', { op: 'warrants' });
  if (!d || d.error) { body(seg + UI.empty(L('ph.err_' + ((d && d.error) || 'x')), 'shield')); wire(); return; }
  const list = d.rows || [];
  body(seg + (list.length
    ? UI.group(list.map((w) => UI.row({
        icon: 'shield',
        title: ((w.firstname || '') + ' ' + (w.lastname || '')).trim() || w.citizenid,
        subtitle: w.reason || '', time: w.at || '',
      })), { header: L('ph.warrants_active') })
    : UI.empty(L('ph.no_warrants'), 'shield')));
  wire();
};

// -- Calculator -------------------------------------------------
// Owned by the phone, and the one app here that needs no module: splitting a payment
// three ways is something players do constantly and currently do in their heads.
let calcAcc = null, calcOp = null, calcVal = '0', calcFresh = true;

function calcPress(k) {
  const put = (v) => { calcVal = calcFresh ? v : (calcVal === '0' ? v : calcVal + v); calcFresh = false; };
  if (k >= '0' && k <= '9') put(k);
  else if (k === '.') { if (!calcVal.includes('.')) put(calcFresh ? '0.' : '.'); }
  else if (k === 'c') { calcAcc = null; calcOp = null; calcVal = '0'; calcFresh = true; }
  else if (k === 'neg') calcVal = String(-parseFloat(calcVal));
  else if (k === 'pct') calcVal = String(parseFloat(calcVal) / 100);
  else if (k === '=') {
    if (calcOp !== null && calcAcc !== null) {
      const b = parseFloat(calcVal);
      const r = { '+': calcAcc + b, '-': calcAcc - b, '*': calcAcc * b, '/': b === 0 ? 0 : calcAcc / b }[calcOp];
      calcVal = String(Math.round(r * 1e6) / 1e6);
      calcAcc = null; calcOp = null; calcFresh = true;
    }
  } else {
    if (calcOp !== null && !calcFresh) calcPress('=');
    calcAcc = parseFloat(calcVal); calcOp = k; calcFresh = true;
  }
  const out = byId('calcout');
  if (out) out.textContent = calcVal;
}

RENDER.calc = () => {
  byId('app').classList.add('black');
  byId('screen').classList.add('appblack');
  const K = [['c', 'fn', 'AC'], ['neg', 'fn', '+/-'], ['pct', 'fn', '%'], ['/', 'op', '÷'],
             ['7', '', '7'], ['8', '', '8'], ['9', '', '9'], ['*', 'op', '×'],
             ['4', '', '4'], ['5', '', '5'], ['6', '', '6'], ['-', 'op', '−'],
             ['1', '', '1'], ['2', '', '2'], ['3', '', '3'], ['+', 'op', '+'],
             ['0', 'wide', '0'], ['.', '', ','], ['=', 'op', '=']];
  body('<div class="calcout" id="calcout">' + esc(calcVal) + '</div>' +
    '<div class="calcgrid">' + K.map(function (e) {
      return '<button class="ckey ' + e[1] + '" data-k="' + esc(e[0]) + '" type="button">' + e[2] + '</button>';
    }).join('') + '</div>');
  rows('.ckey', (b) => b.addEventListener('click', () => calcPress(b.dataset.k)));
};


// ══ Gestures ═══════════════════════════════════════════════════
// The phone is driven by a mouse, so a "swipe" is a click-drag. Where the drag STARTS is
// what decides its meaning, exactly as on the real thing: the bottom edge is the home
// gesture, the top edge is the shade and the control centre, and everywhere else belongs
// to whatever is on screen.
const EDGE = 34;          // how deep the bottom edge zone reaches
const EDGE_TOP = 56;      // the top zone is the whole status bar, or a drag that
                          // starts on the clock would not count as from the top
const SWIPE = 46;         // travel before a drag counts as a swipe
const PANEL_DISMISS_ZONE = 142;
const SWITCHER_TRAVEL = 155;

let g = null;

function screenPoint(e) {
  const r = byId('screen').getBoundingClientRect();
  return { x: e.clientX - r.left, y: e.clientY - r.top, w: r.width, h: r.height };
}

function anyOverlayOpen() {
  return ['cc', 'shade', 'switcher', 'sheet', 'auth', 'folderview', 'emojipanel']
    .some((id) => byId(id).classList.contains('on'));
}

function modalOverlayOpen() {
  return ['switcher', 'sheet', 'auth', 'folderview', 'emojipanel']
    .some((id) => byId(id).classList.contains('on'));
}

const SYSTEM_PANELS = ['shade', 'cc'];

function activeSystemPanel() {
  const id = SYSTEM_PANELS.find((name) => byId(name).classList.contains('on'));
  return id || null;
}

function resetPanelMotion(el) {
  if (!el) return;
  el.classList.remove('tracking');
  el.style.removeProperty('--panel-y');
  el.style.removeProperty('--panel-opacity');
}

function hideSystemPanel(id, instant) {
  const el = byId(id);
  if (!el) return;
  resetPanelMotion(el);
  el.classList.toggle('instant', instant === true);
  el.classList.remove('on');
  el.setAttribute('aria-hidden', 'true');
  if (instant) requestAnimationFrame(() => el.classList.remove('instant'));
}

function hideSystemPanels(instant) {
  SYSTEM_PANELS.forEach((id) => hideSystemPanel(id, instant));
}

function closeOverlays() {
  hideSystemPanels();
  byId('switcher').classList.remove('on');
  closeSheet(true);
  emojiClose();
  hideAuth();
  byId('folderview').classList.remove('on');
  if (editing) exitArrange();
}

function resetTransientUI() {
  g = null;
  appPull = null;
  hideAuth();
  hideSystemPanels(true);
  byId('switcher').classList.remove('on');
  shadeManage = false;
  closeSheet(true);
  emojiClose();
  byId('folderview').classList.remove('on');
  if (editing) exitArrange();
  else if (arr) endDrag(true);

  clearTimeout(glanceTimer); glanceTimer = null;
  clearTimeout(islandTimer); islandTimer = null;
  clearTimeout(peekTimer); peekTimer = null;
  clearTimeout(buzzTimer); buzzTimer = null;
  clearTimeout(hudTimer); hudTimer = null;
  clearTimeout(toastTimer); toastTimer = null;
  clearTimeout(shutterTimer); shutterTimer = null;

  byId('toast').classList.remove('on');
  byId('hud').classList.remove('on');
  byId('device').classList.remove('peeking', 'buzz', 'capturing');
  byId('app').classList.remove('black');
  byId('screen').classList.remove('appblack');
  setIslandMode(call ? 'live' : null);
}

byId('screen').addEventListener('pointerdown', (e) => {
  if (byId('setup').classList.contains('on')) {
    g = null;
    return;
  }
  const p = screenPoint(e);
  const systemPanel = activeSystemPanel();
  const interactive = !!(e.target.closest && e.target.closest(
    'button,input,textarea,select,[role="slider"],.ccslider,.ncard,.row'
  ));
  g = { x0: p.x, y0: p.y, t0: Date.now(), w: p.w, h: p.h,
         fromBottom: p.y > p.h - EDGE, fromTop: p.y < EDGE_TOP, fromLeft: p.x < 18,
         insideOverlay: !!(e.target.closest && e.target.closest(
           '#sheet,#shade,#cc,#switcher,#auth,#folderview,#emojipanel,#setup'
         )),
         previewPanel: null,
         dismissPanel: systemPanel && !interactive && p.y > p.h - PANEL_DISMISS_ZONE
           ? systemPanel : null };
  if ((g.fromTop || g.fromBottom) && e.currentTarget.setPointerCapture) {
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch {}
  }
});

let glassFrame = 0;
let pendingGlassPoint = null;

function trackGlassPointer(e) {
  const p = screenPoint(e);
  const x = Math.max(0, Math.min(100, (p.x / Math.max(1, p.w)) * 100));
  const y = Math.max(0, Math.min(100, (p.y / Math.max(1, p.h)) * 100));
  pendingGlassPoint = [x, y];
  if (glassFrame) return;
  glassFrame = requestAnimationFrame(() => {
    const point = pendingGlassPoint;
    glassFrame = 0;
    pendingGlassPoint = null;
    if (!point) return;
    const screen = byId('screen');
    screen.style.setProperty('--glass-x', point[0].toFixed(2) + '%');
    screen.style.setProperty('--glass-y', point[1].toFixed(2) + '%');
  });
}

byId('screen').addEventListener('pointermove', (e) => {
  trackGlassPointer(e);
  if (!g) return;
  const p = screenPoint(e);
  const dy = p.y - g.y0;

  // The system surfaces follow the finger before they settle. This keeps the app below
  // completely intact and removes the web-page feeling of a panel simply appearing.
  if (g.dismissPanel && dy < 0) {
    const el = byId(g.dismissPanel);
    el.classList.add('tracking');
    el.style.setProperty('--panel-y', Math.max(-p.h, dy) + 'px');
    el.style.setProperty('--panel-opacity', String(Math.max(0, 1 + dy / (p.h * .72))));
    return;
  }

  if (g.fromTop && dy > 4 && !g.insideOverlay && !modalOverlayOpen()) {
    if (!g.previewPanel) {
      g.previewPanel = g.x0 < g.w / 2 ? 'shade' : 'cc';
      if (g.previewPanel === 'shade') prepareShade();
      else prepareCC();
      SYSTEM_PANELS.forEach((id) => { if (id !== g.previewPanel) hideSystemPanel(id, true); });
      byId(g.previewPanel).classList.add('on', 'tracking');
      byId(g.previewPanel).setAttribute('aria-hidden', 'false');
    }
    const el = byId(g.previewPanel);
    const travel = Math.min(p.h, dy);
    el.style.setProperty('--panel-y', Math.min(0, -p.h + travel * 1.18) + 'px');
    el.style.setProperty('--panel-opacity', String(Math.min(1, travel / 150)));
  }
}, { passive: true });
byId('screen').addEventListener('pointerdown', (e) => {
  trackGlassPointer(e);
  const target = e.target.closest && e.target.closest(
    'button, .tile, .row, .card, .ncard, .lnotif, .strowitem, .shot'
  );
  if (!target || !byId('screen').contains(target) || target.disabled) return;
  const r = target.getBoundingClientRect();
  if (getComputedStyle(target).position === 'static') target.style.position = 'relative';
  const flare = document.createElement('span');
  flare.className = 'touch-flare';
  flare.setAttribute('aria-hidden', 'true');
  flare.style.left = (e.clientX - r.left) + 'px';
  flare.style.top = (e.clientY - r.top) + 'px';
  target.appendChild(flare);
  setTimeout(() => flare.remove(), 520);
});

byId('screen').addEventListener('pointerup', (e) => {
  if (!g) return;
  const p = screenPoint(e);
  const dx = p.x - g.x0, dy = p.y - g.y0;
  const held = Date.now() - g.t0;
  const gg = g; g = null;

  if (gg.dismissPanel) {
    const el = byId(gg.dismissPanel);
    if (dy < -SWIPE) hideSystemPanel(gg.dismissPanel);
    else resetPanelMotion(el);
    return;
  }

  if (gg.previewPanel) {
    const el = byId(gg.previewPanel);
    if (dy > SWIPE) {
      resetPanelMotion(el);
      el.classList.add('on');
    } else {
      hideSystemPanel(gg.previewPanel);
    }
    return;
  }

  if (Math.abs(dx) < SWIPE && Math.abs(dy) < SWIPE) return;   // a tap, not a swipe

  // Bottom edge, upwards: home. Held for a moment first: the app switcher. That pause is
  // the whole difference between the two gestures on a real phone.
  if (gg.fromBottom && dy < -SWIPE) {
    // A short flick goes home. A deliberate long pull (or a brief hold) exposes
    // multitasking, which remains usable with both a mouse and a real touch screen.
    if (held > 300 || -dy > SWITCHER_TRAVEL) openSwitcher();
    else { closeOverlays(); goHome(); }
    return;
  }

  // Top edge, downwards: left half is the notification shade, right half the control
  // centre. Same split iOS uses, and it means neither one needs a button.
  if (gg.fromTop && dy > SWIPE) {
    if (modalOverlayOpen()) return;
    if (gg.x0 < gg.w / 2) openShade(); else openCC();
    return;
  }

  // Scrolling a sheet/shade, moving a CC slider or flicking a switcher card belongs to
  // that overlay. Only a genuine edge gesture above is allowed to escape it.
  if (gg.insideOverlay) return;

  if (anyOverlayOpen()) { closeOverlays(); return; }

  // Inside an app, a drag in from the left edge goes back, which is the one gesture
  // people reach for without being told.
  if (byId('app').classList.contains('on') && gg.fromLeft && dx > SWIPE) {
    byId('navback').click();
    return;
  }

  // On the home screen, sideways moves between pages - but never while a tile is being
  // carried, which owns the pointer.
  if (!arr && !byId('home').classList.contains('behind') && !byId('app').classList.contains('on')
      && Math.abs(dx) > Math.abs(dy)) {
    flipPage(dx < 0 ? 1 : -1);
    return;
  }

  // On the lock screen, up unlocks.
  if (!byId('lock').classList.contains('out') && dy < -SWIPE) unlock();
});

byId('screen').addEventListener('pointercancel', () => {
  if (!g) return;
  if (g.previewPanel) hideSystemPanel(g.previewPanel);
  if (g.dismissPanel) resetPanelMotion(byId(g.dismissPanel));
  g = null;
});

// ══ App switcher ═══════════════════════════════════════════════
function openSwitcher() {
  const list = recents
    .map((id) => (state.apps || []).find((a) => a.id === id))
    .filter(Boolean);
  if (!list.length) { toast(L('ph.no_recents')); return; }

  byId('cards').innerHTML = list.map((a) =>
    '<div class="card glass" data-app="' + esc(a.id) + '">' +
      '<div class="chead"><span class="ic">' + svg(a.icon) + '</span>' +
      '<b>' + esc(L(a.label)) + '</b></div><div class="cbody">' +
      '<div class="cpreview">' + appTile(a, 'previewicon') +
      '<b class="previewname">' + esc(L(a.label)) + '</b></div></div></div>').join('') +
    '<div class="switchhint">' + esc(L('ph.switch_hint')) + '</div>';
  byId('switcher').classList.add('on');

  // The strip scrolls, but nothing was making it scroll. `overflow-x: auto` is enough on a
  // touchscreen and useless with a mouse: there is no horizontal wheel and no drag, so the
  // cards past the second one were unreachable. Both are wired here.
  const strip = byId('cards');
  strip.addEventListener('wheel', (e) => {
    // A vertical wheel is what a player has, and sideways is the only axis here.
    if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
    e.preventDefault();
    strip.scrollLeft += e.deltaY;
  }, { passive: false });

  // Drag to pan. `panned` is what keeps a drag from also being read as a tap on the card it
  // started on, and the card's own flick-up-to-close still wins on the vertical axis.
  let panX = null, panY = null, panFrom = 0, panned = false;
  strip.addEventListener('pointerdown', (e) => {
    panX = e.clientX; panY = e.clientY; panFrom = strip.scrollLeft; panned = false;
  });
  strip.addEventListener('pointermove', (e) => {
    if (panX === null) return;
    const dx = e.clientX - panX;
    // A mostly-VERTICAL drag is the card being flicked away, not the strip being panned.
    // Without this test any sideways drift at all claimed the gesture, and the flick was
    // then discarded as "a drag that moved the strip".
    if (!panned && Math.abs(e.clientY - panY) > Math.abs(dx)) return;
    if (!panned && Math.abs(dx) < 6) return;
    panned = true;
    strip.scrollLeft = panFrom - dx;
  });
  ['pointerup', 'pointerleave', 'pointercancel'].forEach((ev) =>
    strip.addEventListener(ev, () => { panX = null; panY = null; }));

  [...strip.querySelectorAll('.card')].forEach((c) => {
    let y0 = null, dragging = false;

    const settle = () => {
      dragging = false;
      y0 = null;
      c.style.removeProperty('transform');
      c.style.removeProperty('opacity');
      c.classList.remove('dragging');
    };

    const close = () => {
      const id = c.dataset.app;
      ui('swipe');
      c.classList.add('gone');
      recents = recents.filter((recent) => recent !== id);
      setTimeout(() => {
        if (openApp && openApp.id === id) closeApp(true);
        if (!recents.length) byId('switcher').classList.remove('on');
        else openSwitcher();
      }, 240);
    };

    c.addEventListener('pointerdown', (e) => {
      y0 = e.clientY;
      dragging = true;
      // **The card has to capture the pointer.**
      //
      // Without this, flicking up moved the pointer OFF the card - which is the whole point
      // of the gesture - so `pointerup` fired on whatever was underneath and the card's own
      // handler never ran. The flick worked only if you released while still inside the card,
      // which for a sixty-pixel upward throw almost never happens. That is why swipe-to-close
      // did nothing.
      try { c.setPointerCapture(e.pointerId); } catch { /* mouse without capture support */ }
    });

    // The card follows the finger, so the gesture confirms itself while it is happening
    // rather than only when it succeeds.
    c.addEventListener('pointermove', (e) => {
      if (!dragging || y0 === null) return;
      const dy = Math.min(0, e.clientY - y0);
      if (dy > -4) return;
      c.classList.add('dragging');
      c.style.transform = 'translateY(' + dy + 'px)';
      c.style.opacity = String(Math.max(0.35, 1 + dy / 260));
    });

    c.addEventListener('pointerup', (e) => {
      const flicked = y0 !== null && e.clientY - y0 < -60;
      const wasPanned = panned;
      settle();
      panned = false;
      // A drag that panned the strip sideways is not a tap on a card.
      if (wasPanned) return;
      if (flicked) { close(); return; }
      const a = (state.apps || []).find((x) => x.id === c.dataset.app);
      byId('switcher').classList.remove('on');
      if (a) enterApp(a, null);
    });

    // A cancelled pointer must put the card back rather than leave it half thrown.
    c.addEventListener('pointercancel', settle);
  });
}

// ══ Notification shade ═════════════════════════════════════════
function prepareShade() {
  const d = new Date();
  byId('shadeclock').textContent =
    String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  byId('shadedate').textContent =
    d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });
  shadeManage = false;
  renderShade();
  byId('shadeclose').setAttribute('aria-label', L('ph.close'));
}

function openShade() {
  prepareShade();
  hideSystemPanel('cc', true);
  resetPanelMotion(byId('shade'));
  byId('shade').classList.add('on');
  byId('shade').setAttribute('aria-hidden', 'false');
}

// The app a notification belongs to, resolved to something printable.
function appOf(id) {
  return (state.apps || available || []).find((a) => a.id === id)
      || (available || []).find((a) => a.id === id) || { id, label: id, icon: id };
}

function renderShade() {
  const sh = byId('shade');
  sh.classList.toggle('manage', shadeManage);
  byId('shtitle').textContent = L('ph.notifs');
  const mng = byId('shmanage'), clr = byId('shclear');
  mng.textContent = shadeManage ? L('ph.notif_done') : L('ph.notif_manage');
  clr.textContent = L('ph.clear_all');
  clr.classList.toggle('hidden', !notifs.length || shadeManage);

  const list = byId('shadelist');
  if (!notifs.length) { list.innerHTML = '<div class="nempty">' + esc(L('ph.notif_empty')) + '</div>'; return; }

  // Grouped by app, groups in the order their newest notification arrived.
  // Null prototype: an app id reaches here from a notification, and another resource's
  // Notify decides that string. With a plain object, an id of '__proto__' or 'constructor'
  // resolves to an inherited value instead of an absent key, and the .push below throws -
  // which would leave the whole notification centre blank until the entry ages out.
  const order = [], byApp = Object.create(null);
  notifs.forEach((n) => { if (!byApp[n.app]) { byApp[n.app] = []; order.push(n.app); } byApp[n.app].push(n); });

  list.innerHTML = order.map((appId) => {
    const a = appOf(appId);
    const muted = appMuted(appId);
    const head = '<div class="ngrouphead">' + appTile(a) +
      '<span class="gname">' + esc(L(a.label) || a.id) + '</span>' +
      (shadeManage ? '<button class="gmute ' + (muted ? 'on' : '') + '" data-mute="' + esc(appId) + '">' +
        esc(muted ? L('ph.notif_muted') : L('ph.notif_mute_app')) + '</button>' : '') + '</div>';
    const cards = byApp[appId].map((n) =>
      '<div class="ncard" data-nid="' + n.id + '">' +
        '<span class="nic">' + UI.appIcon(n.icon) + '</span>' +
        '<span class="nbody"><span class="nt">' + esc(n.title) + '</span>' +
        '<span class="nb">' + esc(n.body) + '</span></span>' +
        '<span class="nw">' + esc(relTime(n.at)) + '</span>' +
        '<button class="nx" data-x="' + n.id + '" type="button" aria-label="' +
          esc(L('ph.close')) + '">' + svg('xmark') + '</button></div>').join('');
    return '<div class="ngroup">' + head + cards + '</div>';
  }).join('');

  qrows('shadelist', '.ncard', (c) => c.addEventListener('click', (e) => {
    if (e.target.closest('.nx')) return;
    if (shadeManage) return;
    const n = notifs.find((x) => String(x.id) === c.dataset.nid);
    hideSystemPanel('shade');
    if (n && n.onClick) n.onClick();
  }));
  qrows('shadelist', '.nx', (x) => x.addEventListener('click', (e) => {
    e.stopPropagation();
    notifs = notifs.filter((n) => String(n.id) !== x.dataset.x);
    paintNotifs(); renderShade();
  }));
  qrows('shadelist', '.gmute', (b) => b.addEventListener('click', async (e) => {
    e.stopPropagation();
    await setAppMuted(b.dataset.mute, !appMuted(b.dataset.mute));
    renderShade();
  }));
}

function prepareCC() {
  renderCC();
  const p = state._power || {};
  const battery = Number.isFinite(Number(p.battery)) ? Math.round(Number(p.battery)) + '%' : '';
  const deviceName = String((state.prefs || {}).deviceName || state.number || '').trim();
  byId('ccdevice').textContent = [deviceName, battery].filter(Boolean).join(' · ');
  byId('ccclose').setAttribute('aria-label', L('ph.close'));
  primeNowPlaying().then(() => {
    if (byId('cc').classList.contains('on')) renderCC();
  });
}

function openCC() {
  prepareCC();
  hideSystemPanel('shade', true);
  resetPanelMotion(byId('cc'));
  byId('cc').classList.add('on');
  byId('cc').setAttribute('aria-hidden', 'false');
}

byId('shmanage').addEventListener('click', () => { shadeManage = !shadeManage; renderShade(); });
byId('shclear').addEventListener('click', () => clearAllNotifications());
[
  ['shadeclose', 'shade'],
  ['ccclose', 'cc'],
].forEach(([buttonId, panelId]) => {
  const button = byId(buttonId);
  // These controls sit in the top gesture zone. Stop the screen recogniser before it
  // can claim their pointer, so a close press is always delivered as a close press.
  button.addEventListener('pointerdown', (e) => e.stopPropagation());
  button.addEventListener('click', (e) => {
    e.stopPropagation();
    hideSystemPanel(panelId);
  });
});

// ══ Side buttons ═══════════════════════════════════════════════
// Real controls, not decoration. Volume moves the volume of whatever v-music says this
// player may control; if nothing is playing it says so rather than pretending.
let hudTimer = null;

function hud(icon, label, pct) {
  const el = byId('hud');
  const hasLevel = pct !== undefined;
  el.className = 'hud ' + (hasLevel ? 'levelhud' : 'noticehud');
  el.innerHTML = hasLevel
    ? '<span class="hudlabel">' + esc(label) + '</span>' +
      '<span class="hudtrack"><i style="height:' + Math.round(pct * 100) + '%"></i>' +
        '<span class="hudglyph">' + svg(icon) + '</span></span>'
    : '<span class="hudnoticeicon">' + svg(icon) + '</span><span>' + esc(label) + '</span>';
  el.classList.add('on');
  clearTimeout(hudTimer);
  hudTimer = setTimeout(() => el.classList.remove('on'), 1400);
}

let volume = 0.5;

// The volume rocker on the side of the handset.
//
// It read `sources` from the Music app's payload - a list the phone has always answered as
// empty - so it showed "nothing playing" while a track was audibly playing, and the post it
// then never reached carried an `id` that nothing has ever sent. Same root cause as the
// control centre's dead media tile: the phone knows what it started, so it reads that.
/// Move the volume slider that is on screen, if one is.
///
/// The side buttons used to re-render the whole Music app for this. Even without the blanking
/// that is a rebuild of every card and row in the view - the scroll jumps, the artwork
/// animations restart - and a volume rocker is pressed five times in a row. One number
/// changed; one slider needs to know.
function musicPaintVolume(value) {
  const slider = byId('mvolume');
  if (!slider) return;
  const percent = Math.round(Math.max(0, Math.min(1, value)) * 100);
  slider.value = percent;
  // The filled part of the track is drawn from this, not from `value` - without it the
  // handle moves and the colour behind it does not.
  slider.style.setProperty('--volume', percent + '%');
}

async function nudgeVolume(delta) {
  if (!musicNow) { hud('speaker', L('ph.nothing_playing')); return; }
  volume = Math.max(0, Math.min(1, (musicNow.volume ?? volume) + delta));
  musicNow.volume = volume;
  if (ccNow) ccNow.volume = volume;
  hud('speaker', musicNow.title || L('ph.untitled'), volume);
  musicPaintVolume(volume);
  const r = await post('music', { action: 'volume', volume });
  if (r && r.error) toast(L('ph.err_' + r.error));
}

function wireSideButtons() {
  // Power: lock and wake, the way the real button behaves.
  document.querySelector('.btn-side.power').addEventListener('click', () => {
    if (byId('lock').classList.contains('out')) { closeOverlays(); lockScreen(); }
    else unlock();
  });
  document.querySelector('.btn-side.vol-up').addEventListener('click', () => nudgeVolume(0.1));
  document.querySelector('.btn-side.vol-down').addEventListener('click', () => nudgeVolume(-0.1));

  // Action button: opens whichever app the player chose in Settings. Unset, it says so
  // instead of quietly doing nothing.
  document.querySelector('.btn-side.action').addEventListener('click', () => {
    const id = (state.prefs || {}).actionApp;
    const a = id && (state.apps || []).find((x) => x.id === id);
    if (!a) { hud('settings', L('ph.action_unset')); return; }
    const openActionApp = () => {
      closeOverlays();
      enterApp(a, null);
    };
    if (!byId('lock').classList.contains('out')) unlock(openActionApp);
    else openActionApp();
  });
}

// ══ FruitStore ═════════════════════════════════════════════════
// Two decisions, kept apart: the OPERATOR decides what is available (Editor -> Phone
// apps), the PLAYER decides what to keep. The store can never conjure an app the operator
// has not permitted, and it refuses to remove the ones the phone needs to work.
// One page per app, like a store has. The description comes from the locale when the
// framework ships one, from RegisterApp's `desc` when a third party wrote one, and from
// an honest fallback when nobody did.
function descOf(a) {
  const k = 'ph.desc_' + a.id;
  const v = L(k);
  if (v !== k) return v;
  if (a.desc) return a.desc;
  return L('ph.desc_generic');
}

function storeFacts(a) {
  let seed = 0;
  String(a.id || '').split('').forEach((char) => { seed = (seed * 31 + char.charCodeAt(0)) % 997; });
  return {
    rating: (4.5 + (seed % 5) / 10).toFixed(1),
    reviews: 120 + (seed * 37) % 4800,
    age: (a.category === 'social' || a.category === 'finance') ? '12+' : '4+',
    version: String(a.version || '1.0'),
    size: (18 + seed % 64) + ' MB',
  };
}

function storePermissionLabel(permission) {
  const key = 'ph.permission_' + permission;
  const translated = L(key);
  return translated === key
    ? String(permission || '').replace(/[-_]/g, ' ').replace(/\b\w/g, (char) => char.toUpperCase())
    : translated;
}

function storePreview(a, index) {
  const name = esc(L(a.label));
  if (a.id === 'cipher') {
    const scenes = [
      '<div class="stcipherseal">' + svg('lockshut') + '<span><b>' +
        esc(L('ph.cipher_e2e')) + '</b><small>' + esc(L('ph.cipher_active')) + '</small></span></div>' +
        '<div class="stcipherpeople"><i>R</i><span></span><i>Z</i></div>',
      '<div class="stcipherchat"><i>' + esc(L('ph.cipher_packet')) + '</i><i></i><i></i>' +
        '<b>' + svg('lockshut') + esc(L('ph.cipher_secure_session')) + '</b></div>',
      '<div class="stcipherprint">' + svg('shield') + '<b>' + esc(L('ph.cipher_safety_number')) +
        '</b><i>71 2B DC 90<br>44 18 AF 2E</i><small>' + esc(L('ph.cipher_verified')) + '</small></div>',
    ];
    return '<div class="stshot cipherstore">' +
      '<div class="stshotbar"><span>9:41</span><i></i><i></i></div>' +
      '<div class="stshotapp">' + UI.appIcon('cipher') + '<b>' + name + '</b></div>' +
      scenes[index % scenes.length] +
      '<div class="stcipherglow"></div></div>';
  }
  const variant = ['feed', 'cards', 'dashboard'][index % 3];
  return '<div class="stshot ' + variant + '">' +
    '<div class="stshotbar"><span>9:41</span><i></i><i></i></div>' +
    '<div class="stshotapp">' + appTile(a) + '<b>' + name + '</b></div>' +
    '<div class="stmockhero"><span></span><strong>' + name + '</strong><small>' +
      esc(L('ph.store_preview_' + (index + 1))) + '</small></div>' +
    '<div class="stmockrows"><i></i><i></i><i></i></div>' +
    '<div class="stmockdock"><i></i><i></i><i></i></div>' +
  '</div>';
}

function storeDetail(a) {
  if (!openApp || openApp.id !== 'store') return;
  beginView();
  const has = isInstalled(a.id);
  const facts = storeFacts(a);
  setNav(L('app.store'), L('app.store'), null, () => {
    RENDER.store();
  });
  const features = (a.features || []).slice(0, 8);
  const permissions = (a.permissions || []).slice(0, 10);
  const detailStyle = a.accent ? ' style="--app-tint:' + esc(a.accent) + '"' : '';
  body(
    '<div class="stdetail"' + detailStyle + '><div class="stdetailhero"><div class="storb"></div><div class="sthead">' + appTile(a) +
      '<div class="stinfo"><div class="stbig">' + esc(L(a.label)) + '</div>' +
      '<div class="stcat">' + esc(a.developer || (a.owner === 'v-phone' ? 'iFruit Studio' : (a.owner || 'iFruit'))) + '</div>' +
      '<div class="stact">' +
        (a.required
          ? '<span class="stget have">' + esc(L('ph.store_required')) + '</span>'
          : (has
              ? '<button class="stget have" id="stopen" type="button">' + esc(L('ph.store_open')) + '</button>' +
                // Remove is offered for a DOWNLOADED app only. Anything else came with the
                // handset, and a player who deletes the Bank has broken a feature their
                // server expects them to have rather than freed up a slot. The server
                // refuses it too - this only keeps the button from being there to press.
                (a.optional
                  ? '<button class="stdel" id="stdel" type="button">' + esc(L('ph.store_delete')) + '</button>'
                  : '')
              : '<button class="stget" id="stget" type="button">' + esc(L('ph.store_install')) + '</button>')) +
      '</div></div></div></div>' +
    '<div class="stmeta">' +
      '<div><div class="mv">' + facts.rating + ' ★</div><div class="mk">' +
        esc(Number(facts.reviews).toLocaleString()) + ' ' + esc(L('ph.store_ratings')) + '</div></div>' +
      '<div><div class="mv">' + facts.age + '</div><div class="mk">' + esc(L('ph.store_age')) + '</div></div>' +
      '<div><div class="mv">' + facts.size + '</div><div class="mk">' + esc(L('ph.store_size')) + '</div></div>' +
    '</div>' +
    '<div class="stscreens" aria-label="' + esc(L('ph.store_previews')) + '">' +
      [0, 1, 2].map((index) => storePreview(a, index)).join('') + '</div>' +
    '<div class="grouphead">' + esc(L('ph.about')) + '</div>' +
    '<div class="storedesc">' + esc(descOf(a)) + '</div>' +
    (features.length
      ? '<div class="grouphead">' + esc(L('ph.store_features')) + '</div>' +
        '<div class="stfeatures">' + features.map((feature) =>
          '<span>' + svg('check') + esc(feature) + '</span>').join('') + '</div>'
      : '') +
    '<div class="stsectioncard"><div><span class="stcardicon">' + svg('sparkles') + '</span>' +
      '<span><b>' + esc(L('ph.store_whats_new')) + '</b><small>' +
        esc(L('ph.store_whats_new_body')) + '</small></span></div><em>v' + esc(facts.version) + '</em></div>' +
    '<div class="stprivacy"><div class="stprivacyicon">' + svg('lockshut') + '</div>' +
      '<div><b>' + esc(L('ph.store_privacy')) + '</b><span>' +
        esc(a.id === 'cipher' ? L('ph.cipher_server_blind') : L('ph.store_privacy_body')) +
        '</span></div>' + svg('chevron') + '</div>' +
    (permissions.length
      ? '<div class="grouphead">' + esc(L('ph.store_permissions')) + '</div>' +
        '<div class="stpermissions">' + permissions.map((permission) =>
          UI.chip(storePermissionLabel(permission), 'permission')).join('') + '</div>'
      : '') +
    '<div class="grouphead">' + esc(L('ph.store_information')) + '</div>' +
    '<div class="group stinfoRows">' +
      UI.row({ title: L('ph.store_dev'), value: a.developer || (a.owner === 'v-phone' ? 'iFruit Studio' : (a.owner || 'iFruit')) }) +
      UI.row({ title: L('ph.store_cat'), value: L('ph.cat_' + (a.category || 'utilities')) }) +
      UI.row({ title: L('ph.store_version'), value: facts.version }) +
      UI.row({ title: L('ph.store_compatibility'), value: L('ph.store_phone_ready') }) +
    '</div></div>'
  );
  pushAnim();
  byId('appbody').scrollTop = 0;

  const so = byId('stopen');
  if (so) so.addEventListener('click', () => {
    const app = (state.apps || []).find((x) => x.id === a.id);
    if (app) enterApp(app, null);
  });
  const sg = byId('stget');
  if (sg) sg.addEventListener('click', async () => { if (await storeInstall(a.id, true)) storeDetail(a); });
  const sd = byId('stdel');
  // Confirmed, because it takes the icon off the home screen and any data the app kept goes
  // with it on some apps. Reinstalling is free - what was paid for is remembered against the
  // character - and the sheet says so, since that is the fact that makes the decision easy.
  if (sd) sd.addEventListener('click', () => {
    sheet(L('ph.store_delete_ask').replace('{app}', L(a.label)),
      '<div class="groupfoot">' + esc(L('ph.store_delete_hint')) + '</div>' +
      UI.button(L('ph.store_delete'), 'stdelyes', 'neg') +
      UI.button(L('ph.cancel'), 'stdelno', 'plain'),
      () => {
        const epoch = sheetEpoch;
        byId('stdelyes').addEventListener('click', async () => {
          if (!closeSheet(false, epoch)) return;
          if (await storeInstall(a.id, false)) { ui('toggleoff'); storeDetail(a); }
        });
        byId('stdelno').addEventListener('click', () => closeSheet(false, epoch));
      });
  });
}

let storeCat = 'all';

function isInstalled(id) { return (state.apps || []).some((x) => x.id === id); }

// Only the categories that actually have an app in them, in a fixed order so the store
// does not reshuffle itself every time somebody installs something.
const CAT_ORDER = ['social', 'finance', 'utilities', 'travel', 'work', 'duty',
                   'entertainment', 'health', 'essentials'];

function storeCats(all) {
  const present = new Set(all.map((a) => a.category || 'utilities'));
  return CAT_ORDER.filter((c) => present.has(c));
}

async function storeInstall(id, install) {
  // The arrangement you already have is yours. Without this the new app landed wherever
  // its slot said, shoving every icon after it along and spilling the last one onto a new
  // page - which is not what installing one app should do to a home screen.
  const before = layoutItems();

  const r = await post('install', { app: id, install });
  if (!r || r.error) {
    // A refused purchase says what it costs, which is the one thing worth knowing.
    if (r && r.error === 'nomoney') { toast(L('ph.store_nomoney').replace('{price}', money(r.price))); }
    else { toast(L('ph.err_' + ((r && r.error) || 'x'))); }
    return false;
  }
  // A paid app was just bought: the catalogue's `purchased` flag has moved on.
  if (install) await refresh();
  await refresh();
  available = state.available || available;

  // Keep the old order exactly, drop anything that left, and put anything new on the end -
  // so it fills the gap on the last page, or starts a new one when there is no room.
  const live = new Set((state.apps || []).filter((a) => !a.dock).map((a) => a.id));
  const kept = before.filter((it) => it.t === 'folder'
    ? (it.apps || []).some((x) => live.has(x))
    : live.has(it.id));
  const seen = new Set();
  kept.forEach((it) => { if (it.t === 'folder') (it.apps || []).forEach((x) => seen.add(x)); else seen.add(it.id); });
  const added = [...live].filter((x) => !seen.has(x)).map((x) => ({ t: 'app', id: x }));
  if (added.length || kept.length !== before.length) await saveLayout(kept.concat(added));

  renderHome();
  ui(install ? 'success' : 'toggleoff');
  toast(L(install ? 'ph.store_added' : 'ph.store_removed'));
  return true;
}

/** What the button on a store listing says. A paid app the player has not bought yet shows
 *  its price instead of "Get", the way a store does. */
function storeLabel(a, has) {
  if (a.required) return L('ph.store_required');
  if (has) return L('ph.store_open');
  if (a.price && !a.purchased) return money(a.price);
  return L('ph.store_install');
}

function storeRow(a) {
  const has = isInstalled(a.id);
  const label = storeLabel(a, has);
  return '<div class="strowitem" data-app="' + esc(a.id) + '">' + appTile(a) +
    '<div class="stmid"><div class="stt">' + esc(L(a.label)) + '</div>' +
    '<div class="stc">' + esc(L('ph.cat_' + (a.category || 'utilities'))) + '</div></div>' +
    '<button class="stget ' + (has || a.required ? 'have' : '') + '" data-act="' +
      (a.required ? 'none' : (has ? 'open' : 'get')) + '" type="button">' + esc(label) + '</button></div>';
}

RENDER.store = () => {
  setNav(L('app.store'), null);

  // Deduplicated by id: the registry is a config seed merged with the operator's rows, and
  // a duplicate there used to surface as the same app listed twice in the store.
  const byIdSeen = new Set();
  const all = (available || [])
    .filter((a) => a && a.id && !byIdSeen.has(a.id) && byIdSeen.add(a.id))
    .sort((a, b) => (a.slot || 99) - (b.slot || 99));
  if (!all.length) { body(UI.empty(L('ph.store_empty'), 'store')); return; }

  // The featured slot goes to something you do NOT have yet: a shop window showing what
  // you already own is a shelf, not a window.
  const cats = storeCats(all);

  body(
    searchHtml(L('ph.store_search')) +
    '<div class="seg scroll">' +
      '<button class="' + (storeCat === 'all' ? 'on' : '') + '" data-c="all">' + esc(L('ph.all')) + '</button>' +
      cats.map((c) => '<button class="' + (storeCat === c ? 'on' : '') + '" data-c="' + esc(c) + '">' +
        esc(L('ph.cat_' + c)) + '</button>').join('') +
    '</div><div id="stbody"></div>'
  );

  const wire = () => {
    rows('.stfeat, .strowitem', (el) => el.addEventListener('click', (e) => {
      if (e.target.closest('.stget')) return;
      const a = all.find((x) => x.id === el.dataset.app);
      if (a) storeDetail(a);
    }));
    rows('.stget', (b) => b.addEventListener('click', async (e) => {
      e.stopPropagation();
      const act = b.dataset.act;
      if (act === 'none') return;
      const id = b.closest('[data-app]').dataset.app;
      if (act === 'open') {
        const app = (state.apps || []).find((x) => x.id === id);
        if (app) enterApp(app, null);
        return;
      }
      if (await storeInstall(id, true)) paint(byId('q') ? byId('q').value.trim().toLowerCase() : '');
    }));
  };

  const paint = (q) => {
    const shown = storeCat === 'all' ? all : all.filter((a) => (a.category || 'utilities') === storeCat);
    const list = q ? all.filter((a) => [
      L(a.label), descOf(a), a.developer, a.owner, a.category,
      ...(a.keywords || []), ...(a.features || []),
    ].filter(Boolean).join(' ').toLowerCase().includes(q)) : shown;
    let html = '';

    // Recomputed on every paint, never captured once: installing the featured app used to
    // leave it in the window still offering something you now own. If there is nothing
    // left to get, the window goes away rather than advertising your own apps back at you.
    const feat = all.find((a) => a.optional && !isInstalled(a.id))
              || all.find((a) => !a.required && !isInstalled(a.id))
              || null;
    if (!q && storeCat === 'all' && feat) {
      html += '<div class="stfeat" data-app="' + esc(feat.id) + '">' +
        '<div class="stkick">' + esc(L('ph.store_featured')) + '</div>' +
        '<div class="strow">' + UI.appIcon(feat.icon) +
        '<div><div class="stname">' + esc(L(feat.label)) + '</div>' +
        '<div class="stsub">' + esc(descOf(feat)) + '</div></div></div></div>';
    }

    if (!list.length) {
      byId('stbody').innerHTML = html + UI.empty(L('ph.store_none'), 'store');
      wire(); return;
    }

    if (q || storeCat !== 'all') {
      html += '<div class="group" style="padding:0 14px">' + list.map(storeRow).join('') + '</div>';
    } else {
      cats.forEach((c) => {
        const inCat = list.filter((a) => (a.category || 'utilities') === c);
        if (!inCat.length) return;
        html += '<div class="stsection">' + esc(L('ph.cat_' + c)) + '</div>' +
          '<div class="group" style="padding:0 14px;margin-bottom:20px">' +
          inCat.map(storeRow).join('') + '</div>';
      });
    }
    byId('stbody').innerHTML = html;
    wire();
  };

  [...byId('appbody').querySelectorAll('.seg button')].forEach((b) =>
    b.addEventListener('click', () => { storeCat = b.dataset.c; RENDER.store(); }));
  paint('');
  onSearch(paint);
};

// -- Health -----------------------------------------------------
// v-status already tracks every one of these. A second copy here would drift the first
// time either side changed, so this reads and never stores.
function ringHtml(label, value, max, colour) {
  const pct = Math.max(0, Math.min(1, (Number(value) || 0) / max));
  const C = 2 * Math.PI * 31;
  return '<div class="ring"><div class="dial">' +
    '<svg viewBox="0 0 78 78"><circle class="bg" cx="39" cy="39" r="31"/>' +
    '<circle cx="39" cy="39" r="31" stroke="' + colour + '" stroke-dasharray="' + C + '" ' +
    'stroke-dashoffset="' + (C * (1 - pct)) + '"/></svg>' +
    '<span class="val">' + Math.round(pct * 100) + '</span></div>' +
    '<div class="lab">' + esc(label) + '</div></div>';
}

let healthTab = 'today';
// Whether this character's job may read other people's records. Answered by the server with
// the record itself, so the tab appears without a second round trip - and the server checks it
// again on every read, because a tab is not a permission.
let healthReader = false;

// The hospitals, once. The list is the config: it cannot change while the server is up, so
// re-fetching it every time somebody taps the tab would be waste. `null` means "not asked
// yet", which is why the tab is offered on a first open rather than hidden until proven.
let healthHospitals = null;

// Everybody close enough to be examined, and their records.
//
// The list and the read are both checked on the server - job, grade, distance, and that the
// person is really there - so this screen is a convenience over that and never the gate.
async function healthPatients() {
  if (!openApp || openApp.id !== 'health') return;
  beginView();
  setNav(L('app.health'), null);
  loading();
  const d = await post('health', { op: 'nearby' });
  if (!openApp || openApp.id !== 'health') return;
  if (!d || d.error) {
    body(UI.empty(L('ph.err_' + ((d && d.error) || 'x')), 'contacts'));
    return;
  }
  const list = d.players || [];
  if (!list.length) {
    body(UI.empty(L('ph.health_nobody'), 'contacts') +
      '<div class="groupfoot">' + esc(L('ph.health_range_hint')
        .replace('{n}', String(Math.round(d.range || 5)))) + '</div>');
    return;
  }
  body(UI.group(list.map((pl) => UI.row({
    avatar: pl.name, title: pl.name, value: '#' + pl.id, chevron: true,
    data: { pid: pl.id },
  }))) + '<div class="groupfoot">' + esc(L('ph.health_read_hint')) + '</div>');

  rows('.row[data-pid]', (r) => r.addEventListener('click', async () => {
    const res = await post('health', { op: 'read', id: Number(r.dataset.pid) });
    if (!res || !res.ok) { toast(L('ph.err_' + ((res && res.error) || 'x'))); return; }
    healthRecordSheet(res.name, res.record || {});
  }));
}

// One record, read-only. Shared by the reader's screen and by an accepted FruitDrop, because
// a record looks the same whichever way it arrived.
function healthRecordSheet(name, r) {
  const line = (label, value) => (value
    ? UI.row({ icon: 'id', title: L(label), subtitle: String(value) }) : '');
  sheet(name || L('ph.record'),
    UI.group([
      r.blood ? UI.row({ icon: 'heart', tint: '#FF2D55', title: L('ph.blood'),
                         value: String(r.blood), mono: true }) : '',
      line('ph.allergies', r.allergies),
      line('ph.conditions', r.conditions),
      line('ph.meds', r.meds),
      line('ph.ice', r.ice),
      UI.row({ icon: 'heart', title: L('ph.donor'),
               value: L(r.donor ? 'ph.yes' : 'ph.no') }),
    ].filter(Boolean)) +
    // Nothing is empty-checked away: a record with nothing in it is itself worth knowing, and
    // an empty sheet would read as a failure to load.
    ((r.blood || r.allergies || r.conditions || r.meds || r.ice) ? ''
      : '<div class="groupfoot">' + esc(L('ph.health_empty')) + '</div>'));
}

// ── Hospitals ──────────────────────────────────────────────────
// A list the operator wrote, and a waypoint. The phone cannot know where a server put its
// hospitals - an MLO moves the door - so this shows what it was told and nothing more.
function healthHospitalList() {
  body(
    UI.group(healthHospitals.map((h, i) => UI.row({
      icon: 'heart', tint: '#FF453A', title: h.label,
      subtitle: h.address || '',
      // Only the ones with a position are worth a chevron: the rest are information.
      value: (h.x && h.y) ? L('ph.locate_short') : '',
      chevron: !!(h.x && h.y),
      data: { h: String(i) },
    })), { header: L('ph.hospitals'), footer: L('ph.hospitals_hint') })
  );

  rows('.row[data-h]', (r) => r.addEventListener('click', async () => {
    const h = healthHospitals[Number(r.dataset.h)];
    if (!h || !h.x || !h.y) return;
    const set = await post('waypoint', { x: h.x, y: h.y });
    toast(L(set && set.ok ? 'ph.veh_located' : 'ph.err_x'));
    ui('key');
  }));
}

RENDER.health = async () => {
  // Asked once, before the tabs are drawn, so the tab is never offered on a server that
  // listed no hospitals - and never missing on one that did. It costs nothing: the list is
  // the config and the client already holds it, so this never reaches the server.
  if (healthHospitals === null) {
    const d = await post('hospitals');
    healthHospitals = (d && d.hospitals) || [];
  }

  const tabs = [
    { id: 'today', icon: 'heart', label: 'ph.today' },
    { id: 'record', icon: 'id', label: 'ph.record' },
  ];
  if (healthHospitals.length) tabs.push({ id: 'hospitals', icon: 'map', label: 'ph.hospitals' });
  // Only for a job the operator listed. `healthReader` is last known rather than asked for
  // here - the record read fills it - so the tab may be a beat late on the very first open and
  // is then correct. It is a shortcut to a screen, not a permission: every read is checked
  // again on the server.
  if (healthReader) tabs.push({ id: 'patients', icon: 'contacts', label: 'ph.patients' });
  tabbar(tabs, healthTab, (t) => { healthTab = t; RENDER.health(); });
  if (healthTab === 'record') { healthRecord(); return; }
  if (healthTab === 'hospitals') { healthHospitalList(); return; }
  if (healthTab === 'patients') { healthPatients(); return; }

  // The vitals view asks for the record as well, purely to learn whether this character may
  // read other people's. Without it a medic would have to open their own record once before
  // the Patients tab appeared, which is a strange thing to have to discover.
  post('health', { op: 'get' }).then((d) => {
    const may = !!(d && d.reader);
    if (may !== healthReader && openApp && openApp.id === 'health') {
      healthReader = may;
      RENDER.health();
    }
  });
  loading();
  const d = await post('health');
  if (!d || d.error) { body(UI.empty(L('ph.err_off'), 'heart')); return; }
  const rows = [];
  if (d.bleed > 0) rows.push(UI.row({ icon: 'heart', tint: '#FF3B30', title: L('ph.bleeding'), value: String(d.bleed), tone: 'neg' }));
  if (d.sick > 0) rows.push(UI.row({ icon: 'heart', tint: '#FF3B30', title: L('ph.illness'), value: String(d.sick), tone: 'neg' }));
  body(
    '<div class="rings">' +
      ringHtml(L('ph.vitality'), d.health, 100, '#ff453a') +
      ringHtml(L('ph.armour'), d.armour, 100, '#0a84ff') +
      ringHtml(L('ph.hunger'), d.hunger, 100, '#ff9f0a') +
      ringHtml(L('ph.thirst'), d.thirst, 100, '#64d2ff') +
    '</div>' +
    ringHtml(L('ph.stress'), d.stress, 100, '#bf5af2').replace('class="ring"', 'class="ring" style="margin-bottom:20px"') +
    (rows.length ? UI.group(rows, { header: L('ph.attention') })
                 : UI.group([UI.row({ icon: 'heart', tint: '#FF3B30', title: L('ph.all_well') })]))
  );
};

// -- Reminders --------------------------------------------------
// Owned by the phone, and stored the same way a third-party app would store it: through
// the per-app storage the SDK exposes. If the example app's path were not good enough
// for a built-in one, it would not be good enough to hand to anybody else either.
let reminders = null;

async function loadReminders() {
  if (reminders) return reminders;
  const r = await post('appStorage', { app: 'reminders', op: 'get', key: 'items' });
  try { reminders = JSON.parse((r && r.value) || '[]') || []; } catch { reminders = []; }
  return reminders;
}

function saveReminders() {
  return post('appStorage', { app: 'reminders', op: 'set', key: 'items', value: JSON.stringify(reminders) });
}

RENDER.reminders = async () => {
  setNav(L('app.reminders'), null, { icon: 'add', onClick: () => {
    sheet(L('ph.new_reminder'), UI.field('rtext', L('ph.reminder_ph')) + UI.button(L('ph.save'), 'rsave'),
      () => byId('rsave').addEventListener('click', async () => {
        const v = byId('rtext').value.trim();
        if (!v) return;
        const epoch = sheetEpoch;
        reminders.unshift({ t: v, done: false });
        await saveReminders();
        if (closeSheet(false, epoch)) RENDER.reminders();
      }));
  } });
  await loadReminders();
  if (!reminders.length) { body(UI.empty(L('ph.no_reminders'), 'check')); return; }
  const open = reminders.filter((r) => !r.done);
  const done = reminders.filter((r) => r.done);
  body(
    (open.length ? UI.group(open.map((r) => UI.row({
      icon: 'check', tint: '#FF9500', title: r.t, data: { i: reminders.indexOf(r) },
    })), { header: L('ph.to_do') }) : '') +
    (done.length ? UI.group(done.map((r) => UI.row({
      icon: 'check', tint: '#FF9500', title: r.t, value: L('ph.done'), tone: 'pos', data: { i: reminders.indexOf(r) },
    })), { header: L('ph.done') }) : '')
  );
  rows('.row[data-i]', (el) => el.addEventListener('click', async () => {
    const r = reminders[Number(el.dataset.i)];
    if (!r) return;
    // Ticking a done one removes it: a list you can never shorten stops being a list.
    if (r.done) reminders.splice(Number(el.dataset.i), 1); else r.done = true;
    await saveReminders(); RENDER.reminders();
  }));
};

// -- Camera -----------------------------------------------------
// Real, and only as real as the operator made it: with no upload target configured there
// is nowhere for a photo to go, and the app says so rather than pretending to save one.
// The camera, drawn like the iOS one: a black viewfinder with framing marks, a shutter
// ring, the last shot as a roll thumbnail, and a control to lay the phone on its side.
let camMode = 'photo';     // 'photo' | 'video' (video only when the server hosts media)
let camRecording = false;
let camFront = false;      // selfie: a game camera in front of the ped
let camAppOpen = false;    // the Camera app is up, so closeApp knows to tear it down

// Record a clip. The client relay hides the phone, the server records and uploads through
// screencapture, and the URL comes back. The countdown is cosmetic - the server owns the
// real clock and the cap.
async function cameraRecord() {
  if (camRecording) return;
  camRecording = true;
  const seconds = Math.max(1, Math.min(30, Number(state.mediaVideoMax) || 15));
  const rec = byId('camrec');
  if (rec) rec.classList.remove('hidden');
  let n = 0;
  const tick = setInterval(() => {
    n += 1;
    if (byId('camrectime')) byId('camrectime').textContent = String(n);
    if (n >= seconds) clearInterval(tick);
  }, 1000);

  const res = await post('record', { seconds });
  clearInterval(tick);
  camRecording = false;
  if (rec) rec.classList.add('hidden');
  if (!res || !res.ok || !res.url) { toast(L('ph.err_' + ((res && res.error) || 'x'))); return; }
  // A clip is a media item: offer to post it, and keep it on the roll.
  clipShareSheet(res.url);
}

// After a clip, ask where it goes. Straight to Bleeter or Snapmatic, or just kept.
function clipShareSheet(url) {
  sheet(L('ph.clip_ready'),
    UI.row({ icon: 'bleet', title: L('app.bleeter'), data: { to: 'bleeter' } }) +
    UI.row({ icon: 'snap', title: L('app.snap'), data: { to: 'snap' } }) +
    '<video class="clippreview" src="' + esc(url) + '" muted loop autoplay playsinline></video>',
    () => {
      [...byId('sheet').querySelectorAll('[data-to]')].forEach((el) =>
        el.addEventListener('click', async () => {
          const app = el.dataset.to;
          const epoch = sheetEpoch;
          const r = await post('social', { op: 'post', kind: 'video', image: url, body: '', app });
          if (!closeSheet(false, epoch)) return;
          toast(r && r.ok ? L('ph.clip_posted') : L('ph.err_' + ((r && r.error) || 'x')));
        }));
    });
}

// Is the Camera app usable? The server always sends an explicit boolean, so ABSENT means
// "this server did not say", not "off". Treating a missing field as off is what made the app
// report itself disabled on a server whose own startup log said `camera: on` - one missing
// key in a payload became a feature nobody could turn on.
//
// An operator who switches it off gets `false`, which is caught here. Nothing else is.
const cameraOn = () => state.camera !== false;

RENDER.camera = async () => {
  if (!cameraOn()) { body(UI.empty(L('ph.camera_off'), 'camera')); return; }
  const d = await post('photos', { op: 'list' });
  const shots = (d && d.photos) || [];
  const last = shots[0];

  // Immersive: no title bar, no padding, the black fills the screen edge to edge.
  byId('navbar').classList.add('hidden');
  byId('app').classList.add('camfull');
  byId('screen').classList.add('appblack');
  // The viewfinder shows the world, not a black rectangle. `camlive` makes the screen and
  // the app surface transparent so the game is visible THROUGH the handset - which is the
  // preview of the photograph about to be taken, and needs no capture loop to produce.
  //
  // Lua is told at the same moment: it puts the player in first person and hides the HUD and
  // minimap, so what is framed is what is photographed.
  // Only on the way IN. `RENDER.camera` is re-run by the landscape and selfie buttons, so
  // anything done here unconditionally would fight them.
  //
  // The `camlive` CLASS is Lua's to set, not this function's: it is what makes the screen
  // see-through, and it must appear at the same moment the cursor leaves. Two owners for one
  // class is how it ended up on screen with a cursor still over it.
  const entering = !camAppOpen;
  camAppOpen = true;
  if (entering) {
    // The engine frames the shot and the handset leaves the screen while it does. The phone
    // is drawn again the moment the camera closes, which Lua signals.
    post('camMode', { on: true, front: camFront });
  }

  body(
    '<div class="camui">' +
      '<div class="camtop">' +
        '<button class="camchip back" id="camback" type="button" aria-label="' + esc(L('ph.back')) + '">' +
          svg('chevron') + '</button>' +
        '<button class="camchip ' + (landscape ? 'on' : '') +
          '" id="camland" type="button" aria-label="' + esc(L('ph.landscape')) + '">' +
          svg('landscape') + '</button>' +
      '</div>' +
      '<div class="camview">' +
        '<span class="cammark tl"></span><span class="cammark tr"></span>' +
        '<span class="cammark bl"></span><span class="cammark br"></span>' +
        '<div class="camgrid"></div>' +
        '<div class="camhint">' + esc(L('ph.vf_hint')) + '</div>' +
      '</div>' +
      // Photo, and - when the server has video hosting on - a Video mode toggle.
      '<div class="cammode">' +
        '<span class="' + (camMode === 'photo' ? 'on' : '') + '" data-mode="photo">' + esc(L('ph.cam_photo')) + '</span>' +
        (state.mediaVideo ? '<span class="' + (camMode === 'video' ? 'on' : '') + '" data-mode="video">' +
          esc(L('ph.cam_video')) + '</span>' : '') +
      '</div>' +
      '<div class="camctl">' +
        (last ? '<button class="camroll" id="camroll" type="button" style="' + photoStyle(last) + '"></button>'
              : '<span class="camroll empty"></span>') +
        '<button class="camshutter' + (camMode === 'video' ? ' video' : '') + '" id="shoot" type="button" aria-label="' +
          esc(L('ph.shooting')) + '"><span></span></button>' +
        '<button class="camflip' + (camFront ? ' on' : '') + '" id="camselfie" type="button" aria-label="' +
          esc(L('ph.cam_selfie')) + '">' + svg('camrotate') + '</button>' +
      '</div>' +
      '<div class="camrec hidden" id="camrec"><span class="camrecdot"></span><span id="camrectime">0</span>s</div>' +
    '</div>'
  );

  rows('.cammode span[data-mode]', (el) => el.addEventListener('click', () => {
    camMode = el.dataset.mode; RENDER.camera();
  }));

  byId('shoot').addEventListener('click', async () => {
    if (camMode === 'video') { cameraRecord(); return; }
    toast(L('ph.shooting'));
    const res = await post('shoot');
    if (!res || res.error) { toast(L('ph.err_' + ((res && res.error) || 'x'))); return; }
    RENDER.camera();
  });
  byId('camback').addEventListener('click', () => closeApp());
  const toggle = () => { setLandscape(!landscape); RENDER.camera(); };
  byId('camland').addEventListener('click', toggle);
  // Flip to the front camera: a game camera in front of the ped, facing back, so a photo
  // or clip is of the player. The client sets it up and tears it down.
  byId('camselfie').addEventListener('click', () => {
    camFront = !camFront;
    post('camFacing', { front: camFront });
    RENDER.camera();
  });
  const roll = byId('camroll');
  if (roll) roll.addEventListener('click', () => {
    const a = (state.apps || []).find((x) => x.id === 'gallery');
    if (a) enterApp(a, null); else photoSheet(shots, 0);
  });
};

// The Gallery: every photo, tap to view, and from there set it as wallpaper, AirDrop it,
// or delete it. Same store as the camera - one shoots, one keeps.
let galleryAlbum = '';     // '' is everything

RENDER.gallery = async () => {
  const d = await post('photos', { op: 'list' });
  const shots = (d && d.photos) || [];
  const albums = (d && d.albums) || [];
  setNav(L('app.gallery'), null);
  if (!shots.length) { body(UI.empty(L('ph.no_photos'), 'images')); return; }

  // Albums are worked out from the photos, so the strip can never list one that is empty.
  const strip = '<div class="seg scroll" id="galbums">' +
    '<button class="' + (galleryAlbum === '' ? 'on' : '') + '" data-a="">' + esc(L('ph.all_photos')) + '</button>' +
    albums.map((a) => '<button class="' + (galleryAlbum === a ? 'on' : '') + '" data-a="' + esc(a) + '">' +
      esc(a) + '</button>').join('') + '</div>';

  const shown = shots.map((v, i) => ({ v: photoRow(v), i }))
    .filter((x) => galleryAlbum === '' || x.v.album === galleryAlbum);

  body(strip + (shown.length
    ? '<div class="shots">' + shown.map((x) =>
        '<div class="shot" data-i="' + x.i + '" style="' + photoStyle(x.v) + '"></div>').join('') + '</div>'
    : UI.empty(L('ph.album_empty'), 'images')));

  qrows('galbums', 'button', (b) => b.addEventListener('click', () => {
    galleryAlbum = b.dataset.a; RENDER.gallery();
  }));
  rows('.shot', (el) => el.addEventListener('click', () => photoSheet(shots, Number(el.dataset.i), albums)));
};

// ══ Zooming a photo ════════════════════════════════════════════
// A photograph is worth looking at closely, and a phone that cannot is annoying. The wheel
// zooms about the cursor - so the detail under the pointer stays under it - and a drag pans
// once the picture is larger than its frame. Double-click resets.
//
// Pure CSS transform on the img: nothing is re-fetched and the filter chosen above still
// applies, because the transform and the filter are independent properties.
function wirePhotoZoom(wrapId, imgId) {
  const wrap = byId(wrapId), img = byId(imgId);
  if (!wrap || !img) return;
  let z = 1, ox = 0, oy = 0, drag = null;
  const MIN = 1, MAX = 6;

  // A cropped preview draws with `object-fit: cover`, which a transform would fight, so
  // zooming steps aside while a shape is chosen.
  const off = () => wrap.dataset.nozoom === '1';

  const apply = () => {
    if (off()) { img.style.transform = ''; return; }
    // Never leave a gap: at any zoom the picture must still cover its frame.
    const w = wrap.clientWidth, h = wrap.clientHeight;
    const maxX = Math.max(0, w * z - w), maxY = Math.max(0, h * z - h);
    ox = Math.min(0, Math.max(-maxX, ox));
    oy = Math.min(0, Math.max(-maxY, oy));
    img.style.transform = 'translate(' + ox + 'px,' + oy + 'px) scale(' + z + ')';
    const hint = byId(wrapId + 'hint');
    if (hint) hint.textContent = z > 1.01 ? Math.round(z * 100) + '%' : '';
  };

  wrap.addEventListener('wheel', (e) => {
    if (off()) return;
    e.preventDefault();
    const r = wrap.getBoundingClientRect();
    const px = e.clientX - r.left, py = e.clientY - r.top;
    const before = z;
    z = Math.min(MAX, Math.max(MIN, z * (e.deltaY < 0 ? 1.18 : 1 / 1.18)));
    // Keep the point under the cursor fixed: solve for the offset that does not move it.
    const k = z / before;
    ox = px - (px - ox) * k;
    oy = py - (py - oy) * k;
    if (z <= MIN + 0.001) { z = MIN; ox = 0; oy = 0; }
    apply();
  }, { passive: false });

  wrap.addEventListener('pointerdown', (e) => {
    if (off() || z <= MIN + 0.001) return;
    drag = { x: e.clientX, y: e.clientY, ox, oy };
    wrap.classList.add('panning');
  });
  wrap.addEventListener('pointermove', (e) => {
    if (!drag) return;
    ox = drag.ox + (e.clientX - drag.x);
    oy = drag.oy + (e.clientY - drag.y);
    apply();
  });
  ['pointerup', 'pointerleave', 'pointercancel'].forEach((ev) =>
    wrap.addEventListener(ev, () => { drag = null; wrap.classList.remove('panning'); }));
  wrap.addEventListener('dblclick', () => { if (off()) return; z = MIN; ox = 0; oy = 0; apply(); });
  apply();
}

function photoSheet(shots, i, albums) {
  const r = photoRow(shots[i]);
  const url = r.url;
  let crop = CROPS.includes(r.crop) ? r.crop : 'none';
  let focus = focusOf(r.focus);
  sheet(L('app.gallery'),
    '<div class="shotzoom" id="shotwrap"><img class="shotbig" id="shotbig" src="' + esc(url) +
      '" style="filter:' + filterCss(r.filter) + '" />' +
      '<span class="shotzoomhint" id="shotwraphint"></span></div>' +
    // Retouching: pick a look, it applies live and is remembered with the photo.
    '<div class="grouphead">' + esc(L('ph.filters')) + '</div>' +
    '<div class="seg scroll" id="sfilters">' + FILTERS.map((f) =>
      '<button class="' + ((r.filter || 'none') === f ? 'on' : '') + '" data-f="' + f + '">' +
      esc(L('ph.filter_' + f)) + '</button>').join('') + '</div>' +
    // Reshaping: the same idea one step further. Pick a shape and the preview above becomes
    // that shape immediately; the slider says which band of the picture survives it.
    '<div class="grouphead">' + esc(L('ph.crop')) + '</div>' +
    '<div class="seg scroll" id="scrops">' + CROPS.map((c) =>
      '<button class="' + (crop === c ? 'on' : '') + '" data-c="' + c + '">' +
      esc(L('ph.crop_' + c)) + '</button>').join('') + '</div>' +
    '<div class="focusrow" id="sfocusrow">' +
      '<span>' + esc(L('ph.crop_focus')) + '</span>' +
      '<input type="range" id="sfocus" min="0" max="100" step="1" value="' + focus +
        '" aria-label="' + esc(L('ph.crop_focus')) + '" />' +
    '</div>' +
    UI.button(L('ph.album_set'), 'salbum', 'plain') +
    UI.button(L('ph.airdrop_share'), 'sshare', 'tinted') +
    UI.button(L('ph.set_wallpaper'), 'swall') +
    UI.button(L('ph.delete'), 'sdel', 'destructive'),
    () => {
      // Draw whatever shape is current. `cover` on the img plus a ratio on the frame is the
      // whole crop: no canvas, no re-upload, and the stored filter still applies because
      // object-fit and filter are independent properties.
      const paint = () => {
        const wrap = byId('shotwrap'), img = byId('shotbig'), ratio = cropRatio(crop);
        if (!wrap || !img) return;
        // Wind any zoom back to 1 while zooming still answers, or its internal scale survives
        // the crop and the next wheel starts from 3x on a picture drawn at 1x.
        if (ratio && wrap.dataset.nozoom !== '1') wrap.dispatchEvent(new MouseEvent('dblclick'));
        wrap.dataset.nozoom = ratio ? '1' : '0';
        wrap.style.aspectRatio = ratio ? String(ratio) : '';
        img.style.height = ratio ? '100%' : '';
        img.style.objectFit = ratio ? 'cover' : '';
        img.style.objectPosition = ratio ? '50% ' + focus + '%' : '';
        if (ratio) img.style.transform = '';
        const row = byId('sfocusrow');
        // Framing only means something once something is being cut off.
        if (row) row.classList.toggle('off', !ratio);
      };
      paint();
      wirePhotoZoom('shotwrap', 'shotbig');
      [...byId('sheet').querySelectorAll('#scrops button')].forEach((b) =>
        b.addEventListener('click', async () => {
          crop = b.dataset.c;
          [...byId('scrops').querySelectorAll('button')].forEach((x) => x.classList.toggle('on', x === b));
          paint();
          await post('photos', { op: 'edit', index: i + 1, crop: crop === 'none' ? '' : crop });
          toast(L('ph.crop_saved'));
        }));
      const slider = byId('sfocus');
      if (slider) {
        // Repaint on every movement, save when it stops: dragging must not post fifty times.
        slider.addEventListener('input', () => { focus = focusOf(slider.value); paint(); });
        ['change', 'pointerup'].forEach((ev) => slider.addEventListener(ev, async () => {
          await post('photos', { op: 'edit', index: i + 1, focus });
          toast(L('ph.crop_saved'));
        }));
      }
      [...byId('sheet').querySelectorAll('#sfilters button')].forEach((b) =>
        b.addEventListener('click', async () => {
          const f = b.dataset.f;
          byId('shotbig').style.filter = filterCss(f);
          [...byId('sfilters').querySelectorAll('button')].forEach((x) => x.classList.toggle('on', x === b));
          await post('photos', { op: 'edit', index: i + 1, filter: f === 'none' ? '' : f });
          toast(L('ph.crop_saved'));
        }));
      byId('salbum').addEventListener('click', () => {
        const list = (albums || []).slice();
        sheet(L('ph.album_set'),
          UI.field('albname', L('ph.album_name'), r.album || '', 'maxlength="40"') +
          UI.button(L('ph.save'), 'albgo', 'tinted') +
          (list.length ? UI.group(list.map((a) => UI.row({ icon: 'folder', title: a, data: { alb: a } }))) : ''),
          () => {
            byId('albgo').addEventListener('click', async () => {
              const album = byId('albname').value.trim();
              const epoch = sheetEpoch;
              await post('photos', { op: 'edit', index: i + 1, album });
              if (closeSheet(false, epoch)) RENDER.gallery();
            });
            [...byId('sheet').querySelectorAll('.row')].forEach((el) => el.addEventListener('click', async () => {
              const epoch = sheetEpoch;
              await post('photos', { op: 'edit', index: i + 1, album: el.dataset.alb });
              if (closeSheet(false, epoch)) RENDER.gallery();
            }));
          });
      });
      byId('sshare').addEventListener('click', () => airdropShare('photo', { url }));
      byId('swall').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        // The framing goes with it: a portrait crop exists so the wallpaper shows the right
        // part of a wide photograph, and losing it here would make the whole exercise moot.
        const r = await post('prefs', { wallpaperUrl: url, wallFocus: focus });
        if (!closeSheet(false, epoch)) return;
        if (r && r.ok) { state.prefs = r.prefs; applyWallpaper(); toast(L('ph.wall_set')); }
        else toast(L('ph.err_' + ((r && r.error) || 'x')));
      });
      byId('sdel').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        await post('photos', { op: 'del', index: i + 1 });
        if (!closeSheet(false, epoch)) return;
        toast(L('ph.photo_deleted'));
        if (openApp && openApp.id === 'gallery') RENDER.gallery(); else RENDER.camera();
      });
    });
}

// ══ AirDrop ════════════════════════════════════════════════════
// Pick a nearby device and send. The scan and the send are both gated server-side on
// Bluetooth and range, so this only ever draws what the server says is reachable.
function airdropShare(kind, payload) {
  sheet(L('ph.airdrop'),
    '<div class="airhint">' + esc(L('ph.airdrop_hint')) + '</div><div id="airlist"></div>',
    async () => {
      const host = byId('airlist');
      host.innerHTML = '<div class="airscan">' + esc(L('ph.airdrop_scanning')) + '</div>';
      const r = await post('airdropScan');
      if (byId('airlist') !== host || !host.isConnected) return;
      if (!r || r.error) { host.innerHTML = UI.empty(L('ph.airdrop_' + ((r && r.error) || 'x')), 'airdrop'); return; }
      const devs = r.devices || [];
      if (!devs.length) { host.innerHTML = UI.empty(L('ph.airdrop_none'), 'airdrop'); return; }
      host.innerHTML = UI.group(devs.map((dv) => UI.row({
        icon: 'airdrop', tint: '#0A84FF', title: dv.name, subtitle: L('ph.airdrop_nearby'),
        chevron: true, data: { to: dv.id },
      })));
      [...host.querySelectorAll('.row')].forEach((el) => el.addEventListener('click', async () => {
        const to = Number(el.dataset.to);
        closeSheet();
        const res = await post('airdropSend', { to, kind, payload });
        toast(res && res.ok ? L('ph.airdrop_sent') : L('ph.airdrop_' + ((res && res.error) || 'x')));
      }));
    });
}

// The receiver's prompt. Nothing is written until they accept.
// ── A charging point that wants paying ─────────────────────────
// One payment buys the whole stop; leaving the zone is what makes the next one cost. None of
// that is decided here - the price, which charger it is and whether it has already been paid
// for all live on the server, and this sheet sends nothing but yes or no. See
// server/charging.lua.
let chargeSheetEpoch = null;

function chargeOfferSheet(o) {
  o = o || {};
  const price = Math.max(0, Math.round(Number(o.price) || 0));
  sheet(L('ph.charge_offer_title'),
    '<div class="airbig">' + svg('settings') + '<span>' + esc(o.label || '') + '</span></div>' +
    '<div class="airfrom">' +
      esc(L('ph.charge_offer_line').replace('{price}', String(price))) + '</div>' +
    UI.button(L('ph.charge_pay').replace('{price}', String(price)), 'chgok', 'tinted') +
    UI.button(L('ph.charge_later'), 'chgno', 'plain') +
    '<div class="groupfoot">' + esc(L('ph.charge_offer_hint')) + '</div>',
    () => {
      chargeSheetEpoch = sheetEpoch;
      byId('chgok').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        const r = await post('chargePay', {});
        if (!closeSheet(false, epoch)) return;
        if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
        ui('money');
        toast(L('ph.charge_paid'));
      });
      byId('chgno').addEventListener('click', () => {
        // Told to the server, not just dismissed: a refusal it does not hear about is a
        // refusal it asks about again four seconds later.
        post('chargeDecline', {});
        closeSheet();
      });
    });
}

// ── FruitCharge: find a charger, and pay a paid one ────────────
// The app the paid-charging notification points at. It lists the public chargers, takes you
// to one, and is where a paid charge is accepted - with an auto-accept for a regular who does
// not want to be asked. Everything money and position is the server's; this draws and asks.
// See server/charging.lua.
// ── Taxi: hail a ride, or drive one ────────────────────────────
// A ride-hailing app's shape on this phone's components: a card that says whether anybody is out
// driving, a booking sheet, and a live strip once a ride is on. A driver gets a second tab with
// the queue, sorted by how far away each fare is.
//
// Both providers answer and the page is written for both. doc-taxijob keeps its own field names -
// `callId`, `taxisAvailable`, `etoiles` - and the config provider's are flatter; `taxiPost` and
// `taxiRideOf` are the only two places that know the difference.
let taxiTab = 'ride';          // 'ride' | 'drive'
let taxiData = null;
let taxiPassengers = 1;
let taxiDest = '';
let taxiNote = '';
let taxiTip = 0;

/// Which provider is live, and therefore which relay to talk to.
const taxiDoc = () => !!(taxiData && taxiData.doc);

/// The one ride this player is on, in either provider's shape.
function taxiRideOf(d) {
  if (!d) return null;
  if (d.ride) return d.ride;                       // config provider
  // doc-taxijob does not hand back a ride object - its own app tracked a callId it had been
  // given. `taxiCall` remembers it, so a booking made in this session is still followed.
  //
  // The STATE used to be hard-coded 'pending' here, and that was the bug: a passenger whose
  // driver had accepted, arrived and finished the ride watched "looking for a driver" the entire
  // time. doc-taxijob does not answer "what is my ride doing" - it BROADCASTS, and client/taxi.lua
  // now listens and mirrors what it heard into `taxiDocState`.
  if (d.doc && taxiLastCall) {
    return { id: taxiLastCall, state: taxiDocState || 'pending', driver: taxiDocDriver || '' };
  }
  return null;
}
let taxiLastCall = null;
let taxiDocState = null;    // 'pending' | 'accepted' | 'done', mirrored from doc-taxijob
let taxiDocDriver = null;   // never a name: doc-taxijob keeps the driver anonymous to the client
let taxiDocFare = null;     // the driver's side: the fare they accepted, and how to ring them

/// The steps a ride passes through, which is not the same list on both providers.
///
/// doc-taxijob has three states - pending, accepted, completed - and no separate "on board". The
/// four-step rail drew a step that could never light on that provider, and a progress bar that
/// stops at three quarters on a finished ride reads as something having gone wrong.
function taxiSteps(doc) {
  return doc ? ['pending', 'accepted', 'done'] : ['pending', 'accepted', 'riding', 'done'];
}

function taxiStep(state, doc) {
  const order = taxiSteps(doc);
  const at = order.indexOf(String(state || 'pending'));
  return at < 0 ? 0 : at;
}

RENDER.taxi = async () => {
  loading();
  // The config provider answers `taxiOpen` and says whether doc-taxijob owns this server; if it
  // does, its own state is asked for instead.
  let d = await post('taxiOpen', {});
  if (d && d.doc) {
    const doc = await post('taxiDoc', { op: 'state' });
    if (doc && !doc.error) d = Object.assign({}, d, doc, { doc: true });
    // The mirrored state lives in client/taxi.lua, because the events that set it arrive whether
    // this app is open or not. Read on every render so reopening the app shows where the ride
    // actually is rather than where it was when the page last happened to be looking.
    const live = await post('taxiDocState', {});
    if (live && live.ok) {
      taxiDocState = live.state || taxiDocState;
      taxiDocDriver = live.driver || taxiDocDriver;
      taxiDocFare = (live.fare && live.fare.callId) ? live.fare : taxiDocFare;
    }
  }
  if (!d || d.error) {
    body(UI.empty(L('ph.taxi_e_' + ((d && d.error) || 'off')), 'taxi'));
    return;
  }
  taxiData = d;

  const on = (name) => ((d.features || {})[name] !== false);
  const driver = d.isDriver === true && on('driver');

  if (driver) {
    tabbar([
      { id: 'ride', icon: 'taxi', label: 'ph.taxi_tab_ride' },
      { id: 'drive', icon: 'garage', label: 'ph.taxi_tab_drive',
        badge: (d.queue || []).length },
    ], taxiTab, (tab) => { taxiTab = tab; RENDER.taxi(); });
  } else {
    taxiTab = 'ride';
    foot('');
  }

  if (taxiTab === 'drive') { taxiDriver(d); return; }

  setNav(L('app.taxi'), null, null);

  const ride = taxiRideOf(d);
  const drivers = Number(d.drivers !== undefined ? d.drivers : d.taxisAvailable) || 0;

  // ── the live strip ──
  // Only while a ride is on. It is the reason somebody opens this app twice.
  const strip = ride ? (() => {
    const steps = taxiSteps(d.doc);
    const step = taxiStep(ride.state, d.doc);
    return '<div class="txtrack">' +
      '<div class="txtrackrow"><b>' + esc(L('ph.taxi_st_' + String(ride.state || 'pending'))) +
        '</b><span>' + esc(ride.driver || '') + '</span></div>' +
      '<div class="txbar"><i style="width:' +
        Math.round(((step + 1) / steps.length) * 100) + '%"></i></div>' +
      '<div class="txsteps">' +
        steps.map((s, i) =>
          '<span class="' + (step >= i ? 'on' : '') + '">' +
          esc(L('ph.taxi_step_' + s)) + '</span>').join('') +
      '</div>' +
      (Number(ride.fare) > 0
        ? '<div class="txfare">' + esc(L('ph.taxi_due').replace('{n}', money(ride.fare))) + '</div>'
        : '') +
    '</div>';
  })() : '';

  body(
    strip +
    UI.hero({
      appicon: 'taxi',
      eyebrow: L('app.taxi'),
      // The one fact that decides whether booking is worth trying.
      value: drivers > 0 ? L('ph.taxi_drivers').replace('{n}', String(drivers))
                         : L('ph.taxi_nodrivers'),
      subtitle: (on('estimate') && d.basePrice !== undefined)
        ? L('ph.taxi_rates').replace('{base}', money(d.basePrice))
                            .replace('{km}', money(d.pricePerKm))
        : '',
    }) +
    // What can be done depends entirely on where the ride is.
    (!ride
      ? (d.cooldown
          ? '<div class="groupfoot">' +
              esc(L('ph.taxi_cooldown').replace('{s}', String(d.cooldown))) + '</div>'
          : UI.button(L('ph.taxi_book'), 'txbook', 'tinted'))
      : (ride.state === 'done'
          ? UI.button(L('ph.taxi_settle'), 'txpay', 'tinted')
          : UI.button(L('ph.taxi_cancel'), 'txcancel', 'destructive'))) +
    (ride && ride.state === 'done' && on('rating') && d.rating !== false
      ? UI.button(L('ph.taxi_rate'), 'txrate', 'plain') : '') +
    '<div class="groupfoot">' + esc(L('ph.taxi_hint')) + '</div>'
  );

  if (byId('txbook')) byId('txbook').addEventListener('click', () => taxiBook(d));
  if (byId('txcancel')) byId('txcancel').addEventListener('click', async () => {
    const r = taxiDoc()
      ? await post('taxiDoc', { op: 'cancel', callId: ride.id })
      : await post('taxiAct', { op: 'cancel', id: ride.id });
    if (!r || r.error) { toast(L('ph.taxi_e_' + ((r && r.error) || 'x'))); return; }
    taxiLastCall = null;
    toast(L('ph.taxi_cancelled'));
    RENDER.taxi();
  });
  if (byId('txpay')) byId('txpay').addEventListener('click', () => taxiSettle(d, ride));
  if (byId('txrate')) byId('txrate').addEventListener('click', () => taxiRate(d, ride));
};

/// Booking: how many people, where to, and anything the driver should know.
function taxiBook(d) {
  const on = (name) => ((d.features || {})[name] !== false);
  const max = Math.max(1, Number(d.maxPassengers) || 4);
  taxiPassengers = Math.min(taxiPassengers, max);

  const seats = () => '<div class="seg" id="txseats">' +
    Array.from({ length: max }, (_, i) => i + 1).map((n) =>
      '<button class="' + (n === taxiPassengers ? 'on' : '') + '" data-p="' + n + '">' +
      n + '</button>').join('') + '</div>';

  sheet(L('ph.taxi_book'),
    '<div class="grouphead">' + esc(L('ph.taxi_passengers')) + '</div>' + seats() +
    (on('destination')
      ? UI.field('txdest', L('ph.taxi_dest'), taxiDest, 'maxlength="60"') : '') +
    (on('note') ? UI.field('txnote', L('ph.taxi_note'), taxiNote, 'maxlength="120"') : '') +
    (on('estimate') && d.basePrice !== undefined
      ? '<div class="groupfoot">' +
          esc(L('ph.taxi_estimate').replace('{n}', money(d.basePrice))) + '</div>'
      : '') +
    UI.button(L('ph.taxi_confirm'), 'txgo', 'tinted'),
    () => {
      const epoch = sheetEpoch;
      [...byId('txseats').querySelectorAll('button')].forEach((b) =>
        b.addEventListener('click', () => {
          taxiPassengers = Number(b.dataset.p) || 1;
          [...byId('txseats').children].forEach((x) => x.classList.remove('on'));
          b.classList.add('on');
        }));

      byId('txgo').addEventListener('click', async () => {
        const go = byId('txgo');
        if (go.disabled) return;          // double-tapping must not book twice
        go.disabled = true;
        taxiDest = byId('txdest') ? byId('txdest').value.trim() : '';
        taxiNote = byId('txnote') ? byId('txnote').value.trim() : '';

        const r = taxiDoc()
          // doc-taxijob reads `name`, `passengers` and `destination`. The name is its own
          // player's, which its callback already knows - passed for the ticket it prints.
          ? await post('taxiDoc', { op: 'call', call: {
              name: d.playerName || '', passengers: taxiPassengers, destination: taxiDest,
            } })
          : await post('taxiCall', {
              passengers: taxiPassengers, destination: taxiDest, note: taxiNote,
            });

        if (!r || (!r.ok && !r.success)) {
          go.disabled = false;
          // doc-taxijob answers a human `reason`; the config provider answers a code.
          toast((r && r.reason) ? r.reason : L('ph.taxi_e_' + ((r && r.error) || 'x')));
          return;
        }
        if (!closeSheet(false, epoch)) return;
        ui('sent');
        taxiLastCall = r.callId || r.id || null;
        const n = Number(r.drivers !== undefined ? r.drivers : r.taxisAvailable) || 0;
        toast(n > 0 ? L('ph.taxi_sent').replace('{n}', String(n)) : L('ph.taxi_sent_nobody'));
        RENDER.taxi();
      });
    });
}

/// Settling up: the fare, and a tip if the server allows one.
function taxiSettle(d, ride) {
  const on = (name) => ((d.features || {})[name] !== false);
  const fare = Math.max(0, Number(ride.fare) || 0);
  const tipCfg = d.tip || {};
  const tipOn = on('tip') && tipCfg.on !== false;
  const tipAmount = Math.min(Math.floor(fare * taxiTip / 100), Number(tipCfg.max) || 500);

  sheet(L('ph.taxi_settle'),
    UI.group([
      UI.row({ icon: 'taxi', title: L('ph.taxi_fare'), value: money(fare), mono: true }),
      ride.km ? UI.row({ icon: 'map', title: L('ph.taxi_distance'),
                         value: (Number(ride.km) / 1000).toFixed(1) + ' km' }) : '',
      tipAmount ? UI.row({ icon: 'heart', title: L('ph.taxi_tip'),
                           value: money(tipAmount), mono: true }) : '',
      UI.row({ icon: 'wallet', title: L('ph.taxi_total'),
               value: money(fare + tipAmount), mono: true }),
    ].filter(Boolean)) +
    (tipOn
      ? '<div class="grouphead">' + esc(L('ph.taxi_tip')) + '</div>' +
        '<div class="seg" id="txtip">' + (tipCfg.presets || [0, 10, 20]).map((pct) =>
          '<button class="' + (Number(pct) === taxiTip ? 'on' : '') + '" data-t="' + pct + '">' +
          (Number(pct) === 0 ? esc(L('ph.taxi_tip_none')) : pct + '%') + '</button>').join('') +
        '</div>'
      : '') +
    UI.button(L('ph.taxi_pay').replace('{n}', money(fare + tipAmount)), 'txpaygo', 'tinted'),
    () => {
      const epoch = sheetEpoch;
      const tip = byId('txtip');
      if (tip) [...tip.querySelectorAll('button')].forEach((b) =>
        b.addEventListener('click', () => {
          taxiTip = Number(b.dataset.t) || 0;
          if (!closeSheet(false, epoch)) return;
          taxiSettle(d, ride);
        }));

      byId('txpaygo').addEventListener('click', async () => {
        const go = byId('txpaygo');
        if (go.disabled) return;
        go.disabled = true;
        // In doc-taxijob mode the fare is its own business - it charges at the end of the ride -
        // so this only offers the TIP, through its own callback.
        const r = taxiDoc()
          ? await post('taxiDoc', { op: 'tip', tip: { amount: tipAmount, method: 'cash' } })
          : await post('taxiPay', { id: ride.id, tip: tipAmount });
        if (!r || (!r.ok && !r.success)) {
          go.disabled = false;
          toast(L('ph.taxi_e_' + ((r && r.error) || 'x')));
          return;
        }
        if (!closeSheet(false, epoch)) return;
        ui('money');
        toast(L('ph.taxi_paid'));
        taxiLastCall = null;
        taxiTip = 0;
        RENDER.taxi();
      });
    });
}

/// Rating the driver.
function taxiRate(d, ride) {
  let stars = 5;
  const draw = () => [1, 2, 3, 4, 5].map((n) =>
    '<button class="zustar' + (n <= stars ? ' on' : '') + '" data-s="' + n + '" type="button">' +
    svg('star') + '</button>').join('');

  sheet(L('ph.taxi_rate'),
    '<div class="zustars" id="txstars">' + draw() + '</div>' +
    UI.field('txcomment', L('ph.taxi_comment'), '', 'maxlength="200"') +
    UI.button(L('ph.taxi_rate_send'), 'txratego', 'tinted'),
    () => {
      const epoch = sheetEpoch;
      const wire = () => [...byId('txstars').querySelectorAll('[data-s]')].forEach((b) =>
        b.addEventListener('click', () => {
          stars = Number(b.dataset.s) || 5;
          byId('txstars').innerHTML = draw();
          wire();
        }));
      wire();
      byId('txratego').addEventListener('click', async () => {
        const comment = byId('txcomment') ? byId('txcomment').value.trim() : '';
        // **`etoiles` and `commentaire`** for doc-taxijob: those are the names its callback
        // reads, and the English ones would rate every driver at nought.
        const r = taxiDoc()
          ? await post('taxiDoc', { op: 'rate', rating: { etoiles: stars, commentaire: comment } })
          : await post('taxiRate', { id: ride.id, stars, comment });
        if (!r || (!r.ok && !r.success)) {
          toast(L('ph.taxi_e_' + ((r && r.error) || 'x')));
          return;
        }
        if (!closeSheet(false, epoch)) return;
        ui('success');
        toast(L('ph.taxi_rated'));
        RENDER.taxi();
      });
    });
}

/// The driver's side: the queue, nearest first, and what to do with a fare.
async function taxiDriver(d) {
  setNav(L('ph.taxi_tab_drive'), null, {
    icon: 'refresh', label: L('ph.refresh'), onClick: () => RENDER.taxi(),
  });

  // In doc-taxijob mode the queue comes from it, with the distance worked out on the client.
  let calls = d.queue || [];
  if (taxiDoc()) {
    const q = await post('taxiDoc', { op: 'pending' });
    calls = (q && q.calls) || [];
  }
  // Nearest first: a driver takes the fare they can reach, not the one that waited longest.
  calls = calls.slice().sort((a, b) => {
    const da = Number(a.dist), db = Number(b.dist);
    if (Number.isFinite(da) && da >= 0 && Number.isFinite(db) && db >= 0) return da - db;
    return 0;
  });

  const row = (c) => UI.row({
    icon: 'taxi', tint: '#ffb300',
    title: c.name || L('ph.taxi_anon'),
    subtitle: [
      c.dist >= 0 ? ((Number(c.dist) / 1000).toFixed(1) + ' km') : null,
      c.passengers ? L('ph.taxi_seats').replace('{n}', String(c.passengers)) : null,
      c.destination || null,
    ].filter(Boolean).join('  ·  '),
    chevron: true,
    data: { txc: String(c.callId || c.id) },
  });

  // The fare this driver accepted, and the one thing they could not do about it: reach the
  // passenger. doc-taxijob hands the driver the client's name and server id on accept, so the
  // number is resolved on our server and the call goes out through the phone's own dialler.
  const fare = taxiDocFare && taxiDocFare.callId ? taxiDocFare : null;
  const mineCard = fare ? UI.group([
    UI.row({
      icon: 'taxi', tint: '#ffb300',
      title: fare.name || L('ph.taxi_anon'),
      subtitle: L('ph.taxi_doc_onboard'),
    }),
    fare.number
      ? UI.row({ icon: 'phone', tint: '#34C759', title: L('ph.taxi_doc_callclient'),
                 value: anyNum(fare.number), chevron: true, data: { txcall: fare.number } })
      : UI.row({ icon: 'phone', title: L('ph.taxi_doc_nonumber'), subtitle: '' }),
  ], { header: L('ph.taxi_doc_myfare') }) : '';

  body(
    UI.hero({ appicon: 'taxi', eyebrow: L('ph.taxi_tab_drive'),
              value: calls.length ? String(calls.length) : L('ph.taxi_queue_empty'),
              subtitle: calls.length ? L('ph.taxi_queue') : L('ph.taxi_queue_empty_hint') }) +
    mineCard +
    (calls.length
      ? UI.group(calls.map(row), { footer: L('ph.taxi_queue_hint') })
      : UI.empty(L('ph.taxi_queue_empty'), 'taxi'))
  );

  rows('[data-txcall]', (el) => el.addEventListener('click', () => {
    // Straight through placeCall, which is the one path that plays the reorder tone and says why
    // when a number does not answer.
    placeCall(el.dataset.txcall);
  }));

  rows('[data-txc]', (el) => el.addEventListener('click', () => {
    const c = calls.find((x) => String(x.callId || x.id) === el.dataset.txc);
    if (!c) return;
    const id = c.callId || c.id;
    const mine = d.ride && String(d.ride.id) === String(id) ? d.ride : null;

    sheet(c.name || L('ph.taxi_anon'),
      UI.group([
        c.destination ? UI.row({ icon: 'map', title: L('ph.taxi_dest'), subtitle: c.destination }) : '',
        c.passengers ? UI.row({ icon: 'contacts', title: L('ph.taxi_passengers'),
                                value: String(c.passengers) }) : '',
        c.dist >= 0 ? UI.row({ icon: 'location', title: L('ph.taxi_distance'),
                               value: (Number(c.dist) / 1000).toFixed(1) + ' km' }) : '',
        c.note ? UI.row({ icon: 'note', title: L('ph.taxi_note'), subtitle: c.note }) : '',
      ].filter(Boolean)) +
      // Accept, then the two steps of the ride. Only the config provider has those: doc-taxijob
      // runs the ride itself once its driver accepts, and a second thing driving it would be two
      // systems disagreeing about who is in the car.
      UI.button(L('ph.taxi_accept'), 'txaccept', 'tinted') +
      ((c.x || (c.coords && c.coords.x)) ? UI.button(L('ph.taxi_route'), 'txroute', 'plain') : '') +
      (!taxiDoc() && mine && mine.state === 'accepted'
        ? UI.button(L('ph.taxi_arrived'), 'txarrived', 'plain') : '') +
      (!taxiDoc() && mine && mine.state === 'riding'
        ? UI.button(L('ph.taxi_finish'), 'txfinish', 'plain') : ''),
      () => {
        const epoch = sheetEpoch;
        const act = async (op, label) => {
          const r = taxiDoc()
            ? await post('taxiDoc', { op: 'accept', callId: id })
            : await post('taxiAct', { op, id });
          if (!r || r.error) { toast(L('ph.taxi_e_' + ((r && r.error) || 'x'))); return; }
          if (!closeSheet(false, epoch)) return;
          ui('success');
          toast(L(label));
          RENDER.taxi();
        };
        byId('txaccept').addEventListener('click', () => act('accept', 'ph.taxi_accepted'));
        if (byId('txarrived')) byId('txarrived').addEventListener('click',
          () => act('arrived', 'ph.taxi_arrived_ok'));
        if (byId('txfinish')) byId('txfinish').addEventListener('click',
          () => act('finish', 'ph.taxi_finished'));
        if (byId('txroute')) byId('txroute').addEventListener('click', async () => {
          const x = c.x !== undefined ? c.x : (c.coords && c.coords.x);
          const y = c.y !== undefined ? c.y : (c.coords && c.coords.y);
          const r = await post('taxiRoute', { x, y });
          if (r && r.ok) { ui('waypoint'); toast(L('ph.taxi_routed')); }
        });
      });
  }));
}

// ── Zuber: food, ordered from the phone ────────────────────────
// Uber Eats' shape, on this phone's components: a dark header with the address, cards with a
// tint and a rating, a menu by category, a basket, and a tracker at the top once an order is
// out. Nothing about it is a copy of the original app's markup - it is the same job done with
// `UI.row`, `UI.hero` and `sheet`, so it looks like the rest of the phone rather than a website
// inside it.
//
// Two providers answer, and the page is written for both. doc-restaurant's payload keeps its own
// field names - `state.open`, `products`, `promotions`, `rating` - and the config provider's is
// flatter. `zuberCards()` is the one place that knows the difference; everything below reads
// what it returns. See server/zuber.lua and client/zuber.lua.
let zuberTab = 'browse';       // 'browse' | 'orders'
let zuberOpenId = null;        // the restaurant whose menu is showing
let zuberCart = {};            // { [item]: { label, price, qty } }
let zuberKind = 'delivery';
let zuberTier = 0;          // the loyalty tier being redeemed, 0 for none              // a percentage, chosen from the presets
let zuberNote = '';
let zuberQuery = '';
let zuberData = null;          // the last payload, so a repaint needs no round trip

const ZUBER_CATS = ['formulas', 'drinks', 'softs', 'alcohols', 'starters', 'mains', 'desserts'];

/// Where a dish's picture lives.
///
/// doc-restaurant hands back a FILE NAME - `burger.png`, or whatever the item's own `image` says -
/// because its own page knew which inventory the server runs. This phone does not, so the folder
/// is `Config.Zuber.imageBase` and the name is appended. An absolute URL is passed through
/// untouched, for a server that stores full links.
function zuberImage(name) {
  const file = String(name || '');
  if (!file) return '';
  if (/^https?:\/\//i.test(file) || file.indexOf('nui://') === 0) return file;
  const base = (zuberData && zuberData.imageBase) || '';
  if (!base) return '';
  return base.replace(/\/+$/, '') + '/' + file.replace(/^\/+/, '');
}

/// **Is doc-restaurant the one taking the money for this order?**
///
/// It decides whether this app may show a total at all. doc-restaurant's total IS the sum of the
/// item prices: the government tax is taken OUT of that - it splits TTC into HT plus tax and pays
/// each side - and it has no delivery charge of any kind. So anything this app adds on top is a
/// number nobody will ever be charged.
///
/// That is exactly what went wrong: `Config.Zuber.deliveryFee` and a tip were being added to a
/// doc-restaurant order, and the screen said 174 for an order that correctly cost 130. A wrong
/// total is the worst kind of bug in a shop - it is a number the player believes.
function zuberChargesUs(d) { return !(d && d.doc); }

/// Both payloads, reduced to one shape the rest of this app reads.
///
/// doc-restaurant hands back a MAP keyed by job with its own field names; the config provider
/// hands back a list. Normalised here and only here - the alternative was every function below
/// asking which provider it was looking at.
function zuberCards(d) {
  if (!d) return [];
  if (!d.doc) return (d.restaurants || []).slice();

  const out = [];
  const restaurants = d.restaurants || {};
  Object.keys(restaurants).forEach((job) => {
    const r = restaurants[job] || {};
    const state = r.state || {};
    // Its menu arrives as { category: [ { item, label, image, enabled } ] } with the price in a
    // separate `prices` map, because doc-restaurant lets a restaurant reprice a dish without
    // touching the catalogue.
    const menu = [];
    const products = r.products || {};
    // **`promotions` is an ARRAY**, not a map: doc-restaurant builds it with `table.insert` as
    // `{ item, discount, title }` rows. Reading it as `promotions[item]` found nothing, so every
    // promotion was invisible and every discounted price was the full one.
    const promoFor = (item) => {
      const list = r.promotions;
      if (!list) return null;
      if (Array.isArray(list)) return list.find((x) => x && x.item === item) || null;
      return list[item] || null;   // a fork that keyed it, or the config provider
    };
    Object.keys(products).forEach((category) => {
      (products[category] || []).forEach((prod) => {
        // `prices` IS keyed by item, and holds a plain number. A restaurant that has not set a
        // price for a dish has no entry at all - and that dish is not for sale, which is a
        // different thing from being free. `$0` on a menu is a bug somebody will exploit.
        const priced = (r.prices || {})[prod.item];
        const base = Number(priced && priced.price !== undefined ? priced.price : priced);
        const hasPrice = Number.isFinite(base) && base > 0;
        const promo = hasPrice ? promoFor(prod.item) : null;
        menu.push({
          item: prod.item,
          label: prod.label || prod.item,
          // doc-restaurant resolves the item's own image for us - `itemData.image`, or
          // `<item>.png` - so the app shows the real dish rather than a generic bag.
          image: prod.image || null,
          price: promo ? Math.round(base * (1 - (Number(promo.discount) || 0) / 100)) : (hasPrice ? base : 0),
          was: promo ? base : null,
          promo: promo ? Number(promo.discount) || 0 : 0,
          category,
          // Unpriced is unavailable. So is a dish the restaurant switched off.
          enabled: prod.enabled !== false && hasPrice,
          unpriced: !hasPrice,
        });
      });
    });
    out.push({
      id: job, job,
      label: r.name || job,
      tint: r.color || r.colorRGB || null,
      open: state.open === true,
      delivery: state.delivery !== false,
      takeaway: state.takeaway !== false,
      drive: r.hasDrive === true,
      rating: r.rating || null,
      x: r.coords && (r.coords.x !== undefined ? r.coords.x : r.coords[1]),
      y: r.coords && (r.coords.y !== undefined ? r.coords.y : r.coords[2]),
      discount: Number((d.clientDiscounts || {})[job]) || 0,
      // The loyalty scheme. doc-restaurant keeps the customer's card in `fidelityProfiles` and
      // the restaurant's tiers in `fidelityConfigs`, both keyed by job - and its own server
      // RE-CHECKS whichever tier is claimed, so this only offers what is already true.
      loyalty: (d.fidelityProfiles || {})[job] || null,
      loyaltyConfig: (d.fidelityConfigs || {})[job] || null,
      employee: (d.isEmployeeMap || {})[job] === true,
      menu,
      tags: [],
    });
  });
  // Open first, then by name: a shut restaurant is not what somebody opened this app for.
  out.sort((a, b) => (b.open ? 1 : 0) - (a.open ? 1 : 0) || String(a.label).localeCompare(b.label));
  return out;
}

const zuberPost = (op, body) => (zuberData && zuberData.doc)
  ? post('zuberDoc', Object.assign({ op }, body || {}))
  : post(op === 'restaurants' ? 'zuberOpen' : ('zuber' + op[0].toUpperCase() + op.slice(1)), body || {});

function zuberCartCount() {
  return Object.keys(zuberCart).reduce((n, k) => n + (Number(zuberCart[k].qty) || 0), 0);
}

function zuberCartTotal() {
  return Object.keys(zuberCart).reduce((n, k) =>
    n + (Number(zuberCart[k].price) || 0) * (Number(zuberCart[k].qty) || 0), 0);
}

/// The status of an order, as a step out of four, so the tracker can draw a bar rather than a
/// word nobody reads twice.
function zuberStep(status) {
  const order = ['pending', 'accepted', 'preparing', 'ready', 'delivering', 'completed'];
  const at = order.indexOf(String(status || 'pending'));
  return at < 0 ? 0 : at;
}

RENDER.zuber = async () => {
  loading();
  // The config provider answers `zuberOpen`; doc-restaurant answers through its own relay. Which
  // one is live is the client's to know, so both are asked and the first that answers wins.
  let d = await post('zuberOpen', {});
  if (d && d.doc) {
    const doc = await post('zuberDoc', { op: 'restaurants' });
    if (doc && !doc.error) d = Object.assign(d, doc, { doc: true });
    // Who this player is allowed to rate, and what they have already said. doc-restaurant
    // unlocks a rating after a delivered order and keeps that decision to itself, so this is
    // asked rather than worked out here - the app must not invite somebody to rate a place the
    // server will then refuse.
    const mine = await post('zuberDoc', { op: 'ratings' });
    if (mine && !mine.error) {
      d.myRatings = mine.mine || {};
      d.canRate = mine.eligible || {};
    }
  }
  if (!d || d.error) {
    body(UI.empty(L('ph.zuber_e_' + ((d && d.error) || 'off')), 'zuber'));
    return;
  }
  zuberData = d;

  const cards = zuberCards(d);
  const active = d.active || null;

  // Whatever the operator left on. A switched-off feature is absent, not a button that
  // apologises: `features` is sent by the server, so the page never reads the config itself.
  const on = (name) => ((d.features || {})[name] !== false);

  if (on('history')) {
    tabbar([
      { id: 'browse', icon: 'zuber', label: 'ph.zuber_tab_browse' },
      { id: 'orders', icon: 'note', label: 'ph.zuber_tab_orders', badge: active ? 1 : 0 },
    ], zuberTab, (tab) => { zuberTab = tab; zuberOpenId = null; RENDER.zuber(); });
  } else {
    zuberTab = 'browse';
    foot('');
  }

  if (zuberTab === 'orders') { zuberOrders(d); return; }
  if (zuberOpenId) { zuberMenu(d, cards.find((c) => c.id === zuberOpenId)); return; }

  setNav(L('app.zuber'), null, null);

  // ── The tracker ──
  // Only when something is on its way. An order is the thing somebody opens this app to check.
  const tracker = (active && on('tracker')) ? (() => {
    const step = zuberStep(active.status);
    return '<button class="zutrack" id="zutrack" type="button">' +
      '<div class="zutrackrow"><b>' + esc(L('ph.zuber_st_' + String(active.status || 'pending'))) +
        '</b><span>' + esc(active.label || active.restaurant || '') + '</span></div>' +
      '<div class="zubar"><i style="width:' + Math.round((step / 5) * 100) + '%"></i></div>' +
    '</button>';
  })() : '';

  // A search across every menu, not just the names: somebody looking for a burger does not know
  // which restaurant sells one, which is the whole reason to search from the front page.
  const q = zuberQuery.trim().toLowerCase();
  const favs = d.favourites || [];
  const isFav = (c) => favs.indexOf('r:' + c.id) !== -1;

  // Searchable means orderable. A dish with no price is not for sale, so matching one would send
  // somebody to a restaurant for something that is not on its menu - the same reason those rows
  // are gone from the menu itself.
  const sellable = (c) => (c.menu || []).filter((m) => !m.unpriced);

  const card = (c) => {
    const dish = q && !String(c.label).toLowerCase().includes(q)
      ? sellable(c).find((m) => String(m.label).toLowerCase().includes(q))
      : null;
    return '<button class="zucard' + (c.open ? '' : ' shut') + '" data-zr="' + esc(c.id) + '" type="button">' +
      '<div class="zutint" style="background:' + esc(c.tint || '#111') + '"></div>' +
      '<div class="zubody">' +
        '<div class="zutop"><b>' + esc(c.label) + '</b>' +
          (on('favourites') && isFav(c) ? '<i class="zufav">' + svg('star') + '</i>' : '') + '</div>' +
        '<div class="zumeta">' +
          (c.open ? '<span class="zuopen">' + esc(L('ph.zuber_open')) + '</span>'
                  : '<span class="zushut">' + esc(L('ph.zuber_shut')) + '</span>') +
          (c.rating && Number(c.rating.nb_votes) > 0
            ? '<span>' + svg('star') + ' ' + (Number(c.rating.moyenne) || 0).toFixed(1) + '</span>' : '') +
          (c.eta ? '<span>' + esc(String(c.eta)) + ' min</span>' : '') +
          (c.drive ? '<span>' + esc(L('ph.zuber_drive')) + '</span>' : '') +
          (Number(c.discount) > 0
            ? '<span class="zupromo">-' + Math.round(Number(c.discount)) + '%</span>' : '') +
        '</div>' +
        ((c.tags || []).length ? '<div class="zutags">' + c.tags.map(esc).join(' · ') + '</div>' : '') +
        (dish ? '<div class="zutags">' + esc(dish.label) + ' · ' + esc(money(dish.price)) + '</div>' : '') +
      '</div></button>';
  };

  // The list lives in its own container and the search repaints only that. Repainting the whole
  // view on each keystroke would destroy the input and take the focus - and the caret - with it,
  // so the second letter would go nowhere.
  const paint = () => {
    const host = byId('zulist');
    if (!host) return;
    const query = zuberQuery.trim().toLowerCase();
    const hits = cards.filter((c) => {
      if (!query) return true;
      if (String(c.label).toLowerCase().includes(query)) return true;
      return sellable(c).some((m) => String(m.label).toLowerCase().includes(query));
    });
    host.innerHTML = hits.length
      ? hits.map(card).join('')
      : UI.empty(L(cards.length ? 'ph.zuber_nomatch' : 'ph.zuber_none'), 'zuber');
    qrows('zulist', '[data-zr]', (el) => el.addEventListener('click', () => {
      zuberOpenId = el.dataset.zr;
      zuberCart = {};
      RENDER.zuber();
    }));
  };

  body(tracker + (on('search') ? searchHtml(L('ph.zuber_search')) : '') +
       '<div id="zulist" class="zulist"></div>');
  paint();

  if (byId('zutrack')) byId('zutrack').addEventListener('click', () => {
    zuberTab = 'orders';
    RENDER.zuber();
  });
  if (on('search')) onSearch((value) => { zuberQuery = value; paint(); });
};

/// One restaurant: its menu by category, and the basket.
function zuberMenu(d, c) {
  if (!c) { zuberOpenId = null; RENDER.zuber(); return; }
  setNav(c.label, L('app.zuber'), {
    icon: 'star',
    onClick: async () => {
      const r = await post('zuberFavourite', { key: 'r:' + c.id });
      if (r && r.ok) {
        zuberData.favourites = r.favourites || [];
        toast(L(r.on ? 'ph.zuber_faved' : 'ph.zuber_unfaved'));
      }
    },
  }, () => { zuberOpenId = null; RENDER.zuber(); });

  // A dish with no price row is not on sale, so it is not on the menu.
  //
  // It used to be listed and labelled "no price set", which is the right thing to tell the
  // OWNER and pointless for a customer: on doc-restaurant, where prices live in its own config
  // and a new dish often has no row yet, half a seafood menu read as unbuyable placeholders and
  // the two dishes that could actually be ordered were lost among them. A menu is a list of what
  // you can have.
  //
  // Counted rather than silently dropped: the footer says how many were withheld, so a restaurant
  // owner looking at their own menu still learns that something needs a price - the fact was
  // worth keeping, the row was not.
  const full = (c.menu || []);
  const menu = full.filter((m) => !m.unpriced);
  const hiddenCount = full.length - menu.length;

  const byCat = {};
  menu.forEach((m) => {
    if (!byCat[m.category]) byCat[m.category] = [];
    byCat[m.category].push(m);
  });
  // The config's own categories first, in a sensible eating order, then anything a server
  // invented that this list does not know about - dropped categories would be dropped food.
  const cats = ZUBER_CATS.filter((k) => byCat[k])
    .concat(Object.keys(byCat).filter((k) => ZUBER_CATS.indexOf(k) === -1));

  const line = (m) => {
    const row = UI.row({
      icon: 'zuber', tint: m.enabled === false ? '#8E8E93' : (c.tint || '#111'),
      title: m.label,
      // Sold out is still worth showing: the dish exists, it has a price, and it will be back.
      subtitle: m.enabled === false ? L('ph.zuber_soldout')
        : (m.promo ? L('ph.zuber_promo').replace('{n}', String(m.promo)) : ''),
      // The old price struck through beside the new one, which is what a promotion looks like.
      value: m.enabled === false ? '' : money(m.price),
      mono: true,
      chevron: m.enabled !== false,
      data: m.enabled === false ? {} : { zi: m.item },
    });
    if (!m.image) return row;
    // The item's own picture replaces the glyph tile. Swapped into the rendered row rather than
    // adding an option to `UI.row`, because a picture is this app's idea and not the kit's.
    return row.replace('<span class="ricon"',
      '<span class="ricon zupic" style="background-image:url(&quot;' +
      esc(zuberImage(m.image)) + '&quot;)"');
  };

  const count = zuberCartCount();
  body(
    UI.hero({
      appicon: 'zuber',
      eyebrow: c.open ? L('ph.zuber_open') : L('ph.zuber_shut'),
      title: c.label,
      subtitle: [
        c.eta ? (c.eta + ' min') : null,
        c.delivery ? L('ph.zuber_delivery') : null,
        c.takeaway ? L('ph.zuber_takeaway') : null,
      ].filter(Boolean).join('  ·  '),
    }) +
    (c.x && c.y ? UI.button(L('ph.zuber_route'), 'zuroute', 'plain') : '') +
    // In doc-restaurant mode the reviews are always reachable, even at nought votes: "nobody has
    // said anything yet" is an answer, and hiding the button made a new restaurant look broken.
    ((zuberData && zuberData.doc) ? UI.button(L('ph.zuber_reviews'), 'zurev', 'plain') : '') +
    // Rating is offered only when doc-restaurant says this player has earned it - it unlocks
    // after a delivered order. `mine` is what they already said, so the button says so.
    (zuberCanRate(d, c)
      ? UI.button(L(zuberMyRating(d, c) ? 'ph.zuber_rate_again' : 'ph.zuber_rate'),
                  'zuratebtn', 'plain')
      : '') +
    (menu.length
      ? cats.map((cat) =>
          UI.group(byCat[cat].map(line), { header: L('ph.zuber_cat_' + cat) })).join('')
      // Every dish withheld means a restaurant that is open and has nothing priced. Saying so
      // beats an empty screen, which reads as the app having failed to load the menu.
      : UI.empty(L(hiddenCount ? 'ph.zuber_all_unpriced' : 'ph.zuber_no_menu'), 'zuber')) +
    (hiddenCount && menu.length
      ? '<div class="groupfoot">' +
          esc(L('ph.zuber_unpriced_hidden').replace('{n}', String(hiddenCount))) + '</div>'
      : '') +
    (count
      ? '<div class="zubasket" id="zubasket">' +
          '<b>' + esc(L('ph.zuber_basket').replace('{n}', String(count))) + '</b>' +
          '<span>' + esc(money(zuberCartTotal())) + '</span></div>'
      : '<div class="groupfoot">' + esc(L('ph.zuber_basket_empty')) + '</div>')
  );

  if (byId('zuroute')) byId('zuroute').addEventListener('click', async () => {
    // doc-restaurant sends the coordinates with its payload; the config provider keeps them on
    // the server and answers with them. Either way the waypoint is set on the client.
    const r = (zuberData && zuberData.doc)
      ? await post('zuberRoute', { x: c.x, y: c.y })
      : await post('zuberLocate', { restaurant: c.id });
    if (r && r.ok) { ui('waypoint'); toast(L('ph.zuber_routed').replace('{n}', c.label)); }
    else toast(L('ph.err_x'));
  });

  if (byId('zurev')) byId('zurev').addEventListener('click', () => zuberReviews(c));
  if (byId('zuratebtn')) byId('zuratebtn').addEventListener('click', () =>
    zuberRate(c, zuberMyRating(d, c)));

  // Adding a dish updates the BASKET BAR and nothing else.
  //
  // It used to call `zuberMenu` again, which rebuilds the hero, every category, every row and
  // every listener - so a tap read as the whole page flashing, and the scroll position jumped
  // back to the top on the second dish. The only thing a tap changes is the count and the total,
  // so that is the only thing that is redrawn.
  const paintBasket = () => {
    const host = byId('zubasket');
    const count = zuberCartCount();
    if (!host) {
      // The bar is not on screen yet - this is the first dish - so the view does need building
      // once. Every tap after this one lands on the branch above.
      if (count) zuberMenu(d, c);
      return;
    }
    if (!count) { zuberMenu(d, c); return; }   // the last one was removed
    host.innerHTML = '<b>' + esc(L('ph.zuber_basket').replace('{n}', String(count))) + '</b>' +
      '<span>' + esc(money(zuberCartTotal())) + '</span>';
  };

  rows('[data-zi]', (el) => el.addEventListener('click', () => {
    const m = (c.menu || []).find((x) => x.item === el.dataset.zi);
    if (!m || m.enabled === false) return;
    if (!c.open) { toast(L('ph.zuber_e_closed')); return; }
    const entry = zuberCart[m.item] || { label: m.label, price: m.price, qty: 0 };
    entry.qty += 1;
    zuberCart[m.item] = entry;
    ui('sent');
    // A short pulse on the row that was tapped, so the tap is acknowledged where it happened
    // rather than only at the bottom of the screen.
    el.classList.add('zuadded');
    setTimeout(() => el.classList.remove('zuadded'), 260);
    paintBasket();
  }));

  if (byId('zubasket')) byId('zubasket').addEventListener('click', () => zuberCheckout(d, c));
}

/// The basket, the tip and the order. Every number here is recomputed on the server before a
/// penny moves - this only shows what it will be.
function zuberCheckout(d, c) {
  const items = Object.keys(zuberCart);
  if (!items.length) return;

  const food = zuberCartTotal();
  // What the tier takes off the food. Shown here and recomputed on doc-restaurant's side, which
  // is the authority - this is a preview of its arithmetic, never a substitute for it.
  const loyaltyOff = (chosen && points >= chosen.points)
    ? Math.floor(food * chosen.discount / 100) : 0;
  // The fee and the tax belong to the CONFIG provider, where this app does the charging itself.
  // In doc-restaurant mode both are zero, because it charges neither.
  const ours = zuberChargesUs(d);
  const fee = (ours && zuberKind === 'delivery') ? (Number(d.fee) || 0) : 0;
  // The config provider ADDS its tax on top of the food, because it is the one charging.
  const tax = ours ? Math.floor(food * (Number(d.tax) || 0) / 100) : 0;
  const total = Math.max(0, food - loyaltyOff) + fee + tax;

  // **doc-restaurant's tax is already INSIDE the price**, so it is shown as a breakdown of the
  // total rather than added to it. Its own formula, exactly: HT = TTC / (1 + rate), and the tax
  // is what is left over - the restaurant is paid the HT and the government the difference.
  //
  // Adding it instead would repeat the mistake this whole screen was just fixed for: a total the
  // player is never charged. The rate comes from `Config.Zuber.docTaxRate`, which has to match
  // doc-restaurant's own `Config.TaxRate` - its config is in its own resource and cannot be read
  // from here.
  const docRate = ours ? 0 : Math.max(0, Number(d.docTaxRate) || 0);
  const ttc = Math.max(0, food - loyaltyOff);
  const includedTax = docRate > 0 ? (ttc - Math.floor(ttc / (1 + docRate / 100))) : 0;

  // ── the loyalty card ──
  // Only when the restaurant runs a scheme AND this customer holds an active card: an empty
  // loyalty block on every order would be furniture.
  const card = c.loyalty;
  const lcfg = c.loyaltyConfig;
  const loyaltyOn = on('loyalty') && !!(card && lcfg)
    && (card.has_fidelity === true || card.has_fidelity === 1)
    && String(card.fidelity_status || 'active') === 'active';
  const points = loyaltyOn ? (Number(card.points) || 0) : 0;

  // Every tier the restaurant switched on, with what it costs in points and what it gives back.
  // A tier the customer cannot afford is shown and locked rather than hidden - knowing the next
  // one is forty points away is the whole reason to collect them.
  const tiers = [];
  if (loyaltyOn) {
    for (let n = 1; n <= 5; n += 1) {
      const enabled = lcfg['tier_' + n + '_enabled'];
      if (enabled === 1 || enabled === true) {
        tiers.push({
          n,
          points: Number(lcfg['tier_' + n + '_points']) || 0,
          discount: Number(lcfg['tier_' + n + '_discount']) || 0,
        });
      }
    }
  }
  const chosen = tiers.find((x) => x.n === zuberTier) || null;
  if (zuberTier && !chosen) zuberTier = 0;        // a tier that stopped being offered

  const rows_ = items.map((key) => {
    const e = zuberCart[key];
    return UI.row({
      icon: 'zuber', tint: c.tint || '#111',
      title: e.label,
      subtitle: '× ' + e.qty,
      value: money(e.price * e.qty), mono: true,
      data: { zdel: key },
    });
  });

  sheet(L('ph.zuber_checkout'),
    UI.group(rows_, { header: L('ph.zuber_basket_head'), footer: L('ph.zuber_tap_remove') }) +
    // Delivery or collection. A restaurant that only does one gets no choice to make.
    ((c.delivery && c.takeaway)
      ? '<div class="seg" id="zukind">' +
          '<button class="' + (zuberKind === 'delivery' ? 'on' : '') + '" data-k="delivery">' +
            esc(L('ph.zuber_delivery')) + '</button>' +
          '<button class="' + (zuberKind === 'takeaway' ? 'on' : '') + '" data-k="takeaway">' +
            esc(L('ph.zuber_takeaway')) + '</button>' +
        '</div>'
      : '') +
    // The loyalty card: what is on it, and what it can buy off this order.
    (loyaltyOn
      ? '<div class="grouphead">' + esc(L('ph.zuber_loyalty')) + '</div>' +
        '<div class="zuloyal">' +
          '<b>' + esc(L('ph.zuber_points').replace('{n}', String(points))) + '</b>' +
          (Number(card.points_lifetime) > 0
            ? '<span>' + esc(L('ph.zuber_points_life')
                .replace('{n}', String(Math.floor(Number(card.points_lifetime))))) + '</span>'
            : '') +
        '</div>' +
        (tiers.length
          ? '<div class="seg scroll" id="zutier">' +
              '<button class="' + (zuberTier === 0 ? 'on' : '') + '" data-tier="0">' +
                esc(L('ph.zuber_tier_none')) + '</button>' +
              tiers.map((x) => {
                const can = points >= x.points;
                return '<button class="' + (zuberTier === x.n ? 'on' : '') +
                  (can ? '' : ' off') + '" data-tier="' + (can ? x.n : '') + '">' +
                  '-' + x.discount + '% · ' + x.points + ' pts</button>';
              }).join('') +
            '</div>'
          : '<div class="groupfoot">' + esc(L('ph.zuber_no_tiers')) + '</div>')
      : '') +
    UI.field('zunote', L('ph.zuber_note'), zuberNote, 'maxlength="200"') +
    UI.group([
      UI.row({ icon: 'zuber', title: L('ph.zuber_food'), value: money(food), mono: true }),
      fee ? UI.row({ icon: 'garage', title: L('ph.zuber_fee'), value: money(fee), mono: true }) : '',
      loyaltyOff ? UI.row({ icon: 'star', title: L('ph.zuber_loyalty_off')
                              .replace('{n}', String(chosen.discount)),
                            value: '-' + money(loyaltyOff), mono: true, tone: 'pos' }) : '',
      tax ? UI.row({ icon: 'bank', title: L('ph.zuber_tax'), value: money(tax), mono: true }) : '',
      // Included, not added - the label says so, and the value carries no plus sign.
      includedTax ? UI.row({ icon: 'bank',
                             title: L('ph.zuber_tax_incl').replace('{n}', String(docRate)),
                             value: money(includedTax), mono: true }) : '',
      UI.row({ icon: 'wallet', title: L('ph.zuber_total'), value: money(total), mono: true }),
    ].filter(Boolean)) +
    // In doc-restaurant mode the restaurant is the authority on the price. The total shown is
    // the sum of its own line prices, which is what it will charge - and the footnote says so,
    // because a customer who is told nothing assumes the app decided.
    '<div class="groupfoot">' + esc(L(ours ? 'ph.zuber_total_hint'
                                           : 'ph.zuber_total_resto')) + '</div>' +
    UI.button(L('ph.zuber_order').replace('{n}', money(total)), 'zugo', 'tinted'),
    () => {
      const epoch = sheetEpoch;
      const kind = byId('zukind');
      if (kind) [...kind.querySelectorAll('button')].forEach((b) =>
        b.addEventListener('click', () => {
          zuberKind = b.dataset.k;
          if (!closeSheet(false, epoch)) return;
          zuberCheckout(d, c);
        }));
      const tierSeg = byId('zutier');
      if (tierSeg) [...tierSeg.querySelectorAll('button')].forEach((b) =>
        b.addEventListener('click', () => {
          // A locked tier carries no value, so it cannot be chosen by tapping it.
          if (b.dataset.tier === '') { toast(L('ph.zuber_tier_locked')); return; }
          zuberTier = Number(b.dataset.tier) || 0;
          zuberNote = byId('zunote') ? byId('zunote').value : zuberNote;
          if (!closeSheet(false, epoch)) return;
          zuberCheckout(d, c);
        }));

      [...byId('sheet').querySelectorAll('[data-zdel]')].forEach((row) =>
        row.addEventListener('click', () => {
          const key = row.dataset.zdel;
          if (!zuberCart[key]) return;
          zuberCart[key].qty -= 1;
          if (zuberCart[key].qty <= 0) delete zuberCart[key];
          zuberNote = byId('zunote') ? byId('zunote').value : zuberNote;
          if (!closeSheet(false, epoch)) return;
          if (zuberCartCount()) zuberCheckout(d, c); else zuberMenu(d, c);
        }));

      byId('zugo').addEventListener('click', async () => {
        const go = byId('zugo');
        if (go.disabled) return;         // double-tapping order must not order twice
        go.disabled = true;
        zuberNote = byId('zunote') ? byId('zunote').value.trim() : '';

        const basket = items.map((key) => ({
          item: key, qty: zuberCart[key].qty,
          // Sent because doc-restaurant's own order shape carries them. Both servers price the
          // line themselves; nothing here is trusted.
          label: zuberCart[key].label, price: zuberCart[key].price,
        }));

        const r = (zuberData && zuberData.doc)
          // **doc-restaurant's own field names.** It reads `job`, `items` and `orderComment`,
          // and it overwrites `citizenid`, `customerName` and `customerPhone` with the real
          // player itself - deliberately, so a client cannot order as somebody else. Sending
          // them would be sending values it throws away. `type` is passed for a build that
          // wants it and ignored by this one.
          ? await post('zuberDoc', { op: 'order', order: {
              job: c.job || c.id,
              items: basket,
              orderComment: zuberNote,
              type: zuberKind,
              // **The loyalty tier.** Its `submitOrder` reads `fidelityTierApplied`, checks the
              // tier is enabled and that the customer really has the points, then consumes them
              // and applies the discount itself. Zuber never sent it, so the whole scheme was
              // unusable from this app - the points were shown by its own tablet and could not
              // be spent from the phone.
              fidelityTierApplied: zuberTier,
            } })
          : await post('zuberOrder', { restaurant: c.id, kind: zuberKind, items: basket,
                                       note: zuberNote });

        if (!r || (!r.ok && !r.success)) {
          go.disabled = false;
          toast(L('ph.zuber_e_' + ((r && r.error) || 'x')));
          return;
        }
        if (!closeSheet(false, epoch)) return;
        ui('money');
        toast(L('ph.zuber_sent'));
        zuberCart = {};
        zuberTier = 0;
        zuberOpenId = null;
        zuberTab = 'orders';
        RENDER.zuber();
      });
    });
}

/// Past orders, and the one tap that repeats one.
function zuberOrders(d) {
  setNav(L('ph.zuber_tab_orders'), null, null);
  const list = d.history || [];
  const active = d.active || null;
  const cards = zuberCards(d);

  const itemsOf = (o) => {
    try {
      const parsed = typeof o.items === 'string' ? JSON.parse(o.items) : (o.items || []);
      return Array.isArray(parsed) ? parsed : [];
    } catch { return []; }
  };

  const row = (o) => {
    const items = itemsOf(o);
    const n = items.reduce((a, i) => a + (Number(i.qty) || 0), 0);
    return UI.row({
      icon: 'zuber',
      tint: zuberStep(o.status) >= 5 ? '#8E8E93' : '#111',
      title: o.label || o.restaurant || '',
      subtitle: [L('ph.zuber_st_' + String(o.status || 'pending')),
                 n ? (n + ' × ') : '', shortWhen((Number(o.ts) || 0) * 1000)]
        .filter(Boolean).join('  '),
      value: money(Number(o.total) || 0), mono: true,
      chevron: true, data: { zo: String(o.id) },
    });
  };

  body(
    (active
      ? (() => {
          const step = zuberStep(active.status);
          return '<div class="zutrack big">' +
            '<div class="zutrackrow"><b>' + esc(L('ph.zuber_st_' + String(active.status || 'pending'))) +
              '</b><span>' + esc(active.label || active.restaurant || '') + '</span></div>' +
            '<div class="zubar"><i style="width:' + Math.round((step / 5) * 100) + '%"></i></div>' +
            '<div class="zusteps">' +
              ['accepted', 'preparing', 'delivering', 'completed'].map((s, i) =>
                '<span class="' + (step > i ? 'on' : '') + '">' +
                esc(L('ph.zuber_st_' + s)) + '</span>').join('') +
            '</div></div>';
        })()
      : '') +
    (list.length
      ? UI.group(list.map(row), { header: L('ph.zuber_history'),
          footer: L(d.historyFromDoc ? 'ph.zuber_history_doc' : 'ph.zuber_history_hint') })
      : UI.empty(L('ph.zuber_nohistory'), 'note'))
  );

  rows('[data-zo]', (el) => el.addEventListener('click', () => {
    const o = list.find((x) => String(x.id) === el.dataset.zo);
    if (!o) return;
    const items = itemsOf(o);
    const c = cards.find((x) => x.id === (o.restaurant || o.job));

    sheet(o.label || o.restaurant || '',
      UI.group(items.map((i) => UI.row({
        icon: 'zuber', title: i.label || i.item, subtitle: '× ' + (i.qty || 1),
        value: money((Number(i.price) || 0) * (Number(i.qty) || 1)), mono: true,
      })).concat([
        UI.row({ icon: 'wallet', title: L('ph.zuber_total'),
                 value: money(Number(o.total) || 0), mono: true }),
        UI.row({ icon: 'check', title: L('ph.zuber_st_' + String(o.status || 'pending')) }),
      ])) +
      (o.note ? '<div class="groupfoot">' + esc(o.note) + '</div>' : '') +
      // Only when the restaurant is still there and still open: a button that cannot work is
      // worse than no button.
      (c && c.open && items.length
        ? UI.button(L('ph.zuber_again'), 'zuagain', 'tinted') : '') +
      (zuberCanRate(zuberData, c)
        ? UI.button(L(zuberMyRating(zuberData, c) ? 'ph.zuber_rate_again' : 'ph.zuber_rate'),
                    'zurate', 'plain') : ''),
      () => {
        const epoch = sheetEpoch;
        if (byId('zuagain')) byId('zuagain').addEventListener('click', () => {
          // The basket is rebuilt from the CURRENT menu, not from the old prices: a dish that
          // went up has gone up, and re-ordering at last week's price would be a bug that
          // looks like a feature.
          zuberCart = {};
          items.forEach((i) => {
            const m = (c.menu || []).find((x) => x.item === i.item);
            if (m && m.enabled !== false) {
              zuberCart[m.item] = { label: m.label, price: m.price, qty: Number(i.qty) || 1 };
            }
          });
          if (!closeSheet(false, epoch)) return;
          if (!zuberCartCount()) { toast(L('ph.zuber_again_gone')); return; }
          zuberTab = 'browse';
          zuberOpenId = c.id;
          RENDER.zuber();
        });
        if (byId('zurate')) byId('zurate').addEventListener('click', () => {
          if (!closeSheet(false, epoch)) return;
          zuberRate(c || { id: o.restaurant, job: o.restaurant, label: o.label },
                    zuberMyRating(zuberData, c));
        });
      });
  }));
}

/// May this player rate this restaurant? doc-restaurant's answer, never a guess.
///
/// Its `eligible` arrives as either a map keyed by job or a list of them, depending on the
/// build, so both are read - a shape that changed would otherwise silently hide the button.
function zuberCanRate(d, c) {
  if (!d || !d.doc || !c) return false;
  const e = d.canRate;
  if (!e) return false;
  const key = c.job || c.id;
  if (Array.isArray(e)) return e.indexOf(key) !== -1;
  return e[key] === true || e[key] === 1 || (e[key] !== undefined && e[key] !== false);
}

/// What this player already said about it, if anything.
function zuberMyRating(d, c) {
  if (!d || !d.myRatings || !c) return null;
  const mine = d.myRatings[c.job || c.id];
  if (!mine) return null;
  // `getMyRatings` answers `mine[job] = { etoiles, commentaire }`. Normalised to one shape here
  // so the sheet and the button do not each have to know doc-restaurant's spelling.
  if (typeof mine !== 'object') return { note: Number(mine) || 0 };
  return {
    note: Number(mine.etoiles !== undefined ? mine.etoiles : (mine.note || mine.stars)) || 0,
    comment: mine.commentaire !== undefined ? mine.commentaire : (mine.comment || ''),
  };
}

/// Rating a restaurant. doc-restaurant owns the stars and decides whether this player has
/// earned the right to leave one, so this only asks.
function zuberRate(c, existing) {
  let stars = Math.max(1, Math.min(5, Number(existing && (existing.note || existing.stars)) || 5));
  const draw = () => [1, 2, 3, 4, 5].map((n) =>
    '<button class="zustar' + (n <= stars ? ' on' : '') + '" data-s="' + n + '" type="button">' +
    svg('star') + '</button>').join('');

  sheet(L('ph.zuber_rate') + ' - ' + (c.label || ''),
    '<div class="zustars" id="zustars">' + draw() + '</div>' +
    UI.field('zucomment', L('ph.zuber_comment'),
             (existing && existing.comment) || '', 'maxlength="200"') +
    UI.button(L('ph.zuber_rate_send'), 'zuratego', 'tinted'),
    () => {
      const epoch = sheetEpoch;
      const wire = () => [...byId('zustars').querySelectorAll('[data-s]')].forEach((b) =>
        b.addEventListener('click', () => {
          stars = Number(b.dataset.s) || 5;
          byId('zustars').innerHTML = draw();
          wire();
        }));
      wire();
      byId('zuratego').addEventListener('click', async () => {
        // doc-restaurant's `rateRestaurant` reads `data.etoiles` and `data.commentaire`.
        // The English names it does not read were silently rating everything at nought.
        const r = await post('zuberDoc', { op: 'rate', rating: {
          job: c.job || c.id,
          etoiles: stars,
          commentaire: byId('zucomment') ? byId('zucomment').value.trim() : '',
        } });
        if (!r || r.error) { toast(L('ph.zuber_e_' + ((r && r.error) || 'x'))); return; }
        if (!closeSheet(false, epoch)) return;
        ui('success');
        toast(L('ph.zuber_rated'));
        RENDER.zuber();
      });
    });
}

/// What other customers said. doc-restaurant only.
async function zuberReviews(c) {
  const r = await post('zuberDoc', { op: 'reviews', job: c.job || c.id });
  const list = (r && r.reviews) || [];
  sheet(L('ph.zuber_reviews'),
    list.length
      // doc-restaurant returns { etoiles, commentaire, author, updated_at }. The English
      // names are kept as fallbacks so a fork that renamed them still renders.
      //
      // A row is ONE line and ellipsises, which is right for a list and wrong for the only place
      // a review can be read: half a sentence is not an opinion. So each row opens the review in
      // full - see `zuberReview` below.
      ? UI.group(list.map((rev, i) => UI.row({
          avatar: rev.author || rev.name || '?',
          title: (rev.author || rev.name || L('ph.zuber_anon')),
          subtitle: rev.commentaire || rev.comment || '',
          value: '★ ' + (Number(rev.etoiles !== undefined ? rev.etoiles
                                : (rev.note || rev.stars)) || 0),
          chevron: true, data: { zrev: String(i) },
        })), { footer: L('ph.zuber_review_hint') })
      : UI.empty(L('ph.zuber_noreviews'), 'star'),
    () => {
      const epoch = sheetEpoch;
      [...byId('sheet').querySelectorAll('[data-zrev]')].forEach((row) =>
        row.addEventListener('click', () => {
          const rev = list[Number(row.dataset.zrev)];
          if (!rev) return;
          if (!closeSheet(false, epoch)) return;
          zuberReview(c, rev, list);
        }));
    });
}

/// One review, in full.
///
/// The list can only afford a line each; this is where the whole thing is readable, with the
/// stars drawn rather than counted and the date if the server sent one. `back` returns to the
/// list, because reading one review is almost never the end of it.
function zuberReview(c, rev, list) {
  const stars = Number(rev.etoiles !== undefined ? rev.etoiles : (rev.note || rev.stars)) || 0;
  const text = rev.commentaire || rev.comment || '';
  const when = rev.updated_at || rev.at || rev.date;

  sheet(rev.author || rev.name || L('ph.zuber_anon'),
    '<div class="zurevhead">' +
      '<div class="zurevstars">' + [1, 2, 3, 4, 5].map((n) =>
        '<i class="' + (n <= stars ? 'on' : '') + '">' + svg('star') + '</i>').join('') + '</div>' +
      (when ? '<span>' + esc(shortWhen(txEpochMs(when) || when)) + '</span>' : '') +
    '</div>' +
    // The comment itself, wrapping and selectable, in the same block the phone reads mail in.
    (text
      ? '<div class="mailbody zurevbody">' + esc(text) + '</div>'
      : '<div class="groupfoot">' + esc(L('ph.zuber_review_nocomment')) + '</div>') +
    (list && list.length > 1 ? UI.button(L('ph.zuber_reviews'), 'zurevback', 'plain') : ''),
    () => {
      const epoch = sheetEpoch;
      if (byId('zurevback')) byId('zurevback').addEventListener('click', () => {
        if (!closeSheet(false, epoch)) return;
        zuberReviews(c);
      });
    });
}

RENDER.charging = async () => {
  loading();
  const d = await post('chargingApp', {});
  if (!d || d.error) {
    body(UI.empty(L('ph.charge_e_' + ((d && d.error) || 'off')), 'charging'));
    return;
  }

  const chargers = d.chargers || [];
  const prefs = d.prefs || {};
  const priceText = (n) => (Number(n) > 0 ? money(n) : L('ph.charge_free'));
  const labelOf = (id) => (chargers.find((c) => c.id === id) || {}).label || '';

  const atPaid = d.atCharger && Number(d.atCharger.price) > 0;
  const paying = d.session && (!d.atCharger || d.session === d.atCharger.id);

  const header = d.session
    ? UI.hero({ appicon: 'charging', eyebrow: L('ph.charge_status'),
                value: L('ph.charge_active'), subtitle: labelOf(d.session) || (d.atCharger || {}).label || '' })
    : (atPaid
      ? UI.hero({ appicon: 'charging', eyebrow: d.atCharger.label,
                  value: money(d.atCharger.price), subtitle: L('ph.charge_here_pay') })
      : UI.hero({ appicon: 'charging', eyebrow: L('app.charging'),
                  value: L('ph.charge_idle'), subtitle: L('ph.charge_idle_hint') }));

  const payBtn = (atPaid && !paying)
    ? UI.button(L('ph.charge_pay').replace('{price}', String(d.atCharger.price)), 'chgpay', 'tinted')
    : '';

  const list = chargers.length
    ? UI.group(chargers.map((c) => UI.row({
        icon: 'charging',
        tint: c.here ? '#30d158' : (Number(c.price) > 0 ? '#0A84FF' : '#8E8E93'),
        title: c.label,
        subtitle: [
          c.here ? L('ph.charge_youre_here') : null,
          c.distance != null ? (c.distance + ' m') : null,
          priceText(c.price),
        ].filter(Boolean).join('  '),
        chevron: true, data: { chg: c.id },
      })), { header: L('ph.charge_points'), footer: L('ph.charge_points_hint') })
    : UI.empty(L('ph.charge_none'), 'charging');

  // Auto-accept: a standing yes to a paid charger, up to a ceiling the player sets.
  const auto = d.autoAcceptOn
    ? UI.group([
        UI.row({ icon: 'timer', tint: '#5E5CE6', title: L('ph.charge_auto'),
                 subtitle: L('ph.charge_auto_hint'),
                 toggle: prefs.autoAccept === true, data: { chgauto: '1' } }),
      ].concat(prefs.autoAccept
        ? [UI.row({ icon: 'bank', tint: '#30d158', title: L('ph.charge_auto_max'),
                    value: Number(prefs.autoMax) > 0 ? money(prefs.autoMax) : L('ph.charge_auto_nomax'),
                    chevron: true, data: { chgmax: '1' } })]
        : []), { header: L('ph.charge_options') })
    : '';

  body(header + payBtn + list + auto);

  const again = () => RENDER.charging();

  if (byId('chgpay')) byId('chgpay').addEventListener('click', async () => {
    const r = await post('chargePay', {});
    if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
    ui('money');
    toast(L('ph.charge_paid'));
    again();
  });

  rows('[data-chg]', (el) => el.addEventListener('click', async () => {
    const c = chargers.find((x) => x.id === el.dataset.chg);
    if (!c) return;
    await post('chargingWaypoint', { x: c.x, y: c.y });
    ui('waypoint');
    toast(L('ph.charge_routed').replace('{n}', c.label));
  }));

  const savePrefs = async (next) => {
    const r = await post('chargingPrefs', {
      autoAccept: next.autoAccept, autoMax: next.autoMax,
    });
    if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
    again();
  };

  const autoRow = document.querySelector('[data-chgauto]');
  if (autoRow) autoRow.addEventListener('click', () =>
    savePrefs({ autoAccept: !(prefs.autoAccept === true), autoMax: prefs.autoMax || 0 }));

  const maxRow = document.querySelector('[data-chgmax]');
  if (maxRow) maxRow.addEventListener('click', () => {
    const cap = Number(d.autoMaxCap) || 0;
    sheet(L('ph.charge_auto_max'),
      UI.field('chgmaxval', L('ph.bank_amount'), Number(prefs.autoMax) > 0 ? String(prefs.autoMax) : '',
               'type="number" inputmode="numeric" min="0"' + (cap > 0 ? ' max="' + cap + '"' : '')) +
      '<div class="groupfoot">' + esc(cap > 0
        ? L('ph.charge_auto_max_hint').replace('{n}', String(cap))
        : L('ph.charge_auto_max_hint_free')) + '</div>' +
      UI.button(L('ph.confirm'), 'chgmaxgo', 'tinted'),
      () => {
        const epoch = sheetEpoch;
        byId('chgmaxgo').addEventListener('click', async () => {
          const v = Math.max(0, Math.floor(Number(byId('chgmaxval').value) || 0));
          if (!closeSheet(false, epoch)) return;
          savePrefs({ autoAccept: true, autoMax: v });
        });
      });
  });
};

function airdropOffer(o) {
  o = o || {};
  const icon = o.kind === 'photo' ? 'images'
    : o.kind === 'track' ? 'music'
    : o.kind === 'health' ? 'heart'
    : o.kind === 'email' ? 'mail'
    : 'contacts';
  const preview = o.kind === 'photo'
    ? '<img class="shotbig" src="' + esc(o.preview || '') + '" />'
    : '<div class="airbig">' + svg(icon) + '<span>' + esc(o.preview || '') + '</span></div>';
  sheet(L('ph.airdrop_incoming'),
    preview +
    '<div class="airfrom">' + esc(L('ph.airdrop_from')) + ' <b>' + esc(o.from || '') + '</b></div>' +
    UI.button(L('ph.airdrop_accept'), 'airok', 'tinted') +
    UI.button(L('ph.airdrop_decline'), 'airno', 'plain'),
    () => {
      byId('airok').addEventListener('click', async () => {
        closeSheet();
        const r = await post('airdropRespond', { offerId: o.offerId, accept: true });
        if (!r || !r.ok) { toast(L('ph.airdrop_' + ((r && r.error) || 'x'))); return; }
        // A record is not filed anywhere: it belongs to the person it describes, and writing
        // it into the reader's own would overwrite theirs. It is handed over to be READ.
        if (r.health) {
          healthRecordSheet(r.health.name || o.from || '', r.health);
          return;
        }
        // A track is filed here rather than on the server: the library lives in this phone's
        // app storage, and the page is what knows its layout.
        if (r.track && r.track.url) {
          const library = await musicLibrary();
          if (!library.some((row) => row.url === r.track.url)) {
            library.unshift(musicNormalise(r.track));
            await musicSaveLibrary(library);
          }
          toast(L('ph.airdrop_track_saved'));
          if (openApp && openApp.id === 'music') RENDER.music(true);
          return;
        }
        await refresh();
        toast(L('ph.airdrop_saved'));
      });
      byId('airno').addEventListener('click', async () => {
        closeSheet();
        await post('airdropRespond', { offerId: o.offerId, accept: false });
      });
    });
}


// ══ Verification codes ═════════════════════════════════════════
// A code you have to read off one screen and type into another is the small daily annoyance
// iOS solved years ago, so the phone does the same two things: offers to copy it from the
// message, and offers to fill it where it is asked for.
//
// The detector is deliberately narrow. It wants a run of 4 to 8 digits AND a word nearby
// that says what it is, in either shipped language, so an ordinary text containing a house
// number or a price does not sprout a "copy code" button.
const CODE_WORDS = /(code|verification|verif|vérification)/i;

function codeInText(body) {
  const text = String(body || '');
  if (!CODE_WORDS.test(text)) return null;
  const m = text.match(/(?:^|[^0-9])([0-9]{4,8})(?:[^0-9]|$)/);
  return m ? m[1] : null;
}

// The newest code the phone has been sent, for the fill button on a code field. Reads the
// conversation list, which already holds each thread's last message, so this needs no extra
// server call - and it is ordered newest first by the server.
function latestCode() {
  for (const c of (state.conversations || [])) {
    const code = codeInText(c.body);
    if (code) return code;
  }
  return null;
}

// A one-tap chip that puts the code into a field. Rendered only when there is a code to
// put there, so it never sits in the way promising something it cannot do.
function codeFillChip(fieldId) {
  const code = latestCode();
  if (!code) return '';
  return '<button class="linkbtn codefill" type="button" data-fill="' + esc(code) +
    '" data-into="' + esc(fieldId) + '">' + esc(L('ph.use_code')) + ' ' + esc(code) + '</button>';
}

function wireCodeFill() {
  rows('[data-fill]', (b) => b.addEventListener('click', () => {
    const el = byId(b.dataset.into);
    if (!el) return;
    el.value = b.dataset.fill;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.focus();
  }));
}

// ══ Clipboard ══════════════════════════════════════════════════
// navigator.clipboard needs a secure context, and cfx-nui:// is not one, so this is the
// textarea trick. It is the only thing that works in CEF, and a number you cannot copy
// is a number you have to read out loud.
function copyText(text, said) {
  ui('copy');
  // The page is served from https://cfx-nui-<resource>/, which CEF treats as a secure
  // context, so the real clipboard API is available. The textarea trick stays as the
  // fallback: it is the only thing that works when it is not.
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text)
      .then(() => toast(said || L('ph.copied')))
      .catch(() => legacyCopy(text, said));
    return true;
  }
  return legacyCopy(text, said);
}

function legacyCopy(text, said) {
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.setAttribute('readonly', '');
  ta.style.cssText = 'position:absolute;left:-9999px;opacity:0';
  document.body.appendChild(ta);
  ta.select();
  ta.setSelectionRange(0, ta.value.length);
  let ok = false;
  try { ok = document.execCommand('copy'); } catch { ok = false; }
  document.body.removeChild(ta);
  toast(ok ? (said || L('ph.copied')) : L('ph.copy_failed'));
  return ok;
}

// ══ Search field ═══════════════════════════════════════════════
function searchHtml(placeholder) {
  return '<div class="search">' + svg('search') +
    '<input id="q" placeholder="' + esc(placeholder) + '" autocomplete="off" /></div>';
}

function onSearch(fn) {
  const q = byId('q');
  if (!q) return;
  q.addEventListener('input', () => fn(q.value.trim().toLowerCase()));
}

// ══ Tab bar ════════════════════════════════════════════════════
function tabbar(tabs, current, onPick) {
  foot('<div class="tabbar">' + tabs.map((t) => {
    // A count on the icon, the way Messages carries unread. Drawn only when there is one:
    // `badge: 0` is a tab with nothing waiting, not a tab wearing a zero.
    const n = Number(t.badge) || 0;
    return '<button class="' + (t.id === current ? 'on' : '') + '" data-t="' + esc(t.id) +
      '" type="button" aria-current="' + (t.id === current ? 'page' : 'false') + '">' +
      '<span class="tbicon">' + svg(t.icon) +
        (n ? '<i class="tbadge">' + esc(n > 99 ? '99+' : String(n)) + '</i>' : '') + '</span>' +
      '<span>' + esc(L(t.label)) + '</span></button>';
  }).join('') + '</div>');
  [...byId('appfoot').querySelectorAll('button')].forEach((b) =>
    b.addEventListener('click', () => onPick(b.dataset.t)));
}


// ══ Cipher ═════════════════════════════════════════════════════
// Cipher is different from the ordinary Messages app: the browser creates the key pair,
// stores only an encrypted private key locally and gives Lua the public half. Every body
// reaches the server as an AES-GCM envelope, so notification previews intentionally say
// only that a packet arrived.
const CIPHER_TEXT = new TextEncoder();
const CIPHER_VAULT_VERSION = 1;

const cipherActive = () => !!openApp && openApp.id === 'cipher';
const cipherVaultName = () => 'vphone:cipher:v1:' + String(state.number || 'unknown');

function cipherToB64(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = '';
  bytes.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary);
}

function cipherFromB64(value) {
  const binary = atob(String(value || ''));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function cipherVaultRead() {
  try {
    const value = localStorage.getItem(cipherVaultName());
    return value ? JSON.parse(value) : null;
  } catch {
    return null;
  }
}

function cipherVaultWrite(value) {
  try {
    localStorage.setItem(cipherVaultName(), JSON.stringify(value));
    return true;
  } catch {
    return false;
  }
}

function cipherVaultRemove() {
  try { localStorage.removeItem(cipherVaultName()); } catch { /* local vault unavailable */ }
}

async function cipherPinKey(pin, salt) {
  const base = await crypto.subtle.importKey(
    'raw', CIPHER_TEXT.encode(String(pin)), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey({
    name: 'PBKDF2',
    salt,
    iterations: 180000,
    hash: 'SHA-256',
  }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

async function cipherNewKeys(pin, handle) {
  if (!globalThis.crypto || !globalThis.crypto.subtle) throw new Error('unsupported');
  const pair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const publicJwk = await crypto.subtle.exportKey('jwk', pair.publicKey);
  const privateJwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
  const publicKey = JSON.stringify(publicJwk);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', CIPHER_TEXT.encode(publicKey)));
  const fingerprint = Array.from(
    digest.slice(0, 16),
    (byte) => byte.toString(16).padStart(2, '0').toUpperCase()
  ).join(':');
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const wrappingKey = await cipherPinKey(pin, salt);
  const wrapped = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, wrappingKey, CIPHER_TEXT.encode(JSON.stringify(privateJwk)));
  return {
    privateKey: pair.privateKey,
    publicKey,
    fingerprint,
    vault: {
      v: CIPHER_VAULT_VERSION,
      handle,
      salt: cipherToB64(salt),
      iv: cipherToB64(iv),
      data: cipherToB64(wrapped),
    },
  };
}

async function cipherOpenVault(pin, expectedHandle) {
  const vault = cipherVaultRead();
  if (!vault || Number(vault.v) !== CIPHER_VAULT_VERSION) throw new Error('nokey');
  if (expectedHandle && vault.handle !== expectedHandle) throw new Error('wrongkey');
  const key = await cipherPinKey(pin, cipherFromB64(vault.salt));
  const clear = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: cipherFromB64(vault.iv) }, key, cipherFromB64(vault.data));
  const jwk = JSON.parse(new TextDecoder().decode(clear));
  return crypto.subtle.importKey(
    'jwk', jwk, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
}

async function cipherConversationKey(peer) {
  const publicJwk = JSON.parse(peer.publicKey);
  const publicKey = await crypto.subtle.importKey(
    'jwk', publicJwk, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: publicKey }, cipherPrivateKey, 256);
  const material = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey']);
  const fingerprints = [cipherProfile.fingerprint, peer.fingerprint].sort().join('|');
  return crypto.subtle.deriveKey({
    name: 'HKDF',
    hash: 'SHA-256',
    salt: CIPHER_TEXT.encode('iFruit Cipher v1'),
    info: CIPHER_TEXT.encode(fingerprints),
  }, material, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

async function cipherEncrypt(peer, text) {
  if (cipherDemo) return JSON.stringify({ v: 1, iv: 'demo', data: 'demo', plain: text });
  const key = await cipherConversationKey(peer);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const payload = JSON.stringify({ text, sentAt: Date.now() });
  const data = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv }, key, CIPHER_TEXT.encode(payload));
  return JSON.stringify({ v: 1, iv: cipherToB64(iv), data: cipherToB64(data) });
}

async function cipherDecrypt(peer, envelope) {
  try {
    const packed = typeof envelope === 'string' ? JSON.parse(envelope) : envelope;
    if (cipherDemo && typeof packed.plain === 'string') return packed.plain;
    if (!packed || Number(packed.v) !== 1) throw new Error('version');
    const key = await cipherConversationKey(peer);
    const clear = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: cipherFromB64(packed.iv) }, key, cipherFromB64(packed.data));
    const payload = JSON.parse(new TextDecoder().decode(clear));
    return String(payload.text || '');
  } catch {
    return L('ph.cipher_unreadable');
  }
}

function cipherError(result) {
  const code = String((result && result.error) || 'x');
  const specific = L('ph.cipher_err_' + code);
  return specific !== 'ph.cipher_err_' + code ? specific : L('ph.err_' + code);
}

function cipherTime(value) {
  const ms = whenMs(value);
  if (!Number.isFinite(ms)) return '';
  return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function cipherInitial(peer) {
  return esc(String(peer.displayName || peer.handle || '?').trim().charAt(0).toUpperCase());
}

function cipherBurnLabel(seconds) {
  if (Number(seconds) === 300) return L('ph.cipher_burn_5m');
  if (Number(seconds) === 3600) return L('ph.cipher_burn_1h');
  if (Number(seconds) === 86400) return L('ph.cipher_burn_1d');
  return L('ph.cipher_burn_off');
}

function cipherWelcome() {
  setNav(L('app.cipher'), null);
  foot('');
  body(
    '<section class="cipherwelcome">' +
      '<div class="ciphermark">' + UI.appIcon('cipher') + '<i></i></div>' +
      '<div class="cipherkicker">' + esc(L('ph.cipher_private_network')) + '</div>' +
      '<h1>' + esc(L('ph.cipher_welcome')) + '</h1>' +
      '<p>' + esc(L('ph.cipher_welcome_hint')) + '</p>' +
      '<div class="cipherproof"><span>' + svg('lockshut') + '</span><div><b>' +
        esc(L('ph.cipher_e2e')) + '</b><small>' + esc(L('ph.cipher_e2e_hint')) +
      '</small></div></div>' +
    '</section>' +
    '<div class="cipherform">' +
      UI.field('cipherhandle', L('ph.cipher_handle'), '', 'maxlength="20" autocapitalize="none" spellcheck="false"') +
      UI.field('ciphername', L('ph.cipher_codename'), '', 'maxlength="32"') +
      UI.field('cipherpin', L('ph.cipher_pin'), '', 'type="password" maxlength="6" inputmode="numeric" autocomplete="new-password"') +
      UI.field('cipherpin2', L('ph.cipher_pin_confirm'), '', 'type="password" maxlength="6" inputmode="numeric" autocomplete="new-password"') +
      UI.button(L('ph.cipher_create'), 'ciphercreate') +
      '<div class="cipherfine">' + esc(L('ph.cipher_pin_hint')) + '</div>' +
    '</div>'
  );
  byId('ciphercreate').addEventListener('click', async () => {
    const handle = byId('cipherhandle').value.trim().toLowerCase().replace(/^@/, '');
    const displayName = byId('ciphername').value.trim();
    const pin = byId('cipherpin').value;
    if (!/^[a-z0-9_]{3,20}$/.test(handle)) { toast(L('ph.cipher_err_handle')); return; }
    if (!displayName) { toast(L('ph.cipher_err_fields')); return; }
    if (!/^\d{6}$/.test(pin)) { toast(L('ph.cipher_err_pin')); return; }
    if (pin !== byId('cipherpin2').value) { toast(L('ph.cipher_pin_mismatch')); return; }
    const button = byId('ciphercreate');
    button.disabled = true;
    button.textContent = L('ph.cipher_generating');
    try {
      const keys = await cipherNewKeys(pin, handle);
      const result = await post('cipher', {
        op: 'create',
        handle,
        displayName,
        pin,
        publicKey: keys.publicKey,
        fingerprint: keys.fingerprint,
      });
      if (!cipherActive()) return;
      if (!result || !result.ok) {
        button.disabled = false;
        button.textContent = L('ph.cipher_create');
        toast(cipherError(result));
        return;
      }
      if (!cipherVaultWrite(keys.vault)) {
        button.disabled = false;
        button.textContent = L('ph.cipher_create');
        toast(L('ph.cipher_err_storage'));
        return;
      }
      cipherPrivateKey = keys.privateKey;
      cipherProfile = result.profile;
      cipherDemo = result.demo === true;
      toast(L('ph.cipher_identity_ready'));
      cipherMain();
    } catch {
      button.disabled = false;
      button.textContent = L('ph.cipher_create');
      toast(L('ph.cipher_err_crypto'));
    }
  });
}

function cipherLockScreen(profile) {
  setNav(L('app.cipher'), null);
  foot('');
  const storedVault = cipherVaultRead();
  const hasVault = !!storedVault && storedVault.handle === profile.handle;
  body(
    '<section class="cipherunlock">' +
      '<div class="cipherring"><span>' + svg('lockshut') + '</span><i></i></div>' +
      '<div class="cipherkicker">@' + esc(profile.handle) + '</div>' +
      '<h1>' + esc(L('ph.cipher_locked')) + '</h1>' +
      '<p>' + esc(hasVault ? L('ph.cipher_unlock_hint') : L('ph.cipher_key_missing')) + '</p>' +
    '</section>' +
    (hasVault
      ? '<div class="cipherform">' +
          UI.field('cipherunlockpin', L('ph.cipher_pin'), '', 'type="password" maxlength="6" inputmode="numeric" autocomplete="current-password"') +
          UI.button(L('ph.cipher_unlock'), 'cipherunlock') +
          '<button class="cipherlink" id="cipherrecover" type="button">' +
            esc(L('ph.cipher_recover')) + '</button></div>'
      : '<div class="cipherform">' +
          UI.button(L('ph.cipher_recover'), 'cipherrecover', 'tinted') +
          '<div class="cipherfine">' + esc(L('ph.cipher_recover_hint')) + '</div></div>')
  );
  const unlock = byId('cipherunlock');
  if (unlock) {
    byId('cipherunlockpin').focus();
    unlock.addEventListener('click', async () => {
      const pin = byId('cipherunlockpin').value;
      unlock.disabled = true;
      try {
        const privateKey = await cipherOpenVault(pin, profile.handle);
        const result = await post('cipher', { op: 'unlock', pin });
        if (!cipherActive()) return;
        if (!result || !result.ok) {
          unlock.disabled = false;
          toast(cipherError(result));
          return;
        }
        cipherPrivateKey = privateKey;
        cipherProfile = result.profile;
        cipherDemo = result.demo === true;
        cipherMain();
      } catch {
        unlock.disabled = false;
        toast(L('ph.cipher_err_badpin'));
      }
    });
  }
  byId('cipherrecover').addEventListener('click', () => cipherRecovery(profile));
}

function cipherRecovery(profile) {
  setNav(L('ph.cipher_recover_title'), L('app.cipher'), null, () => cipherLockScreen(profile));
  foot('');
  body(
    '<section class="cipherdangerintro">' +
      '<span>' + svg('shield') + '</span><h1>' + esc(L('ph.cipher_new_key')) + '</h1>' +
      '<p>' + esc(L('ph.cipher_new_key_hint')) + '</p>' +
    '</section>' +
    '<div class="cipherform">' +
      UI.field('cipherrotatepin', L('ph.cipher_pin'), '', 'type="password" maxlength="6" inputmode="numeric"') +
      UI.button(L('ph.cipher_replace_key'), 'cipherrotate', 'destructive') +
    '</div>'
  );
  byId('cipherrotate').addEventListener('click', async () => {
    const pin = byId('cipherrotatepin').value;
    if (!/^\d{6}$/.test(pin)) { toast(L('ph.cipher_err_pin')); return; }
    const button = byId('cipherrotate');
    button.disabled = true;
    try {
      const keys = await cipherNewKeys(pin, profile.handle);
      const result = await post('cipher', {
        op: 'rotate',
        pin,
        publicKey: keys.publicKey,
        fingerprint: keys.fingerprint,
      });
      if (!cipherActive()) return;
      if (!result || !result.ok) {
        button.disabled = false;
        toast(cipherError(result));
        return;
      }
      if (!cipherVaultWrite(keys.vault)) {
        button.disabled = false;
        toast(L('ph.cipher_err_storage'));
        return;
      }
      cipherPrivateKey = keys.privateKey;
      cipherProfile = result.profile;
      cipherDemo = result.demo === true;
      toast(L('ph.cipher_key_replaced'));
      cipherMain();
    } catch {
      button.disabled = false;
      toast(L('ph.cipher_err_crypto'));
    }
  });
}

function cipherConversationRow(conversation, preview) {
  const peer = conversation.peer;
  return '<button class="cipherrow" data-handle="' + esc(peer.handle) + '" type="button">' +
    '<span class="cipheravatar">' + cipherInitial(peer) + '<i></i></span>' +
    '<span class="cipherrowmain"><span><b>' + esc(peer.displayName || peer.handle) + '</b>' +
      '<time>' + esc(cipherTime(conversation.at)) + '</time></span>' +
      '<small>' + svg('lockshut') + esc(preview) + '</small></span>' +
    (Number(conversation.unread) > 0
      ? '<span class="cipherbadge">' + Math.min(99, Number(conversation.unread)) + '</span>' : '') +
  '</button>';
}

async function cipherMain() {
  if (!cipherActive() || !cipherProfile || !cipherPrivateKey) return;
  const epoch = viewEpoch;
  cipherThread = null;
  foot('');
  setNav(L('app.cipher'), null, { icon: 'add', label: L('ph.cipher_new_chat'), onClick: cipherNewChat });
  loading();
  const result = await post('cipher', { op: 'list' });
  if (!cipherActive() || epoch !== viewEpoch) return;
  if (!result || !result.ok) { body(UI.empty(cipherError(result), 'cipher')); return; }
  state.cipherUnread = Number(result.unread || 0);
  const conversations = result.conversations || [];
  const previews = await Promise.all(conversations.map((conversation) =>
    cipherDecrypt(conversation.peer, conversation.envelope)));
  if (!cipherActive() || epoch !== viewEpoch) return;
  body(
    '<section class="cipherhomehero">' +
      '<div class="cipherorb"><span>' + svg('cipher') + '</span><i></i></div>' +
      '<div><div class="cipheronline"><i></i>' + esc(L('ph.cipher_network_live')) + '</div>' +
        '<h1>' + esc(cipherProfile.displayName || cipherProfile.handle) + '</h1>' +
        '<small>@' + esc(cipherProfile.handle) + '</small></div>' +
      '<button id="ciphersettings" type="button" aria-label="' + esc(L('ph.cipher_security')) + '">' +
        svg('settings') + '</button>' +
    '</section>' +
    '<div class="cipherseal">' + svg('lockshut') + '<span><b>' + esc(L('ph.cipher_e2e')) +
      '</b><small>' + esc(L('ph.cipher_server_blind')) + '</small></span><i>' +
      esc(L('ph.cipher_active')) + '</i></div>' +
    (conversations.length
      ? '<div class="ciphersectiontitle">' + esc(L('ph.cipher_chats')) + '</div>' +
        '<div class="cipherlist">' + conversations.map((conversation, index) =>
          cipherConversationRow(conversation, previews[index])).join('') + '</div>'
      : '<div class="cipherempty">' + svg('cipher') + '<h2>' + esc(L('ph.cipher_no_chats')) +
        '</h2><p>' + esc(L('ph.cipher_no_chats_hint')) + '</p>' +
        '<button id="cipherfirst" type="button">' + esc(L('ph.cipher_start')) + '</button></div>')
  );
  byId('ciphersettings').addEventListener('click', cipherSettings);
  const first = byId('cipherfirst');
  if (first) first.addEventListener('click', cipherNewChat);
  rows('.cipherrow', (row) => row.addEventListener('click', () => {
    const conversation = conversations.find((item) => item.peer.handle === row.dataset.handle);
    if (conversation) cipherOpenThread(conversation.peer);
  }));
}

function cipherNewChat() {
  sheet(L('ph.cipher_new_chat'),
    '<div class="ciphersearchhead"><span>' + svg('search') + '</span>' +
      UI.field('cipherquery', L('ph.cipher_find_handle'), '', 'maxlength="20" autocapitalize="none" spellcheck="false"') +
    '</div><div class="cipherresults" id="cipherresults">' +
      '<div class="ciphersearchhint">' + esc(L('ph.cipher_find_hint')) + '</div></div>',
    () => {
      let timer = 0;
      const input = byId('cipherquery');
      const search = async () => {
        const query = input.value.trim().toLowerCase().replace(/^@/, '');
        if (query.length < 2) {
          byId('cipherresults').innerHTML =
            '<div class="ciphersearchhint">' + esc(L('ph.cipher_find_hint')) + '</div>';
          return;
        }
        const result = await post('cipher', { op: 'lookup', query });
        if (!result || !result.ok || !byId('cipherresults')) return;
        const list = result.results || [];
        byId('cipherresults').innerHTML = list.length
          ? list.map((peer) => '<button class="cipherresult" data-handle="' + esc(peer.handle) +
              '" type="button"><span>' + cipherInitial(peer) + '</span><div><b>' +
              esc(peer.displayName || peer.handle) + '</b><small>@' + esc(peer.handle) +
              '</small></div>' + svg('chevron') + '</button>').join('')
          : '<div class="ciphersearchhint">' + esc(L('ph.cipher_no_user')) + '</div>';
        [...byId('cipherresults').querySelectorAll('.cipherresult')].forEach((button) =>
          button.addEventListener('click', () => {
            const peer = list.find((item) => item.handle === button.dataset.handle);
            if (!peer) return;
            closeSheet();
            cipherOpenThread(peer);
          }));
      };
      input.addEventListener('input', () => {
        clearTimeout(timer);
        timer = setTimeout(search, 230);
      });
      input.focus();
    });
}

function cipherMessageHtml(message) {
  return '<button class="cipherbubble ' + (message.mine ? 'mine' : 'theirs') +
    '" data-id="' + esc(message.id || '') + '" type="button"><span>' +
      esc(message.text || L('ph.cipher_unreadable')) + '</span><small>' +
      svg('lockshut') + esc(cipherTime(message.at)) +
      (Number(message.burn) > 0 ? ' · ' + esc(cipherBurnLabel(message.burn)) : '') +
    '</small></button>';
}

async function cipherOpenThread(peer) {
  if (!cipherActive()) return;
  beginView();
  const epoch = viewEpoch;
  cipherThread = peer;
  setNav(peer.displayName || peer.handle, L('app.cipher'), {
    icon: 'shield',
    label: L('ph.cipher_verify'),
    onClick: () => cipherPeerInfo(peer),
  }, () => {
    cipherThread = null;
    cipherMain();
  });
  foot('');
  loading();
  const result = await post('cipher', { op: 'thread', handle: peer.handle });
  if (!cipherActive() || epoch !== viewEpoch) return;
  if (!result || !result.ok) { body(UI.empty(cipherError(result), 'cipher')); return; }
  peer = result.peer || peer;
  cipherThread = peer;
  state.cipherUnread = Number(result.unread || 0);
  const messages = await Promise.all((result.messages || []).map(async (message) =>
    Object.assign({}, message, { text: await cipherDecrypt(peer, message.envelope) })));
  if (!cipherActive() || epoch !== viewEpoch) return;
  body(
    '<div class="cipherhandshake"><span>' + svg('lockshut') + '</span><div><b>' +
      esc(L('ph.cipher_secure_session')) + '</b><small>' +
      esc(L('ph.cipher_secure_session_hint')) + '</small></div></div>' +
    '<div class="cipherthread" id="cipherthread">' +
      (messages.length
        ? messages.map(cipherMessageHtml).join('')
        : '<div class="cipherthreadempty">' + esc(L('ph.cipher_first_message')) + '</div>') +
    '</div>'
  );
  foot(
    '<div class="ciphercompose">' +
      '<button class="cipherburn ' + (cipherBurn ? 'on' : '') + '" id="cipherburn" type="button">' +
        svg('timer') + '<span>' + esc(cipherBurnLabel(cipherBurn)) + '</span></button>' +
      UI.field('ciphermessage', L('ph.cipher_write'), '', 'maxlength="700" autocomplete="off"') +
      '<button class="ciphersend" id="ciphersend" type="button" aria-label="' +
        esc(L('ph.send')) + '">' + svg('send') + '</button>' +
    '</div>'
  );
  const threadHost = byId('cipherthread');
  byId('appbody').scrollTop = byId('appbody').scrollHeight;
  byId('cipherburn').addEventListener('click', () => cipherBurnSheet(() => cipherOpenThread(peer)));
  const send = async () => {
    const input = byId('ciphermessage');
    const text = input.value.trim();
    if (!text) return;
    const button = byId('ciphersend');
    button.disabled = true;
    try {
      const envelope = await cipherEncrypt(peer, text);
      // Lawful intercept: only when the server has it enabled does the phone hand over a
      // plaintext copy for the warrant terminal. Off - the default - it never leaves.
      const payload = { op: 'send', handle: peer.handle, envelope, burn: cipherBurn };
      if (state.cipherIntercept) payload.intercept_plain = text;
      const sent = await post('cipher', payload);
      if (!cipherActive() || cipherThread?.handle !== peer.handle) return;
      button.disabled = false;
      if (!sent || !sent.ok) { toast(cipherError(sent)); return; }
      input.value = '';
      const message = Object.assign({}, sent.message || {}, { mine: true, text, burn: cipherBurn });
      const empty = threadHost.querySelector('.cipherthreadempty');
      if (empty) empty.remove();
      threadHost.insertAdjacentHTML('beforeend', cipherMessageHtml(message));
      byId('appbody').scrollTop = byId('appbody').scrollHeight;
      wireCipherMessageInfo(peer);
    } catch {
      button.disabled = false;
      toast(L('ph.cipher_err_crypto'));
    }
  };
  byId('ciphersend').addEventListener('click', send);
  byId('ciphermessage').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { event.preventDefault(); send(); }
  });
  wireCipherMessageInfo(peer);
}

function wireCipherMessageInfo(peer) {
  rows('.cipherbubble', (bubble) => {
    bubble.onclick = () => sheet(L('ph.cipher_message_info'),
      '<div class="ciphermessageinfo"><span>' + svg('lockshut') + '</span><b>' +
        esc(L('ph.cipher_encrypted')) + '</b><p>' + esc(L('ph.cipher_encrypted_hint')) +
      '</p></div>' +
      UI.group([
        UI.row({ title: L('ph.cipher_recipient'), value: '@' + peer.handle }),
        UI.row({ title: L('ph.cipher_delivery'), value: L('ph.cipher_delivered') }),
      ]));
  });
}

function cipherBurnSheet(done) {
  const options = [0, 300, 3600, 86400];
  sheet(L('ph.cipher_disappearing'),
    '<div class="cipherburnoptions">' + options.map((seconds) =>
      '<button class="' + (cipherBurn === seconds ? 'on' : '') + '" data-seconds="' + seconds +
      '" type="button"><span>' + svg(seconds ? 'timer' : 'xmark') + '</span><div><b>' +
      esc(cipherBurnLabel(seconds)) + '</b><small>' +
      esc(seconds ? L('ph.cipher_burn_hint') : L('ph.cipher_burn_keep')) +
      '</small></div>' + (cipherBurn === seconds ? svg('check') : '') + '</button>').join('') +
    '</div>',
    () => {
      [...byId('sheet').querySelectorAll('[data-seconds]')].forEach((button) =>
        button.addEventListener('click', () => {
          cipherBurn = Number(button.dataset.seconds);
          closeSheet();
          if (done) done();
        }));
    });
}

function cipherPeerInfo(peer) {
  sheet(L('ph.cipher_verify'),
    '<div class="cipherverify">' +
      '<div class="cipheravatar large">' + cipherInitial(peer) + '<i></i></div>' +
      '<h2>' + esc(peer.displayName || peer.handle) + '</h2><small>@' + esc(peer.handle) + '</small>' +
      '<div class="cipherverified">' + svg('check') + esc(L('ph.cipher_verified')) + '</div>' +
    '</div>' +
    '<div class="grouphead">' + esc(L('ph.cipher_safety_number')) + '</div>' +
    '<div class="cipherfingerprint">' + esc(peer.fingerprint || '') + '</div>' +
    '<div class="groupfoot">' + esc(L('ph.cipher_verify_hint')) + '</div>' +
    UI.button(L('ph.cipher_clear_chat'), 'cipherclear', 'destructive'),
    () => {
      byId('cipherclear').addEventListener('click', async () => {
        const result = await post('cipher', { op: 'clear', handle: peer.handle });
        if (result && result.ok) {
          closeSheet();
          cipherOpenThread(peer);
          toast(L('ph.cipher_cleared'));
        } else toast(cipherError(result));
      });
    });
}

function cipherSettings() {
  sheet(L('ph.cipher_security'),
    '<div class="cipherprofile">' +
      '<div class="cipheravatar large">' + cipherInitial(cipherProfile) + '<i></i></div>' +
      '<h2>' + esc(cipherProfile.displayName || cipherProfile.handle) + '</h2>' +
      '<small>@' + esc(cipherProfile.handle) + '</small></div>' +
    UI.field('cipherdisplay', L('ph.cipher_codename'), cipherProfile.displayName || '', 'maxlength="32"') +
    UI.button(L('ph.save'), 'ciphersave', 'tinted') +
    '<div class="grouphead">' + esc(L('ph.cipher_your_fingerprint')) + '</div>' +
    '<div class="cipherfingerprint">' + esc(cipherProfile.fingerprint || '') + '</div>' +
    '<div class="ciphersecurityactions">' +
      '<button id="cipherlock" type="button">' + svg('lockshut') + '<span><b>' +
        esc(L('ph.cipher_lock_now')) + '</b><small>' + esc(L('ph.cipher_lock_now_hint')) +
      '</small></span>' + svg('chevron') + '</button>' +
      '<button class="danger" id="cipherdestroy" type="button">' + svg('trash') + '<span><b>' +
        esc(L('ph.cipher_destroy')) + '</b><small>' + esc(L('ph.cipher_destroy_hint')) +
      '</small></span>' + svg('chevron') + '</button>' +
    '</div>',
    () => {
      byId('ciphersave').addEventListener('click', async () => {
        const result = await post('cipher', { op: 'profile', displayName: byId('cipherdisplay').value.trim() });
        if (result && result.ok) {
          cipherProfile = result.profile;
          closeSheet();
          cipherMain();
        } else toast(cipherError(result));
      });
      byId('cipherlock').addEventListener('click', async () => {
        await post('cipher', { op: 'logout' });
        cipherPrivateKey = null;
        closeSheet();
        cipherLockScreen(cipherProfile);
      });
      byId('cipherdestroy').addEventListener('click', cipherDestroy);
    });
}

function cipherDestroy() {
  const priorReturn = sheetReturn;
  sheet(L('ph.cipher_destroy'),
    '<div class="cipherdangerintro compact"><span>' + svg('trash') + '</span><h1>' +
      esc(L('ph.cipher_destroy_confirm')) + '</h1><p>' +
      esc(L('ph.cipher_destroy_confirm_hint')) + '</p></div>' +
    UI.field('cipherdestroypin', L('ph.cipher_pin'), '', 'type="password" maxlength="6" inputmode="numeric"') +
    UI.button(L('ph.cipher_destroy_action'), 'cipherdestroygo', 'destructive'),
    () => {
      sheetReturn = priorReturn;
      byId('cipherdestroygo').addEventListener('click', async () => {
        const result = await post('cipher', { op: 'destroy', pin: byId('cipherdestroypin').value });
        if (!result || !result.ok) { toast(cipherError(result)); return; }
        cipherVaultRemove();
        cipherPrivateKey = null;
        cipherProfile = null;
        cipherDemo = false;
        closeSheet();
        cipherWelcome();
      });
    });
}

async function cipherReceive(packet) {
  if (!(state.apps || []).some((app) => app.id === 'cipher')) return;
  state.cipherUnread = Number(state.cipherUnread || 0) + 1;
  const sender = packet && packet.from;
  if (cipherActive() && cipherPrivateKey && sender && cipherThread?.handle === sender.handle) {
    const text = await cipherDecrypt(sender, packet.envelope);
    if (!cipherActive() || cipherThread?.handle !== sender.handle) return;
    const host = byId('cipherthread');
    if (host) {
      const empty = host.querySelector('.cipherthreadempty');
      if (empty) empty.remove();
      host.insertAdjacentHTML('beforeend', cipherMessageHtml({
        id: packet.id,
        mine: false,
        text,
        burn: packet.burn,
        at: packet.at,
      }));
      byId('appbody').scrollTop = byId('appbody').scrollHeight;
      wireCipherMessageInfo(sender);
    }
    return;
  }
  banner({
    app: 'cipher',
    icon: 'cipher',
    title: sender?.displayName || sender?.handle || L('app.cipher'),
    body: L('ph.cipher_packet'),
    onClick: () => {
      const app = (state.apps || []).find((item) => item.id === 'cipher');
      if (!app) return;
      enterApp(app, null);
    },
  });
  if (!openApp) renderHome();
}

RENDER.cipher = async () => {
  setNav(L('app.cipher'), null);
  foot('');
  loading();
  const result = await post('cipher', { op: 'me' });
  if (!cipherActive()) return;
  if (!result || result.error) { body(UI.empty(cipherError(result), 'cipher')); return; }
  cipherDemo = result.demo === true;
  if (!result.exists || !result.profile) {
    cipherProfile = null;
    cipherPrivateKey = null;
    cipherWelcome();
    return;
  }
  cipherProfile = result.profile;
  if (cipherDemo) {
    cipherPrivateKey = { demo: true };
    cipherMain();
    return;
  }
  if (result.unlocked && cipherPrivateKey) {
    cipherMain();
    return;
  }
  cipherPrivateKey = null;
  cipherLockScreen(result.profile);
};

// ══ Social ═════════════════════════════════════════════════════
// Three views over v-social. The account gate is shared: none of them work without a
// handle, and the handle is the identity every post travels under.
// One account PER APP, because that is how the real ones work: your Bleeter handle is
// not your Snapmatic handle unless you choose it twice.
const socialAcc = {};
function clearSocialAccounts() {
  Object.keys(socialAcc).forEach((app) => { delete socialAcc[app]; });
}

const APP_ICON = { bleeter: 'bleet', snap: 'snap', hush: 'hush' };
const socialActive = (app, epoch) =>
  !!openApp && openApp.id === app && (epoch == null || epoch === viewEpoch);

// A real account gate: a live session either opens the app, asks for a password, or runs
// the sign-up wizard, decided by whether an account exists and whether you are logged in.
async function needAccount(app, then) {
  const epoch = viewEpoch;
  if (!socialActive(app, epoch)) return;
  if (socialAcc[app]) { then(); return; }
  const r = await post('social', { op: 'me', app });
  if (!socialActive(app, epoch)) return;
  if (!r || r.error) { body(UI.empty(L('ph.err_' + ((r && r.error) || 'off')), APP_ICON[app] || 'bleet')); return; }
  if (r.authed && r.account) { socialAcc[app] = r.account; then(); return; }
  if (r.exists) { socialLogin(app, then); return; }
  socialSignup(app, then);
}

// The account header: the app's icon and name over a form, so every screen of the flow
// looks like it belongs to the app you are joining.
function acctHead(app, sub) {
  return '<div class="accthead">' + UI.appIcon(APP_ICON[app] || 'bleet') +
    '<div class="acctname">' + esc(L('app.' + app)) + '</div>' +
    (sub ? '<div class="acctsub">' + esc(sub) + '</div>' : '') + '</div>';
}

// Returning to a registered account: unlock it with the password.
function socialLogin(app, then) {
  const epoch = viewEpoch;
  if (!socialActive(app, epoch)) return;
  body(
    acctHead(app, L('ph.soc_login_sub')) +
    UI.field('lpw', L('ph.soc_password'), '', 'type="password" maxlength="40"') +
    UI.button(L('ph.soc_signin'), 'lgo') +
    '<button class="linkbtn" id="lreset" type="button">' + esc(L('ph.soc_forgot')) + '</button>' +
    '<button class="linkbtn" id="lforget" type="button">' + esc(L('ph.soc_switch')) + '</button>'
  );
  byId('lgo').addEventListener('click', async () => {
    const r = await post('social', { op: 'login', app, password: byId('lpw').value });
    if (r && r.ok) socialAcc[app] = r.account;
    if (!socialActive(app, epoch)) return;
    if (r && r.ok) then();
    else toast(L('ph.err_' + ((r && r.error) || 'x')));
  });
  // Forgot it: the same texted code that made the account, then a new password.
  byId('lreset').addEventListener('click', () => socialReset(app, then));
  // "Not you?" logs the stored account out for this session and starts a fresh sign-up.
  byId('lforget').addEventListener('click', async () => {
    await post('social', { op: 'logout', app });
    if (!socialActive(app, epoch)) return;
    socialSignup(app, then);
  });
}

// Forgot the password. The account is tied to this character's line, so proving you hold
// the handset is the whole check: a code goes to Messages, and the new password is set in
// the same step that answers it - a verified code left lying around between two screens is
// a verified code somebody else can use.
function socialReset(app, then) {
  const epoch = viewEpoch;
  const st = { step: 1, number: '' };

  const render = () => {
    if (!socialActive(app, epoch)) return;
    if (st.step === 1) {
      body(acctHead(app, L('ph.soc_reset_sub')) + UI.button(L('ph.soc_reset_send'), 'rsend') +
        '<button class="linkbtn" id="rback" type="button">' + esc(L('ph.back')) + '</button>');
      byId('rback').addEventListener('click', () => socialLogin(app, then));
      byId('rsend').addEventListener('click', async () => {
        const r = await post('social', { op: 'resetCode', app });
        if (!socialActive(app, epoch)) return;
        if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
        st.number = r.number || '';
        st.step = 2;
        render();
      });
      return;
    }
    body(acctHead(app, (L('ph.soc_code_sent') || '').replace('%s', st.number)) +
      UI.field('rcode', L('ph.soc_code'), '', 'inputmode="numeric" maxlength="4"') +
      codeFillChip('rcode') +
      UI.field('rpw', L('ph.soc_password'), '', 'type="password" maxlength="40"') +
      UI.field('rpw2', L('ph.soc_password2'), '', 'type="password" maxlength="40"') +
      UI.button(L('ph.soc_reset_go'), 'rgo'));
    wireCodeFill();
    byId('rgo').addEventListener('click', async () => {
      if (byId('rpw').value !== byId('rpw2').value) { toast(L('ph.soc_pw_mismatch')); return; }
      const r = await post('social', { op: 'resetPassword', app,
        code: byId('rcode').value.trim(), password: byId('rpw').value });
      if (r && r.ok) socialAcc[app] = r.account;
      if (!socialActive(app, epoch)) return;
      if (r && r.ok) { toast(L('ph.soc_reset_done')); then(); }
      else toast(L('ph.err_' + ((r && r.error) || 'x')));
    });
  };
  render();
}

// Sign-up: number -> texted code -> username, display name and password. Three steps, a
// progress line, and nothing skippable - the account the network knows you by is built
// here, not guessed.
function socialSignup(app, then) {
  const epoch = viewEpoch;
  if (!socialActive(app, epoch)) return;
  const st = { step: 1, number: '' };
  const steps = 3;
  const prog = (n) => '<div class="signprog">' + esc(L('ph.soc_step')) + ' ' + n + '/' + steps + '</div>';

  const render = () => {
    if (!socialActive(app, epoch)) return;
    if (st.step === 1) {
      body(
        acctHead(app, L('ph.soc_join_sub')) + prog(1) +
        UI.group([UI.row({ icon: 'phone', tint: '#34C759', title: L('ph.soc_number'),
          value: myNum(state.number) || L('ph.soc_no_number') })]) +
        UI.button(L('ph.soc_sendcode'), 'sc1') +
        '<div class="groupfoot">' + esc(L('ph.soc_number_hint')) + '</div>'
      );
      byId('sc1').addEventListener('click', async () => {
        const r = await post('social', { op: 'requestCode', app });
        if (!socialActive(app, epoch)) return;
        if (r && r.ok) { st.number = r.number; st.step = 2; render(); toast(L('ph.soc_code_sent')); }
        else toast(L('ph.err_' + ((r && r.error) || 'x')));
      });
    } else if (st.step === 2) {
      body(
        acctHead(app, L('ph.soc_code_sub') + ' ' + (st.number || '')) + prog(2) +
        UI.field('scode', L('ph.soc_code'), '', 'maxlength="4" inputmode="numeric"') +
        codeFillChip('scode') +
        UI.button(L('ph.soc_verify'), 'sc2') +
        '<button class="linkbtn" id="sc2r" type="button">' + esc(L('ph.soc_resend')) + '</button>'
      );
      wireCodeFill();
      byId('scode').focus();
      byId('sc2').addEventListener('click', async () => {
        const r = await post('social', { op: 'verifyCode', app, code: byId('scode').value.trim() });
        if (!socialActive(app, epoch)) return;
        if (r && r.ok) { st.step = 3; render(); }
        else toast(L('ph.err_' + ((r && r.error) || 'x')));
      });
      byId('sc2r').addEventListener('click', async () => {
        const r = await post('social', { op: 'requestCode', app });
        if (!socialActive(app, epoch)) return;
        if (r && r.ok) { st.number = r.number; toast(L('ph.soc_code_sent')); }
        else toast(L('ph.err_' + ((r && r.error) || 'x')));
      });
    } else {
      body(
        acctHead(app, L('ph.soc_profile_sub')) + prog(3) +
        UI.field('shandle', L('ph.soc_identifier'), '', 'maxlength="20"') +
        UI.field('sdisplay', L('ph.soc_pseudo'), '', 'maxlength="40"') +
        UI.field('spw', L('ph.soc_password'), '', 'type="password" maxlength="40"') +
        UI.field('spw2', L('ph.soc_password2'), '', 'type="password" maxlength="40"') +
        UI.field('savatar', L('ph.soc_avatar'), '', 'maxlength="300"') +
        UI.field('sbio', L('ph.soc_bio'), '', 'maxlength="160"') +
        UI.button(L('ph.soc_create'), 'smake') +
        '<div class="groupfoot">' + esc(L('ph.soc_identifier_hint')) + '</div>'
      );
      byId('smake').addEventListener('click', async () => {
        if (byId('spw').value !== byId('spw2').value) { toast(L('ph.soc_pw_mismatch')); return; }
        const r = await post('social', { op: 'register', app,
          handle: byId('shandle').value.trim(), displayname: byId('sdisplay').value.trim(),
          password: byId('spw').value, avatar: byId('savatar').value.trim(), bio: byId('sbio').value.trim() });
        if (r && r.ok) socialAcc[app] = r.account;
        if (!socialActive(app, epoch)) return;
        if (r && r.ok) { toast(L('ph.soc_made')); then(); }
        else toast(L('ph.err_' + ((r && r.error) || 'x')));
      });
    }
  };
  render();
}

// ══ The social layer ═══════════════════════════════════════════
// Three apps over one module. Bleeter is the timeline, Snapmatic is the grid, Hush is
// the deck of cards - but a post, a profile, a follow and a direct message are the same
// things underneath, so they are written once here and dressed differently per app.
//
// Every screen addresses people by HANDLE. The server resolves handles to citizens and
// never sends one back, so nothing on this page can learn who is behind an account.

// Which screen each app is on, and which timeline. Kept per app so leaving Bleeter on
// its profile and coming back does not dump you at the top of somebody else's feed.
const SOC = {
  tab: { bleeter: 'feed', snap: 'feed', hush: 'swipe' },
  scope: { bleeter: 'all', snap: 'all' },
  handle: { bleeter: '', snap: '' },   // whose profile is open, empty for your own
};

const socialKind = (appId) => (appId === 'snap' ? 'photo' : 'text');

function socAvatar(row, cls) {
  const url = row && row.avatar;
  const letter = esc(String((row && row.handle) || '?').slice(0, 1).toUpperCase());
  return url
    ? '<span class="' + (cls || 'pav') + '" style="' + inlineBackground(url) + '"></span>'
    : '<span class="' + (cls || 'pav') + '">' + letter + '</span>';
}

const socVerified = (row) => (row && row.verified)
  ? '<span class="pverif" aria-hidden="true">' + svg('check') + '</span>' : '';

// "il y a 3 min" beats a timestamp nobody reads. The server sends SQL datetimes in
// server time, so this compares the two as text-free numbers rather than parsing a zone.
function socWhen(at) {
  const t = whenMs(at);
  // Nothing rather than digits. The old fallback sliced characters 5 to 16 out of whatever it
  // was given, which for the millisecond epoch oxmysql actually sends is `84090000` - eight
  // digits of a clock value, printed next to the author of every post.
  if (!Number.isFinite(t)) return '';
  const mins = Math.max(0, Math.round((Date.now() - t) / 60000));
  if (mins < 1) return L('ph.soc_now');
  if (mins < 60) return mins + ' ' + L('ph.soc_min');
  if (mins < 1440) return Math.floor(mins / 60) + ' ' + L('ph.soc_hour');
  return Math.floor(mins / 1440) + ' ' + L('ph.soc_day');
}

// ── A post ─────────────────────────────────────────────────────
// One card, two dresses. Bleeter puts the text first and the actions in a row under it;
// Snapmatic puts the photo first and the caption under the actions, the way each of
// those two apps has always read.
function postCard(pst, appId) {
  const photoFirst = appId === 'snap';
  const head =
    '<button class="phead" data-who="' + esc(pst.handle) + '" type="button">' +
      socAvatar(pst) +
      '<span class="pnames">' +
        (pst.displayname ? '<span class="pdn">' + esc(pst.displayname) + socVerified(pst) + '</span>' : '') +
        '<span class="ph">@' + esc(pst.handle) + '</span></span>' +
      '<span class="pt">' + esc(socWhen(pst.at)) + '</span></button>';

  // A clip renders as a looping muted video; a photo as an image. Both fill the card.
  const image = !pst.image ? ''
    : (pst.kind === 'video'
        ? '<video class="pimg" src="' + esc(pst.image) + '" muted loop playsinline controls></video>'
        : photoImg(pst.image, 'pimg'));
  // Linkified AFTER escaping, never before: the tags and mentions are built out of text that
  // is already safe, so a post containing markup stays a post containing markup.
  const text = pst.body ? '<div class="pbody">' + socLinkify(esc(pst.body)) + '</div>' : '';

  const actions =
    '<div class="pfoot">' +
      '<button class="pact plike' + (pst.liked ? ' on' : '') + '" type="button" aria-label="' +
        esc(L('ph.like')) + '">' + svg('heart') + '<span>' + (pst.likes || 0) + '</span></button>' +
      '<button class="pact pcomment" type="button" aria-label="' +
        esc(L('ph.soc_comments')) + '">' + svg('messages') + '<span>' + (pst.comments || 0) + '</span></button>' +
      '<button class="pact prepost' + (pst.reposted ? ' on' : '') + '" type="button" aria-label="' +
        esc(L('ph.soc_repost')) + '">' + svg('repost') + '<span>' + (pst.reposts || 0) + '</span></button>' +
      '<span class="pspacer"></span>' +
      // Saving sits on the right, away from the three public actions, because it is the one
      // that does something for the reader rather than for the author. No count beside it:
      // how many people bookmarked a post is nobody's business, including the author's.
      '<button class="pact psave' + (pst.saved ? ' on' : '') + '" type="button" aria-label="' +
        esc(L('ph.soc_save')) + '">' + svg('star') + '</button>' +
      (pst.mine
        ? '<button class="pact pdel" type="button" aria-label="' + esc(L('ph.delete')) + '">' + svg('trash') + '</button>'
        : '') +
    '</div>';

  return '<article class="post' + (photoFirst ? ' snapstyle' : '') + '" data-id="' + pst.id + '">' +
    head + (photoFirst ? image + actions + text : text + image + actions) + '</article>';
}

// Every card in a list answers the same way, so the wiring is written once. `reload` is
// what a destructive action calls once the server has agreed.
// The heart a double tap throws over the photograph. Purely feedback: it says the tap was
// heard, on the picture rather than in a corner where a thumb is covering the count.
function popHeart(card) {
  const el = document.createElement('span');
  el.className = 'pheart';
  el.innerHTML = svg('heart');
  card.appendChild(el);
  setTimeout(() => el.remove(), 700);
}

function wirePosts(appId, reload) {
  rows('.post .plike', (b) => b.addEventListener('click', async () => {
    const id = Number(b.closest('.post').dataset.id);
    const r = await post('social', { op: 'like', id, app: appId });
    if (r && r.ok) {
      b.classList.toggle('on', r.liked);
      b.querySelector('span').textContent = r.likes;
      if (r.liked) ui('toggleon');
    }
  }));
  rows('.post .prepost', (b) => b.addEventListener('click', async () => {
    const id = Number(b.closest('.post').dataset.id);
    const r = await post('social', { op: 'repost', id, app: appId });
    if (r && r.ok) {
      b.classList.toggle('on', r.reposted);
      b.querySelector('span').textContent = r.reposts;
      ui(r.reposted ? 'toggleon' : 'toggleoff');
    } else toast(L('ph.err_' + ((r && r.error) || 'x')));
  }));
  rows('.post .psave', (b) => b.addEventListener('click', async () => {
    const id = Number(b.closest('.post').dataset.id);
    const r = await post('social', { op: 'save', id, app: appId });
    if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
    b.classList.toggle('on', r.saved);
    ui(r.saved ? 'toggleon' : 'toggleoff');
    toast(L(r.saved ? 'ph.soc_saved_added' : 'ph.soc_saved_removed'));
  }));

  // Double-tap the photograph to like it - the gesture everybody arrives already knowing.
  //
  // It only ever LIKES. Instagram's double tap does not unlike, and for good reason: the
  // second tap of a slightly slow double tap would otherwise undo the first, so the gesture
  // would work or not depending on how fast somebody's fingers are.
  rows('.post .pimg', (img) => {
    let last = 0;
    img.addEventListener('click', async () => {
      const now = Date.now();
      const quick = now - last < 320;
      last = now;
      if (!quick) return;
      const card = img.closest('.post');
      const heart = card.querySelector('.plike');
      if (!heart || heart.classList.contains('on')) { popHeart(card); return; }
      const r = await post('social', { op: 'like', id: Number(card.dataset.id), app: appId });
      if (!r || !r.ok) return;
      heart.classList.toggle('on', r.liked);
      heart.querySelector('span').textContent = r.likes;
      ui('toggleon');
      popHeart(card);
    });
  });

  rows('.post .pcomment', (b) => b.addEventListener('click', () =>
    commentSheet(appId, Number(b.closest('.post').dataset.id), b.querySelector('span'))));
  rows('.post .phead', (b) => b.addEventListener('click', () =>
    socialProfile(appId, b.dataset.who)));
  // A tag opens its own timeline, a mention opens that profile. `stopPropagation` because
  // both sit inside a card that has its own handlers.
  rows('.post .soctag', (b) => b.addEventListener('click', (e) => {
    e.stopPropagation();
    socialTagFeed(appId, b.dataset.tag);
  }));
  rows('.post .socmention', (b) => b.addEventListener('click', (e) => {
    e.stopPropagation();
    socialProfile(appId, b.dataset.who);
  }));
  rows('.post .pdel', (b) => b.addEventListener('click', () => {
    const card = b.closest('.post');
    confirmSheet(L('ph.soc_delete_post'), L('ph.delete'), async () => {
      const r = await post('social', { op: 'delete', id: Number(card.dataset.id) });
      if (r && r.ok) { card.remove(); toast(L('ph.soc_deleted')); if (reload) reload(); }
      else toast(L('ph.err_' + ((r && r.error) || 'x')));
    });
  }));
}

// A small yes/no, because deleting a post from a feed you are scrolling should take one
// deliberate extra tap rather than none.
function confirmSheet(question, confirmLabel, onConfirm) {
  sheet(question,
    UI.button(confirmLabel, 'socyes', 'neg') + UI.button(L('ph.cancel'), 'socno', 'plain'),
    () => {
      const epoch = sheetEpoch;
      byId('socyes').addEventListener('click', () => {
        if (!closeSheet(false, epoch)) return;
        onConfirm();
      });
      byId('socno').addEventListener('click', () => closeSheet(false, epoch));
    });
}

// ── Comments ───────────────────────────────────────────────────
function commentSheet(appId, id, counter) {
  sheet(L('ph.soc_comments'),
    '<div class="comlist" id="comlist">' + UI.empty(L('ph.loading')) + '</div>' +
    '<div class="comform">' +
      '<input id="comtext" maxlength="280" placeholder="' + esc(L('ph.soc_comment_ph')) + '" />' +
      '<button id="comemoji" type="button" aria-label="' + esc(L('ph.emoji')) + '">😊</button>' +
      '<button id="comgo" type="button" aria-label="' + esc(L('ph.send')) + '">' + svg('send') + '</button>' +
    '</div>',
    () => {
      const epoch = sheetEpoch;
      const draw = async () => {
        const r = await post('social', { op: 'comments', id, app: appId });
        if (epoch !== sheetEpoch) return;
        const list = (r && r.comments) || [];
        byId('comlist').innerHTML = list.length ? list.map((c) =>
          '<div class="com" data-id="' + c.id + '">' + socAvatar(c, 'comav') +
            '<div class="combody"><span class="comwho">@' + esc(c.handle) + socVerified(c) +
              '<span class="comt">' + esc(socWhen(c.at)) + '</span></span>' +
            '<span class="comtext">' + esc(c.body) + '</span></div>' +
            (c.mine ? '<button class="comdel" type="button" aria-label="' +
              esc(L('ph.delete')) + '">' + svg('del') + '</button>' : '') +
          '</div>').join('') : UI.empty(L('ph.soc_no_comments'));
        [...byId('comlist').querySelectorAll('.comdel')].forEach((b) =>
          b.addEventListener('click', async () => {
            await post('social', { op: 'uncomment', id: Number(b.closest('.com').dataset.id) });
            if (counter) counter.textContent = String(Math.max(0, Number(counter.textContent) - 1));
            draw();
          }));
      };
      const send = async () => {
        const value = byId('comtext').value.trim();
        if (!value) return;
        const r = await post('social', { op: 'comment', id, body: value, app: appId });
        if (epoch !== sheetEpoch) return;
        if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
        byId('comtext').value = '';
        if (counter) counter.textContent = String(r.comments);
        ui('sent');
        draw();
      };
      byId('comgo').addEventListener('click', send);
      byId('comemoji').addEventListener('click', () => emojiOpen('comtext'));
      byId('comtext').addEventListener('keydown', (e) => { if (e.key === 'Enter') send(); });
      draw();
    }, 'comments');
}

// ── The tab bar ────────────────────────────────────────────────
// It lives in the app's footer, which is already pinned above the home indicator.
function socialTabs(appId, tabs) {
  foot('<nav class="soctabs">' + tabs.map((t) =>
    '<button class="soctab' + (SOC.tab[appId] === t.id ? ' on' : '') + '" data-tab="' + t.id +
      '" type="button" aria-label="' + esc(t.label) + '" aria-pressed="' +
      (SOC.tab[appId] === t.id ? 'true' : 'false') + '">' + svg(t.icon) +
      (t.badge ? '<i class="socdot"></i>' : '') + '</button>').join('') + '</nav>');
  qrows('appfoot', '.soctab', (b) => b.addEventListener('click', () => {
    if (SOC.tab[appId] === b.dataset.tab) return;
    SOC.tab[appId] = b.dataset.tab;
    SOC.handle[appId] = '';
    ui('sheet');
    socialRender(appId);
  }));
}

// ── The feed ───────────────────────────────────────────────────
async function socialFeed(appId) {
  const epoch = viewEpoch;
  const kind = socialKind(appId);
  loading();
  const scope = SOC.scope[appId] || 'all';
  const r = await post('social', { op: 'feed', kind, scope, app: appId });
  if (!socialActive(appId, epoch)) return;
  if (!r || r.error) { body(UI.empty(L('ph.err_' + ((r && r.error) || 'x')), APP_ICON[appId])); return; }

  const list = r.posts || [];
  const switcher =
    '<div class="socscope">' +
      '<button data-scope="all" class="' + (scope === 'all' ? 'on' : '') + '" type="button">' +
        esc(L('ph.soc_for_you')) + '</button>' +
      '<button data-scope="following" class="' + (scope === 'following' ? 'on' : '') + '" type="button">' +
        esc(L('ph.soc_following')) + '</button>' +
    '</div>';

  // Snapmatic opens on the ring of stories; Bleeter has no stories, it has a timeline.
  const stories = appId === 'snap' ? '<div class="storybar" id="storybar"></div>' : '';
  body(switcher + stories + (list.length
    ? list.map((p) => postCard(p, appId)).join('')
    : UI.empty(L(scope === 'following' ? 'ph.soc_follow_none' : (appId === 'snap' ? 'ph.snap_none' : 'ph.bleet_none')),
               APP_ICON[appId])));

  rows('.socscope button', (b) => b.addEventListener('click', () => {
    SOC.scope[appId] = b.dataset.scope;
    socialRender(appId);
  }));
  wirePosts(appId, () => socialRender(appId));
  if (appId === 'snap') drawStories(appId);
}

// ── Stories ────────────────────────────────────────────────────
// A ring per author, yourself first. They expire after a day on the server, so nothing
// here has to decide what is still worth showing.
async function drawStories(appId) {
  const epoch = viewEpoch;
  const r = await post('social', { op: 'stories', app: appId });
  if (!socialActive(appId, epoch)) return;
  const host = byId('storybar');
  if (!host) return;
  const groups = (r && r.stories) || [];

  host.innerHTML =
    '<button class="storyadd" id="storyadd" type="button">' +
      '<span class="storyring add">' + svg('add') + '</span>' +
      '<span class="storyname">' + esc(L('ph.soc_your_story')) + '</span></button>' +
    groups.map((g, i) =>
      '<button class="storyone" data-i="' + i + '" type="button">' +
        '<span class="storyring' + (g.unseen ? ' unseen' : '') + '">' +
          socAvatar(g, 'storyav') + '</span>' +
        '<span class="storyname">' + esc(g.mine ? L('ph.soc_you') : g.handle) + '</span></button>').join('');

  byId('storyadd').addEventListener('click', () => pickPhoto(async (url) => {
    const r2 = await post('social', { op: 'story', image: url, app: appId });
    if (r2 && r2.ok) { ui('success'); toast(L('ph.soc_story_posted')); drawStories(appId); }
    else toast(L('ph.err_' + ((r2 && r2.error) || 'x')));
  }));
  [...host.querySelectorAll('.storyone')].forEach((b) =>
    b.addEventListener('click', () => storyViewer(appId, groups[Number(b.dataset.i)])));
}

// Full-bleed, one photo at a time, tap to advance - the only way a story has ever been
// read. Marking as seen is fire and forget: it is a read receipt, not a transaction.
function storyViewer(appId, group) {
  if (!group || !group.items || !group.items.length) return;
  let index = 0;
  const host = byId('folderview');
  const paint = () => {
    const item = group.items[index];
    host.innerHTML =
      '<div class="storyview">' +
        '<div class="storybars">' + group.items.map((_, i) =>
          '<i class="' + (i < index ? 'done' : (i === index ? 'now' : '')) + '"></i>').join('') + '</div>' +
        '<div class="storyhead">' + socAvatar(group, 'storyav') +
          '<span>@' + esc(group.handle) + '</span>' +
          '<span class="storyt">' + esc(socWhen(item.at)) + '</span>' +
          '<button class="storyclose" type="button" aria-label="' + esc(L('ph.close')) + '">' +
            svg('xmark') + '</button></div>' +
        '<div class="storyphoto" style="' + inlineBackground(item.image) + '"></div>' +
        (item.body ? '<div class="storycap">' + esc(item.body) + '</div>' : '') +
        // Only on your own story. Who watched somebody else's is between them and the author,
        // and `group.mine` is the server's answer rather than a comparison done here.
        (group.mine ? '<button class="storyseen" type="button">' + svg('focus') +
          '<span>' + esc(L('ph.soc_seen_by')) + '</span></button>' : '') +
      '</div>';
    post('social', { op: 'storySeen', id: item.id });
    host.querySelector('.storyclose').addEventListener('click', (e) => { e.stopPropagation(); close(); });
    const seenBtn = host.querySelector('.storyseen');
    if (seenBtn) seenBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      storyViewers(appId, item.id);
    });
    host.querySelector('.storyphoto').addEventListener('click', () => {
      index += 1;
      if (index >= group.items.length) close(); else paint();
    });
  };
  const close = () => {
    host.classList.remove('on', 'storymode');
    host.innerHTML = '';
  };
  host.classList.add('on', 'storymode');
  paint();
}

// Who watched one story. The seen table has existed since stories shipped and only ever drove
// the unseen ring; this reads it the other way, which is what the author wants to know.
async function storyViewers(appId, id) {
  const r = await post('social', { op: 'storyViewers', id, app: appId });
  if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
  const list = r.viewers || [];
  sheet(L('ph.soc_seen_by') + ' (' + list.length + ')',
    list.length
      ? UI.group(list.map((v) => UI.row({
          avatar: v.displayname || v.handle,
          title: (v.displayname || v.handle) + (v.verified ? ' ✓' : ''),
          subtitle: '@' + v.handle,
        })))
      : UI.empty(L('ph.soc_no_viewers'), 'focus'));
}

// ── Search ─────────────────────────────────────────────────────
async function socialSearch(appId, query) {
  const epoch = viewEpoch;
  const r = await post('social', { op: 'search', q: query || '', app: appId });
  if (!socialActive(appId, epoch)) return;
  const host = byId('socresults');
  if (!host) return;
  const list = (r && r.accounts) || [];
  host.innerHTML = list.length ? UI.group(list.map((a) =>
    '<button class="row lead socfind" data-who="' + esc(a.handle) + '" type="button">' +
      socAvatar(a, 'socav') +
      // `rmain`/`rt`/`rs`, which is what the row styles are actually called. This said
      // `rowtext`/`rowtitle`/`rowsub` - three classes that appear nowhere in the stylesheet -
      // so the two lines had no layout at all and collapsed into each other: a result read
      // "ss@sss · 0 followers" on one line instead of a name above a handle.
      '<span class="rmain"><span class="rt">' +
        esc(a.displayname || a.handle) + socVerified(a) + '</span>' +
      '<span class="rs">@' + esc(a.handle) + ' · ' + a.followers + ' ' +
        esc(L('ph.soc_followers')) + '</span></span>' +
      (a.me ? '' : '<span class="socfollow' + (a.followed ? ' on' : '') + '" data-follow="' +
        esc(a.handle) + '">' + esc(L(a.followed ? 'ph.soc_unfollow' : 'ph.soc_follow')) + '</span>') +
    '</button>').join('')) : UI.empty(L('ph.soc_no_user'));

  [...host.querySelectorAll('.socfind')].forEach((b) => b.addEventListener('click', (e) => {
    // The follow pill lives inside the row, so it has to claim the tap for itself.
    const pill = e.target.closest('[data-follow]');
    if (pill) { e.stopPropagation(); socialFollow(appId, pill.dataset.follow, pill); return; }
    socialProfile(appId, b.dataset.who);
  }));
}

function socialSearchView(appId) {
  body(
    '<div class="socsearch">' + svg('search') +
      '<input id="socq" autocomplete="off" placeholder="' + esc(L('ph.soc_search_ph')) + '" /></div>' +
    // What people are talking about, above the results: the search tab is where somebody goes
    // when they do not already know what they are looking for.
    '<div id="soctrend"></div>' +
    '<div id="socresults">' + UI.empty(L('ph.loading')) + '</div>'
  );
  socDrawTrending(appId);
  let timer = null;
  byId('socq').addEventListener('input', () => {
    clearTimeout(timer);
    // A keystroke is not a query. Wait for the typing to stop rather than asking the
    // server once per letter.
    timer = setTimeout(() => socialSearch(appId, byId('socq').value.trim()), 220);
  });
  socialSearch(appId, '');
}

// The tags with the most posts behind them in the configured window. Drawn only if there are
// any: an empty "trending" box is worse than none.
async function socDrawTrending(appId) {
  const host = byId('soctrend');
  if (!host) return;
  const d = await post('social', { op: 'trending', app: appId });
  const list = (d && d.trending) || [];
  if (!byId('soctrend')) return;              // the player left while it was in flight
  if (!list.length) { host.innerHTML = ''; return; }

  host.innerHTML = '<div class="grouphead">' + esc(L('ph.soc_trending')) + '</div>' +
    '<div class="seg scroll soctrendrow">' + list.map((t) =>
      '<button type="button" data-tag="' + esc(t.tag) + '">#' + esc(t.tag) +
      '<small>' + t.posts + '</small></button>').join('') + '</div>';
  [...host.querySelectorAll('button')].forEach((b) =>
    b.addEventListener('click', () => socialTagFeed(appId, b.dataset.tag)));
}

async function socialFollow(appId, handle, pill) {
  const r = await post('social', { op: 'follow', handle, app: appId });
  if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return null; }
  ui(r.followed ? 'toggleon' : 'toggleoff');
  if (pill) {
    pill.classList.toggle('on', r.followed);
    pill.textContent = L(r.followed ? 'ph.soc_unfollow' : 'ph.soc_follow');
  }
  return r;
}

// ── A profile ──────────────────────────────────────────────────
async function socialProfile(appId, handle) {
  const epoch = beginView();
  SOC.tab[appId] = 'me';
  SOC.handle[appId] = handle || '';
  loading();
  const r = await post('social', { op: 'profile', handle: handle || '', app: appId });
  if (!socialActive(appId, viewEpoch)) return;
  if (!r || r.error) { body(UI.empty(L('ph.err_' + ((r && r.error) || 'x')), APP_ICON[appId])); return; }

  const a = r.account, c = r.counts || {};
  const grid = appId === 'snap';
  const posts = r.posts || [];

  body(
    // The cover banner, and only when there is one: an empty grey strip above every profile
    // would cost the header its shape for nothing.
    (a.cover ? '<div class="soccover" style="' + inlineBackground(a.cover) + '"></div>' : '') +
    '<div class="socprof' + (a.cover ? ' hascover' : '') + '">' + socAvatar(a, 'socbigav') +
      '<div class="socname' + (a.verified ? ' isverified' : '') + '">' +
        esc(a.displayname || a.handle) + socVerified(a) + '</div>' +
      '<div class="sochandle">@' + esc(a.handle) + '</div>' +
      // Said in words on the profile, not only as a badge. A blue tick is a convention the
      // reader has to already know; the line under it is what makes an account visibly
      // official to somebody who has never seen one before.
      (a.verified ? '<div class="socverifline">' + svg('check') + '<span>' +
        esc(L('ph.soc_verified')) + '</span></div>' : '') +
      (a.bio ? '<div class="socbio">' + esc(a.bio) + '</div>' : '') +
      '<div class="soccounts">' +
        '<span><b>' + (c.posts || 0) + '</b>' + esc(L('ph.soc_posts')) + '</span>' +
        '<span><b>' + (c.followers || 0) + '</b>' + esc(L('ph.soc_followers')) + '</span>' +
        '<span><b>' + (c.following || 0) + '</b>' + esc(L('ph.soc_following_count')) + '</span>' +
      '</div>' +
      (r.me ? '<button class="socedit" id="socedit" type="button">' + esc(L('ph.soc_edit')) + '</button>' +
              '<button class="socedit" id="socsaved" type="button">' + esc(L('ph.soc_saved')) + '</button>'
            : '<div class="socprofacts">' +
                '<button class="socbig' + (r.followed ? ' on' : '') + '" id="socfollow" type="button">' +
                  esc(L(r.followed ? 'ph.soc_unfollow' : 'ph.soc_follow')) + '</button>' +
                '<button class="socbig plain" id="socdm" type="button">' +
                  esc(L('ph.soc_message')) + '</button></div>') +
    '</div>' +
    (posts.length
      ? (grid ? '<div class="socgrid">' + posts.map((p) =>
            '<button class="socthumb" data-id="' + p.id + '" style="' +
              inlineBackground(p.image) + '" type="button"></button>').join('') + '</div>'
          : posts.map((p) => postCard(p, appId)).join(''))
      : UI.empty(L('ph.soc_no_posts'), APP_ICON[appId]))
  );
  pushAnim();

  if (r.me) byId('socedit').addEventListener('click', () => socialEdit(appId, a));
  if (r.me) byId('socsaved').addEventListener('click', () => socialSaved(appId));
  else {
    byId('socfollow').addEventListener('click', () => socialFollow(appId, a.handle, byId('socfollow')));
    byId('socdm').addEventListener('click', () => socialDmThread(appId, a.handle));
  }
  if (grid) rows('.socthumb', (b) => b.addEventListener('click', () => {
    const one = posts.find((p) => String(p.id) === b.dataset.id);
    if (!one) return;
    sheet(L('app.snap'), '<div class="socone">' + postCard(one, appId) + '</div>', () => {
      wirePosts(appId, () => socialRender(appId));
    });
  }));
  else wirePosts(appId, () => socialProfile(appId, handle));
}

function socialEdit(appId, account) {
  sheet(L('ph.soc_edit'),
    UI.field('socdn', L('ph.soc_displayname'), account.displayname || '', 'maxlength="40"') +
    UI.field('socav', L('ph.soc_avatar'), account.avatar || '', 'maxlength="300"') +
    UI.button(L('ph.soc_pick_avatar'), 'socavpick', 'plain') +
    UI.field('soccov', L('ph.soc_cover'), account.cover || '', 'maxlength="300"') +
    UI.button(L('ph.soc_pick_cover'), 'soccovpick', 'plain') +
    UI.field('socbio', L('ph.soc_bio'), account.bio || '', 'maxlength="160"') +
    UI.button(L('ph.save'), 'socsave'),
    () => {
      const epoch = sheetEpoch;
      // One picker per picture, each named for the one it fills.
      //
      // There was a single button labelled "choose a photo" between the two fields, and it
      // filled the COVER - so the obvious way to set a profile picture set the banner instead,
      // and the only route to an avatar was pasting a URL. Two fields need two buttons, and a
      // button that fills one of two fields has to say which.
      byId('socavpick').addEventListener('click', () =>
        pickPhoto((url) => { byId('socav').value = url; }));
      byId('soccovpick').addEventListener('click', () =>
        pickPhoto((url) => { byId('soccov').value = url; }));
      byId('socsave').addEventListener('click', async () => {
        const r = await post('social', { op: 'setup', app: appId,
          displayname: byId('socdn').value, avatar: byId('socav').value,
          cover: byId('soccov').value, bio: byId('socbio').value });
        if (!r || !r.ok) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return; }
        if (!closeSheet(false, epoch)) return;
        socialAcc[appId] = r.account;
        ui('success');
        socialProfile(appId, '');
      });
    });
}

// ── Direct messages ────────────────────────────────────────────
async function socialDmList(appId) {
  const epoch = viewEpoch;
  loading();
  const r = await post('social', { op: 'dmList', app: appId });
  if (!socialActive(appId, epoch)) return;
  const threads = (r && r.threads) || [];
  body(threads.length ? UI.group(threads.map((t) =>
    '<button class="row lead socdmrow" data-who="' + esc(t.handle) + '" type="button">' +
      socAvatar(t, 'socav') +
      '<span class="rmain"><span class="rt">' + esc(t.displayname || t.handle) + socVerified(t) + '</span>' +
      '<span class="rs">' + esc((t.mine ? L('ph.you') + ' ' : '') + (t.body || L('ph.photo'))) + '</span></span>' +
      (t.unread ? '<span class="socunread">' + t.unread + '</span>' : '') +
    '</button>').join('')) : UI.empty(L('ph.soc_no_dm'), 'messages'));
  rows('.socdmrow', (b) => b.addEventListener('click', () => socialDmThread(appId, b.dataset.who)));
}

async function socialDmThread(appId, handle) {
  const epoch = beginView();
  loading();
  const r = await post('social', { op: 'dmThread', handle, app: appId });
  if (!socialActive(appId, viewEpoch)) return;
  if (!r || r.error) { body(UI.empty(L('ph.err_' + ((r && r.error) || 'x')), 'messages')); return; }

  // Back goes to the thread list, not out of the app: this is a screen deeper, and the
  // navigation bar should say so.
  setNav('@' + handle, L('app.' + appId), null, () => { SOC.tab[appId] = 'dm'; socialRender(appId); });
  const bubbles = (r.messages || []).map((m) =>
    '<div class="bub ' + (m.mine ? 'me' : 'them') + '">' +
      (m.image ? '<img class="bubimg" src="' + esc(m.image) + '" alt="" />' : '') +
      (m.body ? '<span>' + esc(m.body) + '</span>' : '') + '</div>').join('');
  body('<div class="bubs" id="socbubs">' + (bubbles || UI.empty(L('ph.soc_dm_start'))) + '</div>');
  foot(
    '<div class="comform dmform">' +
      '<input id="dmtext" maxlength="500" placeholder="' + esc(L('ph.message')) + '" />' +
      '<button id="dmemoji" type="button" aria-label="' + esc(L('ph.emoji')) + '">😊</button>' +
      '<button id="dmphoto" type="button" aria-label="' + esc(L('ph.pick_photo')) + '">' + svg('images') + '</button>' +
      '<button id="dmgo" type="button" aria-label="' + esc(L('ph.send')) + '">' + svg('send') + '</button>' +
    '</div>');
  byId('appbody').scrollTop = byId('appbody').scrollHeight;

  const send = async (payload) => {
    const r2 = await post('social', Object.assign({ op: 'dmSend', handle, app: appId }, payload));
    if (!r2 || !r2.ok) { toast(L('ph.err_' + ((r2 && r2.error) || 'x'))); return; }
    ui('sent');
    socialDmThread(appId, handle);
  };
  byId('dmgo').addEventListener('click', () => {
    const value = byId('dmtext').value.trim();
    if (value) send({ body: value });
  });
  byId('dmtext').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const value = byId('dmtext').value.trim();
    if (value) send({ body: value });
  });
  byId('dmemoji').addEventListener('click', () => emojiOpen('dmtext'));
  byId('dmphoto').addEventListener('click', () => pickPhoto((url) => send({ image: url })));
}

// ── The router ─────────────────────────────────────────────────
// One entry point per app: it draws the tab bar, then whichever screen the tab names.
function socialRender(appId) {
  if (!openApp || openApp.id !== appId) return;
  beginView();
  foot('');
  const tabs = appId === 'hush'
    ? [{ id: 'swipe', icon: 'sparkles', label: L('app.hush') },
       { id: 'matches', icon: 'heart', label: L('ph.hush_matches') },
       { id: 'me', icon: 'contacts', label: L('ph.soc_profile') }]
    : [{ id: 'feed', icon: 'home', label: L('ph.soc_feed') },
       // Explore is Snapmatic's: a grid of photographs makes no sense on a text timeline.
       ...(appId === 'snap'
         ? [{ id: 'explore', icon: 'sparkles', label: L('ph.soc_explore') }] : []),
       { id: 'search', icon: 'search', label: L('ph.soc_search') },
       // `badge` is what the tab bar actually renders for this: a dot on the icon. It draws
       // the icon and the label is only an aria-label, so a count put in the text would have
       // been read out by a screen reader and shown to nobody.
       { id: 'notifs', icon: 'bell', label: L('ph.soc_notifs'),
         badge: socUnread[appId] > 0 },
       { id: 'dm', icon: 'messages', label: L('ph.soc_dm') },
       { id: 'me', icon: 'contacts', label: L('ph.soc_profile') }];

  // The count behind the tab label. Asked without blocking the draw: if it comes back
  // different, the tab bar is redrawn on its own rather than holding up the view.
  if (appId !== 'hush') {
    socRefreshUnread(appId).then((changed) => {
      if (changed && openApp && openApp.id === appId) socialRender(appId);
    });
  }

  const composer = appId === 'bleeter' ? bleetCompose : (appId === 'snap' ? snapCompose : null);
  const wantsAdd = composer && SOC.tab[appId] === 'feed';
  setNav(L('app.' + appId), null, wantsAdd ? { icon: 'add', onClick: composer } : null);
  socialTabs(appId, tabs);

  const tab = SOC.tab[appId];
  if (appId === 'hush') {
    if (tab === 'matches') return hushMatches();
    if (tab === 'me') return hushProfile();
    return hushSwipe();
  }
  if (tab === 'explore') return socialExplore(appId);
  if (tab === 'saved') return socialSaved(appId);
  if (tab === 'notifs') return socialNotifs(appId);
  if (tab === 'search') return socialSearchView(appId);
  if (tab === 'dm') return socialDmList(appId);
  if (tab === 'me') return socialProfile(appId, SOC.handle[appId]);
  return socialFeed(appId);
}

// ══ Explore, and what you kept ═════════════════════════════════
// Both are grids of photographs rather than a timeline: the point of either is to scan a lot
// of pictures quickly and open the one you want.
function socGrid(appId, list, emptyKey, reload) {
  if (!list.length) { body(UI.empty(L(emptyKey), APP_ICON[appId])); return; }
  body('<div class="shots socgrid">' + list.map((pst, i) =>
    '<div class="shot" data-gi="' + i + '" style="' +
      inlineBackground(pst.image) + '"></div>').join('') + '</div>');
  // A tile opens the post on its own, where the caption, the likes and the comments are.
  rows('.shot[data-gi]', (el) => el.addEventListener('click', () =>
    socPostSheet(appId, list[Number(el.dataset.gi)], reload)));
}

// One post, full size, with everything the grid left out.
function socPostSheet(appId, pst, reload) {
  if (!pst) return;
  sheet('@' + (pst.handle || ''), '<div id="socone">' + postCard(pst, appId) + '</div>', () => {
    // The card's own handlers, so a like or a save from here behaves as it does in the feed.
    qrows('sheet', '.post .plike', (b) => b.addEventListener('click', async () => {
      const r = await post('social', { op: 'like', id: pst.id, app: appId });
      if (!r || !r.ok) return;
      b.classList.toggle('on', r.liked);
      b.querySelector('span').textContent = r.likes;
      ui(r.liked ? 'toggleon' : 'toggleoff');
    }));
    qrows('sheet', '.post .psave', (b) => b.addEventListener('click', async () => {
      const r = await post('social', { op: 'save', id: pst.id, app: appId });
      if (!r || !r.ok) return;
      b.classList.toggle('on', r.saved);
      toast(L(r.saved ? 'ph.soc_saved_added' : 'ph.soc_saved_removed'));
    }));
    qrows('sheet', '.post .pcomment', (b) => b.addEventListener('click', () =>
      commentSheet(appId, pst.id, b.querySelector('span'))));
    qrows('sheet', '.post .phead', (b) => b.addEventListener('click', () => {
      closeSheet(true);
      socialProfile(appId, b.dataset.who);
    }));
  });
}

async function socialExplore(appId) {
  const epoch = viewEpoch;
  loading();
  const r = await post('social', { op: 'explore', app: appId });
  if (!socialActive(appId, epoch)) return;
  if (!r || r.error) { body(UI.empty(L('ph.err_' + ((r && r.error) || 'x')), APP_ICON[appId])); return; }
  socGrid(appId, r.posts || [], 'ph.soc_no_explore', () => socialExplore(appId));
}

async function socialSaved(appId) {
  const epoch = viewEpoch;
  setNav(L('ph.soc_saved'), L('app.' + appId), null, () => socialRender(appId));
  loading();
  const r = await post('social', { op: 'saved', app: appId });
  if (!socialActive(appId, epoch)) return;
  if (!r || r.error) { body(UI.empty(L('ph.err_' + ((r && r.error) || 'x')), 'star')); return; }
  socGrid(appId, r.posts || [], 'ph.soc_no_saved', () => socialSaved(appId));
}

// ══ Notifications ══════════════════════════════════════════════
// Per app, because a Bleeter like has nothing to do with a Snapmatic one.
const socUnread = { bleeter: 0, snap: 0 };

// Asked whenever a social app is drawn, so the number on the tab is right before anybody
// opens it. One indexed COUNT, not the sixty rows behind it.
async function socRefreshUnread(appId) {
  const r = await post('social', { op: 'notifCount', app: appId });
  const n = (r && r.unread) || 0;
  if (socUnread[appId] === n) return false;
  socUnread[appId] = n;
  return true;
}

function socNotifLine(n) {
  const who = n.displayname || ('@' + n.handle);
  const key = {
    like: 'ph.soc_n_like', comment: 'ph.soc_n_comment', repost: 'ph.soc_n_repost',
    follow: 'ph.soc_n_follow', mention: 'ph.soc_n_mention',
  }[n.kind] || 'ph.soc_n_other';
  return L(key).replace('{who}', who);
}

async function socialNotifs(appId) {
  loading();
  const d = await post('social', { op: 'notifs', app: appId });
  if (!d || d.error) { body(UI.empty(L('ph.err_' + ((d && d.error) || 'x')), 'bell')); return; }

  const list = d.notifs || [];
  if (!list.length) { body(UI.empty(L('ph.soc_no_notifs'), 'bell')); }
  else {
    body(UI.group(list.map((n, i) => UI.row({
      icon: { like: 'heart', comment: 'messages', repost: 'repost',
              follow: 'contacts', mention: 'bleet' }[n.kind] || 'bell',
      tint: { like: '#FF2D55', comment: '#0A84FF', repost: '#34C759',
              follow: '#5856D6', mention: '#FF9F0A' }[n.kind] || '#8E8E93',
      title: socNotifLine(n),
      // The post it happened to, so a like is not just a name with no context.
      subtitle: (n.excerpt || '') + (n.excerpt ? '  ·  ' : '') + socWhen(n.ts * 1000),
      chevron: true,
      data: { ni: String(i) },
    }))));
    rows('.row[data-ni]', (r) => r.addEventListener('click', () => {
      const n = list[Number(r.dataset.ni)];
      if (!n) return;
      // A follow has no post behind it, so it opens the profile instead.
      // The comment sheet IS the single-post view here; its counter argument is optional.
      if (n.postId) commentSheet(appId, n.postId);
      else socialProfile(appId, n.handle);
    }));
  }

  // Opening the tab IS reading them. The count is cleared here rather than per row.
  if (list.some((n) => !n.seen)) {
    await post('social', { op: 'notifSeen', app: appId });
    socUnread[appId] = 0;
    // The dot is taken off the tab directly. Rebuilding the whole tab bar would need the tabs
    // array back, and re-rendering the view would fetch the list a second time to show
    // something the player is already looking at.
    const dot = document.querySelector('#appfoot .soctab[data-tab="notifs"] .socdot');
    if (dot) dot.remove();
  }
}

// ══ Hashtags ═══════════════════════════════════════════════════
// A tag in a body becomes a link, and so does an @handle. Both are built from the ESCAPED
// text, never from the raw body: the linkifier runs after esc(), so a post containing markup
// stays text.
function socLinkify(escaped) {
  return escaped
    .replace(/#([\w\u00C0-\u024F]{2,40})/g, '<button class="soctag" type="button" data-tag="$1">#$1</button>')
    .replace(/@(\w{2,20})/g, '<button class="socmention" type="button" data-who="$1">@$1</button>');
}

async function socialTagFeed(appId, tag) {
  loading();
  setNav('#' + tag, L('app.' + appId), null, () => socialRender(appId));
  const d = await post('social', { op: 'tag', app: appId, tag });
  if (!d || d.error) { body(UI.empty(L('ph.err_' + ((d && d.error) || 'x')), 'bleet')); return; }
  const list = d.posts || [];
  body(list.length
    ? list.map((pst) => postCard(pst, appId)).join('')
    : UI.empty(L('ph.soc_no_tag').replace('{tag}', tag), 'bleet'));
  if (list.length) wirePosts(appId, () => socialTagFeed(appId, tag));
}

// -- Composers --------------------------------------------------
//
// Both composers work the same way, and it is worth stating why, because they did not.
//
// Choosing a photograph used to PUBLISH it, immediately, using whatever text happened to be
// in the field at that moment. So there was no way to write a caption for a picture you had
// already chosen, no way to look at what you were about to post, and no way to change your
// mind. Attaching and publishing are two different decisions and they now have two different
// buttons: pick a photo, see it, write about it, then post.
//
// The `app` is always sent explicitly. The server falls back to `appOfKind`, which answers
// 'snap' for every photograph - so a photo composed in Bleeter and sent without an app
// landed on Snapmatic instead. It was filed correctly from Snapmatic and wrongly from
// Bleeter, which is exactly the shape of the bug that was reported.
function socCompose(appId) {
  const isSnap = appId === 'snap';
  const textId = isSnap ? 'scap' : 'btext';
  let image = '';

  // The attachment, drawn under the field. Repainted in place rather than by rebuilding the
  // sheet, so the caption already typed survives picking - and re-picking - a photograph.
  const paintAttach = () => {
    const host = byId('socattach');
    if (!host) return;
    host.innerHTML = image
      ? '<div class="socattached" style="' + photoStyle(image) + '">' +
          '<button class="socattachx" id="bdrop" type="button" aria-label="' +
            esc(L('ph.remove')) + '">' + svg('xmark') + '</button>' +
        '</div>'
      : '';
    if (image) byId('bdrop').addEventListener('click', () => {
      image = '';
      paintAttach();
      ui('detach');
    });
    const go = byId('bgo');
    // Snapmatic is a photo app: there is nothing to post until one is attached.
    if (go && isSnap) go.disabled = !image;
  };

  sheet(L(isSnap ? 'ph.snap_new' : 'ph.bleet_new'),
    '<div id="socattach"></div>' +
    UI.field(textId, L(isSnap ? 'ph.snap_caption' : 'ph.bleet_ph'), '',
             'maxlength="' + (isSnap ? 140 : 280) + '"') +
    UI.button('😊 ' + L('ph.emoji'), 'bemoji', 'plain') +
    UI.button(L('ph.pick_photo'), 'bpick', 'plain') +
    UI.button(L(isSnap ? 'ph.snap_share' : 'ph.bleet_send'), 'bgo'),
    () => {
      byId('bemoji').addEventListener('click', () => emojiOpen(textId));
      byId('bpick').addEventListener('click', () => pickPhoto((url) => {
        image = url;
        paintAttach();
        ui('attach');
      }));
      byId('bgo').addEventListener('click', async () => {
        const bodyText = byId(textId).value;
        // Nothing at all to send: say so here rather than making the server answer 'empty'.
        if (!image && bodyText.replace(/\s/g, '') === '') {
          toast(L(isSnap ? 'ph.snap_needphoto' : 'ph.err_empty'));
          return;
        }
        const epoch = sheetEpoch;
        const r = await post('social', {
          op: 'post', app: appId,
          kind: image ? 'photo' : 'text',
          body: bodyText, image,
        });
        if (!closeSheet(false, epoch)) return;
        if (r && r.ok) { ui('sent'); socialRender(appId); }
        else toast(L('ph.err_' + ((r && r.error) || 'x')));
      });
      paintAttach();
    });
}

function bleetCompose() { socCompose('bleeter'); }
function snapCompose() {
  // Snapmatic posts photographs, so an empty gallery is a dead end worth naming up front
  // rather than after somebody has written a caption.
  if (!(state.photos || []).length) { toast(L('ph.snap_noshots')); return; }
  socCompose('snap');
}

RENDER.bleeter = () => needAccount('bleeter', () => socialRender('bleeter'));
RENDER.snap = () => needAccount('snap', () => socialRender('snap'));
RENDER.hush = () => needAccount('hush', () => socialRender('hush'));

// -- Hush -------------------------------------------------------
// The deck. One card at a time, thrown left or right - by the buttons, or by dragging
// it, which is the gesture the whole genre is built on.
async function hushSwipe() {
  const epoch = viewEpoch;
  loading();
  const me = await post('social', { op: 'hushMe' });
  if (!socialActive('hush', epoch)) return;
  if (!me || me.error) { body(UI.empty(L('ph.err_' + ((me && me.error) || 'off')), 'hush')); return; }
  if (!me.profile) { hushOnboard(); return; }

  const r = await post('social', { op: 'hushNext' });
  if (!socialActive('hush', epoch)) return;
  if (!r || r.error) { body(UI.empty(L('ph.err_' + ((r && r.error) || 'x')), 'hush')); return; }
  const pf = r.profile;
  if (!pf) { body(UI.empty(L('ph.hush_empty'), 'hush')); return; }

  // Up to three photographs, tapped through. `photos` is what the server sends now; `photo`
  // alone is what an older row has, so both are accepted.
  const photos = (pf.photos && pf.photos.length) ? pf.photos : (pf.photo ? [pf.photo] : []);
  let shot = 0;

  body(
    '<div class="hushdeck">' +
      '<div class="hushcard" id="hcard">' +
        '<div class="hphoto" id="hphoto"' +
          (photos[0] ? ' style="' + inlineBackground(photos[0]) + '"' : '') + '>' +
          // Which of the photographs is showing, in the bars Tinder puts across the top.
          (photos.length > 1
            ? '<div class="hbars" id="hbars">' + photos.map((_, i) =>
                '<i class="' + (i === 0 ? 'on' : '') + '"></i>').join('') + '</div>'
            : '') +
          '<span class="hstamp yes">' + esc(L('ph.like')) + '</span>' +
          '<span class="hstamp no">' + esc(L('ph.pass')) + '</span>' +
          // They already super liked you. Shown BEFORE the swipe, which is the entire point of
          // a super like - after the fact it would just be trivia.
          (pf.superOnMe ? '<div class="hsuperflag">' + svg('star') +
            esc(L('ph.hush_super_you')) + '</div>' : '') +
          '<div class="hmeta">' +
            '<div class="hname">' + esc(pf.name || '?') + (pf.age ? ', ' + pf.age : '') + '</div>' +
            // Rounded to ten metres by the server; nil when they are not connected, and then
            // nothing is claimed at all.
            (pf.distance !== undefined && pf.distance !== null
              ? '<div class="hdist">' + svg('location') +
                esc(hushDistanceText(pf.distance)) + '</div>' : '') +
            (pf.bio ? '<div class="hbio">' + esc(pf.bio) + '</div>' : '') +
          '</div>' +
        '</div>' +
      '</div>' +
    '</div>' +
    '<div class="hushrow">' +
      '<button class="hushbtn back" id="hback" type="button" aria-label="' +
        esc(L('ph.hush_rewind')) + '">' + svg('refresh') + '</button>' +
      '<button class="hushbtn no" id="hno" type="button" aria-label="' +
        esc(L('ph.pass')) + '">' + svg('xmark') + '</button>' +
      '<button class="hushbtn super" id="hsuper" type="button" aria-label="' +
        esc(L('ph.hush_super')) + '">' + svg('star') + '</button>' +
      '<button class="hushbtn yes" id="hyes" type="button" aria-label="' +
        esc(L('ph.like')) + '">' + svg('heart') + '</button>' +
    '</div>'
  );
  pushAnim();

  // Tap the photograph to see the next one. Deliberately a tap and not a swipe: a swipe on
  // this card already means yes or no, and one gesture cannot mean two things.
  if (photos.length > 1) {
    byId('hphoto').addEventListener('click', () => {
      shot = (shot + 1) % photos.length;
      const el = byId('hphoto');
      el.setAttribute('style', inlineBackground(photos[shot]));
      [...byId('hbars').children].forEach((b, i) => b.classList.toggle('on', i === shot));
    });
  }

  byId('hback').addEventListener('click', async () => {
    const r2 = await post('social', { op: 'hushRewind' });
    if (!r2 || !r2.ok) { toast(L('ph.err_' + ((r2 && r2.error) || 'x'))); return; }
    ui('toggleon');
    toast(L('ph.hush_rewound'));
    hushSwipe();
  });

  const choose = async (like, superLike) => {
    const card = byId('hcard');
    if (card) {
      card.classList.add(like ? 'flyright' : 'flyleft');
      ui(like ? 'toggleon' : 'toggleoff');
    }
    const c = await post('social', { op: 'hushChoice', ref: pf.ref, like, super: !!superLike });
    if (c && c.error) {
      // A refused super like must NOT count as a swipe: the card has to come back, so the
      // player can still pass or like normally instead of losing the profile to a cap.
      if (card) card.classList.remove('flyright', 'flyleft');
      toast(L('ph.err_' + ((c && c.error) || 'x')));
      return;
    }
    if (c && c.match) {
      ui('success');
      // The match moment, on the card rather than in a banner that slides away: this is the
      // one thing on the app both sides asked for, and it deserves to be looked at.
      hushMatchSheet(c);
      return;
    }
    setTimeout(() => { if (socialActive('hush', epoch)) hushSwipe(); }, 240);
  };
  byId('hno').addEventListener('click', () => choose(false));
  byId('hyes').addEventListener('click', () => choose(true));
  byId('hsuper').addEventListener('click', () => choose(true, true));
  wireHushDrag(byId('hcard'), choose);
}

// "It's a match". A sheet rather than a banner: a banner slides away while somebody is still
// reading it, and this is the moment the whole app exists for.
function hushMatchSheet(c) {
  sheet(L('ph.hush_match'),
    '<div class="hushmatch">' +
      '<div class="hmtitle">' + esc(L('ph.hush_match_line').replace('{name}', c.name || '?')) + '</div>' +
      (c.super ? '<div class="hmsuper">' + svg('star') + esc(L('ph.hush_super_sent')) + '</div>' : '') +
      (c.number ? '<div class="hmnum">' + esc(maskNum(c.number)) + '</div>' : '') +
    '</div>' +
    (c.number ? UI.button(L('ph.hush_say_hi'), 'hmsay', 'tinted') : '') +
    UI.button(L('ph.hush_keep_swiping'), 'hmnext', 'plain'),
    () => {
      const epoch2 = sheetEpoch;
      if (byId('hmsay')) byId('hmsay').addEventListener('click', () => {
        if (!closeSheet(false, epoch2)) return;
        // Straight into the conversation the match already created on both phones.
        const app = (state.apps || []).find((x) => x.id === 'messages');
        messageTo(c.number);
      });
      byId('hmnext').addEventListener('click', () => {
        if (!closeSheet(false, epoch2)) return;
        hushSwipe();
      });
    });
}

// Drag the card and it follows the finger, tilting as it goes; let go past the
// threshold and it is a choice. Anything short of that springs back, so a hesitant
// swipe is never counted as an answer.
function wireHushDrag(card, choose) {
  if (!card) return;
  let start = null;
  const THRESHOLD = 88;

  card.addEventListener('pointerdown', (e) => {
    start = { x: e.clientX, id: e.pointerId };
    card.classList.add('dragging');
    if (card.setPointerCapture) { try { card.setPointerCapture(e.pointerId); } catch {} }
  });
  card.addEventListener('pointermove', (e) => {
    if (!start || start.id !== e.pointerId) return;
    const dx = e.clientX - start.x;
    card.style.transform = 'translateX(' + dx + 'px) rotate(' + (dx / 22) + 'deg)';
    card.classList.toggle('wantyes', dx > 30);
    card.classList.toggle('wantno', dx < -30);
  });
  const release = (e) => {
    if (!start || start.id !== e.pointerId) return;
    const dx = e.clientX - start.x;
    start = null;
    card.classList.remove('dragging', 'wantyes', 'wantno');
    card.style.removeProperty('transform');
    if (Math.abs(dx) > THRESHOLD) choose(dx > 0);
  };
  card.addEventListener('pointerup', release);
  card.addEventListener('pointercancel', () => {
    start = null;
    card.classList.remove('dragging', 'wantyes', 'wantno');
    card.style.removeProperty('transform');
  });
}

// Hush has its own profile, because who you are to a date is not who you are to the
// whole network.
function hushOnboard() {
  body(
    UI.field('hbio', L('ph.hush_bio'), '', 'maxlength="160"') +
    UI.field('hphoto', L('ph.hush_photo'), '', 'maxlength="300"') +
    UI.button(L('ph.pick_photo'), 'hpick', 'plain') +
    UI.button(L('ph.hush_join'), 'hgo') +
    '<div class="groupfoot">' + esc(L('ph.hush_hint')) + '</div>'
  );
  byId('hpick').addEventListener('click', () => pickPhoto((url) => { byId('hphoto').value = url; }));
  byId('hgo').addEventListener('click', async () => {
    const r = await post('social', { op: 'hushSetup',
      bio: byId('hbio').value, photo: byId('hphoto').value, active: true });
    if (r && r.ok) { ui('success'); socialRender('hush'); }
    else toast(L('ph.err_' + ((r && r.error) || 'x')));
  });
}

async function hushMatches() {
  const epoch = viewEpoch;
  loading();
  const r = await post('social', { op: 'hushMatches' });
  if (!socialActive('hush', epoch)) return;
  if (!r || r.error) { body(UI.empty(L('ph.err_' + ((r && r.error) || 'x')), 'hush')); return; }
  const list = r.matches || [];
  body(list.length ? UI.group(list.map((m, i) =>
    '<button class="row lead hushmatch" data-i="' + i + '" type="button">' +
      (m.photo ? '<span class="socav" style="' + inlineBackground(m.photo) + '"></span>'
               : '<span class="socav">' + esc(String(m.name || '?').slice(0, 1)) + '</span>') +
      '<span class="rmain"><span class="rt">' +
        esc(m.name || '?') + (m.age ? ', ' + m.age : '') + '</span>' +
      '<span class="rs">' + esc(m.bio || m.number || '') + '</span></span>' +
      svg('chevron') +
    '</button>').join('')) : UI.empty(L('ph.hush_no_matches'), 'hush'));

  // A match is somebody you already swapped numbers with, so the useful thing to do
  // with one is call or write to them.
  rows('.hushmatch', (b) => b.addEventListener('click', () => {
    const m = list[Number(b.dataset.i)];
    if (!m || !m.number) { toast(L('ph.hush_no_number')); return; }
    sheet(m.name || '?',
      UI.row({ icon: 'phone', title: L('ph.call'), value: m.number, data: { act: 'call' } }) +
      UI.row({ icon: 'messages', title: L('ph.message'), data: { act: 'sms' } }) +
      UI.button(L('ph.hush_unmatch'), 'hunmatch', 'neg'),
      () => {
        const epoch2 = sheetEpoch;
        [...byId('sheet').querySelectorAll('[data-act]')].forEach((el) =>
          el.addEventListener('click', () => {
            if (!closeSheet(false, epoch2)) return;
            if (el.dataset.act === 'call') { placeCall(m.number); return; }
            const messages = (state.apps || []).find((a) => a.id === 'messages');
            if (!messages) return;
            enterApp(messages, null);
            messageTo(m.number);
          }));
        // Confirmed, because it lands on both phones: the match is gone for the other person
        // too, and neither of them can put it back.
        byId('hunmatch').addEventListener('click', () => {
          if (!closeSheet(false, epoch2)) return;
          confirmSheet(L('ph.hush_unmatch_ask'), L('ph.hush_unmatch'), async () => {
            const r2 = await post('social', { op: 'hushUnmatch', ref: m.ref });
            if (!r2 || !r2.ok) { toast(L('ph.err_' + ((r2 && r2.error) || 'x'))); return; }
            ui('toggleoff');
            hushMatches();
          });
        });
      });
  }));
}

async function hushProfile() {
  const epoch = viewEpoch;
  loading();
  const me = await post('social', { op: 'hushMe' });
  if (!socialActive('hush', epoch)) return;
  if (!me || me.error) { body(UI.empty(L('ph.err_' + ((me && me.error) || 'off')), 'hush')); return; }
  const pf = me.profile || { bio: '', photo: '', active: true };

  // Who I am, and who I want to see. `seeking` defaults to everybody, because a default that
  // narrows the deck without being asked to is a bug that looks like an empty app.
  let gender = (pf.gender === 'm' || pf.gender === 'f') ? pf.gender : '';
  let seeking = (pf.seeking === 'm' || pf.seeking === 'f') ? pf.seeking : 'all';

  const segRow = (name, value, options) =>
    '<div class="seg" data-seg="' + name + '">' + options.map((o) =>
      '<button type="button" data-v="' + o.v + '"' +
        (o.v === value ? ' class="on"' : '') + '>' + esc(o.t) + '</button>').join('') + '</div>';

  body(
    '<div class="socprof">' +
      (pf.photo ? '<span class="socbigav" style="' + inlineBackground(pf.photo) + '"></span>'
                : '<span class="socbigav">' + svg('hush') + '</span>') +
      '<div class="socbio">' + esc(pf.bio || L('ph.hush_nobio')) + '</div>' +
    '</div>' +
    UI.field('hbio', L('ph.hush_bio'), pf.bio || '', 'maxlength="160"') +
    // Three photographs. The first is the one the card opens on; the others are tapped through.
    '<div class="stsection">' + esc(L('ph.hush_photos')) + '</div>' +
    [1, 2, 3].map((n) => {
      const id = n === 1 ? 'hphoto' : 'hphoto' + n;
      const value = n === 1 ? (pf.photo || '') : (pf['photo' + n] || '');
      return UI.field(id, L('ph.hush_photo_n').replace('{n}', String(n)), value,
                      'maxlength="300"') +
        UI.button(L('ph.pick_photo'), 'hpick' + n, 'plain');
    }).join('') +
    '<div class="stsection">' + esc(L('ph.hush_iam')) + '</div>' +
    segRow('gender', gender, [{ v: '', t: L('ph.hush_unsaid') },
                              { v: 'm', t: L('ph.hush_man') },
                              { v: 'f', t: L('ph.hush_woman') }]) +
    '<div class="stsection">' + esc(L('ph.hush_seeking')) + '</div>' +
    segRow('seeking', seeking, [{ v: 'all', t: L('ph.hush_everyone') },
                                { v: 'm', t: L('ph.hush_men') },
                                { v: 'f', t: L('ph.hush_women') }]) +
    '<div class="stsection">' + esc(L('ph.hush_agerange')) + '</div>' +
    '<div class="hushage">' +
      UI.field('hmin', L('ph.hush_min_age'), String(pf.minAge || 18),
               'type="number" min="18" max="99"') +
      UI.field('hmax', L('ph.hush_max_age'), String(pf.maxAge || 99),
               'type="number" min="18" max="99"') +
    '</div>' +
    UI.group(UI.row({ appicon: 'hush', title: L('ph.hush_active'),
                      toggle: pf.active !== false, data: { t: 'active' } })) +
    '<div class="groupfoot">' + esc(L('ph.hush_active_hint')) + '</div>' +
    UI.button(L('ph.save'), 'hsave')
  );

  let active = pf.active !== false;
  [1, 2, 3].forEach((n) => byId('hpick' + n).addEventListener('click', () =>
    pickPhoto((url) => { byId(n === 1 ? 'hphoto' : 'hphoto' + n).value = url; })));
  rows('.seg[data-seg] button', (b) => b.addEventListener('click', () => {
    const group = b.closest('.seg');
    [...group.children].forEach((x) => x.classList.remove('on'));
    b.classList.add('on');
    if (group.dataset.seg === 'gender') gender = b.dataset.v; else seeking = b.dataset.v;
    ui('key');
  }));
  // The kit's switch is a styled span, not a checkbox, so the row owns the state.
  rows('.row[data-t="active"]', (el) => el.addEventListener('click', () => {
    active = !active;
    const knob = el.querySelector('.sw');
    if (knob) knob.classList.toggle('on', active);
    ui(active ? 'toggleon' : 'toggleoff');
  }));
  byId('hsave').addEventListener('click', async () => {
    const r = await post('social', { op: 'hushSetup',
      bio: byId('hbio').value, photo: byId('hphoto').value,
      photo2: byId('hphoto2').value, photo3: byId('hphoto3').value,
      gender, seeking,
      minAge: Number(byId('hmin').value) || 18, maxAge: Number(byId('hmax').value) || 99,
      active });
    if (r && r.ok) { ui('success'); toast(L('ph.saved')); }
    else toast(L('ph.err_' + ((r && r.error) || 'x')));
  });
}


// ══ Sound ══════════════════════════════════════════════════════
// Tones are made here rather than shipped: the built-ins are a few oscillator notes, so
// the resource carries no audio files and nothing is fetched at all unless a player has
// pointed a tone at their own MP3. That link is host-gated on the server.
let AC = null;
function audio() {
  if (!AC) { try { AC = new (window.AudioContext || window.webkitAudioContext)(); } catch { AC = false; } }
  if (AC && AC.state === 'suspended') AC.resume();
  return AC || null;
}

// One note. `t` is an offset in seconds so a tone can be written as a little score.
function note(freq, t, dur, gain, type) {
  const ac = audio(); if (!ac) return;
  const o = ac.createOscillator(), g = ac.createGain();
  o.type = type || 'sine';
  o.frequency.value = freq;
  const at = ac.currentTime + t;
  g.gain.setValueAtTime(0, at);
  g.gain.linearRampToValueAtTime(gain, at + 0.012);
  g.gain.exponentialRampToValueAtTime(0.0001, at + dur);
  o.connect(g); g.connect(ac.destination);
  o.start(at); o.stop(at + dur + 0.02);
}

/// The hiss of a line breaking up.
///
/// Real noise, not a tone: filtered white noise is what interference sounds like, and no
/// arrangement of oscillators gets close. Short, quiet, and it respects the ring volume - this
/// is an effect, not an alert, so a player who turned the phone down does not want it either.
function callStatic() {
  const ac = audio(); if (!ac) return;
  const vol = (state.prefs || {}).ringVolume;
  const v = (vol == null ? 0.7 : Number(vol)) * 0.22;
  if (v <= 0) return;

  const seconds = 0.28;
  const frames = Math.floor(ac.sampleRate * seconds);
  const buffer = ac.createBuffer(1, frames, ac.sampleRate);
  const data = buffer.getChannelData(0);
  for (let i = 0; i < frames; i += 1) data[i] = Math.random() * 2 - 1;

  const src = ac.createBufferSource();
  src.buffer = buffer;
  // Band-limited, because full-spectrum white noise is a burst of sand rather than a radio.
  const band = ac.createBiquadFilter();
  band.type = 'bandpass';
  band.frequency.value = 1400;
  band.Q.value = 0.7;
  const g = ac.createGain();
  const now = ac.currentTime;
  g.gain.setValueAtTime(0, now);
  g.gain.linearRampToValueAtTime(v, now + 0.02);
  g.gain.exponentialRampToValueAtTime(0.0001, now + seconds);
  src.connect(band); band.connect(g); g.connect(ac.destination);
  src.start(now);
  src.stop(now + seconds);
}

// Each built-in is a short score: [frequency, start, length].
const TONES = {
  classic: [[880, 0, .16], [1175, .18, .16], [880, .36, .16], [1175, .54, .26]],
  chime:   [[1319, 0, .5], [1568, .12, .5], [2093, .24, .7]],
  pulse:   [[440, 0, .1], [440, .14, .1], [440, .28, .1], [660, .42, .3]],
  radar:   [[523, 0, .22], [659, .22, .22], [784, .44, .22], [1047, .66, .4]],
  ping:    [[1568, 0, .18], [2093, .07, .22]],
  pop:     [[880, 0, .09], [1320, .05, .12]],
  tick:    [[1200, 0, .05]],
};

let ringEl = null;      // the <audio> for a custom link, so it can be stopped
let ringTimer = null;

function stopTone() {
  if (ringEl) { try { ringEl.pause(); } catch {} ringEl = null; }
  clearInterval(ringTimer); ringTimer = null;
}

// The tones the resource ships as real files. They are GENERATED, not sampled - see
// tools/make-sounds.py - and they sound better than a bare oscillator because they carry
// harmonics and a real envelope. Anything that fails to load falls back to the
// synthesised score, so a server that deleted the folder still has a phone that rings.
const SOUND_BASE = 'https://cfx-nui-v-phone/sounds/';
const SOUND_FILES = {
  ring: { classic: 1, chime: 1, pulse: 1, radar: 1, signal: 1 },
  alert: { ping: 1, pop: 1, tick: 1, note: 1 },
  ui: { unlock: 1, lock: 1, success: 1, error: 1, shutter: 1, boothkey: 1, boothkeyback: 1,
        alert911: 1 },
};
let soundsOff = false;   // set once a file has failed, so we stop asking every ring

function soundUrl(kind, name) {
  if (soundsOff || state.soundFiles === false) return null;
  return (SOUND_FILES[kind] || {})[name] ? SOUND_BASE + kind + '_' + name + '.wav' : null;
}

function synth(name, gain) {
  const score = TONES[name] || TONES.classic;
  score.forEach(([f, t, d]) => note(f, t, d, gain, 'sine'));
}

// Play one pass of a tone. A player's own link wins, then the shipped file, then the
// synthesised score. `loop` keeps the element so a ringtone can be stopped.
function playTone(name, url, vol, loop) {
  const p = state.prefs || {};
  const v = vol == null ? (p.ringVolume ?? 0.7) : vol;
  if (v <= 0 || name === 'none') return;

  const src = url || soundUrl('ring', name) || soundUrl('alert', name);
  if (src) {
    try {
      const el = new Audio(src);
      el.volume = Math.max(0, Math.min(1, v));
      el.loop = !!loop;
      // A missing or blocked file must not leave the phone silent.
      el.addEventListener('error', () => {
        if (!url) soundsOff = true;
        synth(name, 0.12 * v);
      }, { once: true });
      el.play().catch(() => {});
      if (loop) ringEl = el;
      return;
    } catch { /* fall through to the built-in */ }
  }
  synth(name, 0.12 * v);
}

// A call rings until it is answered or gives up.
function playRingtone() {
  const p = state.prefs || {};
  stopTone();
  if (p.dnd) return;
  const name = p.ringtone || 'classic', url = p.ringUrl || null;
  playTone(name, url, p.ringVolume, true);
  if (!url) {
    playTone(name, null, p.ringVolume, false);
    ringTimer = setInterval(() => playTone(name, null, p.ringVolume, false), 1600);
  }
}
function stopRingtone() { stopTone(); }

// Everything that is not a call: a message, a mail, a notification.
function playAlert() {
  const p = state.prefs || {};
  if (p.dnd) return;
  playTone(p.alertTone || 'ping', p.alertUrl || null, p.ringVolume, false);
}

// ── Interface sounds ───────────────────────────────────────────
// The small ones: the lock, a key, a switch, a sent message. They are not
// notifications, so Do Not Disturb leaves them alone - the same way iOS keeps the lock
// sound and the keyboard clicks under the ringer, not under the moon. Turning the
// volume down to nothing is what silences them.
//
// Each entry is a score of [frequency, start, length], like the ringtones, and every
// one is deliberately under a fifth of a second: a sound you notice twice is a sound
// you end up hating.
const UI_TONES = {
  unlock:   [[1046, 0, .09], [1568, .05, .14]],
  lock:     [[784, 0, .07], [523, .05, .13]],
  key:      [[2200, 0, .022]],
  keyback:  [[1400, 0, .03]],
  toggleon: [[1318, 0, .05], [1760, .04, .08]],
  toggleoff:[[1046, 0, .05], [784, .04, .09]],
  appopen:  [[1174, 0, .05], [1568, .04, .09]],
  appclose: [[1174, 0, .05], [880, .04, .08]],
  sheet:    [[1046, 0, .06]],
  sent:     [[1568, 0, .06], [2349, .05, .12]],
  received: [[2093, 0, .06], [1568, .06, .12]],
  shutter:  [[2400, 0, .02], [1200, .03, .05]],
  success:  [[1318, 0, .08], [1760, .07, .1], [2637, .15, .18]],
  error:    [[311, 0, .11], [233, .1, .18]],
  faceid:   [[1760, 0, .07], [2349, .06, .09], [2793, .13, .16]],
  // The WEA attention signal: 853 Hz and 960 Hz TOGETHER, twice. The two are close enough to
  // beat against each other instead of blending, and that roughness is the whole design - a
  // pleasant interval is one people learn to ignore. Deliberately the least pleasant sound the
  // phone makes, because it is the only one that means "stop what you are doing".
  emergency: [[853, 0, .9], [960, 0, .9], [853, 1.0, .9], [960, 1.0, .9]],
  // The 911 dispatch tone, for a server running with sound files off. Deliberately NOT the
  // one above: that warns a whole city and is meant to be alarming, this lands on the phone of
  // somebody at work, all evening. Unmistakable on the first note, bearable on the fiftieth -
  // so the two-tone siren fourth, played clean. Kept in step with tools/make-sounds.py.
  alert911: [[580, 0, .26], [435, .24, .26], [580, .5, .26], [435, .74, .34]],
  // ── The quiet half of the phone ────────────────────────────
  // Everything below is an action that used to happen in silence. None of them is a fanfare:
  // a phone that chimes at every touch is a phone people mute, so these are all short, low and
  // clearly subordinate to the ones above - a confirmation, not an announcement.
  //
  // Written as scores rather than files: at forty milliseconds a synthesised note and a sampled
  // one are indistinguishable, and a file per interaction would be a download per interaction.
  swipe:    [[520, 0, .035]],                              // a card thrown away
  refresh:  [[880, 0, .04], [1174, .035, .07]],            // a list pulled to reload
  attach:   [[1046, 0, .04], [1318, .03, .07]],            // a photo joined to something
  detach:   [[1318, 0, .04], [880, .03, .07]],             // and taken back off
  send:     [[1318, 0, .05], [1760, .04, .09], [2093, .09, .13]],   // a mail, a post
  copy:     [[1568, 0, .03], [2093, .025, .055]],          // something on the clipboard
  install:  [[880, 0, .06], [1318, .05, .10], [1760, .10, .16]],    // an app arrives
  uninstall:[[1318, 0, .06], [880, .05, .12]],             // and leaves
  money:    [[1046, 0, .05], [1568, .04, .09], [1318, .09, .14]],   // a payment went through
  folder:   [[740, 0, .04], [988, .03, .07]],              // a folder opens
  waypoint: [[1174, 0, .04], [1568, .035, .08]],           // a marker set on the map
  delete:   [[440, 0, .05], [330, .045, .10]],             // something removed for good
  // A call that cannot connect. This is the REORDER tone - what a telephone network has
  // answered a dead number with for sixty years - and it is deliberately not one of the
  // pleasant little chimes above: 480 Hz and 620 Hz together, three short bursts, ending
  // abruptly. The dissonance is the point. A player hears it and knows the call is over
  // without reading anything, which is what a line of grey text could never do.
  //
  // The two frequencies are sounded as separate notes because that is what the score format
  // allows, and two oscillators at once IS the beat: 620 - 480 leaves the 140 Hz roughness
  // the tone is recognised by.
  callfailed: [
    [480, 0, .2],   [620, 0, .2],
    [480, .33, .2], [620, .33, .2],
    [480, .66, .3], [620, .66, .3],
  ],
  // The payphone's chrome buttons, for a server running with sound files off. The shipped
  // WAVs are the real thing - noise transient and all - but even the fallback keeps what
  // matters: the partials are INHARMONIC, at the free-bar ratios 1 : 2.76 : 5.40, which is
  // what the ear hears as struck metal rather than as a note. A harmonic stack here would
  // just be a chord.
  boothkey:     [[1150, 0, .05], [3174, 0, .034], [6210, 0, .019]],
  boothkeyback: [[900, 0, .062], [2484, 0, .042], [4860, 0, .024]],
};

// UI feedback sits well below a ringtone: it accompanies an action the player just
// took, so it only has to be heard, not answered.
function ui(name) {
  const v = (state.prefs || {}).ringVolume;
  const vol = v == null ? 0.7 : v;
  if (vol <= 0) return;

  // The five that ship as files use them; the rest are a click or two of oscillator,
  // which is cheaper than a fetch and indistinguishable at that length.
  const src = soundUrl('ui', name);
  if (src) {
    try {
      const el = new Audio(src);
      el.volume = Math.max(0, Math.min(1, vol * 0.55));
      el.addEventListener('error', () => { soundsOff = true; }, { once: true });
      el.play().catch(() => {});
      return;
    } catch { /* fall through */ }
  }

  const score = UI_TONES[name];
  if (!score) return;
  score.forEach(([f, t, d]) => note(f, t, d, 0.045 * vol, 'sine'));
}

// ══ Placing a call ═════════════════════════════════════════════
// Every route to a call goes through here: the keypad, a recent, a contact, a conversation
// header, a notification, and the SDK. There were nine call sites and none of them looked at
// the answer, so a number that does not exist did nothing at all on the phone - the failure
// was a framework notification outside the frame and nothing else.
//
// A call that fails now sounds like one. The tone comes first and the message second, because
// the tone is what a player reacts to.
async function placeCall(number, extra) {
  const payload = extra ? Object.assign({ number }, extra) : { number };
  const r = await post('call', payload);
  // The server answers `{ ok = true, id }`, or `{ error }`, or a bare `false` when it cannot
  // even identify the caller. Anything that is not an explicit ok is a failed call.
  if (r && r.ok) return true;
  ui('callfailed');
  toast(L('ph.err_' + ((r && r.error) || 'x')));
  return false;
}

function syncDndAudio() {
  if ((state.prefs || {}).dnd) {
    stopRingtone();
    const island = byId('island');
    if (island && island.classList.contains('notif')) {
      clearTimeout(islandTimer);
      islandTimer = null;
      setIslandMode(null);
    }
    return;
  }
  if (call && call.state === 'in') playRingtone();
}

// ══ The lock screen's second line ══════════════════════════════
// The phone number, and optionally the temporary server id. Asked once: a server id is fixed
// for the life of the connection, so re-asking it on every clock tick would be waste.
let serverIdCache = null;

async function paintLockMeta() {
  const host = byId('locknum');
  if (!host) return;
  const p = state.prefs || {};
  const number = myNum(state.number);

  if (p.showServerId === false) { host.textContent = number; return; }
  if (serverIdCache === null) {
    const r = await post('serverId');
    serverIdCache = (r && r.id) || 0;
  }
  if (!byId('locknum')) return;                 // locked and unlocked while it was in flight
  // Not masked by streamer mode: a server id is already public in the player list, and it is
  // what a viewer would be TOLD in order to help rather than something to hide from them.
  host.textContent = serverIdCache
    ? (number ? number + '  ·  ' + L('ph.server_id') + ' ' + serverIdCache
              : L('ph.server_id') + ' ' + serverIdCache)
    : number;
}

// ══ Buzz and peek ══════════════════════════════════════════════
// The handset shakes for a notification, and - when it is in a pocket rather than in the
// hand - the top of it rises into view carrying that notification, then slides back. The
// peek never takes focus: you are being shown something, not asked to do anything.
let buzzTimer = null, peekTimer = null;

function buzzDevice() {
  if ((state.prefs || {}).dnd) return;
  const d = byId('device');
  d.classList.remove('buzz');
  void d.offsetWidth;               // restart the animation rather than ignore a re-trigger
  d.classList.add('buzz');
  clearTimeout(buzzTimer);
  buzzTimer = setTimeout(() => d.classList.remove('buzz'), 700);
}

function showPeek(kind, data) {
  const d = byId('device');
  if (call || (state.prefs || {}).dnd) return;
  // No phone on them, nothing to lift out of a pocket. The client checks this too; it is
  // repeated here so the rule holds whoever sends the message.
  if (data && data.hasItem === false) return;
  if (!d.classList.contains('hidden') && !d.classList.contains('peeking')) return; // it is open
  const title = kind === 'message'
    ? (nameOfNumber(data.from) || L('ph.new_message_t'))
    : (data.title || L('ph.notification'));
  const bodyTxt = kind === 'message' ? (data.body || L('ph.attach')) : (data.body || '');

  d.classList.remove('hidden');
  d.classList.add('peeking');
  byId('inicon').innerHTML = UI.appIcon(kind === 'message' ? 'messages' : (data.app || data.icon || 'dot'));
  byId('inTitle').textContent = title;
  byId('inBody').textContent = bodyTxt;
  setIslandMode('notif');
  buzzDevice();

  clearTimeout(peekTimer);
  peekTimer = setTimeout(() => {
    if (!call) setIslandMode(null);
    d.classList.remove('peeking');
    d.classList.add('hidden');
    peekTimer = null;
  }, 4600);
}

function archivePeek(kind, data) {
  data = data || {};
  const app = kind === 'message' ? 'messages' : notifApp(data);
  if (appMuted(app)) return;
  const title = kind === 'message'
    ? (data.groupName || nameOfNumber(data.from) || L('ph.new_message_t'))
    : (data.title || L('ph.notification'));
  const bodyText = kind === 'message' ? (data.body || L('ph.attach')) : (data.body || '');
  const onClick = () => {
    const target = (state.apps || []).find((entry) => entry.id === app);
    if (!target) return;
    enterApp(target, null);
    if (kind === 'message') {
      if (data.group) openGroup(data.group, data.groupName || L('ph.groups'));
      else if (data.from) messageTo(data.from);
    }
  };
  notifs.unshift({
    id: ++notifSeq,
    app,
    icon: kind === 'message' ? 'messages' : (data.icon || app),
    title,
    body: bodyText,
    at: Date.now(),
    onClick,
  });
  notifs = notifs.slice(0, 40);
  paintNotifs();
}

// ══ Emoji ══════════════════════════════════════════════════════
// A picker any composer can raise - Messages and the social apps both point it at their
// own input. Emoji are ordinary text, so they travel and store like the rest of a message.
const EMOJI = {
  faces: ['😀','😃','😄','😁','😅','😂','🤣','🙂','😉','😊','😇','🥰','😍','😘','😗','😋','😜','🤪','🤨','😎','🥳','😏','😒','😌','😔','😴','😪','😜','🤗','🤭','🤫','🤔','😐','😑','😬','🙄','😯','😦','😧','😮','😲','🥱','😴','😌','😛','😳','🥺','😢','😭','😤','😠','😡','🤬','🤯','😱','😨','😰','😥','😓','🤥','🥴','🤢','🤮','🤧','😷'],
  gestures: ['👍','👎','👌','🤌','✌️','🤞','🤟','🤙','👈','👉','👆','👇','☝️','✋','🤚','🖐️','🖖','👋','🤝','🙏','💪','👏','🙌','👐','🤲','✊','👊','🤛','🤜','💅','👀','👁️','🧠','🫶'],
  hearts: ['❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💔','❣️','💕','💞','💓','💗','💖','💘','💝','💟','♥️'],
  things: ['🔥','⭐','🌟','✨','💫','🎉','🎊','💯','✅','❌','❓','❗','💤','💢','💥','💦','💨','🕳️','💣','💬','🗨️','👑','💎','🔔','🎵','🎶','🚗','🏠','💰','💵','💊','🍺','🍻','🥂','🍔','🍕','☕','⚽','🎧','📱','💻','⏰','📅','☀️','🌧️','⛈️','❄️','🌙','⚡','🌈','🎁'],
};
const EMOJI_TABS = [['recent','🕘'],['faces','😀'],['gestures','👍'],['hearts','❤️'],['things','🔥']];
let emojiTarget = null, emojiCat = 'faces';
let emojiRecent = [];

function paintEmoji() {
  const pan = byId('emojipanel');
  const list = emojiCat === 'recent' ? emojiRecent : (EMOJI[emojiCat] || []);
  pan.innerHTML =
    '<div class="emojihead"><span>' + esc(L('ph.emoji')) + '</span>' +
      '<button class="emojidone" id="emojidone" type="button">' + esc(L('ph.done')) + '</button></div>' +
    '<div class="emojitabs">' + EMOJI_TABS.map(([k, glyph]) =>
      '<button data-c="' + k + '" class="' + (emojiCat === k ? 'on' : '') +
        '" type="button" aria-label="' + esc(L('ph.emoji_' + k)) + '">' + glyph + '</button>').join('') + '</div>' +
    '<div class="emojigrid">' + (list.length ? list.map((emoji) =>
      '<button data-e="' + emoji + '" type="button">' + emoji + '</button>').join('')
      : '<div class="emojiempty">' + esc(L('ph.emoji_recent_empty')) + '</div>') + '</div>' +
    '<div class="emojifoot"><button id="emojiback" type="button" aria-label="' +
      esc(L('ph.delete')) + '">⌫</button><span>' + esc(L('ph.emoji_hint')) + '</span></div>';

  byId('emojidone').addEventListener('click', emojiClose);
  byId('emojiback').addEventListener('click', () => {
    const inp = byId(emojiTarget);
    if (!inp) return;
    const end = inp.selectionStart != null ? inp.selectionStart : inp.value.length;
    if (end <= 0) return;
    const chars = Array.from(inp.value.slice(0, end));
    chars.pop();
    const left = chars.join('');
    inp.value = left + inp.value.slice(end);
    try { inp.setSelectionRange(left.length, left.length); } catch {}
    inp.focus();
  });
  [...pan.querySelectorAll('.emojitabs button')].forEach((b) =>
    b.addEventListener('click', () => { emojiCat = b.dataset.c; paintEmoji(); }));
  [...pan.querySelectorAll('.emojigrid button')].forEach((b) =>
    b.addEventListener('click', () => {
      const inp = byId(emojiTarget);
      if (!inp) return;
      // Insert at the caret if there is one, otherwise append; then keep typing.
      const at = (inp.selectionStart != null) ? inp.selectionStart : inp.value.length;
      inp.value = inp.value.slice(0, at) + b.dataset.e + inp.value.slice(at);
      const pos = at + b.dataset.e.length;
      emojiRecent = [b.dataset.e].concat(emojiRecent.filter((emoji) => emoji !== b.dataset.e)).slice(0, 28);
      try { inp.setSelectionRange(pos, pos); } catch {}
      inp.focus();
    }));
}
function emojiOpen(inputId) {
  if (emojiTarget === inputId && byId('emojipanel').classList.contains('on')) { emojiClose(); return; }
  emojiTarget = inputId; emojiCat = 'faces'; paintEmoji();
  byId('emojiscrim').classList.add('on');
  byId('emojipanel').classList.add('on');
}
function emojiClose() {
  byId('emojipanel').classList.remove('on');
  byId('emojiscrim').classList.remove('on');
  emojiTarget = null;
}
byId('emojiscrim').addEventListener('click', emojiClose);

let emojiDragY = null;
byId('emojipanel').addEventListener('pointerdown', (e) => {
  const r = byId('emojipanel').getBoundingClientRect();
  emojiDragY = e.clientY < r.top + 60 ? e.clientY : null;
});
byId('emojipanel').addEventListener('pointerup', (e) => {
  if (emojiDragY != null && e.clientY - emojiDragY > 38) emojiClose();
  emojiDragY = null;
});
byId('emojipanel').addEventListener('pointercancel', () => {
  emojiDragY = null;
});

// ══ Sheet, toast, banner ═══════════════════════════════════════
let sheetReturn = null;
let sheetEpoch = 0;
let sheetCancel = null;
const promptQueue = [];
let activePrompt = false;
let promptExpiryTimer = null;

function pumpPrompts() {
  if (activePrompt || byId('sheet').classList.contains('on')) return;
  while (promptQueue.length) {
    const entry = promptQueue.shift();
    const remaining = entry.expires - Date.now();
    if (remaining <= 0) continue;
    activePrompt = true;
    entry.show();
    clearTimeout(promptExpiryTimer);
    promptExpiryTimer = setTimeout(() => {
      promptExpiryTimer = null;
      if (activePrompt) closeSheet();
    }, remaining);
    return;
  }
}

function enqueuePrompt(show, ttlMs) {
  if (typeof show !== 'function') return;
  const now = Date.now();
  for (let i = promptQueue.length - 1; i >= 0; i -= 1) {
    if (promptQueue[i].expires <= now) promptQueue.splice(i, 1);
  }
  while (promptQueue.length >= 6) promptQueue.shift();
  promptQueue.push({
    show,
    expires: now + Math.max(1000, Number(ttlMs) || 30000),
  });
  pumpPrompts();
}

function sheet(title, html, after, variant) {
  if (sheetCancel) {
    const cancel = sheetCancel;
    sheetCancel = null;
    cancel();
  }
  sheetEpoch += 1;
  sheetReturn = null;
  byId('sheet').dataset.variant = variant || '';
  byId('sheet').innerHTML = `<div class="grab"></div><div class="sh">${esc(title)}</div>${html}`;
  byId('sheet').classList.add('on');
  byId('scrim').classList.add('on');
  ui('sheet');
  if (after) after();
}
function closeSheet(force, expectedEpoch) {
  if (expectedEpoch != null && expectedEpoch !== sheetEpoch) return false;
  sheetEpoch += 1;
  if (typeof emojiClose === 'function') emojiClose();
  if (!force && sheetReturn) {
    const restore = sheetReturn;
    sheetReturn = null;
    restore();
    return true;
  }
  if (sheetCancel) {
    const cancel = sheetCancel;
    sheetCancel = null;
    cancel();
  }
  sheetReturn = null;
  const sheetHost = byId('sheet');
  if (sheetHost.contains(document.activeElement) && document.activeElement.blur) {
    document.activeElement.blur();
  }
  sheetHost.dataset.variant = '';
  clearTimeout(promptExpiryTimer);
  promptExpiryTimer = null;
  sheetDrag = null;
  sheetHost.classList.remove('dragging');
  sheetHost.style.removeProperty('transform');
  sheetHost.style.removeProperty('opacity');
  sheetHost.classList.remove('on');
  byId('scrim').classList.remove('on');
  activePrompt = false;
  if (force) promptQueue.length = 0;
  else setTimeout(pumpPrompts, 0);
  return true;
}
byId('scrim').addEventListener('click', () => closeSheet());

let sheetDrag = null;
byId('sheet').addEventListener('pointerdown', (e) => {
  const host = byId('sheet');
  const r = host.getBoundingClientRect();
  if (e.clientY > r.top + 58) return;
  // A sheet that puts a control in its own header - the spotlight's close button, for
  // one - was capturing the pointer for a drag, and a captured pointer never delivers
  // its click to the control underneath. The grab area yields to anything tappable.
  if (e.target.closest('button, a, input, select, textarea, [data-app], [role="button"]')) return;
  sheetDrag = { y: e.clientY, pointerId: e.pointerId };
  host.classList.add('dragging');
  if (host.setPointerCapture) {
    try { host.setPointerCapture(e.pointerId); } catch {}
  }
});
byId('sheet').addEventListener('pointermove', (e) => {
  if (!sheetDrag || sheetDrag.pointerId !== e.pointerId) return;
  const dy = Math.max(0, e.clientY - sheetDrag.y);
  byId('sheet').style.transform = 'translateY(' + dy + 'px)';
  byId('sheet').style.opacity = String(Math.max(.35, 1 - dy / 360));
});
byId('sheet').addEventListener('pointerup', (e) => {
  if (!sheetDrag || sheetDrag.pointerId !== e.pointerId) return;
  const dy = Math.max(0, e.clientY - sheetDrag.y);
  sheetDrag = null;
  const host = byId('sheet');
  host.classList.remove('dragging');
  host.style.removeProperty('transform');
  host.style.removeProperty('opacity');
  if (dy > 70) closeSheet();
});
byId('sheet').addEventListener('pointercancel', () => {
  sheetDrag = null;
  byId('sheet').classList.remove('dragging');
  byId('sheet').style.removeProperty('transform');
  byId('sheet').style.removeProperty('opacity');
});

let toastTimer = null;
function toast(text) {
  const t = byId('toast');
  t.textContent = text;
  t.classList.add('on');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('on'), 2200);
}

// A notification now grows out of the black camera pill, iOS 27 style, and is filed in
// the centre. A muted app is filed nowhere and shows nothing.
let islandTimer = null;
function banner(b) {
  const app = notifApp(b);
  if (appMuted(app)) return;

  // Tapping it opens the app it came from.
  //
  // `onClick` was whatever the caller passed and null otherwise, and almost no caller passed
  // one - so most notifications were decoration: they told you something had happened and then
  // refused to take you to it. The app the notification belongs to is already worked out above,
  // so the default is obvious and there is no reason for it to have been nothing.
  const openIt = () => {
    const target = (state.apps || []).find((entry) => entry.id === app);
    if (target) enterApp(target, null);
    else toast(L('ph.err_notinstalled'));
  };
  const n = { id: ++notifSeq, app, icon: b.icon || app, title: b.title || '', body: b.body || '',
              at: Date.now(), onClick: b.onClick || openIt };
  notifs.unshift(n);
  notifs = notifs.slice(0, 40);
  paintNotifs();
  if (byId('shade').classList.contains('on')) renderShade();
  // First-run setup is intentionally distraction-free. Keep the notification in the
  // centre so it is not lost, but do not cover the assistant or play its alert.
  if (byId('setup').classList.contains('on')) return;
  // Focus keeps a quiet history in Notification Centre without lighting the island.
  if ((state.prefs || {}).dnd) return;
  playAlert();
  islandNotify(n);
}

// The pill expands, holds the notification, then collapses back. It yields to a live
// call, which owns the island outright.
function islandNotify(n) {
  if (call) return;
  const isl = byId('island');
  byId('inicon').innerHTML = UI.appIcon(n.icon);
  byId('inTitle').textContent = n.title;
  byId('inBody').textContent = n.body;
  setIslandMode('notif');
  isl.dataset.notif = n.id;
  clearTimeout(islandTimer);
  islandTimer = setTimeout(() => {
    if (!call && isl.classList.contains('notif')) setIslandMode(null);
    islandTimer = null;
  }, 4200);
}
byId('island').addEventListener('click', () => {
  const isl = byId('island');
  if (!isl.classList.contains('notif')) return;
  const n = notifs.find((x) => String(x.id) === isl.dataset.notif);
  setIslandMode(null);
  clearTimeout(islandTimer);
  if (n && n.onClick) n.onClick();
});

function relTime(t) {
  const m = Math.round((Date.now() - t) / 60000);
  if (m < 1) return L('ph.now') || 'now';
  if (m < 60) return m + ' min';
  return Math.round(m / 60) + ' h';
}

// The lock screen shows the most recent handful; the shade shows everything, grouped.
/// Clear the stack, and the numbers on the icons with it.
///
/// The notification centre is a list this page holds; a badge is a count the server keeps.
/// Two different things, which look like one thing to somebody holding the phone - so
/// clearing the stack used to leave "1" sitting on Messages with nothing left to open. The
/// player saying they have seen it is what marks it seen.
async function clearAllNotifications() {
  notifs = [];
  paintNotifs();
  if (byId('shade').classList.contains('on')) renderShade();
  const r = await post('seenAll', {});
  if (!r || !r.ok) return;
  // The counts come back with the refresh; the home screen is redrawn from them.
  await refresh();
  renderHome();
  if (byId('shade').classList.contains('on')) renderShade();
}

function paintNotifs() {
  const host = byId('locknotifs');
  const shown = notifs.slice(0, 4);
  host.innerHTML =
    (notifs.length > 1
      ? `<button class="lockclear" id="lockclear" type="button">${esc(L('ph.clear_all'))}</button>`
      : '') +
    shown.map((n, i) =>
      `<div class="lnotif glass" style="animation-delay:${i * 50}ms" data-nid="${n.id}">` +
      `<span class="lic">${UI.appIcon(n.icon)}</span>` +
      `<span class="lbody"><span class="lt">${esc(n.title || '')}</span>` +
      `<span class="lb">${esc(n.body || '')}</span></span>` +
      `<button class="lx" data-x="${n.id}" type="button" aria-label="${esc(L('ph.close'))}">${svg('xmark')}</button></div>`).join('');

  // Clear one, or clear the stack. A notification you have read is one you should be able
  // to get rid of without unlocking the phone first.
  [...host.querySelectorAll('.lx')].forEach((b) => b.addEventListener('click', (e) => {
    e.stopPropagation();
    notifs = notifs.filter((n) => String(n.id) !== b.dataset.x);
    paintNotifs();
    if (byId('shade').classList.contains('on')) renderShade();
  }));
  const all = byId('lockclear');
  if (all) all.addEventListener('click', (e) => {
    e.stopPropagation();
    clearAllNotifications();
  });
  // Tapping the card itself still does what the notification is for.
  [...host.querySelectorAll('.lnotif')].forEach((c) => c.addEventListener('click', (e) => {
    if (e.target.closest('.lx')) return;
    const n = notifs.find((x) => String(x.id) === c.dataset.nid);
    if (n && n.onClick) unlock(n.onClick);
  }));
}

// ══ Calls ══════════════════════════════════════════════════════
let callSpeaker = false;

function fmtDuration(s) {
  const m = Math.floor(s / 60), r = s % 60;
  return `${m}:${String(r).padStart(2, '0')}`;
}

function renderCall() {
  const ui = byId('callui');
  // The page owns the ringing: it is the only side that can play a player's own MP3.
  if (call && call.state === 'in') playRingtone(); else stopRingtone();
  if (!call) {
    ui.classList.remove('on');
    setIslandMode(null);
    clearInterval(callTimer); callTimer = null;
    return;
  }
  ui.classList.add('on');
  // FaceTime: a real voice call presented as a video call. FiveM cannot stream a live
  // face, so the layout is the difference, not a video feed - honest, and it reads right.
  ui.classList.toggle('facetime', !!call.video);
  const name = call.number ? nameOfNumber(call.number) : L('ph.unknown');
  byId('callav').textContent = name.slice(0, 1).toUpperCase();
  byId('callnum').textContent = name;
  byId('callstate').textContent = call.video
    ? L('ph.facetime_video')
    : (call.state === 'in' ? L('ph.incoming') : call.state === 'out' ? L('ph.calling') : '');

  // Live activity in the island, which is what a modern iPhone does with a call.
  setIslandMode('live');
  byId('islandIcon').innerHTML = svg('phone');
  byId('islandT1').textContent = name;
  byId('islandT2').textContent = call.state === 'active' ? L('ph.in_call')
    : call.state === 'in' ? L('ph.incoming') : L('ph.calling');

  if (call.state === 'active') {
    if (!callTimer) callStart = Date.now();
    const elapsed = Math.floor((Date.now() - callStart) / 1000);
    byId('callstate').innerHTML =
      `<span class="calltimer" id="ctimer">${fmtDuration(elapsed)}</span>`;
    byId('islandT2').textContent = fmtDuration(elapsed);
    if (!callTimer) {
      callTimer = setInterval(() => {
        const s = Math.floor((Date.now() - callStart) / 1000);
        const el = byId('ctimer'); if (el) el.textContent = fmtDuration(s);
        byId('islandT2').textContent = fmtDuration(s);
      }, 1000);
    }
    byId('callpad').innerHTML =
      `<div class="cpad ${callSpeaker ? 'on' : ''}" data-a="speaker"><span>${svg('speaker')}</span><em>${esc(L('ph.speaker'))}</em></div>`;
    [...byId('callpad').querySelectorAll('.cpad')].forEach((p) => p.addEventListener('click', () => {
      // The only exposed audio control is backed by the real proximity speaker bridge.
      if (p.dataset.a === 'speaker') {
        // A real speaker: the server works out who is close enough to hear it.
        callSpeaker = !callSpeaker;
        post('speaker', { on: callSpeaker }).then((r) => {
          if (!r || r.error) { callSpeaker = false; toast(L('ph.err_' + ((r && r.error) || 'x'))); renderCall(); }
          else toast(L(callSpeaker ? 'ph.speaker_on' : 'ph.speaker_off'));
        });
      }
      else return;
      renderCall();
    }));
  } else {
    byId('callpad').innerHTML = '';
  }

  byId('callbtns').innerHTML =
    (call.state === 'in' ? `<button class="cbtn ok" id="cans" type="button" aria-label="${esc(L('ph.answer'))}">${svg('answer')}</button>` : '') +
    `<button class="cbtn no" id="chang" type="button" aria-label="${esc(L('ph.hangup'))}">${svg('hangup')}</button>`;
  const ans = byId('cans');
  if (ans) ans.addEventListener('click', () => post('answer'));
  byId('chang').addEventListener('click', () => post('hangup'));
}

// ══ Control centre ═════════════════════════════════════════════
// iOS 27 Liquid Glass. Every control is real: airplane and cellular drive the signal
// the status bar draws, wifi and bluetooth their own glyphs, the sliders brightness and
// volume, the toggles focus and the flashlight. A switch that changed nothing would be a
// lie about what the phone can do.
let ccNow = null;   // last-known now-playing, so the panel opens without a flash

async function toggleCC(key) {
  const p = state.prefs || {};
  const defaultsOn = key === 'wifi' || key === 'cellular';
  const current = defaultsOn ? p[key] !== false : p[key] === true;
  const r = await post('prefs', { [key]: !current });
  if (r && r.ok) {
    state.prefs = r.prefs;
    // After the write, not before: the switch clicks when it has actually moved.
    ui(current ? 'toggleoff' : 'toggleon');
    if (key === 'dnd') syncDndAudio();
    applyPower(state._power || {});
    applyStatusFlags();
    renderCC();
  }
}

function renderCC() {
  const p = state.prefs || {};

  byId('ccconn').innerHTML =
    `<button class="ccbtn air ${p.airplane ? 'on' : ''}" data-t="airplane" type="button" aria-label="${esc(L('ph.airplane'))}" aria-pressed="${p.airplane ? 'true' : 'false'}">${svg('airplane')}</button>` +
    `<button class="ccbtn cel ${p.cellular !== false && !p.airplane ? 'on' : ''}" data-t="cellular" type="button" aria-label="${esc(L('ph.cellular'))}" aria-pressed="${p.cellular !== false && !p.airplane ? 'true' : 'false'}">${svg('cell')}</button>` +
    `<button class="ccbtn wif ${p.wifi !== false ? 'on' : ''}" data-t="wifi" type="button" aria-label="${esc(L('ph.wifi'))}" aria-pressed="${p.wifi !== false ? 'true' : 'false'}">${svg('wifi')}</button>` +
    `<button class="ccbtn blu ${p.bluetooth ? 'on' : ''}" data-t="bluetooth" type="button" aria-label="${esc(L('ph.bluetooth'))}" aria-pressed="${p.bluetooth ? 'true' : 'false'}">${svg('bt')}</button>`;
  qrows('ccconn', '.ccbtn', (b) => b.addEventListener('click', () => toggleCC(b.dataset.t)));

  const m = ccNow;
  byId('ccnow').innerHTML =
    `<div class="nowlab">${esc(L('ph.nowplaying'))}</div>` +
    (m
      ? `<div class="nowmid"><span class="nowart">${svg('music')}</span>` +
          `<span style="min-width:0"><span class="nowt">${esc(m.title || L('ph.untitled'))}</span>` +
          `<span class="nows">${esc(L('ph.music_' + (m.kind || 'boombox')))}</span></span></div>` +
        `<div class="nowbtns"><button data-n="toggle" type="button" aria-label="${esc(L(m.paused ? 'ph.resume' : 'ph.pause'))}">${svg(m.paused ? 'play' : 'pause')}</button></div>`
      : `<div class="nowmid"><span class="nowart">${svg('music')}</span>` +
          `<span class="nows">${esc(L('ph.nothing_playing'))}</span></div>`);
  if (m) byId('ccnow').querySelector('[data-n="toggle"]').addEventListener('click', async () => {
    const r = await post('music', { action: m.paused ? 'resume' : 'pause' });
    if (r && r.error) { toast(L('ph.err_' + r.error)); return; }
    m.paused = !m.paused;
    if (musicNow) musicNow.paused = m.paused;
    renderCC();
    // The same repaint the Music app's own pause button does. Rebuilding the whole app
    // behind an open control centre is work nobody can even see happening.
    if (openApp && openApp.id === 'music') musicPaintPlaying();
  });

  const bright = Math.max(0.35, Math.min(1, p.brightness ?? 1));
  byId('ccbright').innerHTML =
    `<div class="fill" style="height:${Math.round(bright * 100)}%"></div><div class="gl">${svg('sun')}</div>`;
  byId('ccvol').innerHTML =
    `<div class="fill" style="height:${Math.round(volume * 100)}%"></div><div class="gl">${svg('speaker')}</div>`;
  byId('ccbright').dataset.label = L('ph.brightness');
  byId('ccbright').setAttribute('aria-label', L('ph.brightness'));
  byId('ccbright').setAttribute('role', 'slider');
  byId('ccbright').setAttribute('tabindex', '0');
  byId('ccbright').setAttribute('aria-valuemin', '35');
  byId('ccbright').setAttribute('aria-valuemax', '100');
  byId('ccbright').setAttribute('aria-valuenow', String(Math.round(bright * 100)));
  byId('ccvol').dataset.label = L('ph.volume');
  byId('ccvol').setAttribute('aria-label', L('ph.volume'));
  byId('ccvol').setAttribute('role', 'slider');
  byId('ccvol').setAttribute('tabindex', '0');
  byId('ccvol').setAttribute('aria-valuemin', '0');
  byId('ccvol').setAttribute('aria-valuemax', '100');
  byId('ccvol').setAttribute('aria-valuenow', String(Math.round(volume * 100)));
  wireSlab('ccbright', (v) => {
    const brightness = 0.35 + v * 0.65;
    state.prefs = Object.assign({}, state.prefs || {}, { brightness });
    applyBrightness();
    byId('ccbright').querySelector('.fill').style.height = Math.round(brightness * 100) + '%';
    byId('ccbright').setAttribute('aria-valuenow', String(Math.round(brightness * 100)));
  }, async (v) => {
    const commit = ++brightnessCommit;
    const r = await post('prefs', { brightness: 0.35 + v * 0.65 });
    if (commit === brightnessCommit && r && r.ok) state.prefs = r.prefs;
  });
  wireSlab('ccvol', (v) => {
    volume = v;
    byId('ccvol').querySelector('.fill').style.height = Math.round(v * 100) + '%';
    byId('ccvol').setAttribute('aria-valuenow', String(Math.round(v * 100)));
  }, async (v) => {
    if (ccNow) await post('music', { action: 'volume', volume: v });
  });

  byId('cctoggles').innerHTML =
    `<button class="ccpill focus ${p.dnd ? 'on' : ''}" data-c="dnd" type="button" aria-label="${esc(L('ph.focus'))}" aria-pressed="${p.dnd ? 'true' : 'false'}">${svg('focus')}</button>` +
    `<button class="ccpill torch ${ccTorch ? 'on' : ''}" data-c="torch" type="button" aria-label="${esc(L('ph.torch'))}" aria-pressed="${ccTorch ? 'true' : 'false'}">${svg('torch')}</button>` +
    `<button class="ccpill" data-c="wall" type="button" aria-label="${esc(L('ph.wallpaper'))}">${svg('wall')}</button>` +
    `<button class="ccpill" data-c="camera" type="button" aria-label="${esc(L('app.camera'))}">${svg('camera')}</button>`;
  qrows('cctoggles', '.ccpill', (b) => b.addEventListener('click', () => ccToggle(b.dataset.c)));
}

let ccTorch = false;
let torchCommit = 0;
let torchPending = false;

function paintTorchState() {
  const quick = byId('qtorch');
  quick.classList.toggle('on', ccTorch);
  quick.setAttribute('aria-pressed', ccTorch ? 'true' : 'false');
}

async function toggleTorch() {
  if (torchPending) return;
  torchPending = true;
  const commit = ++torchCommit;
  const next = !ccTorch;
  const r = await post('torch', { on: next });
  if (commit !== torchCommit) return;
  torchPending = false;
  if (!r || !r.ok) {
    toast(L('ph.err_' + ((r && r.error) || 'x')));
    return;
  }
  ccTorch = next;
  paintTorchState();
  toast(L(ccTorch ? 'ph.torch_on' : 'ph.torch_off'));
  if (byId('cc').classList.contains('on')) renderCC();
}

async function ccToggle(c) {
  if (c === 'dnd') { await toggleCC('dnd'); return; }
  if (c === 'torch') { await toggleTorch(); return; }
  byId('cc').classList.remove('on');
  const id = c === 'camera' ? 'camera' : 'settings';
  const a = (state.apps || []).find((x) => x.id === id);
  if (a) enterApp(a, null);
}

// A vertical slider: press or drag anywhere in the slab, the fill follows the finger.
const slabCallbacks = new WeakMap();
const slabCommits = new WeakMap();
const wiredSlabs = new WeakSet();
let brightnessCommit = 0;

function wireSlab(id, onChange, onCommit) {
  const el = byId(id);
  slabCallbacks.set(el, onChange);
  slabCommits.set(el, onCommit);
  if (wiredSlabs.has(el)) return;
  wiredSlabs.add(el);
  const to = (e) => {
    const r = el.getBoundingClientRect();
    return Math.max(0, Math.min(1, 1 - (e.clientY - r.top) / r.height));
  };
  const emit = (e) => {
    const value = to(e);
    const fn = slabCallbacks.get(el);
    if (fn) fn(value);
    return value;
  };
  let down = false, value = 0;
  el.addEventListener('pointerdown', (e) => {
    down = true;
    el.classList.add('adjusting');
    el.setPointerCapture(e.pointerId);
    value = emit(e);
  });
  el.addEventListener('pointermove', (e) => { if (down) value = emit(e); });
  el.addEventListener('pointerup', (e) => {
    if (!down) return;
    value = emit(e);
    down = false;
    el.classList.remove('adjusting');
    const commit = slabCommits.get(el);
    if (commit) commit(value);
  });
  el.addEventListener('pointercancel', () => {
    down = false;
    el.classList.remove('adjusting');
  });
  el.addEventListener('keydown', (e) => {
    const min = Number(el.getAttribute('aria-valuemin') || 0);
    const max = Number(el.getAttribute('aria-valuemax') || 100);
    let current = Number(el.getAttribute('aria-valuenow') || min);
    if (e.key === 'ArrowUp' || e.key === 'ArrowRight') current += 5;
    else if (e.key === 'ArrowDown' || e.key === 'ArrowLeft') current -= 5;
    else if (e.key === 'Home') current = min;
    else if (e.key === 'End') current = max;
    else return;
    e.preventDefault();
    current = Math.max(min, Math.min(max, current));
    const normalized = (current - min) / Math.max(1, max - min);
    const fn = slabCallbacks.get(el);
    const commit = slabCommits.get(el);
    if (fn) fn(normalized);
    if (commit) commit(normalized);
  });
}

// The control centre's media tile.
//
// It used to ask the Music app's payload for `sources`, a list the phone has always answered
// as empty - so the tile said "nothing playing" while a track was audibly playing. Nothing
// else could have filled it: a deck that plays a URL has no notion of what a PHONE considers
// to be now playing. The phone knows, because it started it, so the tile reads that.
async function primeNowPlaying() {
  if (musicNow) { ccNow = musicNow; return; }
  // A deck the phone cannot drive may still be able to say what it has: keep honouring that.
  const d = await post('app', { app: 'music' });
  const list = (d && d.sources) || [];
  ccNow = list[0] || null;
}

// ══ Third-party app bridge ═════════════════════════════════════
// sdk.js inside an app frame posts here. Everything it can ask for is listed once, so
// what an app is allowed to do is readable in one place rather than inferred.
function sdkHasPermission(app, permission) {
  const declared = app && Array.isArray(app.permissions) ? app.permissions : [];
  // Empty is the backwards-compatible legacy profile. Once an app declares a list, it
  // becomes an allow-list and the FruitStore can state exactly what the app may use.
  return !declared.length || declared.includes(permission);
}

const SDK_PERMISSION = {
  storage: 'storage',
  contacts: 'contacts',
  photos: 'photos',
  location: 'location',
  waypoint: 'location',
  message: 'messages',
  call: 'calls',
  notify: 'notifications',
  badge: 'notifications',
  open: 'apps',
  share: 'sharing',
};

function sdkContactPicker(settle, options) {
  const query = String((options && options.query) || '').trim().toLowerCase();
  const contacts = (state.contacts || []).filter((contact) =>
    !query || (contact.name + ' ' + contact.number).toLowerCase().includes(query));
  if (!contacts.length) {
    settle({ error: 'empty', cancelled: true });
    toast(L('ph.no_contacts'));
    return;
  }
  sheet(L('ph.pick_contact'), UI.group(contacts.map((contact) => UI.row({
    avatar: contact.name,
    title: contact.name,
    subtitle: contact.number,
    chevron: true,
    data: { 'sdk-contact': contact.number },
  }))), () => {
    sheetCancel = () => settle({ ok: false, cancelled: true });
    [...byId('sheet').querySelectorAll('[data-sdk-contact]')].forEach((row) => {
      row.addEventListener('click', () => {
        const contact = contacts.find((entry) => entry.number === row.dataset.sdkContact);
        sheetCancel = null;
        closeSheet();
        settle({ ok: true, contact });
      });
    });
  }, 'sdk-picker');
}

function sdkPhotoPicker(settle) {
  const photos = (state.photos || []).map(photoRow).filter((photo) => photo.url);
  if (!photos.length) {
    settle({ error: 'empty', cancelled: true });
    toast(L('ph.no_photos'));
    return;
  }
  sheet(L('ph.pick_photo'),
    '<div class="shots sdkphotos">' + photos.map((photo, index) =>
      '<button class="shot" type="button" data-sdk-photo="' + index +
        '" style="' + photoStyle(photo) + '" aria-label="' + esc(L('ph.photo')) + '"></button>'
    ).join('') + '</div>',
    () => {
      sheetCancel = () => settle({ ok: false, cancelled: true });
      [...byId('sheet').querySelectorAll('[data-sdk-photo]')].forEach((photo) => {
        photo.addEventListener('click', () => {
          const selected = photos[Number(photo.dataset.sdkPhoto)];
          sheetCancel = null;
          closeSheet();
          settle({ ok: true, photo: selected, url: selected.url });
        });
      });
    }, 'sdk-picker');
}

function sdkActionSheet(settle, options, confirmation) {
  const choices = (options.actions || []).slice(0, 8);
  const rowHtml = choices.map((choice) => UI.row({
    icon: choice.icon || (choice.destructive ? 'trash' : 'chevron'),
    tint: choice.destructive ? '#FF3B30' : (choice.tint || '#0A84FF'),
    title: choice.label || choice.title || choice.id,
    value: choice.value,
    data: { 'sdk-action': choice.id },
  }));
  if (confirmation) {
    rowHtml.push(UI.row({
      icon: 'xmark', tint: '#8E8E93',
      title: options.cancelLabel || L('ph.cancel'),
      data: { 'sdk-action': '__cancel' },
    }));
  }
  sheet(options.title || (confirmation ? L('ph.confirm') : L('ph.app_actions')),
    (options.message ? '<div class="sheethint">' + esc(options.message) + '</div>' : '') +
      UI.group(rowHtml),
    () => {
      sheetCancel = () => settle({ ok: false, cancelled: true });
      [...byId('sheet').querySelectorAll('[data-sdk-action]')].forEach((row) => {
        row.addEventListener('click', () => {
          const id = row.dataset.sdkAction;
          sheetCancel = null;
          closeSheet();
          settle(id === '__cancel'
            ? { ok: false, cancelled: true }
            : { ok: true, id, confirmed: confirmation ? true : undefined });
        });
      });
    }, confirmation ? 'sdk-confirm' : 'sdk-actions');
}

function copySdkText(value) {
  const text = String(value || '');
  if (navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(text).then(() => true).catch(() => false);
  }
  const field = document.createElement('textarea');
  field.value = text;
  field.style.position = 'fixed';
  field.style.opacity = '0';
  document.body.appendChild(field);
  field.select();
  let copied = false;
  try { copied = document.execCommand('copy'); } catch {}
  field.remove();
  return Promise.resolve(copied);
}

function sdkShare(settle, payload) {
  const kind = ['photo', 'contact', 'number'].includes(payload.kind) ? payload.kind : 'text';
  const text = String(payload.text || payload.body || payload.url ||
    (payload.contact && (payload.contact.name + ' ' + payload.contact.number)) || '').slice(0, 1200);
  const actions = [
    UI.row({ icon: 'messages', tint: '#34C759', title: L('ph.share_messages'), data: { 'sdk-share': 'messages' } }),
    UI.row({ icon: 'copy', tint: '#8E8E93', title: L('ph.copy'), data: { 'sdk-share': 'copy' } }),
  ];
  if (kind !== 'text') {
    actions.unshift(UI.row({
      icon: 'airdrop', tint: '#0A84FF', title: L('ph.airdrop'),
      data: { 'sdk-share': 'airdrop' },
    }));
  }
  sheet(payload.title || L('ph.share'), UI.group(actions), () => {
    sheetCancel = () => settle({ ok: false, cancelled: true });
    [...byId('sheet').querySelectorAll('[data-sdk-share]')].forEach((row) => {
      row.addEventListener('click', async () => {
        const channel = row.dataset.sdkShare;
        sheetCancel = null;
        closeSheet();
        if (channel === 'copy') {
          const copied = await copySdkText(text);
          toast(copied ? L('ph.copied') : L('ph.err_x'));
          settle({ ok: copied, channel });
          return;
        }
        if (channel === 'airdrop') {
          const airPayload = kind === 'photo'
            ? { url: String(payload.url || '') }
            : (payload.contact || { name: payload.name || '', number: payload.number || state.number });
          airdropShare(kind, airPayload);
          settle({ ok: true, channel });
          return;
        }
        sdkContactPicker((result) => {
          if (!result || !result.ok) { settle(result || { cancelled: true }); return; }
          const messages = (state.apps || []).find((app) => app.id === 'messages');
          if (!messages) { settle({ error: 'notinstalled' }); return; }
          settle({ ok: true, channel: 'messages', contact: result.contact });
          setTimeout(() => {
            enterApp(messages, null);
            messageTo(result.contact.number, text);
          }, 40);
        }, {});
      });
    });
  }, 'sdk-share');
}

function sdkOpenApp(settle, data) {
  const target = (state.apps || []).find((app) => app.id === String(data.app || ''));
  if (!target) { settle({ error: 'notinstalled' }); return; }
  settle({ ok: true, app: target.id });
  setTimeout(() => {
    enterApp(target, null);
    if (target.id === 'messages' && data.data && data.data.number) {
      messageTo(String(data.data.number), data.data.draft || '');
    } else if (target.id === 'maps' && data.data && Number.isFinite(Number(data.data.x))) {
      post('waypoint', data.data);
    } else if (target.page) {
      const frame = byId('appframe');
      if (frame) frame.addEventListener(
        'load',
        () => frameEvent('launch', data.data || {}, frame.contentWindow),
        { once: true }
      );
    }
  }, 40);
}

const SDK_ALLOWED = {
  request:  (d) => post('sdkRequest', d),         // <appId>:<method>, composed by Lua
  emit:     (d) => post('sdkEmit', d),            // <appId>:<event>, composed by Lua
  storage:  (d) => post('sdkStorage', d),         // per app, per character
  contacts: () => Promise.resolve({ ok: true, contacts: state.contacts || [] }),
  photos:   () => Promise.resolve({ ok: true, photos: state.photos || [] }),
  location: () => post('sdkLocation'),
  waypoint: (d) => post('waypoint', d),
  haptic:   (d) => post('sdkHaptic', d),
  me:       () => Promise.resolve({
    ok: true,
    number: state.number,
    apps: (state.apps || []).map((app) => ({ id: app.id, label: L(app.label), icon: app.icon })),
    app: openApp ? {
      id: openApp.id, label: L(openApp.label), icon: openApp.icon,
      version: openApp.version, developer: openApp.developer,
    } : null,
    permissions: (openApp && openApp.permissions) || [],
    dark: darkNow(),
    locale: document.documentElement.lang || 'fr',
    deviceName: (state.prefs || {}).deviceName || 'iFruit',
  }),
  message:  (d) => post('send', d),
  // Through the same helper, so an app built on the SDK gets the tone too.
  call:     (d) => placeCall(d && d.number, d),
};

window.addEventListener('message', async (e) => {
  const d = e.data || {};
  if (d.__phone !== 'sdk') return;
  const frame = byId('appframe');
  if (!frame || !frame.contentWindow || e.source !== frame.contentWindow ||
      !openApp || !openApp.page) return;
  const source = e.source;
  const appId = openApp.id;
  const appIcon = openApp.icon || 'dot';
  const reply = (payload) => {
    // Reply to the window that made this request, even if navigation has replaced the
    // current iframe while an asynchronous callback was in flight.
    if (source) source.postMessage({ __phone: 'reply', id: d.id, payload }, '*');
  };

  const pickerPermission = d.op === 'picker'
    ? ((d.data && d.data.kind) === 'photo' ? 'photos' : 'contacts')
    : null;
  const requiredPermission = pickerPermission || SDK_PERMISSION[d.op];
  if (requiredPermission && !sdkHasPermission(openApp, requiredPermission)) {
    return reply({ error: 'permission', permission: requiredPermission });
  }

  if (d.op === 'title') { setNav(d.data && d.data.title, null); byId('navbar').classList.remove('hidden'); return reply({ ok: true }); }
  if (d.op === 'navAction') {
    const data = d.data || {};
    if (!data.label && !data.icon) {
      setNav(byId('navtitle').textContent || L(openApp.label), null);
      return reply({ ok: true });
    }
    const icon = UI.icons[data.icon] ? data.icon : null;
    setNav(byId('navtitle').textContent || L(openApp.label), null, {
      icon,
      label: String(data.label || L('ph.app_actions')).slice(0, 40),
      onClick: () => frameEvent('navigation', { id: 'primary' }, source),
    });
    byId('navbar').classList.remove('hidden');
    return reply({ ok: true });
  }
  if (d.op === 'close') { reply({ ok: true }); closeApp(); return; }
  if (d.op === 'toast') { toast((d.data && d.data.text) || ''); return reply({ ok: true }); }
  if (d.op === 'notify') {
    const data = d.data || {};
    banner({ app: appId, icon: appIcon, title: data.title, body: data.body });
    return reply({ ok: true });
  }
  if (d.op === 'badge') {
    const a = (state.apps || []).find((x) => x.id === appId);
    if (a) {
      a.badge = Number(d.data && d.data.count) || 0;
      // Repaint, or the count only appears the next time something else happens to
      // rebuild the grid - which from the app's side looks like badge() did nothing.
      renderHome();
    }
    return reply({ ok: true });
  }
  if (d.op === 'picker') {
    if (d.data && d.data.kind === 'photo') sdkPhotoPicker(reply);
    else sdkContactPicker(reply, (d.data && d.data.options) || {});
    return;
  }
  if (d.op === 'confirm') {
    const data = d.data || {};
    sdkActionSheet(reply, {
      title: data.title,
      message: data.message,
      cancelLabel: data.cancelLabel,
      actions: [{
        id: 'confirm',
        label: data.confirmLabel || L('ph.confirm'),
        icon: data.destructive ? 'trash' : 'check',
        destructive: data.destructive === true,
      }],
    }, true);
    return;
  }
  if (d.op === 'actions') { sdkActionSheet(reply, d.data || {}, false); return; }
  if (d.op === 'share') { sdkShare(reply, d.data || {}); return; }
  if (d.op === 'open') { sdkOpenApp(reply, d.data || {}); return; }
  const fn = SDK_ALLOWED[d.op];
  if (!fn) return reply({ error: 'forbidden' });
  // The app id is stamped LAST, so a page cannot claim to be a different app by
  // putting its own `app` in the payload. Everything an app is allowed to reach is
  // namespaced under this id.
  reply(await fn(Object.assign({}, d.data || {}, { app: appId })));
});

// ══ Refresh ════════════════════════════════════════════════════
// Re-asks the server for everything it owns. Called after any write, because re-rendering
// from a locally patched copy is how a UI starts disagreeing with the database.
async function refresh() {
  const res = await post('refresh');
  if (res && res.ok) Object.assign(state, res);
  // A session can open, expire or be handed back between two refreshes, so the banner is
  // repainted from whatever just arrived rather than only when the phone is set up.
  applyAdminView();
}

// ══ Wiring ═════════════════════════════════════════════════════
byId('lock').addEventListener('click', unlock);
// The home indicator answers to a tap AND a swipe up, the way an iPhone does. It used to
// be a bare click, which missed when the bar is thin and a gesture started a few pixels
// above it or moved as it landed. This tracks a pointer from anywhere in the bottom band,
// fires on a quick upward flick or a clean tap, and never double-fires.
(function wireHome() {
  const bar = byId('homebar');
  let start = null;
  let fired = false;

  const trigger = () => {
    if (fired) return;
    fired = true;
    bar.blur();
    goHome();
  };

  const down = (e) => {
    start = { x: e.clientX, y: e.clientY, t: Date.now() };
    fired = false;
  };
  const move = (e) => {
    if (!start) return;
    // A decisive upward flick fires immediately, so a swipe never has to also be a tap.
    if (start.y - e.clientY > 26) { start = null; trigger(); }
  };
  const up = (e) => {
    if (!start) return;
    const dy = start.y - e.clientY;
    const dx = Math.abs(e.clientX - start.x);
    const quick = Date.now() - start.t < 400;
    start = null;
    // A short press that did not wander, or a small upward move: treat as "go home".
    if (dy > 8 || (quick && dx < 14 && Math.abs(dy) < 14)) trigger();
  };

  bar.addEventListener('pointerdown', down);
  bar.addEventListener('pointermove', move);
  bar.addEventListener('pointerup', up);
  bar.addEventListener('pointercancel', () => { start = null; });
  // A plain click is the fallback for input methods that emit no pointer events. If a
  // pointer sequence handled this interaction `fired` is still set, so it no-ops; then it
  // clears so the NEXT click still works on a click-only device.
  bar.addEventListener('click', () => {
    if (fired) { fired = false; return; }
    trigger();
    fired = false;
  });
})();

// Chromium can expose its desktop focus ring after a touch in some CEF builds. Keep
// focus visible for keyboard users, but never leave that coloured rectangle behind
// after a phone gesture.
document.addEventListener('keydown', (e) => {
  if (e.key === 'Tab') document.documentElement.classList.add('keyboard-nav');
}, true);
document.addEventListener('pointerdown', () => {
  document.documentElement.classList.remove('keyboard-nav');
}, true);

// Spotlight: the pill above the dock finds an app by name and launches it. It exists
// because a sixth page of icons is where apps go to be forgotten.
byId('spill').addEventListener('click', () => {
  sheet(L('ph.search'),
    '<div class="spothead"><strong>' + esc(L('ph.search')) + '</strong>' +
      '<button id="spotclose" type="button" aria-label="' + esc(L('ph.close')) + '">' +
        svg('xmark') + '</button></div>' +
    '<div class="spotsearch">' + svg('search') +
      '<input id="appq" placeholder="' + esc(L('ph.search_apps')) +
        '" autocomplete="off" aria-label="' + esc(L('ph.search_apps')) + '" />' +
      '<button id="appqclear" type="button" aria-label="' + esc(L('ph.clear')) + '">' +
        svg('xmark') + '</button></div>' +
    '<div class="spotsuggest" id="spotsuggest"></div><div id="appres"></div>',
    () => {
      const draw = (q) => {
        const list = (state.apps || []).filter((a) => !q || L(a.label).toLowerCase().includes(q));
        const recentApps = recents.slice(0, 4).map((id) => (state.apps || []).find((a) => a.id === id)).filter(Boolean);
        byId('spotsuggest').innerHTML = q || !recentApps.length ? '' :
          '<div class="spotlabel">' + esc(L('ph.recent')) + '</div><div class="spoticons">' +
            recentApps.map((a) => '<button data-app="' + esc(a.id) + '" type="button">' +
              appTile(a) + '<span>' + esc(L(a.label)) + '</span></button>').join('') + '</div>';
        byId('appres').innerHTML = list.length
          ? '<div class="spotlabel">' + esc(q ? L('ph.results') : L('ph.all_apps')) + '</div>' +
            UI.group(list.map((a) => UI.row({
              appicon: (UI.hasTile && UI.hasTile(a.id)) ? a.id : a.icon, title: L(a.label),
              subtitle: L('ph.cat_' + (a.category || 'utilities')),
              chevron: true, data: { app: a.id },
            })))
          : UI.empty(L('ph.no_app'));
        [...byId('sheet').querySelectorAll('[data-app]')].forEach((r) => r.addEventListener('click', () => {
          const a = (state.apps || []).find((x) => x.id === r.dataset.app);
          closeSheet();
          if (a) enterApp(a, null);
        }));
        byId('appqclear').classList.toggle('visible', !!q);
      };
      draw('');
      byId('appq').addEventListener('input', () => draw(byId('appq').value.trim().toLowerCase()));
      byId('appqclear').addEventListener('click', () => {
        byId('appq').value = '';
        draw('');
        byId('appq').focus();
      });
      byId('spotclose').addEventListener('click', () => closeSheet());
      requestAnimationFrame(() => byId('appq').focus());
    }, 'spotlight');
});
byId('island').addEventListener('click', () => { if (call) renderCall(); });
// The status bar takes pointer events so a drag can START on it, but a tap does
// nothing on purpose: the shade and the control centre are pull-downs, and a click
// that also opened them made every stray tap up there flash a panel.
byId('status').style.pointerEvents = 'auto';

byId('navback').addEventListener('click', () => {
  const onBack = navBackAction;
  navBackAction = null;
  if (onBack) { onBack(); return; }
  closeApp();
});

byId('qcam').addEventListener('click', () => {
  const camera = (state.apps || []).find((a) => a.id === 'camera');
  if (!cameraOn() || !camera) {
    toast(L('ph.camera_off'));
    return;
  }
  const openCamera = () => enterApp(camera, byId('qcam'));
  if (!byId('lock').classList.contains('out')) unlock(openCamera);
  else openCamera();
});
byId('qtorch').addEventListener('click', toggleTorch);

// Hold Alt for the camera - the press only. Lua owns the release and the page must not
// guess at it: dropping NUI focus fires `blur` on this document, so a blur handler here
// would cancel free look on the frame it started, and keyup never arrives either because
// the keyboard is gone by then.
document.addEventListener('keydown', (e) => {
  if (e.repeat) return;

  // **AltGr is not Alt.** On Windows AltGr arrives as Ctrl+Alt, so a plain `key === 'Alt'`
  // test matched it - and on a French keyboard AltGr is how you type @ and #. Reaching for
  // the @ of a handle took the camera over instead of typing a character.
  let altGr = false;
  try { altGr = e.getModifierState('AltGraph'); } catch { /* older engines: ctrlKey covers it */ }
  if (e.key === 'AltGraph' || altGr || e.ctrlKey) return;
  if (e.key !== 'Alt') return;

  // And never while typing. Alt in a text field is somebody reaching for a character or a
  // shortcut, not for the camera, and free look drops the keyboard mid-word.
  const el = document.activeElement;
  if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;

  e.preventDefault();
  post('freelook', { on: true });
});

// What is painting outside the handset. Only with `set phone_debug true`.
//
// Two earlier versions reported on a timer and every single report said appOpen=false, which
// made them useless: the square only appears with an app open. This one watches for the app
// to open and reports THEN.
//
// It reports painting properties rather than hit-testing. Every `elementFromPoint` probe came
// back `body` on all four sides, and that was the real clue: a box-shadow and a filter
// overflow are painted but never hit-tested, so whatever is escaping cannot be found by
// asking what is under a pixel. This lists what each layer is actually drawing.
window.addEventListener('message', (e) => {
  const d = e.data || {};
  if (d.action !== 'open' || window.__vphoneEdgeProbe || !d.debug) return;
  window.__vphoneEdgeProbe = true;
  if (d.cameraWhy) {
    console.info('[v-phone] camera inputs: convar=' + d.cameraWhy.convar +
      ' config=' + d.cameraWhy.config + ' resolved=' + d.cameraWhy.resolved);
  }
  console.info('[v-phone] payload: camera=' + JSON.stringify(d.camera) +
    ' media=' + JSON.stringify(d.media) + ' mediaVideo=' + JSON.stringify(d.mediaVideo) +
    ' -> camera app ' + (d.camera !== false ? 'ENABLED' : 'disabled'));

  let done = 0;
  const report = (why) => {
    try {
      const layers = ['#device', '.bezel', '#screen', '#wallpaper', '#app', '#appbody'];
      const out = layers.map((sel) => {
        const el = document.querySelector(sel);
        if (!el) return sel + '=absent';
        const c = getComputedStyle(el), r = el.getBoundingClientRect();
        const bits = [sel];
        if (c.filter && c.filter !== 'none') bits.push('filter=' + c.filter);
        if (c.backdropFilter && c.backdropFilter !== 'none') bits.push('backdrop=' + c.backdropFilter);
        if (c.boxShadow && c.boxShadow !== 'none') bits.push('shadow=' + c.boxShadow.slice(0, 60));
        if (c.transform && c.transform !== 'none') bits.push('tf=' + c.transform);
        if (c.overflow !== 'visible') bits.push('ovf=' + c.overflow);
        if (c.contain && c.contain !== 'none') bits.push('contain=' + c.contain);
        bits.push('bg=' + c.backgroundColor);
        bits.push('rect=' + [r.x, r.y, r.width, r.height].map(Math.round).join(','));
        return bits.join(' ');
      });
      console.info('[v-phone] LAYERS - ' + why);
      out.forEach((line) => console.info('[v-phone]   ' + line));
    } catch (err) {
      console.error('[v-phone] layer report threw: ' + err);
    }
  };

  const app = document.getElementById('app');
  if (!app) { console.error('[v-phone] probe: no #app'); return; }
  new MutationObserver(() => {
    if (!app.classList.contains('on') || done >= 2) return;
    done += 1;
    setTimeout(() => report('app open, ' + (app.dataset.app || '?')), 700);
  }).observe(app, { attributes: true, attributeFilter: ['class'] });
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    const hadTransient = anyOverlayOpen() || byId('auth').classList.contains('on') ||
      byId('folderview').classList.contains('on') ||
      byId('emojipanel').classList.contains('on') || editing || !!arr;
    resetTransientUI();
    if (hadTransient) return;
    if (byId('app').classList.contains('on')) { closeApp(); return; }
    clearActiveApp();
    post('close');
    return;
  }
  if (e.key === 'ArrowLeft') flipPage(-1);
  if (e.key === 'ArrowRight') flipPage(1);
});

byId('pages').addEventListener('wheel', (e) => { flipPage(e.deltaY > 0 ? 1 : -1); }, { passive: true });
window.addEventListener('resize', applyDevice, { passive: true });
if (window.visualViewport) window.visualViewport.addEventListener('resize', applyDevice, { passive: true });

// The phone keeps game input flowing so you can walk and drive while using it. A focused
// text field is the exception: the client holds the keyboard for the page while you type,
// so pressing "w" writes a w instead of walking you off, and releases it on blur.
const TYPEABLE = 'input, textarea, [contenteditable="true"]';
document.addEventListener('focusin', (e) => {
  if (e.target && e.target.matches && e.target.matches(TYPEABLE)) post('holdInput', { focused: true });
});
document.addEventListener('focusout', (e) => {
  if (e.target && e.target.matches && e.target.matches(TYPEABLE)) post('holdInput', { focused: false });
});

// ══ Lua → page ═════════════════════════════════════════════════
window.addEventListener('message', (e) => {
  // An app iframe must never be able to impersonate Lua with an { action: ... } payload.
  //
  // This used to read `if (e.source && e.source !== window) return`, on the assumption that a
  // CEF host message always arrives with a null source. That assumption does not hold on
  // every FiveM build, and where it fails the phone silently never opens: the message is
  // dropped here, nothing throws, and the DOM keeps insisting the page is healthy.
  //
  // So test the thing actually being defended against instead. The only foreign windows a
  // NUI page has are its own app iframes, and they are enumerable - reject those by identity
  // and let anything else through, whatever the host chose to put in `source`.
  if (e.source && e.source !== window) {
    for (let i = 0; i < window.frames.length; i++) {
      if (e.source === window.frames[i]) return;
    }
  }
  const d = e.data || {};
  if (d.__phone) return;                       // SDK traffic, handled above
  // Alt is held: the cursor has gone back to the camera, so the phone dims a little and
  // stops reacting to hover. Purely cosmetic - Lua has already taken the focus away - but
  // without it the last hovered button stays lit while the player looks around.
  if (d.action === 'freelook') {
    byId('device').classList.toggle('freelook', d.on === true);
    return;
  }
  if (d.action === 'open') {
    torchCommit += 1;
    torchPending = false;
    resetTransientUI();
    S = d.strings || {};
    if (notificationOwner && notificationOwner !== d.number) notifs = [];
    notificationOwner = d.number || null;
    state = d;
    available = d.available || d.apps || [];
    state.sounds = d.sounds || state.sounds || {};
    call = d.call || null;
    dialed = ''; thread = null; threadGroup = null; openApp = null; page = 0;
    const locale = String(d.locale || d.lang || 'en').trim().replace('_', '-');
    document.documentElement.lang = locale || 'en';
    byId('device').classList.remove('hidden');
    byId('qtorch').setAttribute('aria-label', L('ph.torch'));
    byId('qcam').setAttribute('aria-label', L('app.camera'));
    byId('homebar').setAttribute('aria-label', L('ph.home'));
    byId('arrangedone').setAttribute('aria-label', L('ph.arrange_done'));
    // The number, and the temporary server id beside it when the player wants it there. Staff
    // ask for that id constantly and it is the one thing a player cannot look up on their own
    // phone, so the lock screen is the right place for it: visible without unlocking.
    paintLockMeta();
    applyWallpaper();
    applyDevice();
    applyTheme();
    applyPower(d.power || { battery: d.battery, charging: d.charging, signal: d.signal });
    applyGlass((d.prefs && d.prefs.glass) ?? 55);
    applyBrightness();
    applyStatusFlags();
    primeNowPlaying();
    tick();
    paintNotifs();
    const sp = byId('spilltxt'); if (sp) sp.textContent = L('ph.search');
    hideAuth();
    byId('lock').classList.remove('out');
    byId('lockquick').classList.remove('hidden');
    byId('home').classList.add('behind');
    closeApp(true);
    renderCall();
    if (!(state.prefs || {}).setupComplete) {
      openSetup(0);
    } else if (Number((state.prefs || {}).setupVersion || 0) < 2
        && !(state.prefs || {}).securityEnabled) {
      // Existing characters see only the new security portion once. Their identity,
      // appearance and layout are preserved.
      openSetup(4);
    } else {
      byId('setup').classList.remove('on', 'complete');
      byId('setup').setAttribute('aria-hidden', 'true');
    }
  } else if (d.action === 'close') {
    torchCommit += 1;
    torchPending = false;
    if (cipherPrivateKey && !cipherDemo) post('cipher', { op: 'logout' });
    cipherPrivateKey = null;
    cipherThread = null;
    cipherDemo = false;
    resetTransientUI();
    closeApp(true);
    ccTorch = false;
    paintTorchState();
    byId('device').classList.add('hidden');
  } else if (d.action === 'call') {
    const was = call && call.state;
    call = d.call || null;
    if (!call || call.state !== 'active') { clearInterval(callTimer); callTimer = null; }
    if (call && call.state !== was) { callSpeaker = false; }
    renderCall();
  } else if (d.action === 'message') {
    const m = d.message || {};
    const inOpenThread = (threadGroup && m.group != null &&
                          String(m.group) === String(threadGroup.id)) ||
                         (!m.group && thread && m.from === thread);
    if (inOpenThread) {
      const el = byId('thread');
      if (el) {
        el.insertAdjacentHTML('beforeend', bubbleHtml({ mine: false, body: m.body, kind: m.kind, attachment: m.attachment, from: m.from }));
        wireLocButtons();
        byId('appbody').scrollTop = byId('appbody').scrollHeight;
      }
    } else {
      const groupId = m.group;
      const groupName = m.groupName || L('ph.groups');
      banner({ app: 'messages', icon: 'messages',
        title: groupId ? groupName : nameOfNumber(m.from), body: m.body || L('ph.attach'),
        onClick: () => {
          const a = (state.apps || []).find((x) => x.id === 'messages');
          if (!a) return;
          enterApp(a, null);
          if (groupId) openGroup(groupId, groupName);
          else messageTo(m.from);
        } });
      refresh().then(() => { if (!openApp) renderHome(); });
    }
  } else if (d.action === 'cipher') {
    cipherReceive(d.packet || {});
  } else if (d.action === 'power') {
    applyPower(d.power);
  } else if (d.action === 'banner') {
    banner(d.banner || {});
  } else if (d.action === 'socialRefresh') {
    // Only if that app is what is on screen. Redrawing a social view the player is not
    // looking at would throw away wherever they had scrolled to for nothing.
    if (openApp && openApp.id === d.app) socialRender(d.app);
  } else if (d.action === 'buzz') {
    buzzDevice();
  } else if (d.action === 'camLive') {
    // Framing happens through the handset: `camlive` makes its screen see-through so the
    // camera view shows in it. Lua has the cursor, so the phone's buttons are labels now -
    // the keys named on screen do the work.
    byId('device').classList.toggle('camlive', d.on === true);
    return;
  } else if (d.action === 'camShoot') {
    // The on-screen shutter, fired from Lua's key handler. Same path as the button, so
    // there is one capture and one set of error messages.
    const b = byId('shoot');
    if (b) b.click();
    return;
  } else if (d.action === 'shutter') {
    const device = byId('device');
    device.classList.remove('capturing');
    void device.offsetWidth;
    device.classList.add('capturing');
    ui('shutter');
    clearTimeout(shutterTimer);
    shutterTimer = setTimeout(() => {
      device.classList.remove('capturing');
      shutterTimer = null;
    }, 220);
  } else if (d.action === 'shutterDone') {
    clearTimeout(shutterTimer);
    shutterTimer = null;
    byId('device').classList.remove('capturing');
  } else if (d.action === 'emergency') {
    // A staff broadcast about something happening to the whole city.
    //
    // Drawn even with the phone SHUT and even in Do Not Disturb, which nothing else here does:
    // the point of an emergency alert is that it reaches somebody who was not looking at their
    // phone. That is also exactly why it is behind an ace and a config switch - a channel that
    // ignores a player's own silence settings is one that has to be hard to reach.
    emergencyAlert(d.alert || {});
  } else if (d.action === 'emergencyAlert') {
    // A 911 alert for a service this player answers for. A different thing entirely from the
    // staff broadcast above, despite the neighbouring name: that one goes to a whole city.
    if (d.strings && !Object.keys(S || {}).length) S = d.strings;
    emergency911Alert(d);
  } else if (d.action === 'emergencyStatus') {
    if (d.strings && !Object.keys(S || {}).length) S = d.strings;
    emergency911Status(d.update || {});
  } else if (d.action === 'emergencyUpdate') {
    // Somebody took an alert or closed one. Nothing to show; the queue just stops being wrong.
    if (openApp && openApp.id === 'emergency') RENDER.emergency();
  } else if (d.action === 'strings') {
    // Pushed by the client when the language lands after this page loaded.
    if (d.strings && Object.keys(d.strings).length) {
      S = d.strings;
      warnedNoStrings = false;
      if (d.locale) state.locale = d.locale;
      if (openApp && RENDER[openApp.id]) RENDER[openApp.id]();
      else paintLockMeta();
    }
  } else if (d.action === 'peek') {
    if (d.strings && !Object.keys(S || {}).length) S = d.strings;
    showPeek(d.kind, d.data || {});
  } else if (d.action === 'archive') {
    if (d.strings && !Object.keys(S || {}).length) S = d.strings;
    archivePeek(d.kind, d.data || {});
  } else if (d.action === 'voicemailOffer') {
    enqueuePrompt(() => voicemailOffer(d.number || ''), d.ttlMs);
  } else if (d.action === 'airdrop') {
    const offer = d.offer || {};
    enqueuePrompt(() => airdropOffer(offer), offer.ttlMs);
  } else if (d.action === 'chargeOffer') {
    const offer = d.offer || {};
    enqueuePrompt(() => chargeOfferSheet(offer), Math.max(5, Number(offer.seconds) || 45) * 1000);
  } else if (d.action === 'chargeClear') {
    // They walked out of the zone, or staff closed the stop. The sheet goes with it - but only
    // if the sheet on screen is still THIS one, which is what the epoch answers.
    if (chargeSheetEpoch != null) {
      closeSheet(false, chargeSheetEpoch);
      chargeSheetEpoch = null;
    }
    if (openApp && openApp.id === 'charging') RENDER.charging();
  } else if (d.action === 'callGlitch') {
    // The line broke up. The voice is already gone - the client left the call channel - and
    // this is the half that says WHY, so a player hears silence and reads "bad line" rather
    // than "the phone is broken".
    const ui = byId('callui');
    if (ui) {
      ui.classList.toggle('glitching', d.on === true && d.flicker !== false);
      const label = byId('callstate');
      if (label) {
        if (d.on === true) {
          if (!label.dataset.was) label.dataset.was = label.innerHTML;
          label.innerHTML = '<span class="callbreak">' + esc(L('ph.call_breaking')) + '</span>';
        } else if (label.dataset.was) {
          label.innerHTML = label.dataset.was;
          delete label.dataset.was;
        }
      }
    }
    // A short burst of noise. Synthesised rather than a file: it is a hiss, and shipping a
    // wav of a hiss is a download for something six lines of oscillator does better.
    if (d.on === true && d.static !== false) callStatic();
  } else if (d.action === 'taxiDoc') {
    // doc-taxijob broadcast something, and client/taxi.lua worked out what it meant. The phone
    // notification is raised there, where the mute preferences and the pocket state live; this
    // is the app's half - the mirrored state, and a redraw so an open app is never stale.
    const u = d.update || {};
    const kind = String(u.kind || '');
    if (kind === 'state') {
      taxiDocState = u.state || taxiDocState;
      taxiDocDriver = u.driver || taxiDocDriver;
    } else if (kind === 'fare') {
      taxiDocFare = u.fare || null;
    } else if (kind === 'queue') {
      ui('received');
    }
    if (openApp && openApp.id === 'taxi') RENDER.taxi();
  } else if (d.action === 'taxi') {
    // The config provider's own ride events, which carry what happened.
    if (d.strings && !Object.keys(S || {}).length) S = d.strings;
    const u = d.update || {};
    const kind = String(u.kind || '');
    if (kind !== 'taken' && kind !== 'cancelled') {
      archivePeek('notif', {
        app: 'taxi', icon: 'taxi',
        title: L('app.taxi'),
        body: L('ph.taxi_ev_' + kind),
      });
      ui(kind === 'done' || kind === 'paid' ? 'success' : 'received');
    }
    if (openApp && openApp.id === 'taxi') RENDER.taxi();
  } else if (d.action === 'zuberStatus') {
    // An order moved along in the kitchen. The card and the sound are the client's; this keeps
    // the app honest if it happens to be open on the tracker.
    if (d.strings && !Object.keys(S || {}).length) S = d.strings;
    const u = d.update || {};
    archivePeek('notif', {
      app: 'zuber', icon: 'zuber',
      title: u.restaurant || L('app.zuber'),
      body: L('ph.zuber_st_' + String(u.status || 'pending')),
    });
    if (u.sound !== false) ui(String(u.status) === 'completed' ? 'success' : 'received');
    if (openApp && openApp.id === 'zuber') RENDER.zuber();
  } else if (d.action === 'chargeRefresh') {
    // Auto-accept paid for a stop. Nothing to ask, but FruitCharge is now showing a stale
    // "not charging" if it happens to be open.
    if (openApp && openApp.id === 'charging') RENDER.charging();
  } else if (d.action === 'airdropResult') {
    const r = d.result || {};
    toast(r.ok ? (L('ph.airdrop_took') + (r.name ? ' ' + r.name : '')) : L('ph.airdrop_declined'));
  }
});

wireSideButtons();
tick();

// ══ The warrant terminal ═══════════════════════════════════════
// A full-screen surface separate from the phone. The client raises it when an officer
// interacts with a forensics point. It drives its own server callbacks through dedicated
// NUI names, so nothing here can reach a phone read a player would use.
//
// It reuses nothing of the phone shell on purpose: a police tool that looked like the
// suspect's phone would be confusing. It is a terminal - lists, a search, a status line.

let forensicTarget = null;   // { number, name } once a session is open

function fpost(name, data) {
  return fetch('https://' + RESOURCE_NAME + '/' + name, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data || {}),
  }).then((r) => r.json()).catch(() => ({ error: 'net' }));
}

const fesc = (s) => esc(String(s == null ? '' : s));
const fwhen = (at) => fesc(shortWhen(at));

// A case reference for the visit. Not an identifier of anything - it exists so the terminal
// stamps what it shows, which is what makes it read as evidence handling.
let forensicCase = '';

function forensicNewCase() {
  const now = new Date();
  const stamp = String(now.getFullYear()).slice(2)
    + String(now.getMonth() + 1).padStart(2, '0')
    + String(now.getDate()).padStart(2, '0');
  forensicCase = 'LS-' + stamp + '-' + String(Math.floor(Math.random() * 9000) + 1000);
  const host = byId('forensiccase');
  if (host) host.textContent = forensicCase;
}

function forensicOpen() {
  forensicTarget = null;
  forensicNewCase();
  const mark = byId('forensicmark');
  if (mark) mark.textContent = L('ph.forensic_title');
  byId('forensic').classList.remove('hidden');
  forensicSearch();
}

function forensicClose() {
  // The bench is a panel over the terminal with a running clock on it. Leaving it behind meant
  // an officer who closed the terminal mid-crack had an interval still counting down against a
  // screen that was gone, and a submission fired at nothing when it reached zero.
  benchClose();
  byId('forensic').classList.add('hidden');
  byId('forensicbody').innerHTML = '';
  forensicTarget = null;
  fpost('forensicClose', {});
}

// ── The search: a number, then a session ───────────────────────
function forensicSearch() {
  byId('forensicbody').innerHTML =
    '<div class="forensicsearch">' +
      '<div class="forensicprint">' + svg('fingerprint') + '</div>' +
      '<h2>' + fesc(L('ph.forensic_acquire')) + '</h2>' +
      '<p>' + fesc(L('ph.forensic_acquire_hint')) + '</p>' +
      '<div class="forensicfield">' +
        '<input id="forensicnum" placeholder="555-0000" autocomplete="off" ' +
          'aria-label="' + fesc(L('ph.number')) + '" />' +
        '<button id="forensicgo" type="button">' + fesc(L('ph.forensic_access')) + '</button>' +
      '</div>' +
      '<div class="forensicerr" id="forensicerr"></div>' +
      '<div class="forensicnote">' + fesc(L('ph.forensic_warrant_note')) + '</div>' +
    '</div>';

  const go = async () => {
    const number = byId('forensicnum').value.trim();
    if (!number) { byId('forensicerr').textContent = forensicErr({ error: 'nonumber' }); return; }
    byId('forensicerr').textContent = L('ph.forensic_authorising');
    const r = await fpost('forensicStart', { number });
    if (!r || !r.ok) {
      byId('forensicerr').textContent = forensicErr(r);
      return;
    }
    forensicTarget = { number: r.number, name: r.name };
    forensicView('messages');
  };
  byId('forensicgo').addEventListener('click', go);
  byId('forensicnum').addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
  setTimeout(() => byId('forensicnum') && byId('forensicnum').focus(), 50);
}

function forensicErr(r) {
  const code = (r && r.error) || 'x';
  // The terminal is police-only and its strings used to be hardcoded English, which on a
  // French server made the one tool an officer reads under pressure the only screen in the
  // resource not in their language.
  const key = {
    off: 'ph.forensic_e_off', unauthorised: 'ph.forensic_e_unauthorised',
    notatterminal: 'ph.forensic_e_notatterminal', noitem: 'ph.forensic_e_noitem',
    nonumber: 'ph.forensic_e_nonumber', unknownnumber: 'ph.forensic_e_unknownnumber',
    nosession: 'ph.forensic_e_nosession', net: 'ph.forensic_e_net',
  }[code];
  return key ? L(key) : L('ph.forensic_e_denied');
}

// ── The tabs ───────────────────────────────────────────────────
const FORENSIC_TABS = [
  { id: 'messages', label: 'app.messages', icon: 'messages' },
  { id: 'contacts', label: 'app.contacts', icon: 'contacts' },
  { id: 'calls', label: 'ph.permission_calls', icon: 'phone' },
  { id: 'social', label: 'ph.forensic_social', icon: 'bleet' },
  { id: 'cipher', label: 'app.cipher', icon: 'cipher' },
];

function forensicView(tab) {
  const t = forensicTarget || {};
  byId('forensicbody').innerHTML =
    // The exhibit card: what device this is, under a strip of evidence tape.
    '<div class="forensictarget">' +
      '<div class="ftape">' + fesc(L('ph.forensic_exhibit')) + '</div>' +
      '<div class="ftargetid">' +
        '<b>' + fesc(t.name || t.number) + '</b>' +
        '<span>' + fesc(t.number) + '</span>' +
      '</div>' +
      '<div class="ftargetmeta">' + fesc(L('ph.forensic_case')) + ' ' + fesc(forensicCase) + '</div>' +
      '<button id="forensicnew" type="button">' + fesc(L('ph.forensic_new')) + '</button>' +
    '</div>' +
    '<nav class="forensictabs">' + FORENSIC_TABS.map((x) =>
      '<button class="forensictab' + (x.id === tab ? ' on' : '') + '" data-tab="' + x.id +
      '" type="button">' + svg(x.icon) + '<span>' + fesc(L(x.label)) + '</span></button>').join('') +
    '</nav>' +
    '<div class="forensiclist" id="forensiclist">' +
      '<div class="forensicloading">' + fesc(L('ph.forensic_reading')) + '</div></div>';

  byId('forensicnew').addEventListener('click', forensicSearch);
  [...byId('forensicbody').querySelectorAll('.forensictab')].forEach((b) =>
    b.addEventListener('click', () => forensicView(b.dataset.tab)));

  if (tab === 'messages') forensicMessages();
  else if (tab === 'contacts') forensicContacts();
  else if (tab === 'calls') forensicCalls();
  else if (tab === 'social') forensicSocial();
  else if (tab === 'cipher') forensicCipher();
}

function forensicList(html) {
  const host = byId('forensiclist');
  if (host) host.innerHTML = html;
}
function forensicEmpty(text) { return '<div class="forensicempty">' + fesc(text) + '</div>'; }

async function forensicMessages() {
  const r = await fpost('forensicRead', { what: 'messages' });
  if (!r || !r.ok) { forensicList(forensicEmpty(forensicErr(r))); return; }
  const rows = r.rows || [];
  forensicList(rows.length ? rows.map((m) =>
    '<div class="frow ' + (m.outgoing ? 'out' : 'in') + '">' +
      '<div class="fmeta">' +
        '<span class="ftag">' + fesc(L(m.outgoing ? 'ph.forensic_sent' : 'ph.forensic_recv')) + '</span>' +
        '<span>' + fesc(m.outgoing ? (m.to_num || '?') : (m.from_num || '?')) + '</span>' +
        '<span class="ft">' + fwhen(m.at) + '</span></div>' +
      forensicEvidence(m) + '</div>').join('')
    : forensicEmpty(L('ph.forensic_no_messages')));
}

/// What a seized message actually contained, drawn rather than described.
///
/// A picture message keeps its file in `attachment` and leaves `body` empty, so reading only the
/// body produced a row with a blank line in it - and a blank line in an evidence list reads as a
/// broken terminal, not as "there was nothing here". The photo goes through `photoImg`, the same
/// helper the phone's own thread uses, so a crop or a filter the sender applied is what the
/// officer sees; a caption sent with it is kept underneath.
///
/// A shared position is not an image and must not be drawn as one: its `attachment` is `x;y`,
/// which is evidence in its own right, so it is printed as coordinates.
function forensicEvidence(m) {
  const kind = String((m && m.kind) || 'text');
  const file = String((m && m.attachment) || '');
  const caption = String((m && m.body) || '');

  if (kind === 'image' && file) {
    return '<div class="fbody fevidence">' + photoImg(file, 'fimg') +
      (caption ? '<div class="fcap">' + fesc(caption) + '</div>' : '') + '</div>';
  }
  if (kind === 'location' && file) {
    const at = file.split(';');
    return '<div class="fbody fevidence"><i class="floc">' + svg('map') + fesc(
      L('ph.forensic_location').replace('{x}', Number(at[0]).toFixed(1))
        .replace('{y}', Number(at[1]).toFixed(1))) + '</i></div>';
  }
  // An empty text message is still a row worth showing - it says a message was sent - but it
  // says so in words rather than as a gap.
  if (!caption) {
    return '<div class="fbody"><i class="fenc">' + fesc(L('ph.forensic_no_body')) + '</i></div>';
  }
  return '<div class="fbody">' + fesc(caption) + '</div>';
}

async function forensicContacts() {
  const r = await fpost('forensicRead', { what: 'contacts' });
  if (!r || !r.ok) { forensicList(forensicEmpty(forensicErr(r))); return; }
  const rows = r.rows || [];
  forensicList(rows.length ? rows.map((c) =>
    '<div class="frow"><div class="fbody"><b>' + fesc(c.name) + '</b> ' +
      '<span class="fnum">' + fesc(c.number) + '</span>' +
      (Number(c.favourite) ? '<span class="ftag">' + fesc(L('ph.favorited')) + '</span>' : '') +
      '</div></div>').join('')
    : forensicEmpty(L('ph.forensic_no_contacts')));
}

async function forensicCalls() {
  const r = await fpost('forensicRead', { what: 'calls' });
  if (!r || !r.ok) { forensicList(forensicEmpty(forensicErr(r))); return; }
  const rows = r.rows || [];
  forensicList(rows.length ? rows.map((c) =>
    '<div class="frow ' + (c.direction === 'out' ? 'out' : 'in') + '"><div class="fmeta">' +
      '<span class="ftag">' +
        fesc(L(c.direction === 'out' ? 'ph.forensic_out' : 'ph.forensic_in')) + '</span>' +
      '<span>' + fesc(c.other_num) + '</span>' +
      (Number(c.answered) ? '' : '<span class="ftag warn">' + fesc(L('ph.call_missed')) + '</span>') +
      '<span class="ft">' + fwhen(c.at) + '</span></div></div>').join('')
    : forensicEmpty(L('ph.forensic_no_calls')));
}

async function forensicSocial() {
  const r = await fpost('forensicRead', { what: 'social' });
  if (!r || !r.ok) { forensicList(forensicEmpty(forensicErr(r))); return; }
  const posts = r.posts || [], dms = r.dms || [];
  let html = '';
  if (posts.length) {
    html += '<div class="fsub">' + fesc(L('ph.forensic_posts')) + '</div>' + posts.map((p) =>
      '<div class="frow"><div class="fmeta">' +
      '<span class="ftag">' + fesc(p.app) + '</span>' +
      '<span class="ft">' + fwhen(p.at) + '</span></div>' +
      (p.body ? '<div class="fbody">' + fesc(p.body) + '</div>' : '') +
      // The picture itself. This said the word "image" in italics, which told an officer that
      // something was posted and nothing about what - and on Snapmatic the picture IS the post.
      (p.image ? '<div class="fbody fevidence">' + photoImg(p.image, 'fimg') + '</div>' : '') +
      '</div>').join('');
  }
  if (dms.length) {
    html += '<div class="fsub">' + fesc(L('ph.forensic_dms')) + '</div>' + dms.map((d) =>
      '<div class="frow ' + (d.outgoing ? 'out' : 'in') + '"><div class="fmeta">' +
      '<span class="ftag">' + fesc(d.app) + '</span><span>' +
      (d.outgoing ? '&rarr; @' + fesc(d.to_handle || '?') : '@' + fesc(d.from_handle || '?')) +
      '</span><span class="ft">' + fwhen(d.at) + '</span></div>' +
      (d.body ? '<div class="fbody">' + fesc(d.body) + '</div>' : '') +
      (d.image ? '<div class="fbody fevidence">' + photoImg(d.image, 'fimg') + '</div>' : '') +
      '</div>').join('');
  }
  forensicList(html || forensicEmpty(L('ph.forensic_no_social')));
}

// ── Cipher: metadata always, content only with a hard crack ─────
async function forensicCipher() {
  const r = await fpost('forensicRead', { what: 'cipher' });
  if (!r || !r.ok) { forensicList(forensicEmpty(forensicErr(r))); return; }
  const rows = r.rows || [];
  const banner = '<div class="fcipherbanner' + (r.interceptOn ? ' warn' : '') + '">' +
    svg('lockshut') + '<span>' +
    fesc(L(r.interceptOn ? 'ph.forensic_cipher_warn' : 'ph.forensic_cipher_none')) +
    '</span></div>';
  forensicList(banner + (rows.length ? rows.map((m) =>
    '<div class="frow ' + (m.outgoing ? 'out' : 'in') + '" data-cid="' + m.id + '">' +
      '<div class="fmeta"><span class="ftag">' +
        fesc(L(m.outgoing ? 'ph.forensic_sent' : 'ph.forensic_recv')) + '</span><span>' +
        (m.outgoing ? '&rarr; @' + fesc(m.to_handle || '?') : '@' + fesc(m.from_handle || '?')) +
      '</span><span class="ft">' + fwhen(m.at) + '</span></div>' +
      '<div class="fbody fcipherbody">' +
        (m.recoverable
          ? '<button class="fcrack" data-id="' + m.id + '" type="button">' +
              fesc(L('ph.forensic_crack')) + '</button>'
          : '<i class="fenc">' + svg('lockshut') + fesc(L('ph.forensic_encrypted')) + '</i>') +
      '</div></div>').join('') : forensicEmpty(L('ph.forensic_no_cipher'))));

  [...byId('forensiclist').querySelectorAll('.fcrack')].forEach((b) =>
    b.addEventListener('click', async () => {
      const cell = b.parentElement;
      b.disabled = true;
      cell.innerHTML = '<i class="fcracking">' + fesc(L('ph.forensic_cracking')) + '</i>';
      const cr = await fpost('forensicCrack', { id: Number(b.dataset.id) });

      // The bench route: the server sent a puzzle rather than a verdict.
      if (cr && cr.ok && cr.bench) { forensicBench(cr.bench, cell); return; }

      if (cr && cr.ok && cr.cracked) {
        cell.innerHTML = '<span class="fcracked">' + fesc(cr.body) + '</span>';
      } else if (cr && cr.ok) {
        // Rebound by redrawing the whole tab: a Retry button written into the cell by hand
        // has no listener on it, which is what the `forensicCipher()` call underneath was
        // silently fixing. Redraw first, and there is nothing to fix.
        forensicCipher();
      } else {
        cell.innerHTML = '<i class="fenc">' + fesc(forensicErr(cr)) + '</i>';
      }
    }));
}

// ══ The cryptanalysis bench ════════════════════════════════════
// Three stages, one at a time, over the evidence list. Each is a different real technique and
// each arrives generated by the server, which keeps the answers: nothing here decides whether a
// crack succeeded, it only collects what the officer worked out and submits it.
//
// The state is module-level rather than passed around because the clock, the stage index and the
// working answers are all read by handlers that outlive any one render.
let benchData = null;      // the server's puzzle, while the bench is up
let benchStage = 0;        // which stage is on screen
let benchAnswers = [];     // what will be submitted, one entry per stage
let benchClock = null;     // the countdown interval
let benchLeft = 0;         // seconds remaining
let benchCell = null;      // the row that opened it, to write the result back into
let benchWork = null;      // the current stage's working state

/// A list from Lua, as a list.
///
/// An EMPTY Lua table serialises to `{}` and not to `[]`, so a bench configured with no hints,
/// or a stage whose clue list happened to be empty, arrived here as an object - and the first
/// `.map` on it threw inside a render, which takes the whole panel down rather than drawing one
/// bench without hints. Every list off the wire goes through this.
function farr(v) { return Array.isArray(v) ? v : []; }

function forensicBench(bench, cell) {
  benchData = bench;
  benchCell = cell;
  benchStage = 0;
  benchAnswers = [];
  benchLeft = Math.max(20, Number(bench.seconds) || 150);
  cell.innerHTML = '<i class="fcracking">' + fesc(L('ph.forensic_bench_open')) + '</i>';
  benchDraw();
  benchTick();
}

function benchTick() {
  if (benchClock) clearInterval(benchClock);
  benchClock = setInterval(() => {
    benchLeft -= 1;
    const el = byId('benchclock');
    if (el) {
      el.textContent = benchTime(benchLeft);
      el.classList.toggle('low', benchLeft <= 20);
    }
    // Out of time is a submission, not a silence: the server counts the attempt either way, so
    // telling it what happened is what keeps the two sides agreeing on how many are left.
    if (benchLeft <= 0) benchSubmit(true);
  }, 1000);
}

function benchTime(s) {
  const n = Math.max(0, Math.floor(s));
  return Math.floor(n / 60) + ':' + String(n % 60).padStart(2, '0');
}

function benchClose() {
  if (benchClock) { clearInterval(benchClock); benchClock = null; }
  const host = byId('bench');
  if (host) host.remove();
  benchData = null;
  benchWork = null;
}

/// The frame: a stage rail, the clock, and whichever bench is current.
function benchDraw() {
  const stages = farr(benchData && benchData.stages);
  const stage = stages[benchStage];
  if (!stage) return;
  benchWork = null;

  let host = byId('bench');
  if (!host) {
    host = document.createElement('div');
    host.id = 'bench';
    host.className = 'bench';
    byId('forensic').appendChild(host);
  }

  host.innerHTML =
    '<div class="benchhead">' +
      '<div class="benchtitle">' + svg('lockshut') + '<b>' +
        fesc(L('ph.forensic_bench')) + '</b>' +
        '<span class="benchattempts">' + fesc(L('ph.forensic_bench_attempts')
          .replace('{n}', String(benchData.attemptsLeft || 1))) + '</span></div>' +
      '<div class="benchclock" id="benchclock">' + benchTime(benchLeft) + '</div>' +
      '<button class="benchgiveup" id="benchgiveup" type="button">' +
        fesc(L('ph.forensic_bench_abort')) + '</button>' +
    '</div>' +
    '<div class="benchrail">' + stages.map((s, i) =>
      '<span class="benchstep' + (i === benchStage ? ' on' : (i < benchStage ? ' done' : '')) +
      '">' + fesc(L('ph.forensic_bench_' + s.kind)) + '</span>').join('') + '</div>' +
    '<div class="benchbody" id="benchbody"></div>' +
    '<div class="benchfoot">' +
      '<div class="benchhint" id="benchhint">' +
        fesc(L('ph.forensic_bench_hint_' + stage.kind)) + '</div>' +
      '<button class="benchgo" id="benchgo" type="button">' +
        fesc(L(benchStage + 1 >= stages.length
          ? 'ph.forensic_bench_submit' : 'ph.forensic_bench_next')) + '</button>' +
    '</div>';

  byId('benchgiveup').addEventListener('click', () => benchSubmit(true));
  byId('benchgo').addEventListener('click', benchAdvance);

  if (stage.kind === 'substitution') benchSubstitution(stage);
  else if (stage.kind === 'xorkey') benchXor(stage);
  else if (stage.kind === 'rotors') benchRotors(stage);
}

/// Stage on to the next, or submit everything.
function benchAdvance() {
  const stages = farr(benchData && benchData.stages);
  benchAnswers[benchStage] = benchCollect(stages[benchStage]);
  if (benchStage + 1 < stages.length) { benchStage += 1; benchDraw(); return; }
  benchSubmit(false);
}

function benchCollect(stage) {
  if (!stage || !benchWork) return null;
  if (stage.kind === 'substitution') return benchWork.plain();
  if (stage.kind === 'xorkey') return benchWork.key.slice();
  if (stage.kind === 'rotors') return benchWork.rotors.slice();
  return null;
}

async function benchSubmit(gaveup) {
  if (!benchData) return;
  const id = benchData.id;
  if (benchClock) { clearInterval(benchClock); benchClock = null; }

  // A stage the officer never reached submits whatever it had, which is nothing - the server
  // marks it wrong, which is the truth. Only the LAST stage needs collecting here, because
  // every earlier one was collected on its way past.
  if (!gaveup) benchAnswers[benchStage] = benchCollect(farr(benchData.stages)[benchStage]);

  const body = byId('benchbody');
  if (body) body.innerHTML = '<div class="benchwait">' +
    fesc(L('ph.forensic_bench_checking')) + '</div>';

  const r = await fpost('forensicCrackSolve',
    { id, answers: benchAnswers, gaveup: gaveup === true });
  const cell = benchCell;
  benchClose();
  if (!cell) return;

  if (r && r.ok && r.cracked) {
    cell.innerHTML = '<span class="fcracked">' + fesc(r.body) + '</span>';
    return;
  }
  if (r && r.ok) {
    // Why it failed, in the officer's terms. `corrupt` is the one worth separating: the key WAS
    // recovered and the intercepted fragment was unusable anyway, which is the wiretap's fault
    // and not theirs - saying "wrong key" there would teach them the wrong lesson.
    const reason = String(r.reason || 'wrong');
    const key = reason === 'corrupt' ? 'ph.forensic_bench_corrupt'
      : (reason === 'gaveup' ? 'ph.forensic_bench_aborted' : 'ph.forensic_bench_wrong');
    cell.innerHTML = '<i class="fenc">' + fesc(L(key)) + '</i>';
    // Redrawn so the Crack button comes back with a live listener on it, and with the attempt
    // count the server now holds rather than the one this page remembered.
    setTimeout(forensicCipher, 1600);
    return;
  }
  cell.innerHTML = '<i class="fenc">' + fesc(forensicErr(r)) + '</i>';
}

// ── Bench one: frequency analysis ──────────────────────────────
// The ciphertext, a histogram, and a keyboard of assignments. Clicking a cipher letter and then
// a plaintext letter binds them, and every occurrence updates at once - which is the whole point
// of a substitution attack: one good guess cascades.
function benchSubstitution(stage) {
  const LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  const map = {};            // cipher letter -> plain letter
  const locked = {};         // the mappings the server gave away, which cannot be undone
  farr(stage.hints).forEach((h) => { map[h.c] = h.p; locked[h.c] = true; });
  let picked = null;         // the cipher letter awaiting a plaintext letter

  benchWork = {
    plain: () => String(stage.cipher || '').split('')
      .map((ch) => (ch === ' ' ? ' ' : (map[ch] || '.'))).join(''),
  };

  const draw = () => {
    const body = byId('benchbody');
    if (!body) return;
    const cipher = String(stage.cipher || '');
    body.innerHTML =
      '<div class="benchcrypt">' + cipher.split('').map((ch) => ch === ' '
        ? '<span class="bgap"></span>'
        : '<button class="bcell' + (picked === ch ? ' picked' : '') +
          (locked[ch] ? ' locked' : (map[ch] ? ' filled' : '')) +
          '" type="button" data-c="' + fesc(ch) + '">' +
          '<b>' + fesc(map[ch] || '·') + '</b><small>' + fesc(ch) + '</small></button>').join('') +
      '</div>' +
      '<div class="benchfreq">' + farr(stage.freq).map((f) =>
        '<span class="bfreq"><b>' + fesc(f.c) + '</b>' +
        '<i style="height:' + Math.max(3, Math.min(26, Number(f.n) * 5)) + 'px"></i>' +
        '<small>' + fesc(String(f.n)) + '</small></span>').join('') + '</div>' +
      '<div class="benchkeys">' + LETTERS.split('').map((p) =>
        '<button class="bkey" type="button" data-p="' + p + '"' +
        (picked ? '' : ' disabled') + '>' + p + '</button>').join('') +
        '<button class="bkey wipe" type="button" data-p="">' +
          fesc(L('ph.forensic_bench_clear')) + '</button>' +
      '</div>';

    [...body.querySelectorAll('.bcell')].forEach((b) => b.addEventListener('click', () => {
      if (locked[b.dataset.c]) return;
      picked = picked === b.dataset.c ? null : b.dataset.c;
      draw();
    }));
    [...body.querySelectorAll('.bkey')].forEach((b) => b.addEventListener('click', () => {
      if (!picked) return;
      if (b.dataset.p) map[picked] = b.dataset.p; else delete map[picked];
      picked = null;
      draw();
    }));
  };
  draw();
}

// ── Bench two: align the key ───────────────────────────────────
// A repeating-key XOR whose header is known. Each key byte is a dial, and the decode under it
// updates live, so the officer turns each dial until the header appears. Known-plaintext, played.
function benchXor(stage) {
  const bytes = farr(stage.bytes).map((b) => Number(b) || 0);
  const width = Math.max(1, Number(stage.width) || 3);
  const key = new Array(width).fill(0);
  benchWork = { key };

  const decoded = () => bytes.map((b, i) => {
    const code = b ^ key[i % width];
    return (code >= 32 && code < 127) ? String.fromCharCode(code) : '·';
  }).join('');

  const draw = () => {
    const body = byId('benchbody');
    if (!body) return;
    const out = decoded();
    const want = String(stage.header || '');
    const good = out === want;
    body.innerHTML =
      '<div class="benchtarget"><small>' + fesc(L('ph.forensic_bench_header')) +
        '</small><code>' + fesc(want) + '</code></div>' +
      '<div class="benchbytes">' + bytes.map((b) =>
        '<span>' + fesc(b.toString(16).toUpperCase().padStart(2, '0')) + '</span>').join('') +
      '</div>' +
      '<div class="benchout' + (good ? ' good' : '') + '"><code>' + fesc(out) + '</code></div>' +
      '<div class="benchdials">' + key.map((v, i) =>
        '<div class="bdial"><small>' + fesc(L('ph.forensic_bench_byte')
          .replace('{n}', String(i + 1))) + '</small>' +
        '<div class="bdialrow">' +
          '<button type="button" data-d="' + i + '" data-s="-16">&laquo;</button>' +
          '<button type="button" data-d="' + i + '" data-s="-1">&lsaquo;</button>' +
          '<b>' + fesc(v.toString(16).toUpperCase().padStart(2, '0')) + '</b>' +
          '<button type="button" data-d="' + i + '" data-s="1">&rsaquo;</button>' +
          '<button type="button" data-d="' + i + '" data-s="16">&raquo;</button>' +
        '</div></div>').join('') + '</div>';

    [...body.querySelectorAll('.bdialrow button')].forEach((b) =>
      b.addEventListener('click', () => {
        const at = Number(b.dataset.d);
        // Wraps rather than clamps: a dial that stops at FF makes the officer walk all the way
        // back down to try the other end.
        key[at] = ((key[at] + Number(b.dataset.s)) % 256 + 256) % 256;
        draw();
      }));
  };
  draw();
}

// ── Bench three: the rotors ────────────────────────────────────
// Four rotors and a system of modular constraints. Each clue reads as an equation and turns
// green when it holds, so the officer can work the system rather than guess at it.
function benchRotors(stage) {
  const rotors = [0, 0, 0, 0];
  const clues = farr(stage.clues);
  benchWork = { rotors };

  const holds = (c) => {
    const v = Number(c.v) || 0;
    if (c.op === 'sum') return ((rotors[c.a - 1] + rotors[c.b - 1]) % 26) === v;
    if (c.op === 'diff') return (((rotors[c.a - 1] - rotors[c.b - 1]) % 26 + 26) % 26) === v;
    if (c.op === 'total') return rotors.reduce((n, x) => n + x, 0) === v;
    return false;
  };
  const label = (c) => {
    if (c.op === 'sum') return 'R' + c.a + ' + R' + c.b + ' ≡ ' + c.v + ' (mod 26)';
    if (c.op === 'diff') return 'R' + c.a + ' − R' + c.b + ' ≡ ' + c.v + ' (mod 26)';
    if (c.op === 'total') return 'R1 + R2 + R3 + R4 = ' + c.v;
    return '?';
  };

  const draw = () => {
    const body = byId('benchbody');
    if (!body) return;
    body.innerHTML =
      '<div class="benchclues">' + clues.map((c) =>
        '<span class="bclue' + (holds(c) ? ' ok' : '') + '">' + fesc(label(c)) + '</span>').join('') +
      '</div>' +
      '<div class="benchrotors">' + rotors.map((v, i) =>
        '<div class="brotor"><small>R' + (i + 1) + '</small>' +
        '<button type="button" data-r="' + i + '" data-s="1">+</button>' +
        '<b>' + String(v).padStart(2, '0') + '</b>' +
        '<button type="button" data-r="' + i + '" data-s="-1">&minus;</button>' +
        '<i>' + 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'[v] + '</i></div>').join('') + '</div>';

    [...body.querySelectorAll('.brotor button')].forEach((b) =>
      b.addEventListener('click', () => {
        const at = Number(b.dataset.r);
        rotors[at] = ((rotors[at] + Number(b.dataset.s)) % 26 + 26) % 26;
        draw();
      }));
  };
  draw();
}

byId('forensicx').addEventListener('click', forensicClose);

// The client raises and lowers the terminal.
window.addEventListener('message', (e) => {
  const d = e.data || {};
  if (d.action === 'forensic:open') forensicOpen();
  else if (d.action === 'forensic:close') forensicClose();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !byId('forensic').classList.contains('hidden')) forensicClose();
});

// ══ The payphone ═══════════════════════════════════════════════
// The third surface, after the phone and the warrant terminal. A player standing at a call
// box has no handset in hand, so this deliberately looks like the box and not like iFruit:
// a metal panel, a credit meter and a keypad.
//
// It places calls and it never receives them. That is not a rule this page enforces - the
// server does, three times over - but it is the reason there is no incoming state to draw
// here, and the panel says so out loud rather than leaving the player to wonder.

let boothState = null;   // the server's answer to `booth:open`, while the panel is up
let boothCall = null;    // the live call, mirrored from the client
let boothDialled = '';

const bnum = (v, d) => (Number.isFinite(Number(v)) ? Number(v) : (d || 0));

/** Seconds as m:ss, which is how talk time on a card reads. */
function boothClock(seconds) {
  const s = Math.max(0, Math.floor(bnum(seconds)));
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
}

function boothOpen(data, call) {
  boothState = data || {};
  boothCall = call || null;
  boothDialled = '';
  byId('boothbrand').textContent = boothState.brand || 'Badger';
  byId('boothname').textContent = L('ph.booth_title');
  byId('booth').classList.remove('hidden');
  boothRender();
}

function boothClose() {
  byId('booth').classList.add('hidden');
  byId('boothbody').innerHTML = '';
  boothState = null;
  boothDialled = '';
  fpost('boothClose', {});
}

/** The meter, pushed by the server's ticker while a call runs. */
function boothCredit(payload) {
  if (!boothState) return;
  if (payload && payload.credit != null) boothState.credit = bnum(payload.credit);
  if (payload && payload.free != null) boothState.free = payload.free === true;
  const meter = byId('boothmeter');
  if (meter) {
    meter.textContent = boothState.free ? L('ph.booth_free_mode') : boothClock(boothState.credit);
    meter.classList.toggle('empty', !boothState.free && bnum(boothState.credit) <= 0);
  } else {
    boothRender();
  }
}

/** The call state changed. Redraw rather than patch: the panel has two whole faces. */
function boothSetCall(call, reason) {
  boothCall = call || null;
  if (!boothState) return;
  if (!call && reason && reason !== 'hangup') {
    boothState.notice = L('ph.call_' + reason);
  }
  boothRender();
}

function boothErr(r) {
  const key = (r && r.error) ? String(r.error) : 'x';
  const message = L('ph.booth_err_' + key);
  // An unmapped error code must not surface as a raw key on a player's screen.
  return message === 'ph.booth_err_' + key ? L('ph.booth_err_x') : message;
}

// ── The panel ──────────────────────────────────────────────────
// Laid out the way a real faceplate is, top to bottom: the operator's identification plate
// with the box number stamped on it, the coin slot, the readout, the keys, the card reader,
// then the instruction placard. The orange ID plate is the detail that sells it - every
// payphone carries one, and it is where the number of the box is printed.
function boothRender() {
  const s = boothState || {};
  const inCall = boothCall != null;

  byId('boothbody').innerHTML =
    '<div class="boothid">' +
    '<div class="boothidleft">' +
    '<span>' + esc(L('ph.booth_box_number')) + '</span>' +
    '<strong>' + esc(s.number || '') + '</strong>' +
    '</div>' +
    '<div class="boothidright">' +
    '<span>' + esc(s.free ? '' : L('ph.booth_credit')) + '</span>' +
    '<strong id="boothmeter" class="' +
    (!s.free && bnum(s.credit) <= 0 ? 'empty' : '') + '">' +
    esc(s.free ? L('ph.booth_free_mode') : boothClock(s.credit)) + '</strong>' +
    '</div>' +
    '<em>' + esc(L('ph.booth_incoming_never')) + '</em>' +
    '</div>' +
    // The coin slot. Nothing goes in it - the card reader below is what takes payment - but
    // the slot and the return cup are what the eye looks for on a call box.
    '<div class="boothslot" aria-hidden="true"><i></i><span>' +
    esc(L('ph.booth_coin_slot')) + '</span><i></i></div>' +
    (inCall ? boothCallFace() : boothDialFace(s));

  if (inCall) {
    byId('boothend').addEventListener('click', async () => {
      await fpost('boothHangup', {});
    });
    return;
  }
  boothWireDial(s);
}

/** In a call: the number on the readout, a lamp for the line state, and the hook. */
function boothCallFace() {
  const c = boothCall || {};
  const label = c.state === 'active' ? L('ph.booth_connected')
    : c.state === 'out' ? L('ph.booth_ringing')
      : L('ph.booth_dialling');
  return '<div class="boothcall">' +
    '<div class="boothlcd big"><span>' + esc(c.number || '') + '</span></div>' +
    '<div class="boothlamp' + (c.state === 'active' ? ' live' : '') + '">' +
    '<i></i>' + esc(label) + '</div>' +
    '<button class="boothend" id="boothend" type="button">' +
    esc(L('ph.booth_hangup')) + '</button>' +
    '</div>';
}

// ── The keypad's voice ─────────────────────────────────────────
// A payphone key makes TWO sounds, and both are needed for it to feel like one.
//
//   the clack   a milled chrome button bottoming out on a steel chassis. Struck metal, so
//               its partials are inharmonic - rendered by tools/make-sounds.py as a noise
//               transient plus the free-bar ratios, with an oscillator fallback in UI_TONES.
//   the tone    the DTMF pair the line genuinely puts on the wire for that digit. This is
//               the actual sound of dialling; without it a keypad is just a button.
//
// The real frequency table, not an approximation of it: rows 697/770/852/941 against
// columns 1209/1336/1477.
const DTMF_ROWS = [697, 770, 852, 941];
const DTMF_COLS = [1209, 1336, 1477];
const DTMF_GRID = ['123', '456', '789', '*0#'];

function dtmfPair(key) {
  for (let r = 0; r < DTMF_GRID.length; r++) {
    const c = DTMF_GRID[r].indexOf(key);
    if (c >= 0) return [DTMF_ROWS[r], DTMF_COLS[c]];
  }
  return null;
}

/** One press: the clack, then the pair of tones under it. */
function boothKeyPress(key) {
  const del = key === 'del';
  ui(del ? 'boothkeyback' : 'boothkey');

  const pair = del ? null : dtmfPair(key);
  if (!pair) return;
  const v = (state.prefs || {}).ringVolume;
  const vol = v == null ? 0.7 : v;
  if (vol <= 0) return;
  // Quieter than the clack and a touch longer, the way a dial tone sits under the mechanics
  // of the button rather than on top of it. Both frequencies at equal level, as DTMF is.
  pair.forEach((f) => note(f, 0.004, 0.075, 0.028 * vol, 'sine'));
}

// The letters stamped under the digits. The OLD scheme on purpose: no Q and no Z, and 0 is
// the operator - which is what a call box of this age would carry.
const BOOTH_KEYS = [
  ['1', ''], ['2', 'ABC'], ['3', 'DEF'],
  ['4', 'GHI'], ['5', 'JKL'], ['6', 'MNO'],
  ['7', 'PRS'], ['8', 'TUV'], ['9', 'WXY'],
  ['*', ''], ['0', 'OPER'], ['#', ''],
];

/** Idle: the readout, the keys, the card reader, and the instruction placard. */
function boothDialFace(s) {
  const canCard = s.cardItem && !s.free;
  return '<div class="boothdial">' +
    // A recessed amber readout behind glass, not a text box. The input is still a real
    // input so a keyboard works; it is only dressed as a segment display.
    '<div class="boothlcd">' +
    '<input id="boothinput" inputmode="numeric" autocomplete="off" maxlength="' +
    esc(String(bnum(s.maxDialLength, 20))) + '" ' +
    'placeholder="' + esc(L('ph.booth_dial')) + '" value="' + esc(boothDialled) + '" />' +
    '</div>' +
    '<div class="boothkeys">' + BOOTH_KEYS.map(([k, letters]) =>
      '<button type="button" data-key="' + esc(k) + '">' +
      '<b>' + esc(k) + '</b>' + (letters ? '<i>' + esc(letters) + '</i>' : '') +
      '</button>').join('') +
    '<button type="button" class="wide" data-key="del"><b>&#9003;</b></button>' +
    '</div>' +
    '<button class="boothgo" id="boothgo" type="button">' + esc(L('ph.booth_call')) + '</button>' +
    // The card reader: a milled slot with the direction of travel engraved beside it.
    (canCard ? '<button class="boothcard" id="boothcard" type="button">' +
      '<span class="boothcardslot"></span>' +
      '<span class="boothcardtext">' + esc(L('ph.booth_insert_card')) + '</span>' +
      '</button>' : '') +
    // The instruction placard, screwed to the plate. Engraved, not printed.
    '<div class="boothplacard">' +
    (canCard ? '<p>' + esc(L('ph.booth_insert_hint').replace('{minutes}',
      String(Math.floor(bnum(s.cardSeconds, 600) / 60)))) + '</p>' : '') +
    '<p>' + esc(L('ph.booth_emergency_free')) + '</p>' +
    (s.free ? '' : '<p>' +
      esc(L('ph.booth_rate').replace('{seconds}', String(bnum(s.costPerMinute, 60)))) + '</p>') +
    '</div>' +
    '<div class="bootherr' + (s.notice ? ' show' : '') + '" id="bootherr">' +
    esc(s.notice || '') + '</div>' +
    '</div>';
}

function boothWireDial(s) {
  const input = byId('boothinput');
  const err = byId('bootherr');

  const say = (message) => {
    if (!err) return;
    err.textContent = message || '';
    err.classList.toggle('show', !!message);
  };

  input.addEventListener('input', () => { boothDialled = input.value; });

  [...byId('boothbody').querySelectorAll('.boothkeys button')].forEach((b) =>
    b.addEventListener('click', () => {
      const del = b.dataset.key === 'del';
      const cap = bnum((boothState || {}).maxDialLength, 20);
      if (del) boothDialled = boothDialled.slice(0, -1);
      else if (boothDialled.length < cap) boothDialled += b.dataset.key;
      input.value = boothDialled;
      boothKeyPress(b.dataset.key);
    }));

  const go = async () => {
    const number = String(input.value || '').trim();
    if (!number) return;
    say(L('ph.booth_dialling') + '...');
    const r = await fpost('boothCall', { number });
    if (!r || !r.ok) {
      // `lowcredit` is the one error worth being specific about: it tells the player how
      // much more talk time the box wants before it will connect anything.
      say(r && r.error === 'lowcredit'
        ? L('ph.booth_minimum').replace('{seconds}', String(bnum(r.need, 30)))
        : boothErr(r));
      return;
    }
    // The call itself arrives through `booth:call` from the client, so nothing is drawn
    // here: a call the server has not confirmed is a call that is not happening.
    say('');
  };

  byId('boothgo').addEventListener('click', go);
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });

  const card = byId('boothcard');
  if (card) {
    card.addEventListener('click', async () => {
      const r = await fpost('boothCard', {});
      if (!r || !r.ok) { say(boothErr(r)); return; }
      if (boothState) {
        boothState.credit = bnum(r.credit);
        boothState.notice = '';
      }
      boothCredit({ credit: r.credit });
      say(L('ph.booth_card_added').replace('{minutes}',
        String(Math.floor(bnum(r.added, 0) / 60))));
      ui('success');
    });
  }

  if (s.notice) { say(s.notice); s.notice = ''; }
  setTimeout(() => byId('boothinput') && byId('boothinput').focus(), 50);
}

byId('boothx').addEventListener('click', boothClose);

// The client raises and lowers the box, and keeps its meter and its call in step.
window.addEventListener('message', (e) => {
  const d = e.data || {};
  if (d.action === 'booth:open') {
    // A payphone can be the FIRST thing this page ever draws - it is reachable without
    // opening the phone at all - so the strings arrive with it rather than being assumed.
    if (d.strings && Object.keys(d.strings).length) S = d.strings;
    boothOpen(d.data, d.call);
  }
  else if (d.action === 'booth:close') boothClose();
  else if (d.action === 'booth:credit') boothCredit(d.data);
  else if (d.action === 'booth:call') boothSetCall(d.call, d.reason);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !byId('booth').classList.contains('hidden')) boothClose();
});

// ══ FaceTime live picture ══════════════════════════════════════
// Experimental, opt-in, and the only reason it is affordable at all: the raw screen
// capture the client hands over is far too big to relay, so it is shrunk and cropped HERE
// before anything is sent. What leaves the page is a thumbnail of a few kilobytes.
//
// The crop matters. The capture is the whole screen, phone included, so the frame is
// taken from the side of the screen the phone is NOT on: the player's face fills that
// half, because a video call puts the front camera up.
const faceCanvas = document.createElement('canvas');

function faceShrink(dataUri) {
  const cfg = state.facetime || {};
  const w = Math.max(80, Math.min(480, Number(cfg.width) || 220));
  const h = Math.max(80, Math.min(640, Number(cfg.height) || 300));
  const q = Math.max(0.1, Math.min(0.9, Number(cfg.quality) || 0.4));

  const img = new Image();
  img.onload = () => {
    // Take a portrait slice from the half of the screen the phone does not cover.
    const onRight = ((state.prefs || {}).side || 'right') === 'right';
    const sliceW = Math.floor(img.width * 0.42);
    const sliceH = Math.min(img.height, Math.floor(sliceW * (h / w)));
    const sx = onRight ? Math.floor(img.width * 0.06) : Math.floor(img.width * 0.52);
    const sy = Math.max(0, Math.floor((img.height - sliceH) / 2));

    faceCanvas.width = w;
    faceCanvas.height = h;
    const ctx = faceCanvas.getContext('2d');
    try {
      ctx.drawImage(img, sx, sy, sliceW, sliceH, 0, 0, w, h);
      const small = faceCanvas.toDataURL('image/jpeg', q);
      // Self view, straight from the canvas: no round trip for your own picture.
      faceShow('faceself', small);
      post('faceFrame', { frame: small });
    } catch (e) { /* a capture that will not draw is simply skipped */ }
  };
  img.onerror = () => {};
  img.src = dataUri;
}

// Put a frame into one of the two panels, creating it the first time.
function faceShow(id, dataUri) {
  const ui = byId('callui');
  if (!ui) return;
  let el = byId(id);
  if (!dataUri) { if (el) el.remove(); return; }
  if (!el) {
    el = document.createElement('img');
    el.id = id;
    el.className = id === 'faceself' ? 'faceself' : 'facepeer';
    el.alt = '';
    ui.appendChild(el);
  }
  el.src = dataUri;
}

// Leaving a call clears both panels, so a dead frame never lingers on the next one.
function faceClear() {
  faceShow('faceself', null);
  faceShow('facepeer', null);
}

window.addEventListener('message', (e) => {
  const d = e.data || {};
  if (d.action === 'faceShrink' && d.data) faceShrink(d.data);
  else if (d.action === 'facePeer') faceShow('facepeer', d.data || null);
  else if (d.action === 'call' && !d.call) faceClear();
});

// ══ Boot trace ════════════════════════════════════════════════════════════
// Silent unless the server asks for it: `set phone_debug true`, forwarded to the page in
// the open payload. These two lines found a bug that produced no error anywhere - the page
// was healthy, the message arrived, and a guard three lines in was dropping it - so they
// are worth keeping. They are not worth printing on a working server.
window.addEventListener('message', (e) => {
  const d = e.data || {};
  if (d.action !== 'open' || window.__vphoneOpenSeen) return;
  window.__vphoneOpenSeen = true;
  if (!d.debug) return;

  console.info('[v-phone] open received | e.source=' +
    ((e.source === null) ? 'null' : (e.source === window) ? 'window' : 'foreign') +
    ' | frames=' + window.frames.length + ' | origin=' + (e.origin || '(empty)'));

  // Only speaks when the phone is open and cannot be seen, which is otherwise
  // indistinguishable from the page never having run at all.
  setTimeout(() => {
    const el = document.getElementById('device');
    if (!el) { console.error('[v-phone] #device is missing from the page'); return; }
    const cs = getComputedStyle(el), r = el.getBoundingClientRect();
    const why = [];
    if (el.classList.contains('hidden')) why.push('still has .hidden');
    if (cs.display === 'none') why.push('display:none');
    if (cs.visibility !== 'visible') why.push('visibility:' + cs.visibility);
    if (parseFloat(cs.opacity) < 0.01) why.push('opacity:' + cs.opacity);
    if (r.width < 1 || r.height < 1) why.push('zero size');
    if (r.right <= 0 || r.bottom <= 0 || r.left >= innerWidth || r.top >= innerHeight) {
      why.push('off-screen at ' + Math.round(r.x) + ',' + Math.round(r.y));
    }
    if (why.length) console.error('[v-phone] open but not visible: ' + why.join('; '));
  }, 600);
});
