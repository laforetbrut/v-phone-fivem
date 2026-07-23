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
  if (['ambient', 'calls', 'conversation', 'app', 'card', 'places', 'airdropScan'].includes(name)) return true;
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
  return fetch(`https://${RESOURCE_NAME}/${n}`, options)
    .then((r) => r.json())
    .catch((error) => {
      if (error && error.name === 'AbortError') {
        // Keep the abandoned async renderer suspended so it cannot paint an error state
        // over the view that replaced it.
        return new Promise(() => {});
      }
      return { error: 'x' };
    });
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

const L = (k) => S[k] || k;
const money = (n) => '$' + Number(n || 0).toLocaleString('en-US');

// ══ Clock ══════════════════════════════════════════════════════
function tick() {
  const d = new Date();
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  byId('clock').textContent = `${hh}:${mm}`;
  byId('lockclock').textContent = `${hh}:${mm}`;
  const ccClock = byId('ccclock');
  if (ccClock) ccClock.textContent = `${hh}:${mm}`;
  byId('lockdate').textContent = d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });
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
    byId('folderview').classList.remove('on');
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
    `<span class="wrap">${UI.appIcon(a.icon)}` +
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
  const pages = [];
  for (let i = 0; i < items.length; i += arrPerPage) pages.push(items.slice(i, i + arrPerPage));
  if (!pages.length) pages.push([]);
  page = Math.max(0, Math.min(pages.length - 1, page));

  byId('pages').innerHTML = '<div class="ptrack">' + pages.map((pg) =>
    '<div class="page">' + pg.map((it, i) => {
      if (it.t === 'gap') return '<div class="tile gap"></div>';
      return it.t === 'folder' ? folderTile(it, i)
                               : tileHTML(appById(it.id) || { id: it.id, icon: 'dot', label: it.id }, i);
    }).join('') + '</div>').join('') + '</div>';
  // data-idx is the position in `items`, counting only real tiles, so a drop can read it.
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
      if (editing) return;   // a tap in arrange mode never launches
      const gi = Number(t.dataset.idx);
      if (t.classList.contains('isfolder')) { openFolder(gi); return; }
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
    return '<span>' + (a ? UI.appIcon(a.icon) : '') + '</span>';
  }).join('');
  return '<button class="tile isfolder" type="button" data-folder="1" style="--i:' + i + '">' +
    '<span class="wrap"><span class="folder glass">' + four + '</span></span>' +
    '<span class="nm">' + esc(it.name) + '</span></button>';
}

function openFolder(i) {
  const it = layoutItems()[i];
  if (!it || it.t !== 'folder') return;
  byId('foldername').textContent = it.name;
  byId('folderapps').innerHTML = it.apps.map((id, k) => {
    const a = appById(id);
    return a ? tileHTML(a, k) : '';
  }).join('');
  byId('folderview').classList.add('on');
  [...byId('folderapps').querySelectorAll('.tile')].forEach((t) =>
    t.addEventListener('click', () => {
      byId('folderview').classList.remove('on');
      const a = appById(t.dataset.app);
      if (a) enterApp(a, t);
    }));
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

function beginDrag(tile, e) {
  const items = layoutItems();
  const idx = Number(tile.dataset.idx);
  if (Number.isNaN(idx)) return;
  const item = items[idx];
  arr = { item, items: items.filter((_, i) => i !== idx), insert: idx,
          hoverEl: null, since: 0, folderIdx: null, folderTimer: null, edgeTimer: null };

  const g = byId('dragghost');
  const ic = tile.querySelector('.ic, .folder');
  const nm = tile.querySelector('.nm');
  g.innerHTML = (ic ? ic.outerHTML : '') + (nm ? nm.outerHTML : '');
  g.classList.add('on');
  moveGhost(e);
  paintArrange();
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
  const p = ptOf(e), w = byId('screen').clientWidth;
  const edge = (p.x < 24 && page > 0) ? -1 : (p.x > w - 24 && page < pages.length - 1) ? 1 : 0;
  if (edge && !arr.edgeTimer) {
    arr.edgeTimer = setTimeout(() => { arr.edgeTimer = null; flipPage(edge); }, 420);
  } else if (!edge && arr.edgeTimer) { clearTimeout(arr.edgeTimer); arr.edgeTimer = null; }

  const base = page * arrPerPage;

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
  let ins = base + tiles.length;
  for (let i = 0; i < tiles.length; i++) {
    const r = tiles[i].getBoundingClientRect();
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    if (e.clientY < cy - 6 || (Math.abs(e.clientY - cy) <= r.height / 2 && e.clientX < cx)) { ins = base + i; break; }
  }
  if (ins !== arr.insert) { arr.insert = ins; paintArrange(); }
}

function onDragEnd() {
  if (!arr) return;
  const a = arr;
  if (a.edgeTimer) clearTimeout(a.edgeTimer);
  if (a.folderTimer) clearTimeout(a.folderTimer);
  byId('dragghost').classList.remove('on');

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
    hold = setTimeout(() => { hold = null; enterArrange(); beginDrag(tile, e); }, 380);
  });

  window.addEventListener('pointermove', (e) => {
    if (hold && downXY && Math.hypot(e.clientX - downXY.x, e.clientY - downXY.y) > 10) {
      clearTimeout(hold); hold = null;   // a swipe, not a hold
    }
    if (arr) { e.preventDefault(); onDragMove(e); }
  }, { passive: false });

  window.addEventListener('pointerup', () => {
    if (hold) { clearTimeout(hold); hold = null; }
    if (arr) { onDragEnd(); downTile = null; return; }
    // A tap on empty space in arrange mode leaves it, the way iOS does.
    if (editing && !downTile) exitArrange();
    downTile = null;
  });

  byId('arrangedone').addEventListener('click', exitArrange);
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
  const hh = String(d.hours).padStart(2, '0') + ':' + String(d.minutes).padStart(2, '0');
  host.innerHTML =
    '<div class="widget weather"><div class="wtop"><span>' + esc(L('ph.los_santos')) + '</span>' +
      '<span class="wicon">' + svg(icon) + '</span></div>' +
      '<div><div class="wbig">' + esc(hh) + '</div>' +
      '<div class="wsub">' + esc(L('ph.weather_' + icon)) + '</div></div></div>' +
    '<div class="widget cal"><div class="wday">' + esc(L('ph.month_' + MONTHS[(d.month || 1) - 1])) + '</div>' +
      '<div class="wnum">' + esc(d.day || 1) + '</div>' +
      '<div class="wsub">' + esc(L('ph.in_game_date')) + '</div></div>';
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
  beginView();
  const app = byId('app');
  const wasOpen = app.classList.contains('on');
  if (wasOpen && openApp && openApp.page) frameEvent('pause', { app: openApp.id });
  resetTransientUI();
  clearActiveApp();
  clearAppVisualState();
  delete app.dataset.app;
  if (landscape) setLandscape(false);
  byId('screen').classList.remove('app-open');
  navBackAction = null;
  foot('');
  if (!wasOpen || instant) {
    app.classList.remove('on', 'closing');
    openApp = null; thread = null; threadGroup = null;
    clearSocialAccounts();
    return;
  }
  app.classList.remove('on');
  app.classList.add('closing');
  ui('appclose');
  setTimeout(() => { app.classList.remove('closing'); }, 300);
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
      host.innerHTML = UI.group(calls.map((c) => {
        const missed = c.direction === 'in' && !Number(c.answered);
        const dir = missed ? 'missed' : c.direction;
        const name = c.number ? nameOfNumber(c.number) : L('ph.unknown');
        return UI.row({
          icon: dir === 'out' ? 'callout' : (missed ? 'callmissed' : 'callin'),
          tint: missed ? '#FF453A' : '#34C759',
          title: name,
          subtitle: (L('ph.call_' + dir) + '  ') + String(c.at || '').slice(5, 16),
          value: c.number || '', chevron: true, data: { n: c.number || '' },
        });
      }));
      qrows('recents', '.row', (el) => el.addEventListener('click', () => {
        if (el.dataset.n) post('call', { number: el.dataset.n });
      }));
    });
    return;
  }

  if (phoneTab !== 'keypad') {
    // Favourites is the contacts the player marked, not a second address book.
    const list = (state.contacts || []).filter((c) => phoneTab === 'contacts' || Number(c.favourite) === 1);
    body(list.length
      ? UI.group(list.map((c) => UI.row({
          avatar: c.name, title: c.name, subtitle: c.number, chevron: true, data: { n: c.number },
        })))
      : UI.empty(L(phoneTab === 'contacts' ? 'ph.no_contacts' : 'ph.no_favourites'), 'contacts'));
    rows('.row[data-n]', (r) => r.addEventListener('click', () => post('call', { number: r.dataset.n })));
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
  byId('dial').addEventListener('click', () => { if (dialed) post('call', { number: dialed }); });
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
        appicon: 'health',
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
      '<div class="groupfoot">' + esc(L('ph.health_hint')) + '</div>'
    );
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
    subtitle: String(n.at || '').slice(5, 16), chevron: true, data: { id: n.id },
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

