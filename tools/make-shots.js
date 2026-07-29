/**
 * The README's screenshots, taken from the real page.
 *
 *   python tools/make-preview.py     # build the browser preview first
 *   node tools/make-shots.js         # then shoot it
 *
 * The ten pictures in `docs/images` were taken by hand in July, before five apps existed, and
 * a README whose pictures are older than its features is a README that undersells the thing.
 * This makes them repeatable: every shot is a named script that drives the page to one screen
 * and captures the handset, so the whole set can be retaken after any change in one command.
 *
 * Same shape as the existing ten - the whole device, bezel included, 420 x 816 - so a new shot
 * can sit in a table beside an old one without the row looking broken.
 *
 * No dependency is installed. Node 22 has a WebSocket client built in, so this speaks the
 * Chrome DevTools Protocol straight to a headless Chrome that is already on the machine, and
 * hands the frames to ffmpeg for the resize. Same machinery as tools/make-previews.js.
 *
 * Flags:
 *   --only home,store    take just these
 *   --list               print the names and stop
 *   --keep               leave the full-size captures beside the finished ones
 */

const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.dirname(__dirname);
const PREVIEW = path.join(ROOT, 'preview', 'index.html');
const OUT = path.join(ROOT, 'docs', 'images');
const PORT = 9377;

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const ONLY = flag('only', '').split(',').map((s) => s.trim()).filter(Boolean);
const KEEP = argv.includes('--keep');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// Give up on a step rather than let it take the whole run down.
///
/// `Page.captureScreenshot` does not always answer. A clip it cannot satisfy comes back as
/// silence, not as an error, and one screen that will not photograph then hangs a batch of
/// twelve with no output at all - which is how a five-minute job turned into a ten-minute
/// stall twice over. Every step that talks to the browser is bounded now, so a bad shot is a
/// skipped line and the other eleven still land.
function within(ms, what, promise) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(what + ' timed out')), ms)),
  ]);
}

// The finished size, matching the ten shots already in the folder.
const WIDE = 420;
const TALL = 816;

// ══════════════════════════════════════════════════════════════
// The shots
// ══════════════════════════════════════════════════════════════
// Each is a name, a file, and a script that leaves the page on the screen to photograph. The
// script runs in the page and may await; it returns nothing.
//
// `landscape: true` marks a shot where the handset is on its side, so the frame is taken from
// the device's real box rather than from the portrait one.

const SETUP = `
  const app = (id) => (state.apps || []).find((a) => a.id === id);
  const need = (id) => {
    if (app(id)) return app(id);
    const tpl = (state.apps || [])[0];
    const made = Object.assign({}, tpl, { id, label: 'app.' + id, dock: false });
    state.apps.push(made);
    return made;
  };
  const open = async (id, ms) => { await enterApp(need(id), null); await new Promise((r) => setTimeout(r, ms || 900)); };
`;


const MUSIC_FIXTURE = `
  const TRACKS = [
    { title: 'Nightcall', artist: 'Kavinsky', album: 'OutRun' },
    { title: 'Radio Los Santos', artist: 'Big Smoke', album: 'Grove Street' },
    { title: 'Vinewood Nights', artist: 'The Mesa', album: 'After Hours' },
    { title: 'Del Perro Drive', artist: 'Sessanta', album: 'Coastline' },
    { title: 'Paleto Blues', artist: 'Trevor P', album: 'North County' },
    { title: 'Sandy Shores', artist: 'Ron A', album: 'Desert Tape' },
  ].map((t, i) => Object.assign({}, t, {
    url: 'https://example.invalid/' + i, id: 'fx' + i, kind: 'track',
    favorite: i < 3, _libraryIndex: i,
  }));
  musicModel = async () => ({
    library: TRACKS,
    sources: [],
    recent: TRACKS.slice(0, 5),
    playlists: [
      { id: 'p1', name: 'Tournee de nuit', icon: 'play', tracks: TRACKS.slice(0, 4) },
      { id: 'p2', name: 'Au garage', icon: 'wrench', tracks: TRACKS.slice(2) },
    ],
    limits: {},
    current: Object.assign({}, TRACKS[0], { paused: false }),
    enabled: true, handoff: false, provider: 'xsound',
  });
`;

const SHOTS = [
  {
    name: 'home', file: '04-home.png',
    script: `try { unlock(); } catch (e) {}
      await new Promise((r) => setTimeout(r, 900));`,
  },
  {
    name: 'store', file: '11-fruitstore.png',
    script: `${SETUP} await open('store', 1400);`,
  },
  {
    name: 'store-app', file: '12-fruitstore-app.png',
    script: `${SETUP}
      await open('store', 1400);
      const row = [...document.querySelectorAll('.strowitem')].find((r) => r.dataset.app === 'bleeter')
        || document.querySelector('.strowitem');
      if (row) { row.click(); await new Promise((r) => setTimeout(r, 1200)); }
      document.getElementById('appbody').scrollTop = 150;
      await new Promise((r) => setTimeout(r, 400));`,
  },
  {
    // A thread carrying everything the app can now put in one: a day heading, a run of bubbles
    // grouped under one tail, a reply quoting what it answers, a reaction, a picture, the
    // typing dots and the receipt line. Painted from a fixture rather than from the server, so
    // it shows the same screen every time it is taken.
    name: 'messages', file: '23-messages.png',
    script: `${SETUP}
      await open('messages', 700);
      thread = '555-0188';
      threadGroup = null;
      const H = Date.now() - 3600000;
      paintThread([
        { id: 1, mine: false, kind: 'text', at: H, body: 'Tu es passe au garage ?' },
        { id: 2, mine: true,  kind: 'text', at: H + 60000, body: 'Oui, je viens de sortir.' },
        { id: 3, mine: true,  kind: 'text', at: H + 64000, body: 'Ils ont trouve la fuite.',
          reactions: { counts: { love: 1 }, mine: null } },
        { id: 4, mine: false, kind: 'text', at: H + 900000, body: 'Combien au final ?',
          reply: { id: 3, kind: 'text', body: 'Ils ont trouve la fuite.', mine: false } },
        { id: 5, mine: true,  kind: 'image', at: H + 960000, body: 'La facture.',
          attachment: (state.photos && state.photos[0] && (state.photos[0].url || state.photos[0])) || '' },
        { id: 6, mine: false, kind: 'text', at: H + 1020000, body: 'Aie.' },
        { id: 7, mine: true,  kind: 'text', at: H + 1080000, seen: true,
          body: 'On en reparle ce soir.' },
      ], false);
      typingSet('555-0188', true);
      await new Promise((r) => setTimeout(r, 600));`,
  },
  {
    // Not for the README: a folder actually in mid-drag, so the ghost can be looked at rather
    // than reasoned about. Every rule that shrinks a folder's four icons is written
    // `.tile .folder`, and the ghost is not a tile - which is how a dragged folder came to
    // render its contents at full size, stacked, off the grid.
    name: 'drag-folder', file: 'zz-drag-folder.png', scratch: true, assert: true,
    script: `${SETUP}
      const items = layoutItems();
      const apps = items.filter((x) => x && x.t === 'app').slice(0, 4).map((x) => x.id);
      items.unshift({ t: 'folder', name: 'Dossier', apps });
      await saveLayout(items);
      await new Promise((r) => setTimeout(r, 200));
      renderHome();
      await new Promise((r) => setTimeout(r, 900));
      const tile = document.querySelector('.tile.isfolder');
      if (!tile) throw new Error('no folder tile was drawn');
      const box = tile.getBoundingClientRect();
      enterArrange();
      beginDrag(tile, { clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 });
      await new Promise((r) => setTimeout(r, 400));
      const g = document.getElementById('dragghost');
      const inner = g.querySelector('.folder');
      const one = g.querySelector('.folder span .ic');
      if (!inner) throw new Error('the ghost holds no folder');
      const f = inner.getBoundingClientRect();
      const o = one ? one.getBoundingClientRect() : null;
      // Measured, not eyeballed, and it FAILS the shot rather than printing: the harness has
      // no console bridge, so an assertion that throws is the only signal that reaches the
      // terminal. The folder tile is 60 across and each icon inside it is about a quarter of
      // that; anything near 60 for an inner icon is the stacked-at-full-size bug.
      if (!o) throw new Error('the ghost folder holds no icons');
      if (Math.round(f.width) > 70 || Math.round(o.width) > 34) {
        throw new Error('ghost folder ' + Math.round(f.width) + ' inner ' + Math.round(o.width));
      }`,
  },
  {
    name: 'pins', file: '28-map-pins.png',
    script: `${SETUP}
      await open('maps', 700);
      mapsTab = 'pins';
      pins = [
        { id: 1, label: 'La depanneuse', icon: 'garage', x: 0, y: 0, away: 84 },
        { id: 2, label: 'Le spot au bord de l eau', icon: 'star', x: 0, y: 0, away: 620 },
        { id: 3, label: 'Ou j ai laisse la Sultan', icon: 'car', x: 0, y: 0, away: 1450 },
        { id: 4, label: 'Le lockup', icon: 'house', x: 0, y: 0, away: 3800 },
        { id: 5, label: 'Station pas chere', icon: 'fuel', x: 0, y: 0, away: 5200 },
      ];
      paintPins();
      await new Promise((r) => setTimeout(r, 500));`,
  },
  {
    // The conversation header on its own: the chevron, the face, the name and the call button.
    // Taken through `openThread` rather than `paintThread`, because the header is what is
    // being looked at and only that path builds it.
    name: 'thread-head', file: 'zz-thread-head.png', scratch: true, assert: true,
    script: `${SETUP}
      await open('messages', 700);
      state.contacts = (state.contacts || []).concat([
        { id: 900, name: 'Sofia Delgado', number: '555-0188' }]);
      await openThread('555-0188');
      await new Promise((r) => setTimeout(r, 700));
      const act = document.getElementById('navact');
      const bar = document.getElementById('navbar');
      const a = act.getBoundingClientRect();
      const b = bar.getBoundingClientRect();
      const gap = Math.round(b.right - a.right);
      // Measured rather than eyeballed: the call button has to sit the same distance from the
      // edge as the chevron opposite, and be round.
      if (Math.abs(a.width - a.height) > 1) {
        throw new Error('call button is ' + Math.round(a.width) + 'x' + Math.round(a.height));
      }
      if (gap < 16) throw new Error('call button only ' + gap + 'px from the edge');`,
  },
  {
    name: 'music', file: 'zz-music.png', scratch: true,
    script: `${SETUP}${MUSIC_FIXTURE}
      await open('music', 400);
      musicTab = 'listen';
      await RENDER.music();
      await new Promise((r) => setTimeout(r, 600));
      // The first screen has to SHOW the first row of titles, not merely contain them.
      // The hero was tall enough to push them two pixels past the fold, so the app opened
      // on a wall of covers with nothing written under any of them.
      const card = document.querySelector('.musiccard');
      const copy = card && card.querySelector('.musiccardcopy');
      if (!copy) throw new Error('no card copy at all');
      const rp = copy.getBoundingClientRect();
      const rb = document.getElementById('appbody').getBoundingClientRect();
      if (rp.bottom > rb.bottom) {
        throw new Error('card title sits ' + Math.round(rp.bottom - rb.bottom) + 'px below the fold');
      }`,
  },
  {
    name: 'music-browse', file: 'zz-music-browse.png', scratch: true,
    script: `${SETUP}${MUSIC_FIXTURE}
      await open('music', 400);
      musicTab = 'browse';
      await RENDER.music();
      await new Promise((r) => setTimeout(r, 600));`,
  },
  {
    name: 'music-player', file: 'zz-music-player.png', scratch: true,
    script: `${SETUP}${MUSIC_FIXTURE}
      await open('music', 400);
      musicPlayerOpen = true;
      await RENDER.music();
      await new Promise((r) => setTimeout(r, 600));
      // The bottom row has to be REACHABLE. The player clips its own overflow, so a row that
      // does not fit is not scrolled to - it is gone, and with it Favourite, Output and Queue.
      const acts = document.querySelector('.musicplayeractions');
      if (!acts) throw new Error('no action row');
      const ra = acts.getBoundingClientRect();
      const rs = document.getElementById('screen').getBoundingClientRect();
      if (ra.bottom > rs.bottom - 8) {
        throw new Error('action row ends ' + Math.round(ra.bottom - rs.bottom) + 'px past the screen');
      }`,
  },
  {
    name: 'gallery', file: 'zz-gallery.png', scratch: true,
    script: `${SETUP}
      await open('gallery', 900);
      await new Promise((r) => setTimeout(r, 400));`,
  },
  {
    // Viewing one Snapmatic story used to replace every child of #folderview - and its three
    // children live only in index.html, so nothing rebuilt them. Every folder on the home
    // screen was dead for the rest of the session.
    name: 'story-folder', file: null, scratch: true, assert: true,
    script: `${SETUP}
      const host = document.getElementById('folderview');
      // Two ids and one class. folderacts is a CLASS in index.html, not an id - the report
      // that found this bug listed it as an id, and a check that looks for the wrong thing
      // fails for the wrong reason.
      const parts = () => [
        document.getElementById('foldername'),
        document.getElementById('folderapps'),
        host.querySelector('.folderacts'),
      ].filter(Boolean).length;
      if (parts() !== 3) throw new Error('the folder overlay is already incomplete');
      await open('snap', 900);
      storyViewer('snap', { handle: 'someone', mine: false,
        items: [{ id: 1, image: '', at: Date.now() / 1000, body: '' }] });
      await new Promise((r) => setTimeout(r, 300));
      const closer = host.querySelector('.storyclose');
      if (!closer) throw new Error('the story viewer did not open');
      closer.click();
      await new Promise((r) => setTimeout(r, 300));
      const left = parts();
      if (left !== 3) {
        throw new Error('the story viewer destroyed ' + (3 - left) + ' of the folder overlay');
      }
      if (host.querySelector('.storyview')) throw new Error('the story stage was left behind');`,
  },
  {
    // Two elements used to restart an animation the moment they were dismissed, because
    // `animation: none` REMOVES the name and putting it back is a new animation. Both are
    // measured through getAnimations(), which is the browser's own answer.
    name: 'no-restart', file: null, scratch: true, assert: true,
    script: `${SETUP}
      const el = document.getElementById('hud');
      el.classList.add('on');
      await new Promise((r) => setTimeout(r, 400));
      el.classList.remove('on');
      await new Promise((r) => setTimeout(r, 50));
      const running = el.getAnimations().filter((a) => a.playState === 'running');
      if (running.length) {
        throw new Error('the hud restarted ' + running.length + ' animation(s) on dismiss');
      }
      const sheetEl = document.getElementById('sheet');
      sheetEl.classList.add('on');
      await new Promise((r) => setTimeout(r, 700));
      sheetEl.classList.add('dragging');
      await new Promise((r) => setTimeout(r, 50));
      sheetEl.classList.remove('dragging');
      await new Promise((r) => setTimeout(r, 50));
      const back = sheetEl.getAnimations().filter((a) => a.playState === 'running');
      sheetEl.classList.remove('on');
      if (back.length) {
        throw new Error('the sheet replayed its entrance after a tap on the grab bar');
      }`,
  },
  {
    name: 'gallery-view', file: 'zz-gallery-view.png', scratch: true,
    script: `${SETUP}
      const P = ['Vespucci Beach', 'Mission Row', 'Sandy Shores', 'Vespucci Beach',
                 'Paleto Bay', 'Mission Row', 'Del Perro', 'Sandy Shores'];
      const C = [['#ff9c45','#a72841'], ['#4fc7ff','#2450a4'], ['#54d8a0','#126b68'],
                 ['#ae63ff','#45238c'], ['#f3d45b','#bf4864'], ['#ff4365','#811848'],
                 ['#3ddad7','#0d5566'], ['#c3f53c','#3f7a1e']];
      const shot = (i) => 'data:image/svg+xml;utf8,' + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180">' +
        '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">' +
        '<stop offset="0" stop-color="' + C[i][0] + '"/>' +
        '<stop offset="1" stop-color="' + C[i][1] + '"/></linearGradient></defs>' +
        '<rect width="320" height="180" fill="url(#g)"/>' +
        '<circle cx="' + (60 + i * 28) + '" cy="120" r="46" fill="rgba(255,255,255,.16)"/>' +
        '</svg>');
      state.photos = P.map((place, i) => ({ url: shot(i), album: '', filter: '', place }));
      photosForget();
      photosList = async () => ({ ok: true, photos: state.photos, albums: [] });
      galleryTab = 'photos';
      galleryAlbum = '';
      await open('gallery', 700);
      document.querySelectorAll('.shot')[2].click();
      await new Promise((r) => setTimeout(r, 600));
      // The four things the viewer must offer, and the roll it pages through.
      const bar = document.querySelector('.pbar');
      if (!bar) throw new Error('the viewer did not open');
      const n = bar.querySelectorAll('button').length;
      if (n !== 4) throw new Error('expected 4 actions, found ' + n);
      const on = document.querySelector('.prollone.on');
      if (!on || on.dataset.i !== '2') throw new Error('the roll is not on the tapped picture');
      // And it has to GO when you leave. A footer survives a new body being drawn, so the
      // toolbar sat under the grid acting on a photograph nobody was looking at any more.
      await RENDER.gallery(true);
      await new Promise((r) => setTimeout(r, 400));
      if (document.querySelector('.pbar')) throw new Error('the toolbar survived the way back');`,
  },
  {
    // A retouched photograph handed to another app has to carry its retouch. The edit is a
    // recipe in the URL's fragment, so the test is whether the string that LEAVES the gallery
    // still has one - a bare link is the picture as it was before it was edited.
    name: 'photo-share', file: 'zz-share.png', scratch: true, assert: true,
    script: `${SETUP}
      const one = { url: 'https://example.invalid/a.png', album: '', filter: 'noir',
                    crop: 'square', focus: 30 };
      const row = photoRow(one);
      const out = photoEncode(row.url, row);
      if (out.indexOf('#vp=') === -1) throw new Error('the edit was dropped: ' + out);
      const back = photoDecode(out);
      if (back.filter !== 'noir' || back.crop !== 'square' || back.focus !== 30) {
        throw new Error('the recipe did not survive: ' + JSON.stringify(back));
      }
      // And the host gate must still see a clean host, or a shared photo is refused as badhost.
      if (out.split('#')[0] !== 'https://example.invalid/a.png') {
        throw new Error('the fragment leaked into the link: ' + out);
      }`,
  },
  {
    name: 'gallery-albums', file: 'zz-gallery-albums.png', scratch: true,
    script: `${SETUP}
      await open('gallery', 900);
      // The preview's photos carry no place, so one is put on each to show the tab doing its
      // job. The real ones are written by the server at capture time.
      // Self-contained pictures. The preview ships no photographs at all, and a gallery shot of
      // an empty gallery says nothing about the gallery.
      const P = ['Vespucci Beach', 'Mission Row', 'Sandy Shores', 'Vespucci Beach',
                 'Paleto Bay', 'Mission Row', 'Del Perro', 'Sandy Shores'];
      const C = [['#ff9c45','#a72841'], ['#4fc7ff','#2450a4'], ['#54d8a0','#126b68'],
                 ['#ae63ff','#45238c'], ['#f3d45b','#bf4864'], ['#ff4365','#811848'],
                 ['#3ddad7','#0d5566'], ['#c3f53c','#3f7a1e']];
      const shot = (i) => 'data:image/svg+xml;utf8,' + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180">' +
        '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">' +
        '<stop offset="0" stop-color="' + C[i][0] + '"/>' +
        '<stop offset="1" stop-color="' + C[i][1] + '"/></linearGradient></defs>' +
        '<rect width="320" height="180" fill="url(#g)"/>' +
        '<circle cx="' + (60 + i * 28) + '" cy="120" r="46" fill="rgba(255,255,255,.16)"/>' +
        '</svg>');
      state.photos = P.map((place, i) => ({ url: shot(i), album: '', filter: '', place }));
      photosForget();
      photosList = async () => ({ ok: true, photos: state.photos, albums: [] });
      galleryTab = 'albums';
      await RENDER.gallery();
      await new Promise((r) => setTimeout(r, 400));`,
  },
  {
    // Does the framing slider actually move anything? A 16:9 source in a 3:4 frame overflows
    // sideways, so the vertical position it used to set had no slack and every drag was a
    // no-op. Measured by reading the rendered offset at each end rather than by looking.
    name: 'crop-slider', file: 'zz-crop.png', scratch: true, assert: true,
    script: `${SETUP}
      const svgShot = 'data:image/svg+xml;utf8,' + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900">' +
        '<rect width="1600" height="900" fill="#333"/>' +
        '<rect x="0" y="0" width="200" height="900" fill="#f00"/>' +
        '<rect x="1400" y="0" width="200" height="900" fill="#0f0"/></svg>');
      state.photos = [{ url: svgShot, album: '', filter: '', crop: 'portrait', focus: 50 }];
      photosForget();
      photosList = async () => ({ ok: true, photos: state.photos, albums: [] });
      await open('gallery', 700);
      // Two taps now, not one. A thumbnail opens the VIEWER; the editor is behind its Modifier
      // button. This assertion was written before that change and broke on it, which is the
      // assertion doing its job - it just needed the new route.
      document.querySelector('.shot').click();
      await new Promise((r) => setTimeout(r, 500));
      const editBtn = document.getElementById('pedit');
      if (!editBtn) throw new Error('the viewer did not open');
      editBtn.click();
      await new Promise((r) => setTimeout(r, 700));
      const img = document.getElementById('shotbig');
      const slider = document.getElementById('sfocus');
      if (!img || !slider) throw new Error('editor did not open');
      // Which axis can actually move. object-fit cover scales by whichever factor covers the
      // box; the other axis overflows, and it is the ONLY one object-position can shift.
      // Reading the declared property was not a test - "50% 0%" and "50% 100%" differ as strings
      // while rendering identically, which is why this probe passed against the broken code the
      // first time it was written.
      const box = img.getBoundingClientRect();
      const nw = img.naturalWidth, nh = img.naturalHeight;
      if (!nw || !nh) throw new Error('the picture has no natural size yet');
      const scale = Math.max(box.width / nw, box.height / nh);
      const slackX = nw * scale - box.width;
      const slackY = nh * scale - box.height;
      const axis = slackX > slackY ? 0 : 1;      // 0 = horizontal, 1 = vertical
      const read = () => getComputedStyle(img).objectPosition.split(' ')[axis];
      slider.value = 0;
      slider.dispatchEvent(new Event('input', { bubbles: true }));
      await new Promise((r) => setTimeout(r, 120));
      const a = read();
      slider.value = 100;
      slider.dispatchEvent(new Event('input', { bubbles: true }));
      await new Promise((r) => setTimeout(r, 120));
      const b = read();
      if (a === b) {
        throw new Error('the slider does not move the axis with room (' +
          (axis ? 'vertical' : 'horizontal') + '): both ends read ' + a);
      }`,
  },
  {
    // Do the garages actually reach Contacts? The list is fetched, not configured, so the only
    // honest test drives the real code path with the two callbacks stubbed at the post() layer.
    name: 'contacts-garages', file: 'zz-cgarages.png', scratch: true, assert: true,
    script: `${SETUP}
      // post() is a const and cannot be reassigned. The page ships a hook for exactly this -
      // the preview harness uses it too - so the stub goes in front of what is there.
      const under = window.__VPHONE_PREVIEW_POST__;
      window.__VPHONE_PREVIEW_POST__ = (name, body) => {
        // The CONFIG provider: no doc flag, garages in the first reply. This is the default
        // shape on a server without doc-mechanicmdt, and it is the one that was broken.
        if (name === 'repairOpen') {
          return { ok: true, garages: [
            { job: 'mechanic', label: 'Los Santos Customs', open: true, x: -360, y: -125 },
            { job: 'mechanic2', label: 'Route 68 Garage', open: false, x: 563, y: 2737 },
            { job: 'mechanic3', label: "Benny's Original", open: true, x: -237, y: -1326 },
          ] };
        }
        if (name === 'repairDoc' && body && body.op === 'garages') {
          return { ok: true, garages: [
            { job: 'mechanic', label: 'Los Santos Customs', open: true, x: -360, y: -125 },
            { job: 'mechanic2', label: 'Route 68 Garage', open: false, x: 563, y: 2737 },
            { job: 'mechanic3', label: "Benny's Original", open: true, x: -237, y: -1326 },
          ] };
        }
        return under ? under(name, body) : { error: 'x' };
      };
      state.apps = (state.apps || []);
      if (!state.apps.some((a) => a.id === 'repair')) {
        state.apps.push(Object.assign({}, state.apps[0], { id: 'repair', label: 'app.repair' }));
      }
      repairData = null;
      await open('contacts', 900);
      await new Promise((r) => setTimeout(r, 900));
      const host = document.getElementById('cgarages');
      if (!host) throw new Error('no garage host in the contacts body');
      const found = [...host.querySelectorAll('.row[data-g]')];
      if (found.length !== 3) throw new Error('expected 3 garage rows, found ' + found.length);
      // NAMED, not merely present. The first version of this probe fed the page a field it
      // never actually receives, so three rows with blank titles counted as a pass.
      const blank = found.filter((r) => !r.textContent.includes('Los Santos')
        && !r.textContent.includes('Route 68') && !r.textContent.includes('Benny'));
      if (blank.length) throw new Error(blank.length + ' garage rows have no name');`,
  },
  {
    name: 'settings', file: 'zz-settings.png', scratch: true,
    script: `${SETUP}
      await open('settings', 900);
      // Every category has to lead somewhere. A row that draws nothing is worse than no row.
      const cats = [...document.querySelectorAll('.row[data-page]')];
      if (cats.length !== 9) throw new Error('expected 9 categories, found ' + cats.length);
      for (const id of SETTINGS_PAGES.map((x) => x.id)) {
        const html = settingsSection(id);
        if (!html || html.length < 40) throw new Error('the ' + id + ' page is empty');
      }
      await new Promise((r) => setTimeout(r, 300));`,
  },
  {
    name: 'settings-sounds', file: 'zz-settings-sounds.png', scratch: true,
    script: `${SETUP}
      await open('settings', 900);
      settingsPage('sounds');
      await new Promise((r) => setTimeout(r, 500));`,
  },
  {
    name: 'maps', file: '29-map-places.png',
    script: `${SETUP}
      await open('maps', 900);
      await new Promise((r) => setTimeout(r, 400));`,
  },
  {
    // Every face on the real lock screen, side by side with what the picker promised. The
    // picture is one of them; the assertion below is what checks the other four.
    name: 'clock-stack', file: 'zz-clock-stack.png', scratch: true, assert: true,
    script: `${SETUP}
      // Straight to the lock screen. lockScreen() is the real route in; the class is
      // removed by unlock() and nothing else, so this is the state the player sees.
      lockScreen();
      await new Promise((r) => setTimeout(r, 500));
      const el = document.getElementById('lockclock');
      const box = () => el.getBoundingClientRect();
      const set = async (f) => {
        state.prefs.lockClock = f;
        tick();
        await new Promise((r) => setTimeout(r, 200));
      };

      await set('classic');
      const flat = box();
      if (!el.querySelector('.cdh') || !el.querySelector('.cdm')) {
        throw new Error('the real clock is not drawn in parts');
      }
      // The colon has to be there in every face but stack, or classic reads as "1928".
      const colon = getComputedStyle(el.querySelector('.cdh'), '::after').content;
      if (colon.indexOf(':') === -1) throw new Error('classic lost its colon: ' + colon);

      await set('stack');
      const tall = box();
      // Stacked means taller and narrower. Both, because either alone could be a font change.
      if (tall.height < flat.height * 1.5) {
        throw new Error('stack is ' + Math.round(tall.height) + 'px tall, flat is ' +
          Math.round(flat.height) + ' - it did not stack');
      }
      if (tall.width >= flat.width) {
        throw new Error('stack is not narrower than classic');
      }
      const colon2 = getComputedStyle(el.querySelector('.cdh'), '::after').content;
      if (colon2.indexOf(':') !== -1) throw new Error('stack kept its colon');

      // And the other three at least change something measurable, or the face does nothing.
      for (const f of ['slim', 'mono', 'minimal']) {
        await set(f);
        const size = parseFloat(getComputedStyle(el).fontSize);
        const base = 82;
        if (Math.abs(size - base) < 2) {
          throw new Error(f + ' draws at the same size as classic (' + size + ')');
        }
      }
      await set('classic');`,
  },
  {
    name: 'clock', file: '30-lock-clock.png',
    script: `${SETUP}
      lockClockSheet();
      await new Promise((r) => setTimeout(r, 700));`,
  },
  {
    name: 'calc', file: '26-calculator.png',
    script: `${SETUP}
      await open('calc', 600);
      ['7', '*', '8'].forEach((k) => calcPress(k));
      await new Promise((r) => setTimeout(r, 300));`,
  },
  {
    name: 'calc-tape', file: '27-calculator-history.png',
    script: `${SETUP}
      await open('calc', 600);
      calcTape = [
        { q: '148 \\u00d7 3', a: '444' },
        { q: '12500 \\u2212 3200', a: '9300' },
        { q: '9300 \\u00f7 4', a: '2325' },
        { q: '2325 + 175', a: '2500' },
        { q: '86 \\u00d7 12', a: '1032' },
      ];
      calcOpenTape();
      await new Promise((r) => setTimeout(r, 700));`,
  },
  {
    name: 'reminders', file: '24-reminders.png',
    script: `${SETUP}
      await open('reminders', 500);
      const H = Date.now();
      reminders = [
        { id: 1, text: 'Passer chercher les papiers du van', list: 'work',
          due: H - 5400000, repeatMins: 0, flagged: true, done: false },
        { id: 2, text: 'Appeler Ines pour le devis', list: 'personal',
          due: H + 5400000, repeatMins: 0, flagged: false, done: false,
          note: 'Elle est au garage jusqu au soir' },
        { id: 3, text: 'Relever la caisse', list: 'work',
          due: H + 21600000, repeatMins: 1440, flagged: false, done: false },
        { id: 4, text: 'Pneus avant', list: 'shopping', due: 0, repeatMins: 0,
          flagged: false, done: false },
        { id: 5, text: 'Rendre la depanneuse', list: 'other', due: H - 86400000,
          repeatMins: 0, flagged: false, done: true },
      ];
      remTab = 'all';
      paintReminders();
      await new Promise((r) => setTimeout(r, 500));`,
  },
  {
    name: 'notes', file: '25-notes.png',
    script: `${SETUP}
      await open('notes', 500);
      const D = Date.now();
      notes = [
        { id: 1, title: 'Codes du garage', body: 'Codes du garage\\nPorte 4412, coffre 88190.',
          pinned: 1, at: D - 400000000, updated: D - 3600000 },
        { id: 2, title: 'Liste de courses', body: 'Liste de courses\\nHuile, filtres, deux bidons.',
          pinned: 0, at: D - 86400000, updated: D - 86400000 },
        { id: 3, title: 'Devis Sultan', body: 'Devis Sultan\\nDisques avant, plaquettes, main d oeuvre 2h.',
          pinned: 0, at: D - 260000000, updated: D - 172800000 },
        { id: 4, title: 'Plaques a verifier', body: 'Plaques a verifier\\n46FGH902 et le pickup bleu.',
          pinned: 0, at: D - 500000000, updated: D - 400000000 },
      ];
      noteQuery = '';
      paintNotes();
      await new Promise((r) => setTimeout(r, 400));`,
  },
  {
    name: 'contacts', file: '13-contact-card.png',
    script: `${SETUP}
      await open('contacts', 900);
      contactCard({ id: 99, name: 'Mara Ortiz', number: '555-0188',
        photo: (state.photos && state.photos[0] && (state.photos[0].url || state.photos[0])) || '',
        email: 'mara@ifruit.ls', job: 'Photographe',
        address: '9 Vinewood Blvd', birthday: '2 aout', note: 'Rencontree au ponton.' });
      await new Promise((r) => setTimeout(r, 700));`,
  },
  {
    name: 'mycard', file: '14-my-card.png',
    script: `${SETUP}
      await open('contacts', 900);
      state.prefs = Object.assign({}, state.prefs, {
        cardJob: 'Mecanicien, Benny\\'s', cardAddress: '12 Popular St, Vespucci',
        cardBirthday: '14 mars', cardNote: 'Plutot le soir.' });
      myCardEmail = 'alex@ifruit.ls';
      await myCardSheet();
      await new Promise((r) => setTimeout(r, 700));`,
  },
  {
    name: 'fruitee', file: '15-fruitee.png',
    script: `${SETUP} fundTab = 'discover'; await open('fruitee', 1300);`,
  },
  {
    name: 'fruitee-give', file: '16-fruitee-give.png',
    script: `${SETUP}
      fundTab = 'discover';
      await open('fruitee', 1300);
      const card = document.querySelector('.fundcard[data-slug="inesmeds"]') || document.querySelector('.fundcard');
      if (card) { card.click(); await new Promise((r) => setTimeout(r, 900)); }
      const give = document.getElementById('fundgive');
      if (give) { give.click(); await new Promise((r) => setTimeout(r, 700)); }
      const amt = document.getElementById('fundamt');
      if (amt) { amt.value = '1000'; amt.dispatchEvent(new Event('input', { bubbles: true })); }
      await new Promise((r) => setTimeout(r, 400));`,
  },
  {
    name: 'flappy', file: '17-flappyfruit.png',
    script: `${SETUP}
      flapTab = 'play';
      await open('flappy', 1100);
      const g = flapGame;
      if (g) {
        g.flap();
        for (let i = 0; i < 14; i += 1) {
          await new Promise((r) => setTimeout(r, 220));
          if (g.state !== 'playing') break;
          const ahead = g.pipes.filter((p) => p.x + FLAP.PIPE_W > FLAP.BIRD_X - FLAP.BIRD_R)
            .sort((a, b) => a.x - b.x)[0];
          if (ahead && g.y > ahead.gap + FLAP.GAP * 0.45) g.flap();
        }
      }`,
  },
  {
    name: 'brawl', file: '18-fruitbrawl.png',
    script: `${SETUP}
      await open('brawl', 1100);
      const now = Math.floor(Date.now() / 1000);
      brawlPush({ id: 1, round: 5, endsAt: now + 7,
        me:   { hp: 74, stamina: 3, name: 'Alex Mercer', picked: false },
        them: { hp: 52, stamina: 1, name: 'Mara Ortiz', picked: true },
        stake: 50,
        history: [ { mine: 'jab', theirs: 'block' }, { mine: 'heavy', theirs: 'grab' },
                   { mine: 'block', theirs: 'heavy' }, { mine: 'grab', theirs: 'block' } ],
        last: { mine: 'grab', theirs: 'block', tookMe: 0, tookThem: 12,
                tagMe: 'win', tagThem: 'lose' } });
      await new Promise((r) => setTimeout(r, 700));`,
  },
  {
    name: 'brawl-how', file: '19-fruitbrawl-rules.png',
    script: `${SETUP}
      await open('brawl', 1100);
      const how = document.getElementById('bwhow');
      if (how) { how.click(); await new Promise((r) => setTimeout(r, 800)); }`,
  },
  {
    name: 'snap', file: '20-snapmatic.png',
    script: `${SETUP} await open('snap', 1300);`,
  },
  {
    name: 'onlyfruits', file: '21-onlyfruits.png',
    script: `${SETUP} fanTab = 'feed'; await open('onlyfruits', 1300);`,
  },
  {
    // The deck, with everything a card can now carry: the job, what they are here for, the
    // interests with the shared two tinted, the prompt, and how many likes are left today.
    name: 'hush', file: '43-hush.png',
    script: `${SETUP}
      const LIKE_CAP = 3, LIKES_USED = 1, SUPER_CAP = 1, PREMIUM = false;
      const under = window.__VPHONE_PREVIEW_POST__;
      const OPTS = {
        looking: ['casual', 'friends', 'serious', 'unsure'],
        interests: ['animals', 'art', 'beach', 'bikes', 'cars', 'coffee', 'cooking',
                    'dancing', 'films', 'fishing', 'food', 'games', 'guns', 'gym',
                    'hiking', 'music', 'nights', 'travel'],
        prompts: ['brag', 'deal_breaker', 'find_me', 'never_again', 'order_at_bar',
                  'perfect_night', 'sunday', 'worst_habit'],
      };
      const SHOT = 'https://picsum.photos/seed/hush/600/800';
      window.__VPHONE_PREVIEW_POST__ = (name, b) => {
        const op = b && b.op;
        if (name === 'social' && op === 'hushMe') {
          return { ok: true, options: OPTS,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM, until_: 0 },
            pass: { price: 50, account: 'bank', hours: 24, likes: 25, supers: 5,
                    seeLikes: true, rewindLikes: true },
            profile: { bio: 'Mecano le jour, sur la plage le reste du temps.',
                       photo: SHOT, photo2: '', photo3: '',
                       gender: 'f', seeking: 'all', minAge: 21, maxAge: 40, active: true,
                       job: 'Mecanicienne chez Benny', looking: 'serious',
                       interests: ['cars', 'beach', 'music'],
                       prompt: 'find_me', promptAnswer: 'Sous une Sultan, a Sandy Shores.' } };
        }
        if (name === 'social' && op === 'hushNext') {
          return { ok: true,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM },
            profile: { ref: 'ABC123', name: 'Elena', age: 27, distance: 340,
                       bio: 'Je conduis trop vite et je le sais.',
                       photo: SHOT, photos: [SHOT], superOnMe: false,
                       job: 'Barmaid au Vanilla Unicorn', looking: 'casual',
                       interests: ['cars', 'nights', 'music', 'dancing'],
                       shared: ['cars', 'music'],
                       prompt: 'order_at_bar', promptAnswer: 'Un whisky, sec, et pas de paille.' } };
        }
        if (name === 'social' && op === 'hushLikedMe') {
          if (!PREMIUM) return { ok: true, locked: true, count: 7 };
          return { ok: true, locked: false, count: 4, people: [
            { ref: 'A', name: 'Elena', age: 27, photo: SHOT, super: true },
            { ref: 'B', name: 'Marcus', age: 31, photo: SHOT, super: false },
            { ref: 'C', name: 'Yuki', age: 24, photo: SHOT, super: false },
            { ref: 'D', name: 'Sofia', age: 29, photo: SHOT, super: false } ] };
        }
        return under ? under(name, b) : { error: 'x' };
      };

      await open('hush', 500);
      SOC.tab.hush = 'swipe';
      await hushSwipe();
      await new Promise((r) => setTimeout(r, 900));`,
  },
  {
    // The pass. The one screen where money changes hands, so it says the price, the length
    // and every perk before the button.
    name: 'hush-pro', file: '44-hush-premium.png',
    script: `${SETUP}
      const LIKE_CAP = 3, LIKES_USED = 3, SUPER_CAP = 1, PREMIUM = false;
      const under = window.__VPHONE_PREVIEW_POST__;
      const OPTS = {
        looking: ['casual', 'friends', 'serious', 'unsure'],
        interests: ['animals', 'art', 'beach', 'bikes', 'cars', 'coffee', 'cooking',
                    'dancing', 'films', 'fishing', 'food', 'games', 'guns', 'gym',
                    'hiking', 'music', 'nights', 'travel'],
        prompts: ['brag', 'deal_breaker', 'find_me', 'never_again', 'order_at_bar',
                  'perfect_night', 'sunday', 'worst_habit'],
      };
      const SHOT = 'https://picsum.photos/seed/hush/600/800';
      window.__VPHONE_PREVIEW_POST__ = (name, b) => {
        const op = b && b.op;
        if (name === 'social' && op === 'hushMe') {
          return { ok: true, options: OPTS,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM, until_: 0 },
            pass: { price: 50, account: 'bank', hours: 24, likes: 25, supers: 5,
                    seeLikes: true, rewindLikes: true },
            profile: { bio: 'Mecano le jour, sur la plage le reste du temps.',
                       photo: SHOT, photo2: '', photo3: '',
                       gender: 'f', seeking: 'all', minAge: 21, maxAge: 40, active: true,
                       job: 'Mecanicienne chez Benny', looking: 'serious',
                       interests: ['cars', 'beach', 'music'],
                       prompt: 'find_me', promptAnswer: 'Sous une Sultan, a Sandy Shores.' } };
        }
        if (name === 'social' && op === 'hushNext') {
          return { ok: true,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM },
            profile: { ref: 'ABC123', name: 'Elena', age: 27, distance: 340,
                       bio: 'Je conduis trop vite et je le sais.',
                       photo: SHOT, photos: [SHOT], superOnMe: false,
                       job: 'Barmaid au Vanilla Unicorn', looking: 'casual',
                       interests: ['cars', 'nights', 'music', 'dancing'],
                       shared: ['cars', 'music'],
                       prompt: 'order_at_bar', promptAnswer: 'Un whisky, sec, et pas de paille.' } };
        }
        if (name === 'social' && op === 'hushLikedMe') {
          if (!PREMIUM) return { ok: true, locked: true, count: 7 };
          return { ok: true, locked: false, count: 4, people: [
            { ref: 'A', name: 'Elena', age: 27, photo: SHOT, super: true },
            { ref: 'B', name: 'Marcus', age: 31, photo: SHOT, super: false },
            { ref: 'C', name: 'Yuki', age: 24, photo: SHOT, super: false },
            { ref: 'D', name: 'Sofia', age: 29, photo: SHOT, super: false } ] };
        }
        return under ? under(name, b) : { error: 'x' };
      };

      await open('hush', 500);
      await hushPassSheet();
      await new Promise((r) => setTimeout(r, 800));`,
  },
  {
    // Who liked you, locked. The count is real; there is nothing behind the circles because
    // the server sent no names at all.
    name: 'hush-liked', file: '45-hush-liked.png',
    script: `${SETUP}
      const LIKE_CAP = 3, LIKES_USED = 0, SUPER_CAP = 1, PREMIUM = false;
      const under = window.__VPHONE_PREVIEW_POST__;
      const OPTS = {
        looking: ['casual', 'friends', 'serious', 'unsure'],
        interests: ['animals', 'art', 'beach', 'bikes', 'cars', 'coffee', 'cooking',
                    'dancing', 'films', 'fishing', 'food', 'games', 'guns', 'gym',
                    'hiking', 'music', 'nights', 'travel'],
        prompts: ['brag', 'deal_breaker', 'find_me', 'never_again', 'order_at_bar',
                  'perfect_night', 'sunday', 'worst_habit'],
      };
      const SHOT = 'https://picsum.photos/seed/hush/600/800';
      window.__VPHONE_PREVIEW_POST__ = (name, b) => {
        const op = b && b.op;
        if (name === 'social' && op === 'hushMe') {
          return { ok: true, options: OPTS,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM, until_: 0 },
            pass: { price: 50, account: 'bank', hours: 24, likes: 25, supers: 5,
                    seeLikes: true, rewindLikes: true },
            profile: { bio: 'Mecano le jour, sur la plage le reste du temps.',
                       photo: SHOT, photo2: '', photo3: '',
                       gender: 'f', seeking: 'all', minAge: 21, maxAge: 40, active: true,
                       job: 'Mecanicienne chez Benny', looking: 'serious',
                       interests: ['cars', 'beach', 'music'],
                       prompt: 'find_me', promptAnswer: 'Sous une Sultan, a Sandy Shores.' } };
        }
        if (name === 'social' && op === 'hushNext') {
          return { ok: true,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM },
            profile: { ref: 'ABC123', name: 'Elena', age: 27, distance: 340,
                       bio: 'Je conduis trop vite et je le sais.',
                       photo: SHOT, photos: [SHOT], superOnMe: false,
                       job: 'Barmaid au Vanilla Unicorn', looking: 'casual',
                       interests: ['cars', 'nights', 'music', 'dancing'],
                       shared: ['cars', 'music'],
                       prompt: 'order_at_bar', promptAnswer: 'Un whisky, sec, et pas de paille.' } };
        }
        if (name === 'social' && op === 'hushLikedMe') {
          if (!PREMIUM) return { ok: true, locked: true, count: 7 };
          return { ok: true, locked: false, count: 4, people: [
            { ref: 'A', name: 'Elena', age: 27, photo: SHOT, super: true },
            { ref: 'B', name: 'Marcus', age: 31, photo: SHOT, super: false },
            { ref: 'C', name: 'Yuki', age: 24, photo: SHOT, super: false },
            { ref: 'D', name: 'Sofia', age: 29, photo: SHOT, super: false } ] };
        }
        return under ? under(name, b) : { error: 'x' };
      };

      await open('hush', 500);
      SOC.tab.hush = 'likes';
      await hushLiked();
      await new Promise((r) => setTimeout(r, 700));`,
  },
  {
    // The profile editor. It used to offer a bio and one photograph while the server stored
    // fifteen fields, so the deck's own matching filters could never be filled in.
    name: 'hush-profile', file: '46-hush-profile.png',
    script: `${SETUP}
      const LIKE_CAP = 25, LIKES_USED = 2, SUPER_CAP = 5, PREMIUM = true;
      const under = window.__VPHONE_PREVIEW_POST__;
      const OPTS = {
        looking: ['casual', 'friends', 'serious', 'unsure'],
        interests: ['animals', 'art', 'beach', 'bikes', 'cars', 'coffee', 'cooking',
                    'dancing', 'films', 'fishing', 'food', 'games', 'guns', 'gym',
                    'hiking', 'music', 'nights', 'travel'],
        prompts: ['brag', 'deal_breaker', 'find_me', 'never_again', 'order_at_bar',
                  'perfect_night', 'sunday', 'worst_habit'],
      };
      const SHOT = 'https://picsum.photos/seed/hush/600/800';
      window.__VPHONE_PREVIEW_POST__ = (name, b) => {
        const op = b && b.op;
        if (name === 'social' && op === 'hushMe') {
          return { ok: true, options: OPTS,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM, until_: 0 },
            pass: { price: 50, account: 'bank', hours: 24, likes: 25, supers: 5,
                    seeLikes: true, rewindLikes: true },
            profile: { bio: 'Mecano le jour, sur la plage le reste du temps.',
                       photo: SHOT, photo2: '', photo3: '',
                       gender: 'f', seeking: 'all', minAge: 21, maxAge: 40, active: true,
                       job: 'Mecanicienne chez Benny', looking: 'serious',
                       interests: ['cars', 'beach', 'music'],
                       prompt: 'find_me', promptAnswer: 'Sous une Sultan, a Sandy Shores.' } };
        }
        if (name === 'social' && op === 'hushNext') {
          return { ok: true,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM },
            profile: { ref: 'ABC123', name: 'Elena', age: 27, distance: 340,
                       bio: 'Je conduis trop vite et je le sais.',
                       photo: SHOT, photos: [SHOT], superOnMe: false,
                       job: 'Barmaid au Vanilla Unicorn', looking: 'casual',
                       interests: ['cars', 'nights', 'music', 'dancing'],
                       shared: ['cars', 'music'],
                       prompt: 'order_at_bar', promptAnswer: 'Un whisky, sec, et pas de paille.' } };
        }
        if (name === 'social' && op === 'hushLikedMe') {
          if (!PREMIUM) return { ok: true, locked: true, count: 7 };
          return { ok: true, locked: false, count: 4, people: [
            { ref: 'A', name: 'Elena', age: 27, photo: SHOT, super: true },
            { ref: 'B', name: 'Marcus', age: 31, photo: SHOT, super: false },
            { ref: 'C', name: 'Yuki', age: 24, photo: SHOT, super: false },
            { ref: 'D', name: 'Sofia', age: 29, photo: SHOT, super: false } ] };
        }
        return under ? under(name, b) : { error: 'x' };
      };

      await open('hush', 500);
      SOC.tab.hush = 'me';
      await hushProfile();
      await new Promise((r) => setTimeout(r, 800));
      document.getElementById('appbody').scrollTop = 640;
      await new Promise((r) => setTimeout(r, 400));`,
  },
  {
    // **The pass has to actually move both ceilings, and the editor has to actually send
    // every field.** Both are things a screenshot cannot show.
    name: 'hush-limits', file: 'zz-hush-lim.png', scratch: true, assert: true,
    script: `${SETUP}
      const LIKE_CAP = 3, LIKES_USED = 3, SUPER_CAP = 1, PREMIUM = false;
      let sent = null;
      const under = window.__VPHONE_PREVIEW_POST__;
      const OPTS = {
        looking: ['casual', 'friends', 'serious', 'unsure'],
        interests: ['animals', 'art', 'beach', 'bikes', 'cars', 'coffee', 'cooking',
                    'dancing', 'films', 'fishing', 'food', 'games', 'guns', 'gym',
                    'hiking', 'music', 'nights', 'travel'],
        prompts: ['brag', 'deal_breaker', 'find_me', 'never_again', 'order_at_bar',
                  'perfect_night', 'sunday', 'worst_habit'],
      };
      const SHOT = 'https://picsum.photos/seed/hush/600/800';
      window.__VPHONE_PREVIEW_POST__ = (name, b) => {
        const op = b && b.op;
        if (name === 'social' && op === 'hushMe') {
          return { ok: true, options: OPTS,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM, until_: 0 },
            pass: { price: 50, account: 'bank', hours: 24, likes: 25, supers: 5,
                    seeLikes: true, rewindLikes: true },
            profile: { bio: 'Mecano le jour, sur la plage le reste du temps.',
                       photo: SHOT, photo2: '', photo3: '',
                       gender: 'f', seeking: 'all', minAge: 21, maxAge: 40, active: true,
                       job: 'Mecanicienne chez Benny', looking: 'serious',
                       interests: ['cars', 'beach', 'music'],
                       prompt: 'find_me', promptAnswer: 'Sous une Sultan, a Sandy Shores.' } };
        }
        if (name === 'social' && op === 'hushNext') {
          return { ok: true,
            limits: { likes: LIKE_CAP, likesUsed: LIKES_USED, supers: SUPER_CAP,
                      supersUsed: 0, premium: PREMIUM },
            profile: { ref: 'ABC123', name: 'Elena', age: 27, distance: 340,
                       bio: 'Je conduis trop vite et je le sais.',
                       photo: SHOT, photos: [SHOT], superOnMe: false,
                       job: 'Barmaid au Vanilla Unicorn', looking: 'casual',
                       interests: ['cars', 'nights', 'music', 'dancing'],
                       shared: ['cars', 'music'],
                       prompt: 'order_at_bar', promptAnswer: 'Un whisky, sec, et pas de paille.' } };
        }
        if (name === 'social' && op === 'hushLikedMe') {
          if (!PREMIUM) return { ok: true, locked: true, count: 7 };
          return { ok: true, locked: false, count: 4, people: [
            { ref: 'A', name: 'Elena', age: 27, photo: SHOT, super: true },
            { ref: 'B', name: 'Marcus', age: 31, photo: SHOT, super: false },
            { ref: 'C', name: 'Yuki', age: 24, photo: SHOT, super: false },
            { ref: 'D', name: 'Sofia', age: 29, photo: SHOT, super: false } ] };
        }
        return under ? under(name, b) : { error: 'x' };
      };

      const outer = window.__VPHONE_PREVIEW_POST__;
      window.__VPHONE_PREVIEW_POST__ = (name, b) => {
        if (name === 'social' && b && b.op === 'hushSetup') { sent = b; return { ok: true }; }
        return outer(name, b);
      };
      await open('hush', 500);

      // The counter must say nothing is left, and must offer the pass.
      SOC.tab.hush = 'swipe';
      await hushSwipe();
      await new Promise((r) => setTimeout(r, 600));
      const bar = document.querySelector('.hleft');
      if (!bar) throw new Error('the deck drew no likes-left bar');
      if (!bar.classList.contains('out')) throw new Error('0 likes left did not read as out');
      if (!document.getElementById('hbuy')) throw new Error('no way to buy the pass when out');

      // The editor must send EVERY field, not the two it used to.
      SOC.tab.hush = 'me';
      await hushProfile();
      await new Promise((r) => setTimeout(r, 600));
      const save = document.getElementById('hsave');
      if (!save) throw new Error('the profile editor drew no save button');
      save.click();
      await new Promise((r) => setTimeout(r, 400));
      if (!sent) throw new Error('saving sent nothing');
      const want = ['bio', 'photo', 'photo2', 'photo3', 'job', 'gender', 'seeking',
                    'looking', 'interests', 'prompt', 'promptAnswer', 'minAge', 'maxAge',
                    'active'];
      const missing = want.filter((k) => sent[k] === undefined);
      if (missing.length) throw new Error('the editor never sends: ' + missing.join(', '));
      if (!Array.isArray(sent.interests) || !sent.interests.length) {
        throw new Error('interests did not survive the round trip');
      }
      if (sent.seeking !== 'all' || sent.gender !== 'f') {
        throw new Error('the chips did not carry their values: ' +
          JSON.stringify({ g: sent.gender, s: sent.seeking }));
      }`,
  },
  // The full-screen photo viewer is NOT here, and that is a decision rather than an oversight.
  //
  // It turns the handset on its side and lets it GROW TO FILL THE WINDOW, so the capture clip
  // ends up being the whole window - and `Page.captureScreenshot` answers a clip that size with
  // silence rather than with an error. Widening the window does not help: the phone widens with
  // it, because the growing is a function of the space available.
  //
  // Not the network, which was the other suspect and is ruled out - the shots above load their
  // pictures over it perfectly well.
  //
  // Take that one by hand from a browser with the preview open; it photographs fine there. The
  // timeout above exists because of this shot: one screen that would not capture used to hang
  // the whole batch of twelve with no output at all.
  {
    // The strip, full. For the README, and for looking at: twelve tiles that have to read as
    // one family is a claim only a picture can settle.
    name: 'widgets', file: '40-widgets.png',
    script: `${SETUP}
      ['messages', 'music', 'bank', 'health', 'garage', 'reminders', 'export', 'alerts']
        .forEach((id) => need(id));
      state.prefs.widgets = ['weather', 'garage', 'music', 'bank'];
      state._power = { battery: 68, charging: true, signal: 4 };
      musicNow = { title: 'Nightcall', artist: 'Kavinsky', kind: 'track', id: 'fx0' };
      musicOutput = 'car';
      state.conversations = (state.conversations || []).map((c, i) =>
        Object.assign({}, c, { unread: i === 0 ? 3 : 0 }));
      renderHome();
      await new Promise((r) => setTimeout(r, 1200));`,
  },
  {
    // Arranging the strip: the jiggle, a minus on every tile, and the button that adds one.
    // Nothing else photographs those - they only exist while `editing` is true.
    name: 'widgets-edit', file: '41-widgets-edit.png',
    script: `${SETUP}
      ['messages', 'music', 'garage'].forEach((id) => need(id));
      state.prefs.widgets = ['weather', 'messages', 'garage'];
      renderHome();
      await new Promise((r) => setTimeout(r, 1000));
      enterArrange();
      await new Promise((r) => setTimeout(r, 500));`,
  },
  {
    // The gallery. Worth a picture because it is the only screen that names every widget, and
    // because a row here is built from `ph.w_<id>` and `ph.w_<id>_d` - two keys per widget that
    // nothing else reads, so a missing one shows up here and nowhere else.
    name: 'widgets-pick', file: '42-widgets-pick.png',
    script: `${SETUP}
      ['messages', 'music', 'garage', 'bank', 'health', 'reminders', 'export', 'alerts']
        .forEach((id) => need(id));
      state.prefs.widgets = ['weather', 'messages'];
      renderHome();
      await new Promise((r) => setTimeout(r, 900));
      enterArrange();
      await new Promise((r) => setTimeout(r, 300));
      widgetPicker();
      await new Promise((r) => setTimeout(r, 700));
      const rows = document.querySelectorAll('#sheet .row');
      if (!rows.length) throw new Error('the picker drew no rows');
      if (!document.querySelector('#sheet .rs')) throw new Error('no row carries a description');`,
  },
  {
    // **The minus and the plus, actually pressed.**
    //
    // Both shipped dead and neither looked it: the strip is a sibling of #pages, so the
    // pointerup that ended a press on it read as "tapped the wallpaper", left arrange mode and
    // repainted the strip before the click could fire. A screenshot of that state is a
    // screenshot of a perfectly correct-looking badge.
    name: 'widget-controls', file: 'zz-wctl.png', scratch: true, assert: true,
    script: `${SETUP}
      ['messages', 'garage'].forEach((id) => need(id));
      state.prefs.gridCols = 4; state.prefs.gridRows = 4;
      state.prefs.widgets = ['weather', 'messages', 'garage'];
      renderHome();
      await new Promise((r) => setTimeout(r, 900));

      // Holding the strip has to enter arrange mode. It is wired to #pages for the app grid,
      // and the strip is not inside #pages.
      const host = document.getElementById('widgets');
      const first = host.querySelector('.widget[data-w]');
      if (!first) throw new Error('no widget was drawn');
      const box = first.getBoundingClientRect();
      const at = { clientX: box.left + box.width / 2, clientY: box.top + box.height / 2,
                   target: first };
      host.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true,
        clientX: at.clientX, clientY: at.clientY }));
      await new Promise((r) => setTimeout(r, 600));
      window.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }));
      if (!editing) throw new Error('holding the widget strip did not enter arrange mode');

      // The minus removes one, and STAYS in arrange mode.
      const before = widgetIds().length;
      const badge = document.querySelector('#widgets .wrm');
      if (!badge) throw new Error('no remove badge on a widget in arrange mode');
      const gone = badge.dataset.wrm;
      badge.click();
      await new Promise((r) => setTimeout(r, 300));
      const after = widgetIds();
      if (after.length !== before - 1 || after.indexOf(gone) !== -1) {
        throw new Error('the minus did nothing: ' + JSON.stringify(after));
      }
      if (!editing) throw new Error('removing a widget dropped out of arrange mode');

      // The plus opens the gallery.
      const plus = document.getElementById('waddbtn');
      if (!plus) throw new Error('no add button while there is room and something to add');
      plus.click();
      await new Promise((r) => setTimeout(r, 400));
      if (!document.getElementById('sheet').classList.contains('on')) {
        throw new Error('the plus did not open the picker');
      }
      // And a row in it actually adds the widget it names.
      const row = document.querySelector('#sheet .row[data-add]');
      if (!row) throw new Error('the picker offered nothing to add');
      const adding = row.dataset.add;
      row.click();
      await new Promise((r) => setTimeout(r, 500));
      if (widgetIds().indexOf(adding) === -1) {
        throw new Error('picking ' + adding + ' did not add it');
      }
      exitArrange();`,
  },
  {
    // **The layout arithmetic, measured rather than eyeballed.**
    //
    // Three things can be quietly wrong here and none of them looks wrong in a screenshot of a
    // strip that happens to fit: a `--wspan` that does not reach the grid, a strip that grows a
    // third row and pushes the app grid off the bottom, and a small tile that turns out to be
    // the same width as a medium one - which would mean the sizes are decoration.
    name: 'widget-span', file: 'zz-wspan.png', scratch: true, assert: true,
    script: `${SETUP}
      ['bank', 'messages', 'alerts'].forEach((id) => need(id));
      // The shots share one page and a previous one may have chosen a six-row grid. The claim
      // below is about the DEFAULT grid, so it sets it rather than inheriting whatever is
      // there - which is how this assertion first failed on a batch and passed on its own.
      state.prefs.gridCols = 4; state.prefs.gridRows = 4;
      state.prefs.widgets = ['alerts', 'weather', 'messages'];
      renderHome();
      await new Promise((r) => setTimeout(r, 1000));

      const host = document.getElementById('widgets');
      const w = (id) => {
        const el = host.querySelector('.widget[data-w="' + id + '"]');
        if (!el) throw new Error('no ' + id + ' tile');
        return el.getBoundingClientRect();
      };
      // 4 + 2 + 2 = 8 units, the cap, so all three are drawn.
      const tiles = [...host.querySelectorAll('.widget[data-w]')];
      if (tiles.length !== 3) throw new Error('drew ' + tiles.length + ' widgets, wanted 3');

      const band = w('alerts'), tile = w('weather');
      // A band spans four columns and a tile spans two, so the band has to be close to twice
      // as wide - not exactly twice, because it also absorbs the gap between the two columns
      // it covers. Under 1.7x means --wspan never reached the grid and every tile is the same.
      const ratio = band.width / tile.width;
      if (ratio < 1.7 || ratio > 2.4) {
        throw new Error('band/tile width ratio ' + ratio.toFixed(2) +
          ' (tile ' + Math.round(tile.width) + ', band ' + Math.round(band.width) + ')');
      }
      // The band is alone on its row and the two tiles share the one under it.
      if (tile.top <= band.top + 10) throw new Error('the second row did not wrap');
      if (Math.abs(w('messages').top - tile.top) > 2) {
        throw new Error('the two tiles did not share a row');
      }

      // And the app grid still has room. fitGrid shrinks the icons to fit whatever is left, so
      // the failure here is not a clipped grid - it is icons that have collapsed.
      //
      // **Measured against the SAME page with no widgets**, not against a fixed number of
      // pixels. The shots share one browser and whatever a previous one left on screen changes
      // the height the grid gets, so an absolute threshold passes alone and fails in a batch -
      // which it did, and the flap was in the test rather than in the phone. A ratio asks the
      // question the claim is actually about: how much does a second widget row cost?
      const iconWidth = () => {
        const ic = document.querySelector('.page .tile:not(.gap) .ic');
        if (!ic) throw new Error('no app icon on the page');
        return ic.getBoundingClientRect().width;
      };
      const withRows = iconWidth();
      state.prefs.widgets = [];
      renderHome();
      await new Promise((r) => setTimeout(r, 800));
      const bare = iconWidth();
      state.prefs.widgets = ['alerts', 'weather', 'messages'];
      renderHome();
      await new Promise((r) => setTimeout(r, 800));
      // Two rows of widgets are allowed to cost a third of the icon size and no more.
      if (withRows < bare * 0.66) {
        throw new Error('two widget rows took the icons from ' + Math.round(bare) + ' to ' +
          Math.round(withRows));
      }

      // The cap. Ten units cannot fit in eight, so the last one is dropped rather than drawn on
      // a third row - which is what stops a strip from eating the whole home screen.
      state.prefs.widgets = ['alerts', 'weather', 'messages', 'bank'];
      const kept = widgetIds();
      if (kept.length !== 3 || kept.indexOf('bank') !== -1) {
        throw new Error('over-full strip kept ' + JSON.stringify(kept));
      }`,
  },
];