// ── Mail ───────────────────────────────────────────────────────
// A mail client, not a second Messages: an address you own, folders, group recipients,
// drafts you can come back to, replies that quote who they answer, and a keep flag that
// works from any folder.
let mailFolder = 'inbox';
let mailAcc = null;

RENDER.mail = async () => {
  setNav(L('app.mail'), null);
  loading();
  const me = await post('mail', { op: 'me' });
  if (!me || me.error) { body(UI.empty(L('ph.err_' + ((me && me.error) || 'off')), 'mail')); return; }
  if (!me.address) { mailSignup(me.domains || []); return; }
  mailAcc = me.address;
  mailList();
};

// The address is chosen once and is what people write to, which is why it cannot be
// edited away afterwards.
function mailSignup(domains) {
  if (!openApp || openApp.id !== 'mail') return;
  setNav(L('app.mail'), null);
  let domain = domains[0] || 'eyefind.info';
  body(
    '<div class="accthead">' + UI.appIcon('mail') +
      '<div class="acctname">' + esc(L('app.mail')) + '</div>' +
      '<div class="acctsub">' + esc(L('ph.mail_pick_sub')) + '</div></div>' +
    UI.field('mlocal', L('ph.mail_localpart'), '', 'maxlength="20"') +
    '<div class="seg scroll" id="mdoms">' + domains.map((d, i) =>
      '<button class="' + (i === 0 ? 'on' : '') + '" data-d="' + esc(d) + '" type="button">@' + esc(d) + '</button>').join('') + '</div>' +
    UI.button(L('ph.mail_create'), 'mmake', 'tinted') +
    '<div class="groupfoot">' + esc(L('ph.mail_pick_hint')) + '</div>'
  );
  qrows('mdoms', 'button', (b) => b.addEventListener('click', () => {
    domain = b.dataset.d;
    [...byId('mdoms').querySelectorAll('button')].forEach((x) => x.classList.toggle('on', x === b));
  }));
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
  body('<div class="mailaddr">' + esc(mailAcc || '') + '</div><div id="mlist"></div>');

  const r = mailFolder === 'saved'
    ? await post('mail', { op: 'saved' })
    : await post('mail', { op: 'list', folder: mailFolder });
  const host = byId('mlist');
  if (!host) return;
  const list = (r && r.mail) || [];
  if (!list.length) { host.innerHTML = UI.empty(L('ph.mail_empty'), 'mail'); return; }

  host.innerHTML = UI.group(list.map((m) => {
    // Inbox shows who wrote; everywhere else, who it went to.
    const who = (m.folder === 'inbox') ? m.from_addr : (m.to_addr || L('ph.mail_noto'));
    return UI.row({
      avatar: who, title: who,
      subtitle: (m.subject || L('ph.mail_nosubject')) + '  -  ' + String(m.at || '').slice(5, 16),
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
  if (m.folder === 'inbox' && !Number(m.seen)) post('mail', { op: 'seen', boxId: m.box_id });

  setNav(m.subject || L('ph.mail_nosubject'), L('app.mail'), {
    icon: 'star', onClick: async () => {
      const saved = !Number(m.saved);
      await post('mail', { op: 'save', boxId: m.box_id, saved });
      m.saved = saved ? 1 : 0;
      toast(L(saved ? 'ph.mail_kept' : 'ph.mail_unkept'));
    },
  }, () => mailList());
  body(
    '<div class="mailhead">' +
      '<div class="mailsubj">' + esc(m.subject || L('ph.mail_nosubject')) + '</div>' +
      '<div class="mailmeta"><b>' + esc(m.from_addr) + '</b></div>' +
      '<div class="mailmeta">' + esc(L('ph.mail_to')) + ' ' + esc(m.to_addr || '') + '</div>' +
      '<div class="mailmeta">' + esc(String(m.at || '').slice(0, 16)) + '</div>' +
    '</div>' +
    '<div class="mailbody">' + esc(m.body || '') + '</div>' +
    UI.button(L('ph.mail_reply'), 'mreply', 'tinted') +
    UI.button(L('ph.mail_forward'), 'mfwd', 'plain') +
    ((m.to_addr || '').indexOf(',') !== -1 ? UI.button(L('ph.mail_reply_all'), 'mreplyall', 'plain') : '') +
    UI.button(L('ph.delete'), 'mdel', 'destructive')
  );
  byId('mreply').addEventListener('click', () => mailCompose({ reply: m, all: false }));
  // Forward keeps the message and clears the recipients: the point is to send it on.
  byId('mfwd').addEventListener('click', () => mailCompose({ forward: m }));
  const ra = byId('mreplyall');
  if (ra) ra.addEventListener('click', () => mailCompose({ reply: m, all: true }));
  byId('mdel').addEventListener('click', async () => {
    await post('mail', { op: 'del', boxId: m.box_id });
    toast(L('ph.mail_deleted')); mailList();
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

  setNav(L('ph.mail_new'), L('app.mail'), null, () => mailList());
  body(
    UI.field('mto', L('ph.mail_to_ph'), to, 'maxlength="400"') +
    UI.field('msubj', L('ph.mail_subject'), subject, 'maxlength="80"') +
    '<textarea class="mailedit" id="mbody" maxlength="2000" placeholder="' + esc(L('ph.mail_body_ph')) + '">' + esc(bodyTxt) + '</textarea>' +
    UI.button(L('ph.mail_send'), 'msend', 'tinted') +
    UI.button(L('ph.mail_savedraft'), 'msave', 'plain') +
    '<div class="groupfoot">' + esc(L('ph.mail_group_hint')) + '</div>'
  );

  const payload = (op) => ({ op, to: byId('mto').value, subject: byId('msubj').value,
    body: byId('mbody').value, replyTo, boxId });

  byId('msend').addEventListener('click', async () => {
    const res = await post('mail', payload('send'));
    if (res && res.ok) { ui('sent'); toast(L('ph.mail_sent')); mailFolder = 'sent'; mailList(); }
    else if (res && res.error === 'noaddr') toast(L('ph.err_noaddr') + ' ' + (res.address || ''));
    else toast(L('ph.err_' + ((res && res.error) || 'x')));
  });
  byId('msave').addEventListener('click', async () => {
    const res = await post('mail', payload('draft'));
    if (res && res.ok) { toast(L('ph.mail_drafted')); mailFolder = 'draft'; mailList(); }
    else toast(L('ph.err_' + ((res && res.error) || 'x')));
  });
}

// ── Photos: filters, albums, and a picker every app can raise ──
// A filter is a stored name drawn with CSS, never a re-encoded image: the phone holds a
// link and how to draw it, which is the only thing it can honestly hold.
const FILTERS = ['none', 'mono', 'noir', 'fade', 'warm', 'cool', 'vivid'];
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
function photoRow(v) { return (typeof v === 'string') ? { url: v, album: '', filter: '' } : (v || {}); }
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
  return inlineBackground(r.url) + ';filter:' + filterCss(r.filter);
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
        onPick(r.url, r);
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
      avatar: c.name, title: c.name, subtitle: c.number, data: { n: c.number },
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
      subtitle: String(v.at || '').slice(5, 16),
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
    '<div class="vmwhen">' + esc(String(v.at || '').slice(0, 16)) + '</div>' +
    (v.number ? UI.button(L('ph.call'), 'vmcall', 'tinted') : '') +
    UI.button(L('ph.delete'), 'vmdel', 'destructive'),
    () => {
      const c = byId('vmcall');
      if (c) c.addEventListener('click', () => { closeSheet(); post('call', { number: v.number }); });
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
function nameOfNumber(number) {
  const c = (state.contacts || []).find((x) => x.number === number);
  return c ? c.name : (number || L('ph.unknown'));
}

RENDER.messages = () => {
  threadGroup = null;
  setNav(L('app.messages'), null, { icon: 'add', onClick: newMessageSheet });
  const list = state.conversations || [];
  const groups = state.groups || [];
  if (!list.length && !groups.length) { body(UI.empty(L('ph.no_messages'), 'messages')); return; }
  body(
    (groups.length ? UI.group(groups.map((g) => UI.row({
      icon: 'contacts', tint: '#34C759', title: g.name, chevron: true, data: { g: g.id, gn: g.name },
    })), { header: L('ph.groups') }) : '') +
    (list.length ? UI.group(list.map((c) => UI.row({
      avatar: nameOfNumber(c.number), title: nameOfNumber(c.number), subtitle: c.body,
      badge: c.unread > 0 ? c.unread : null, chevron: true, data: { n: c.number },
    }))) : '')
  );
  rows('.row[data-n]', (r) => r.addEventListener('click', () => openThread(r.dataset.n)));
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

async function openThread(number, draft) {
  if (!openApp || openApp.id !== 'messages') return;
  beginView();
  thread = number;
  threadGroup = null;
  setNav(nameOfNumber(number), L('app.messages'), {
    icon: 'phone', onClick: () => post('call', { number }),
  }, () => {
    thread = null;
    foot('');
    RENDER.messages();
  });
  loading();
  const res = await post('conversation', { number });
  if (!res || res.error) { body(UI.empty(L('ph.err_' + ((res && res.error) || 'x')))); return; }
  paintThread(res.messages || []);
  if (draft && byId('msg')) byId('msg').value = String(draft).slice(0, 250);
  pushAnim();
  const c = (state.conversations || []).find((x) => x.number === number);
  if (c) c.unread = 0;
}

function bubbleHtml(m) {
  let inner;
  if (m.kind === 'image') {
    inner = '<img class="mimg" src="' + esc(m.attachment) + '" />' +
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
  return sender + '<div class="bub ' + (m.mine ? 'me' : 'them') +
    (m.kind === 'image' ? ' imgb' : '') + '">' + inner + '</div>';
}

function wireLocButtons() {
  rows('.locbtn', (b) => b.addEventListener('click', async () => {
    const parts = String(b.dataset.loc || '').split(';');
    const r = await post('waypoint', { x: Number(parts[0]), y: Number(parts[1]) });
    if (r && r.ok) toast(L('ph.waypoint_set'));
  }));
}

function paintThread(messages) {
  body(`<div class="thread" id="thread">${messages.map(bubbleHtml).join('')}</div>`);
  wireLocButtons();
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
  sheet(L('ph.new_message_to'),
    UI.field('nmnum', L('ph.number')) + UI.button(L('ph.write'), 'nmgo') +
    UI.button(L('ph.new_group'), 'nggo', 'plain'),
    () => {
      byId('nmgo').addEventListener('click', () => {
        const n = byId('nmnum').value.trim();
        closeSheet();
        if (n) openThread(n);
      });
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
          avatar: c.name, title: c.name, subtitle: c.number, chevron: true,
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
      subtitle: state.number || '', chevron: true, data: { me: '1' } })]) +
    '<div id="clist"></div>');
  rows('.row', (r) => { if (r.dataset.me) r.addEventListener('click',
    () => airdropShare('number', { name: '', number: state.number })); });
  draw('');
  onSearch(draw);
};

function contactSheet(c) {
  if (c.system) {
    const details = [
      UI.row({ icon: 'phone', tint: '#34C759', title: L('ph.number'), value: c.number }),
      c.email ? UI.row({ icon: 'mail', tint: '#0A84FF', title: L('ph.c_email'), value: c.email }) : '',
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
      UI.button(L('ph.message'), 'cmsg', 'plain') +
      UI.button(L('ph.airdrop_share'), 'cshare', 'plain'),
      () => {
        byId('ccall').addEventListener('click', () => { closeSheet(); post('call', { number: c.number }); });
        byId('cmsg').addEventListener('click', () => { closeSheet(); openThread(c.number); });
        byId('cshare').addEventListener('click', () =>
          airdropShare('contact', { name: c.name, number: c.number }));
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
    UI.field('cmail', L('ph.c_email'), c.email || '', 'maxlength="64"') +
    UI.field('caddr', L('ph.c_address'), c.address || '', 'maxlength="120"') +
    UI.field('cbday', L('ph.c_birthday'), c.birthday || '', 'maxlength="20"') +
    UI.field('cnote', L('ph.c_note'), c.note || '', 'maxlength="300"') +
    UI.button(L('ph.pick_photo'), 'cpick', 'plain') +
    UI.button(L('ph.save'), 'csave') +
    (isNew ? '' : UI.button(L('ph.call'), 'ccall', 'tinted')) +
    (isNew ? '' : UI.button(L('ph.message'), 'cmsg', 'plain')) +
    (isNew ? '' : UI.button(L('ph.airdrop_share'), 'cshare', 'plain')) +
    (isNew ? '' : UI.button(L('ph.delete'), 'cdel', 'destructive')),
    () => {
      byId('cpick').addEventListener('click', () => pickPhoto((url) => { byId('cphoto').value = url; }));
      byId('csave').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        const payload = { id: c.id, name: byId('cname').value, number: byId('cnum').value,
          photo: byId('cphoto').value.trim(), email: byId('cmail').value.trim(),
          address: byId('caddr').value.trim(), birthday: byId('cbday').value.trim(),
          note: byId('cnote').value.trim() };
        const res = await post('contactSave', payload);
        if (res && res.ok) {
          if (closeSheet(false, epoch)) { await refresh(); RENDER.contacts(); }
        } else toast(L('ph.err_' + ((res && res.error) || 'x')));
      });
      if (isNew) return;
      byId('ccall').addEventListener('click', () => { closeSheet(); post('call', { number: c.number }); });
      byId('cshare').addEventListener('click', () => airdropShare('contact', { name: c.name, number: c.number }));
      byId('cmsg').addEventListener('click', () => { closeSheet(); openThread(c.number); });
      byId('cdel').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        await post('contactDelete', { id: c.id });
        if (closeSheet(false, epoch)) { await refresh(); RENDER.contacts(); }
      });
    });
}

// ── Bank ───────────────────────────────────────────────────────
RENDER.bank = async () => {
  loading();
  const d = await post('app', { app: 'bank' });
  if (!d || d.error) { body(UI.empty(L('ph.err_off'), 'bank')); return; }
  const tx = d.transactions || [];
  body(
    UI.hero({
      appicon: 'bank',
      eyebrow: L('ph.balance'),
      value: money(d.bank),
      subtitle: `${L('ph.cash')} ${money(d.cash)}`,
    }) +
    (tx.length
      ? UI.group(tx.map((t) => UI.row({
          title: t.label || t.type || '', subtitle: t.at || '',
          value: money(t.amount), mono: true, tone: Number(t.amount) < 0 ? 'neg' : 'pos',
        })), { header: L('ph.history') })
      : UI.empty(L('ph.no_history')))
  );
};

// ── Garage ─────────────────────────────────────────────────────
// Where a car is, not how to spawn one: taking it out is the garage's job and needs the
// player standing at one.
RENDER.garage = async () => {
  loading();
  const d = await post('app', { app: 'garage' });
  if (!d || d.error) { body(UI.empty(L('ph.err_off'), 'garage')); return; }
  const list = Array.isArray(d) ? d : (d.vehicles || []);
  if (!list.length) { body(UI.empty(L('ph.no_vehicles'), 'garage')); return; }
  body(UI.group(list.map((v) => UI.row({
    icon: 'garage', tint: '#0A84FF', title: v.model || '', subtitle: `${v.plate || ''}  ${v.garage || L('ph.out')}`,
    value: v.live ? L('ph.veh_out') : L('ph.veh_stored'),
  }))));
};

// ── Wallet ─────────────────────────────────────────────────────
RENDER.wallet = async () => {
  loading();
  // The card is v-banking's, not the phone's: it mints the number and it is the thing
  // one player hands another instead of a citizen id.
  const card = await post('card');
  const d = await post('app', { app: 'wallet' });
  if (!d || d.error) { body(UI.empty(L('ph.err_off'), 'wallet')); return; }
  const list = Array.isArray(d) ? d : (d.licenses || []);
  // No card until one has been ordered from the bank, so say where to get one rather
  // than drawing an empty rectangle.
  const cardHtml = (card && card.ok && card.card)
    ? '<div class="bankcard"><div class="brand"><span>FLEECA</span><span class="chip"></span></div>' +
      '<div class="num">' + esc(card.card || '') + '</div>' +
      '<div class="foot"><span>' + esc(card.holder || '') + '</span>' +
      '<span class="bal">' + esc(money(card.bank)) + '</span></div></div>'
    : (card && card.ok ? UI.group([UI.row({ icon: 'bank', title: L('ph.no_card'), subtitle: L('ph.no_card_hint') })]) : '');
  if (!list.length) { body(cardHtml + UI.empty(L('ph.no_licenses'), 'wallet')); return; }
  const wireCard = () => {
    const el = document.querySelector('.bankcard');
    if (el && card && card.card) {
      el.style.cursor = 'pointer';
      el.addEventListener('click', () => copyText(card.card, L('ph.card_copied')));
    }
  };
  body(cardHtml + UI.group(list.map((l) => UI.row({
    icon: 'wallet', tint: '#5856D6', title: (L(l.i18n) !== l.i18n ? L(l.i18n) : (l.label || l.key)),
    subtitle: l.issuer || '', value: l.held ? L('ph.lic_held') : L('ph.lic_none'),
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
  if (!d || d.error) { body(UI.empty(L('ph.err_off'), 'jobs')); return; }

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
RENDER.settings = () => {
  const p = state.prefs || {};
  body(
    UI.group([
      UI.row({ icon: 'phone', tint: '#0A84FF', title: p.deviceName || L('ph.setup_default_device'),
        subtitle: p.ownerName || '', chevron: true, data: { t: 'device_name' } }),
      UI.row({ icon: 'phone', tint: '#34C759', title: L('ph.my_number'), value: state.number || '',
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
    '<div class="sliderow">' +
      '<div class="sl"><span>' + esc(L('ph.size')) + '</span><span>' + Math.round((p.size || 1) * 100) + '%</span></div>' +
      '<input type="range" id="dsize" min="75" max="115" step="1" aria-label="' +
        esc(L('ph.size')) + '" value="' + Math.round((p.size || 1) * 100) + '" />' +
      '<div class="seg" style="margin-top:12px">' +
        '<button class="' + (p.side !== 'left' ? 'on' : '') + '" data-side="right">' + esc(L('ph.side_right')) + '</button>' +
        '<button class="' + (p.side === 'left' ? 'on' : '') + '" data-side="left">' + esc(L('ph.side_left')) + '</button>' +
      '</div>' +
    '</div>' +
    UI.group([UI.row({ icon: 'moon', tint: '#5856D6', title: L('ph.dnd'), toggle: !!p.dnd, data: { t: 'dnd' } })],
      { footer: L('ph.dnd_hint') }) +
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
      appicon: a.icon, title: L(a.label),
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
  const ds = byId('dsize');
  if (ds) {
    ds.addEventListener('input', () => {
      state.prefs.size = Number(ds.value) / 100;
      applyDevice();
      ds.style.setProperty('--fill-pct', ((Number(ds.value) - 75) / 40 * 100) + '%');
    });
    ds.addEventListener('change', async () => {
      const res = await post('prefs', { size: Number(ds.value) / 100 });
      if (res && res.ok) state.prefs = res.prefs;
    });
    ds.style.setProperty('--fill-pct', (((p.size || 1) * 100 - 75) / 40 * 100) + '%');
  }

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
    w.style.backgroundPosition = 'center';
    w.style.backgroundRepeat = 'no-repeat';
    w.style.backgroundColor = '#000';
    screen.style.backgroundImage = 'url("' + p.wallpaperUrl + '")';
    screen.style.backgroundSize = (p.wallFit === 'contain') ? 'contain' : 'cover';
    screen.style.backgroundPosition = 'center';
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
function applyDevice() {
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
  { id: 'browse', icon: 'sparkles', label: 'ph.music_new' },
  { id: 'radio', icon: 'speaker', label: 'ph.music_radio' },
  { id: 'library', icon: 'music', label: 'ph.library' },
  { id: 'search', icon: 'search', label: 'ph.search' },
];
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
  return L(key) === key ? L('ph.music_device') : L(key);
}

async function musicModel() {
  const [library, service, recentKeys] = await Promise.all([
    musicLibrary(),
    post('app', { app: 'music' }),
    musicStorage('recent', []),
  ]);
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
    library, sources, recent,
    current: current ? musicNormalise(current) : null,
    enabled: !service || (!service.error && service.enabled !== false),
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
    '<button id="musicmininext" type="button" aria-label="' + esc(L('ph.next')) + '">' + svg('chevron') + '</button></div>';
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
  musicOutput = kind;
  musicQueue = (queue && queue.length ? queue : [track]).map(musicNormalise);
  musicQueueIndex = Math.max(0, musicQueue.findIndex((row) => row.url === track.url));
  musicNow = Object.assign({}, musicNormalise(track), {
    id: result.id, kind, paused: false, volume: track.volume || .65,
  });
  await musicRemember(track);
  toast(kind === 'headphones' ? L('ph.playing_ear') : L('ph.playing'));
  if (openApp && openApp.id === 'music') RENDER.music();
}

async function musicToggle(track) {
  const current = track || musicNow;
  if (!current) return;
  if (!current.id) { await musicPlay(current, musicQueue.length ? musicQueue : [current]); return; }
  const action = current.paused ? 'resume' : 'pause';
  const result = await post('music', { id: current.id, action });
  if (!result || result.error) { toast(L('ph.err_' + ((result && result.error) || 'x'))); return; }
  if (musicNow) musicNow.paused = action === 'pause';
  RENDER.music();
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
  RENDER.music();
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
      if (closeSheet(false, epoch)) RENDER.music();
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
      if (saved) byId('medit').addEventListener('click', () => { closeSheet(); musicAdd(track, index); });
      if (saved) byId('mdelt').addEventListener('click', async () => {
        const epoch = sheetEpoch;
        const library = await musicLibrary();
        if (epoch !== sheetEpoch) return;
        library.splice(index, 1);
        await musicSaveLibrary(library);
        if (closeSheet(false, epoch)) RENDER.music();
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
      '<button id="mplayerqueue" type="button">' + svg('note') + '<span>' + esc(L('ph.queue')) + '</span></button></div></div>');
  byId('mplaymain').addEventListener('click', () => musicToggle(current));
  byId('mprevious').addEventListener('click', () => musicStep(-1));
  byId('mnext').addEventListener('click', () => musicStep(1));
  byId('mplayerfav').addEventListener('click', () => musicFavourite(current));
  byId('mplayerout').addEventListener('click', () => musicOutputSheet(current));
  byId('mplayerqueue').addEventListener('click', musicQueueSheet);
  const slider = byId('mvolume');
  slider.addEventListener('input', () => slider.style.setProperty('--volume', slider.value + '%'));
  slider.addEventListener('change', async () => {
    const value = Number(slider.value) / 100;
    if (musicNow) musicNow.volume = value;
    if (current.id) await post('music', { id: current.id, action: 'volume', volume: value });
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

RENDER.music = async () => {
  setNav(L('app.music'), null, musicTab === 'library'
    ? { icon: 'add', label: L('ph.track_add'), onClick: () => musicAdd() } : null);
  loading();
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
RENDER.property = async () => {
  loading();
  const d = await post('app', { app: 'property' });
  if (!d || d.error) { body(UI.empty(L('ph.err_off'), 'house')); return; }
  const list = d.rows || [];
  if (!list.length) { body(UI.empty(L('ph.no_property'), 'house')); return; }
  body(UI.group(list.map((pr, i) => UI.row({
    icon: 'house', tint: '#12A5BC', title: pr.label,
    subtitle: L('ph.tenancy_' + (pr.tenancy || 'own')) +
      (Number(pr.arrears) > 0 ? '  ' + String(L('ph.arrears')).replace('%s', pr.arrears) : ''),
    value: pr.locked ? L('ph.locked') : '',
    tone: pr.locked ? 'neg' : '',
    chevron: !!pr.locked, data: { i },
  })), { footer: L('ph.property_hint') }));
  rows('.row[data-i]', (r) => r.addEventListener('click', async () => {
    const pr = list[Number(r.dataset.i)];
    if (!pr || !pr.locked) return;
    const res = await post('payRent', { id: pr.property });
    if (res && res.ok) { toast(L('ph.rent_paid')); RENDER.property(); }
    else toast(L('ph.err_' + ((res && res.error) || 'x')));
  }));
};

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
      '<div class="cpreview">' + UI.appIcon(a.icon, 'previewicon') +
      '<b class="previewname">' + esc(L(a.label)) + '</b></div></div></div>').join('') +
    '<div class="switchhint">' + esc(L('ph.switch_hint')) + '</div>';
  byId('switcher').classList.add('on');

  [...byId('cards').querySelectorAll('.card')].forEach((c) => {
    let y0 = null;
    c.addEventListener('pointerdown', (e) => { y0 = e.clientY; });
    c.addEventListener('pointerup', (e) => {
      const flicked = y0 !== null && e.clientY - y0 < -60;
      y0 = null;
      if (flicked) {
        // Flick a card away to close the app, as on a real phone.
        const id = c.dataset.app;
        c.classList.add('gone');
        recents = recents.filter((recent) => recent !== id);
        setTimeout(() => {
          if (openApp && openApp.id === id) closeApp(true);
          if (!recents.length) byId('switcher').classList.remove('on');
          else openSwitcher();
        }, 240);
        return;
      }
      const a = (state.apps || []).find((x) => x.id === c.dataset.app);
      byId('switcher').classList.remove('on');
      if (a) enterApp(a, null);
    });
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
  const order = [], byApp = {};
  notifs.forEach((n) => { if (!byApp[n.app]) { byApp[n.app] = []; order.push(n.app); } byApp[n.app].push(n); });

  list.innerHTML = order.map((appId) => {
    const a = appOf(appId);
    const muted = appMuted(appId);
    const head = '<div class="ngrouphead">' + UI.appIcon(a.icon) +
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
byId('shclear').addEventListener('click', () => { notifs = []; paintNotifs(); renderShade(); });
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

async function nudgeVolume(delta) {
  const d = await post('app', { app: 'music' });
  const list = (d && d.sources) || [];
  if (!list.length) { hud('speaker', L('ph.nothing_playing')); return; }
  const src = list[0];
  volume = Math.max(0, Math.min(1, (src.volume ?? volume) + delta));
  hud('speaker', src.title || L('ph.untitled'), volume);
  await post('music', { id: src.id, action: 'volume', volume });
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
    '<div class="stshotapp">' + UI.appIcon(a.icon) + '<b>' + name + '</b></div>' +
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
    '<div class="stdetail"' + detailStyle + '><div class="stdetailhero"><div class="storb"></div><div class="sthead">' + UI.appIcon(a.icon) +
      '<div class="stinfo"><div class="stbig">' + esc(L(a.label)) + '</div>' +
      '<div class="stcat">' + esc(a.developer || (a.owner === 'v-phone' ? 'iFruit Studio' : (a.owner || 'iFruit'))) + '</div>' +
      '<div class="stact">' +
        (a.required
          ? '<span class="stget have">' + esc(L('ph.store_required')) + '</span>'
          : (has
              ? '<button class="stget have" id="stopen" type="button">' + esc(L('ph.store_open')) + '</button>' +
                '<button class="stdel" id="stdel" type="button">' + esc(L('ph.store_delete')) + '</button>'
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
  if (sd) sd.addEventListener('click', async () => { if (await storeInstall(a.id, false)) storeDetail(a); });
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
  if (!r || r.error) { toast(L('ph.err_' + ((r && r.error) || 'x'))); return false; }
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

function storeRow(a) {
  const has = isInstalled(a.id);
  const label = a.required ? L('ph.store_required')
    : (has ? L('ph.store_open') : L('ph.store_install'));
  return '<div class="strowitem" data-app="' + esc(a.id) + '">' + UI.appIcon(a.icon) +
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

RENDER.health = async () => {
  tabbar([
    { id: 'today', icon: 'heart', label: 'ph.today' },
    { id: 'record', icon: 'id', label: 'ph.record' },
  ], healthTab, (t) => { healthTab = t; RENDER.health(); });
  if (healthTab === 'record') { healthRecord(); return; }
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
RENDER.camera = async () => {
  if (!state.camera) { body(UI.empty(L('ph.camera_off'), 'camera')); return; }
  const d = await post('photos', { op: 'list' });
  const shots = (d && d.photos) || [];
  const last = shots[0];

  // Immersive: no title bar, no padding, the black fills the screen edge to edge.
  byId('navbar').classList.add('hidden');
  byId('app').classList.add('camfull');
  byId('screen').classList.add('appblack');

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
      '<div class="cammode"><span class="on">' + esc(L('ph.cam_photo')) + '</span></div>' +
      '<div class="camctl">' +
        (last ? '<button class="camroll" id="camroll" type="button" style="' + photoStyle(last) + '"></button>'
              : '<span class="camroll empty"></span>') +
        '<button class="camshutter" id="shoot" type="button" aria-label="' +
          esc(L('ph.shooting')) + '"><span></span></button>' +
        '<button class="camflip" id="camland2" type="button" aria-label="' +
          esc(L('ph.landscape')) + '">' + svg('landscape') + '</button>' +
      '</div>' +
    '</div>'
  );

  byId('shoot').addEventListener('click', async () => {
    toast(L('ph.shooting'));
    const res = await post('shoot');
    if (!res || res.error) { toast(L('ph.err_' + ((res && res.error) || 'x'))); return; }
    RENDER.camera();
  });
  byId('camback').addEventListener('click', () => closeApp());
  const toggle = () => { setLandscape(!landscape); RENDER.camera(); };
  byId('camland').addEventListener('click', toggle);
  byId('camland2').addEventListener('click', toggle);
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

function photoSheet(shots, i, albums) {
  const r = photoRow(shots[i]);
  const url = r.url;
  sheet(L('app.gallery'),
    '<img class="shotbig" id="shotbig" src="' + esc(url) + '" style="filter:' + filterCss(r.filter) + '" />' +
    // Retouching: pick a look, it applies live and is remembered with the photo.
    '<div class="grouphead">' + esc(L('ph.filters')) + '</div>' +
    '<div class="seg scroll" id="sfilters">' + FILTERS.map((f) =>
      '<button class="' + ((r.filter || 'none') === f ? 'on' : '') + '" data-f="' + f + '">' +
      esc(L('ph.filter_' + f)) + '</button>').join('') + '</div>' +
    UI.button(L('ph.album_set'), 'salbum', 'plain') +
    UI.button(L('ph.airdrop_share'), 'sshare', 'tinted') +
    UI.button(L('ph.set_wallpaper'), 'swall') +
    UI.button(L('ph.delete'), 'sdel', 'destructive'),
    () => {
      [...byId('sheet').querySelectorAll('#sfilters button')].forEach((b) =>
        b.addEventListener('click', async () => {
          const f = b.dataset.f;
          byId('shotbig').style.filter = filterCss(f);
          [...byId('sfilters').querySelectorAll('button')].forEach((x) => x.classList.toggle('on', x === b));
          await post('photos', { op: 'edit', index: i + 1, filter: f === 'none' ? '' : f });
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
        const r = await post('prefs', { wallpaperUrl: url });
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
function airdropOffer(o) {
  o = o || {};
  const preview = o.kind === 'photo'
    ? '<img class="shotbig" src="' + esc(o.preview || '') + '" />'
    : '<div class="airbig">' + svg(o.kind === 'photo' ? 'images' : 'contacts') + '<span>' + esc(o.preview || '') + '</span></div>';
  sheet(L('ph.airdrop_incoming'),
    preview +
    '<div class="airfrom">' + esc(L('ph.airdrop_from')) + ' <b>' + esc(o.from || '') + '</b></div>' +
    UI.button(L('ph.airdrop_accept'), 'airok', 'tinted') +
    UI.button(L('ph.airdrop_decline'), 'airno', 'plain'),
    () => {
      byId('airok').addEventListener('click', async () => {
        closeSheet();
        const r = await post('airdropRespond', { offerId: o.offerId, accept: true });
        if (r && r.ok) { await refresh(); toast(L('ph.airdrop_saved')); }
        else toast(L('ph.airdrop_' + ((r && r.error) || 'x')));
      });
      byId('airno').addEventListener('click', async () => {
        closeSheet();
        await post('airdropRespond', { offerId: o.offerId, accept: false });
      });
    });
}


// ══ Clipboard ══════════════════════════════════════════════════
// navigator.clipboard needs a secure context, and cfx-nui:// is not one, so this is the
// textarea trick. It is the only thing that works in CEF, and a number you cannot copy
// is a number you have to read out loud.
function copyText(text, said) {
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
  foot('<div class="tabbar">' + tabs.map((t) =>
    '<button class="' + (t.id === current ? 'on' : '') + '" data-t="' + esc(t.id) + '" type="button" ' +
    'aria-current="' + (t.id === current ? 'page' : 'false') + '">' +
    svg(t.icon) + '<span>' + esc(L(t.label)) + '</span></button>').join('') + '</div>');
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
  if (!value) return '';
  const parsed = new Date(String(value).replace(' ', 'T'));
  if (Number.isNaN(parsed.getTime())) return String(value).slice(11, 16);
  return parsed.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
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
      const sent = await post('cipher', { op: 'send', handle: peer.handle, envelope, burn: cipherBurn });
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
    '<button class="linkbtn" id="lforget" type="button">' + esc(L('ph.soc_switch')) + '</button>'
  );
  byId('lgo').addEventListener('click', async () => {
    const r = await post('social', { op: 'login', app, password: byId('lpw').value });
    if (r && r.ok) socialAcc[app] = r.account;
    if (!socialActive(app, epoch)) return;
    if (r && r.ok) then();
    else toast(L('ph.err_' + ((r && r.error) || 'x')));
  });
  // "Not you?" logs the stored account out for this session and starts a fresh sign-up.
  byId('lforget').addEventListener('click', async () => {
    await post('social', { op: 'logout', app });
    if (!socialActive(app, epoch)) return;
    socialSignup(app, then);
  });
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
          value: state.number || L('ph.soc_no_number') })]) +
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
        UI.button(L('ph.soc_verify'), 'sc2') +
        '<button class="linkbtn" id="sc2r" type="button">' + esc(L('ph.soc_resend')) + '</button>'
      );
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
  const t = Date.parse(String(at || '').replace(' ', 'T'));
  if (!t) return esc(String(at || '').slice(5, 16));
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

  const image = pst.image ? '<img class="pimg" src="' + esc(pst.image) + '" alt="" />' : '';
  const text = pst.body ? '<div class="pbody">' + esc(pst.body) + '</div>' : '';

  const actions =
    '<div class="pfoot">' +
      '<button class="pact plike' + (pst.liked ? ' on' : '') + '" type="button" aria-label="' +
        esc(L('ph.like')) + '">' + svg('heart') + '<span>' + (pst.likes || 0) + '</span></button>' +
      '<button class="pact pcomment" type="button" aria-label="' +
        esc(L('ph.soc_comments')) + '">' + svg('messages') + '<span>' + (pst.comments || 0) + '</span></button>' +
      '<button class="pact prepost' + (pst.reposted ? ' on' : '') + '" type="button" aria-label="' +
        esc(L('ph.soc_repost')) + '">' + svg('repost') + '<span>' + (pst.reposts || 0) + '</span></button>' +
      '<span class="pspacer"></span>' +
      (pst.mine
        ? '<button class="pact pdel" type="button" aria-label="' + esc(L('ph.delete')) + '">' + svg('trash') + '</button>'
        : '') +
    '</div>';

  return '<article class="post' + (photoFirst ? ' snapstyle' : '') + '" data-id="' + pst.id + '">' +
    head + (photoFirst ? image + actions + text : text + image + actions) + '</article>';
}

// Every card in a list answers the same way, so the wiring is written once. `reload` is
// what a destructive action calls once the server has agreed.
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
  rows('.post .pcomment', (b) => b.addEventListener('click', () =>
    commentSheet(appId, Number(b.closest('.post').dataset.id), b.querySelector('span'))));
  rows('.post .phead', (b) => b.addEventListener('click', () =>
    socialProfile(appId, b.dataset.who)));
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
      '</div>';
    post('social', { op: 'storySeen', id: item.id });
    host.querySelector('.storyclose').addEventListener('click', (e) => { e.stopPropagation(); close(); });
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
      '<span class="rowtext"><span class="rowtitle">' +
        esc(a.displayname || a.handle) + socVerified(a) + '</span>' +
      '<span class="rowsub">@' + esc(a.handle) + ' · ' + a.followers + ' ' +
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
    '<div id="socresults">' + UI.empty(L('ph.loading')) + '</div>'
  );
  let timer = null;
  byId('socq').addEventListener('input', () => {
    clearTimeout(timer);
    // A keystroke is not a query. Wait for the typing to stop rather than asking the
    // server once per letter.
    timer = setTimeout(() => socialSearch(appId, byId('socq').value.trim()), 220);
  });
  socialSearch(appId, '');
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
    '<div class="socprof">' + socAvatar(a, 'socbigav') +
      '<div class="socname">' + esc(a.displayname || a.handle) + socVerified(a) + '</div>' +
      '<div class="sochandle">@' + esc(a.handle) + '</div>' +
      (a.bio ? '<div class="socbio">' + esc(a.bio) + '</div>' : '') +
      '<div class="soccounts">' +
        '<span><b>' + (c.posts || 0) + '</b>' + esc(L('ph.soc_posts')) + '</span>' +
        '<span><b>' + (c.followers || 0) + '</b>' + esc(L('ph.soc_followers')) + '</span>' +
        '<span><b>' + (c.following || 0) + '</b>' + esc(L('ph.soc_following_count')) + '</span>' +
      '</div>' +
      (r.me ? '<button class="socedit" id="socedit" type="button">' + esc(L('ph.soc_edit')) + '</button>'
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
    UI.field('socbio', L('ph.soc_bio'), account.bio || '', 'maxlength="160"') +
    UI.button(L('ph.save'), 'socsave'),
    () => {
      const epoch = sheetEpoch;
      byId('socsave').addEventListener('click', async () => {
        const r = await post('social', { op: 'setup', app: appId,
          displayname: byId('socdn').value, avatar: byId('socav').value, bio: byId('socbio').value });
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
      '<span class="rowtext"><span class="rowtitle">' + esc(t.displayname || t.handle) + '</span>' +
      '<span class="rowsub">' + esc((t.mine ? L('ph.you') + ' ' : '') + (t.body || L('ph.photo'))) + '</span></span>' +
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
    ? [{ id: 'swipe', icon: 'hush', label: L('app.hush') },
       { id: 'matches', icon: 'heart', label: L('ph.hush_matches') },
       { id: 'me', icon: 'contacts', label: L('ph.soc_profile') }]
    : [{ id: 'feed', icon: 'home', label: L('ph.soc_feed') },
       { id: 'search', icon: 'search', label: L('ph.soc_search') },
       { id: 'dm', icon: 'messages', label: L('ph.soc_dm') },
       { id: 'me', icon: 'contacts', label: L('ph.soc_profile') }];

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
  if (tab === 'search') return socialSearchView(appId);
  if (tab === 'dm') return socialDmList(appId);
  if (tab === 'me') return socialProfile(appId, SOC.handle[appId]);
  return socialFeed(appId);
}

// -- Composers --------------------------------------------------
function bleetCompose() {
  sheet(L('ph.bleet_new'),
    UI.field('btext', L('ph.bleet_ph'), '', 'maxlength="280"') +
      UI.button('😊 ' + L('ph.emoji'), 'bemoji', 'plain') +
      UI.button(L('ph.pick_photo'), 'bpick', 'plain') + UI.button(L('ph.bleet_send'), 'bgo'),
    () => {
      byId('bemoji').addEventListener('click', () => emojiOpen('btext'));
      // A post can carry a photo straight off the phone rather than a pasted link.
      byId('bpick').addEventListener('click', () => pickPhoto(async (url) => {
        const bodyText = byId('btext').value;
        const epoch = sheetEpoch;
        const r = await post('social', { op: 'post', kind: 'photo', body: bodyText, image: url });
        if (!closeSheet(false, epoch)) return;
        if (r && r.ok) { ui('sent'); socialRender('bleeter'); }
        else toast(L('ph.err_' + ((r && r.error) || 'x')));
      }));
      byId('bgo').addEventListener('click', async () => {
        const bodyText = byId('btext').value;
        const epoch = sheetEpoch;
        const r = await post('social', { op: 'post', kind: 'text', body: bodyText });
        if (!closeSheet(false, epoch)) return;
        if (r && r.ok) { ui('sent'); socialRender('bleeter'); }
        else toast(L('ph.err_' + ((r && r.error) || 'x')));
      });
    });
}

// Posting starts from the gallery, because that is where photos already are: the camera
// shoots, Snapmatic shows.
function snapCompose() {
  const shots = state.photos || [];
  if (!shots.length) { toast(L('ph.snap_noshots')); return; }
  sheet(L('ph.snap_new'),
    '<div class="shots" style="margin-bottom:10px">' + shots.map((v, i) =>
      '<div class="shot" data-i="' + i + '" style="' + photoStyle(v) + '"></div>').join('') + '</div>' +
    UI.field('scap', L('ph.snap_caption'), '', 'maxlength="140"') +
      UI.button('😊 ' + L('ph.emoji'), 'semoji', 'plain'),
    () => {
      byId('semoji').addEventListener('click', () => emojiOpen('scap'));
      [...byId('sheet').querySelectorAll('.shot')].forEach((el) =>
        el.addEventListener('click', async () => {
          const bodyText = byId('scap').value;
          const epoch = sheetEpoch;
          const r = await post('social', { op: 'post', kind: 'photo',
            image: photoRow(shots[Number(el.dataset.i)]).url, body: bodyText });
          if (!closeSheet(false, epoch)) return;
          if (r && r.ok) { ui('sent'); socialRender('snap'); }
          else toast(L('ph.err_' + ((r && r.error) || 'x')));
        }));
    });
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

  body(
    '<div class="hushdeck">' +
      '<div class="hushcard" id="hcard">' +
        '<div class="hphoto"' + (pf.photo ? ' style="' + inlineBackground(pf.photo) + '"' : '') + '>' +
          '<span class="hstamp yes">' + esc(L('ph.like')) + '</span>' +
          '<span class="hstamp no">' + esc(L('ph.pass')) + '</span>' +
          '<div class="hmeta">' +
            '<div class="hname">' + esc(pf.name || '?') + (pf.age ? ', ' + pf.age : '') + '</div>' +
            (pf.bio ? '<div class="hbio">' + esc(pf.bio) + '</div>' : '') +
          '</div>' +
        '</div>' +
      '</div>' +
    '</div>' +
    '<div class="hushrow">' +
      '<button class="hushbtn no" id="hno" type="button" aria-label="' +
        esc(L('ph.pass')) + '">' + svg('xmark') + '</button>' +
      '<button class="hushbtn yes" id="hyes" type="button" aria-label="' +
        esc(L('ph.like')) + '">' + svg('heart') + '</button>' +
    '</div>'
  );
  pushAnim();

  const choose = async (like) => {
    const card = byId('hcard');
    if (card) {
      card.classList.add(like ? 'flyright' : 'flyleft');
      ui(like ? 'toggleon' : 'toggleoff');
    }
    const c = await post('social', { op: 'hushChoice', ref: pf.ref, like });
    if (c && c.error) { toast(L('ph.err_' + ((c && c.error) || 'x'))); return; }
    if (c && c.match) {
      ui('success');
      banner({ app: 'hush', icon: 'hush', title: L('ph.hush_match'),
               body: (c.name || '?') + (c.number ? '  ' + c.number : '') });
    }
    setTimeout(() => { if (socialActive('hush', epoch)) hushSwipe(); }, 240);
  };
  byId('hno').addEventListener('click', () => choose(false));
  byId('hyes').addEventListener('click', () => choose(true));
  wireHushDrag(byId('hcard'), choose);
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
      '<span class="rowtext"><span class="rowtitle">' +
        esc(m.name || '?') + (m.age ? ', ' + m.age : '') + '</span>' +
      '<span class="rowsub">' + esc(m.bio || m.number || '') + '</span></span>' +
      svg('chevron') +
    '</button>').join('')) : UI.empty(L('ph.hush_no_matches'), 'hush'));

  // A match is somebody you already swapped numbers with, so the useful thing to do
  // with one is call or write to them.
  rows('.hushmatch', (b) => b.addEventListener('click', () => {
    const m = list[Number(b.dataset.i)];
    if (!m || !m.number) { toast(L('ph.hush_no_number')); return; }
    sheet(m.name || '?',
      UI.row({ icon: 'phone', title: L('ph.call'), value: m.number, data: { act: 'call' } }) +
      UI.row({ icon: 'messages', title: L('ph.message'), data: { act: 'sms' } }),
      () => {
        const epoch2 = sheetEpoch;
        [...byId('sheet').querySelectorAll('[data-act]')].forEach((el) =>
          el.addEventListener('click', () => {
            if (!closeSheet(false, epoch2)) return;
            if (el.dataset.act === 'call') { post('call', { number: m.number }); return; }
            const messages = (state.apps || []).find((a) => a.id === 'messages');
            if (!messages) return;
            enterApp(messages, null);
            openThread(m.number);
          }));
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

  body(
    '<div class="socprof">' +
      (pf.photo ? '<span class="socbigav" style="' + inlineBackground(pf.photo) + '"></span>'
                : '<span class="socbigav">' + svg('hush') + '</span>') +
      '<div class="socbio">' + esc(pf.bio || L('ph.hush_nobio')) + '</div>' +
    '</div>' +
    UI.field('hbio', L('ph.hush_bio'), pf.bio || '', 'maxlength="160"') +
    UI.field('hphoto', L('ph.hush_photo'), pf.photo || '', 'maxlength="300"') +
    UI.button(L('ph.pick_photo'), 'hpick', 'plain') +
    UI.group(UI.row({ icon: 'hush', title: L('ph.hush_active'),
                      toggle: pf.active !== false, data: { t: 'active' } })) +
    '<div class="groupfoot">' + esc(L('ph.hush_active_hint')) + '</div>' +
    UI.button(L('ph.save'), 'hsave')
  );

  let active = pf.active !== false;
  byId('hpick').addEventListener('click', () => pickPhoto((url) => { byId('hphoto').value = url; }));
  // The kit's switch is a styled span, not a checkbox, so the row owns the state.
  rows('.row[data-t="active"]', (el) => el.addEventListener('click', () => {
    active = !active;
    const knob = el.querySelector('.sw');
    if (knob) knob.classList.toggle('on', active);
    ui(active ? 'toggleon' : 'toggleoff');
  }));
  byId('hsave').addEventListener('click', async () => {
    const r = await post('social', { op: 'hushSetup',
      bio: byId('hbio').value, photo: byId('hphoto').value, active });
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

// Play one pass of a tone: a custom URL if there is one, otherwise the synthesised score.
function playTone(name, url, vol, loop) {
  const p = state.prefs || {};
  const v = vol == null ? (p.ringVolume ?? 0.7) : vol;
  if (v <= 0 || name === 'none') return;

  if (url) {
    try {
      const el = new Audio(url);
      el.volume = Math.max(0, Math.min(1, v));
      el.loop = !!loop;
      el.play().catch(() => {});
      if (loop) ringEl = el;
      return;
    } catch { /* fall through to the built-in */ }
  }
  const score = TONES[name] || TONES.classic;
  score.forEach(([f, t, d]) => note(f, t, d, 0.12 * v, 'sine'));
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
};

// UI feedback sits well below a ringtone: it accompanies an action the player just
// took, so it only has to be heard, not answered.
function ui(name) {
  const score = UI_TONES[name];
  if (!score) return;
  const v = (state.prefs || {}).ringVolume;
  const vol = v == null ? 0.7 : v;
  if (vol <= 0) return;
  score.forEach(([f, t, d]) => note(f, t, d, 0.045 * vol, 'sine'));
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
      else if (data.from) openThread(data.from);
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

  const n = { id: ++notifSeq, app, icon: b.icon || app, title: b.title || '', body: b.body || '',
              at: Date.now(), onClick: b.onClick || null };
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
    notifs = [];
    paintNotifs();
    if (byId('shade').classList.contains('on')) renderShade();
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
  const name = call.number ? nameOfNumber(call.number) : L('ph.unknown');
  byId('callav').textContent = name.slice(0, 1).toUpperCase();
  byId('callnum').textContent = name;
  byId('callstate').textContent =
    call.state === 'in' ? L('ph.incoming') : call.state === 'out' ? L('ph.calling') : '';

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
    await post('music', { id: m.id, action: m.paused ? 'resume' : 'pause' });
    m.paused = !m.paused; renderCC();
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
    if (ccNow) await post('music', { id: ccNow.id, action: 'volume', volume: v });
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

// The control centre's media tile reads from v-music, refreshed each time it opens.
async function primeNowPlaying() {
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
            openThread(result.contact.number, text);
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
      openThread(String(data.data.number), data.data.draft || '');
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
  call:     (d) => post('call', d),
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
}

// ══ Wiring ═════════════════════════════════════════════════════
byId('lock').addEventListener('click', unlock);
byId('homebar').addEventListener('click', (e) => {
  e.currentTarget.blur();
  goHome();
});

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
              UI.appIcon(a.icon) + '<span>' + esc(L(a.label)) + '</span></button>').join('') + '</div>';
        byId('appres').innerHTML = list.length
          ? '<div class="spotlabel">' + esc(q ? L('ph.results') : L('ph.all_apps')) + '</div>' +
            UI.group(list.map((a) => UI.row({
              appicon: a.icon, title: L(a.label),
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
  if (!state.camera || !camera) {
    toast(L('ph.camera_off'));
    return;
  }
  const openCamera = () => enterApp(camera, byId('qcam'));
  if (!byId('lock').classList.contains('out')) unlock(openCamera);
  else openCamera();
});
byId('qtorch').addEventListener('click', toggleTorch);

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
  // CEF host messages have no foreign Window source. An iframe must never be able to
  // impersonate Lua with an { action: ... } payload.
  if (e.source && e.source !== window) return;
  const d = e.data || {};
  if (d.__phone) return;                       // SDK traffic, handled above
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
    byId('locknum').textContent = d.number || '';
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
          else openThread(m.from);
        } });
      refresh().then(() => { if (!openApp) renderHome(); });
    }
  } else if (d.action === 'cipher') {
    cipherReceive(d.packet || {});
  } else if (d.action === 'power') {
    applyPower(d.power);
  } else if (d.action === 'banner') {
    banner(d.banner || {});
  } else if (d.action === 'buzz') {
    buzzDevice();
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
  } else if (d.action === 'airdropResult') {
    const r = d.result || {};
    toast(r.ok ? (L('ph.airdrop_took') + (r.name ? ' ' + r.name : '')) : L('ph.airdrop_declined'));
  }
});

wireSideButtons();
tick();