// ══════════════════════════════════════════════════════════════
// The machinery
// ══════════════════════════════════════════════════════════════

function findChrome() {
  return [
    process.env.CHROME_PATH,
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    path.join(process.env.LOCALAPPDATA || '', 'Google/Chrome/Application/chrome.exe'),
    '/usr/bin/google-chrome',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ].filter(Boolean).find((p) => { try { return fs.statSync(p).isFile(); } catch { return false; } });
}

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
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression: `(async () => { ${expression} })()`,
      awaitPromise: true, returnByValue: true,
    });
    if (r.exceptionDetails) {
      throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    }
    return r.result.value;
  }
}

// The page, prepared once: unlocked, every app installed, and the side panel out of frame.
const BOOTSTRAP = `
  try { if (typeof unlock === 'function') unlock(); } catch (e) {}
  await new Promise((r) => setTimeout(r, 500));

  const template = (state.apps || []).find((a) => a.id === 'notes') || (state.apps || [])[0];
  const have = new Set((state.apps || []).map((a) => a.id));
  for (const id of Object.keys(RENDER)) {
    if (!have.has(id)) state.apps.push(Object.assign({}, template, { id, label: 'app.' + id, dock: false }));
  }
  renderHome();

  const css = document.createElement('style');
  css.textContent = \`
    /* The preview's own test panel is not part of the phone. */
    #pvpanel { display: none !important; }
    /* Only the entrance animation is stopped. THE TRANSFORM IS LEFT ALONE, and that is not a
       small thing: applyDevice writes it, and a shot of the full-screen photo viewer turns the
       handset on its side through exactly that property. Overriding it left the phone standing
       upright with its contents lying sideways - the feature photographed as a bug.
       The phone is captured wherever it sits; nothing needs it moved. */
    .device { animation: none !important; }
    /* Nothing that blinks: a caret lands in some shots and not others. */
    *, *::before, *::after { caret-color: transparent !important; }
  \`;
  document.head.appendChild(css);
  await new Promise((r) => setTimeout(r, 400));
  return true;
`;

async function main() {
  if (argv.includes('--list')) {
    SHOTS.forEach((s) => console.log('  ' + s.name.padEnd(14) + s.file));
    return;
  }
  if (!fs.existsSync(PREVIEW)) {
    console.error('no preview to shoot. Run:  python tools/make-preview.py');
    process.exit(1);
  }
  const chrome = findChrome();
  if (!chrome) { console.error('no Chrome found. Set CHROME_PATH.'); process.exit(1); }
  if (spawnSync('ffmpeg', ['-version'], { shell: true }).status !== 0) {
    console.error('no ffmpeg on PATH.'); process.exit(1);
  }

  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'vphone-shot-'));
  const raw = fs.mkdtempSync(path.join(os.tmpdir(), 'vphone-raw-'));
  const child = spawn(chrome, [
    '--headless=new', '--remote-debugging-port=' + PORT, '--user-data-dir=' + profile,
    '--no-first-run', '--no-default-browser-check', '--hide-scrollbars',
    '--force-device-scale-factor=1', '--allow-file-access-from-files',
    '--window-size=1500,1100',
    'file:///' + PREVIEW.replace(/\\/g, '/'),
  ], { stdio: 'ignore' });

  let cdp;
  try {
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
      width: 1500, height: 1100, deviceScaleFactor: 2, mobile: false,
    });
    await sleep(1200);

    fs.mkdirSync(OUT, { recursive: true });
    const wanted = ONLY.length ? SHOTS.filter((s) => ONLY.includes(s.name)) : SHOTS;
    console.log(`taking ${wanted.length} shot(s)`);
    // A shot marked `assert: true` is a TEST, not a picture. Its script throws when the thing
    // it checks is broken, and that has to end the run with a non-zero code - otherwise the
    // check reads as a skipped line in a wall of output and passes silently for ever.
    const failures = [];

    for (const shot of wanted) {
      // Back to a known state between shots: an app left open would otherwise be the
      // background of the next one.
      await cdp.eval(`try { closeSheet(true); } catch (e) {}
        try { closePhoto(); } catch (e) {}
        try { closeApp(true); } catch (e) {}
        await new Promise((r) => setTimeout(r, 350));`);
      await cdp.eval(BOOTSTRAP);

      try {
        await within(25000, 'setup', cdp.eval(shot.script));
      } catch (e) {
        if (shot.assert) {
          // The whole message, not sixty characters of it: an assertion says WHY, and the why
          // is usually the measurement that failed.
          failures.push(`${shot.name}: ${e.message}`);
          console.log(`  ${shot.name.padEnd(14)} FAILED  ${String(e.message).split('\n')[0]}`);
        } else {
          console.log(`  ${shot.name.padEnd(14)} SKIPPED (${String(e.message).slice(0, 60)})`);
        }
        continue;
      }
      // An assertion that passed has nothing to photograph.
      if (shot.assert) {
        console.log(`  ${shot.name.padEnd(14)} ok`);
        continue;
      }
      await sleep(350);

      // The handset's own box, plus room for its shadow. Read AFTER the script, because a
      // shot that turned the phone on its side has a different box.
      // **Clamped to the window, not just floored at zero.**
      //
      // A clip that runs off the right edge does not come back as an error - the capture
      // simply never answers, and the run hangs with no output. The landscape handset grows to
      // about 1075 pixels wide, and twenty-six pixels of margin on each side were enough to
      // push it past a 1100 pixel window. The window is wider now AND the clip is bounded, so
      // neither alone has to be right.
      const box = await cdp.eval(`
        const d = document.getElementById('device');
        const r = d.getBoundingClientRect();
        const pad = 26;
        const vw = window.innerWidth, vh = window.innerHeight;
        const x = Math.max(0, Math.round(r.left - pad));
        const y = Math.max(0, Math.round(r.top - pad));
        return { x, y,
                 width: Math.max(8, Math.min(vw - x, Math.round(r.width + pad * 2))),
                 height: Math.max(8, Math.min(vh - y, Math.round(r.height + pad * 2))) };
      `);

      let png;
      try {
        png = await within(20000, 'capture', cdp.send('Page.captureScreenshot', {
          format: 'png', captureBeyondViewport: false,
          clip: { x: box.x, y: box.y, width: box.width, height: box.height, scale: 2 },
        }));
      } catch (e) {
        console.log(`  ${shot.name.padEnd(14)} SKIPPED (${e.message}, clip `
          + `${box.width}x${box.height} at ${box.x},${box.y})`);
        continue;
      }
      const rawFile = path.join(raw, shot.file);
      fs.writeFileSync(rawFile, Buffer.from(png.data, 'base64'));

      // Scaled to the size the README already uses. A landscape shot keeps its own shape:
      // squeezing a phone lying on its side into a portrait frame would letterbox it into a
      // strip, which is the opposite of what that picture is for.
      const out = path.join(OUT, shot.file);
      const vf = shot.landscape
        ? `scale=${TALL}:-2:flags=lanczos`
        : `scale=${WIDE}:${TALL}:force_original_aspect_ratio=decrease:flags=lanczos,`
          + `pad=${WIDE}:${TALL}:(ow-iw)/2:(oh-ih)/2:color=0x0B0D12`;
      const enc = spawnSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', rawFile,
                                       '-vf', vf, out], { shell: true });
      if (enc.status !== 0) { console.log(`  ${shot.name.padEnd(14)} ENCODE FAILED`); continue; }
      const kb = Math.round(fs.statSync(out).size / 1024);
      console.log(`  ${shot.name.padEnd(14)} ${shot.file.padEnd(28)} ${String(kb).padStart(4)} KB`);
    }

    if (failures.length) {
      console.error('');
      console.error(`${failures.length} assertion(s) failed:`);
      failures.forEach((f) => console.error('  ' + f));
      process.exitCode = 1;
    }
  } finally {
    try { cdp && cdp.ws.close(); } catch { /* already gone */ }
    child.kill();
    await sleep(500);
    if (!KEEP) fs.rmSync(raw, { recursive: true, force: true });
    else console.log('full-size captures kept in ' + raw);
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* Chrome still has it */ }
  }
}

main().catch((e) => { console.error(e.message); process.exit(1); });
