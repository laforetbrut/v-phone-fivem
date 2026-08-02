/**
 * Can a player actually reach this?
 *
 *   python tools/make-preview.py
 *   # open preview/index.html, then paste this file into the browser console:
 *   await vphoneProbe()
 *
 * `tools/check.py` reads the source. This runs the page and asks the question no static check
 * can: with the phone drawn, for every control on every screen, could a cursor click it?
 *
 * Four ways the answer is no, and all four have shipped here at least once:
 *
 *   zero size            drawn, but with no box - usually a class with no rule behind it
 *   outside the phone    laid out past the bezel
 *   covered              something else is on top at the exact point the cursor lands
 *   sideways only        inside a horizontally scrolling strip, past its edge
 *
 * The last one is the reason this file exists. A NUI page has a MOUSE CURSOR and no touch: a
 * strip wider than the screen has no gesture behind it, so anything past the edge is simply
 * gone. The emoji picker shipped with its last categories unreachable, and "the strip scrolls"
 * had been measured and called a success - the wrong question, answered correctly.
 *
 * It installs all 33 apps first, because the preview boots like a fresh install and twelve are
 * gated behind a module. Twenty-one of thirty-three is not a sweep.
 *
 * Reports only problems. An empty `problems` array is the pass.
 */
async function vphoneProbe() {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const errors = [];
  const onError = (e) => errors.push('ERROR ' + (e.message || ''));
  const onReject = (e) => errors.push('REJECT ' + ((e.reason && e.reason.message) || e.reason));
  window.addEventListener('error', onError);
  window.addEventListener('unhandledrejection', onReject);
  const realError = console.error;
  console.error = function (...a) { errors.push('console.error ' + a.map(String).join(' ')); return realError.apply(this, a); };

  try { if (typeof unlock === 'function') unlock(); } catch { /* already unlocked */ }
  await wait(350);

  // Every renderer the phone has, installed. The gated twelve are cloned from a real entry so
  // `enterApp` is handed the shape it expects.
  const template = (state.apps || []).find((a) => a.id === 'notes') || (state.apps || [])[0];
  const have = new Set((state.apps || []).map((a) => a.id));
  for (const id of Object.keys(RENDER)) {
    if (!have.has(id)) state.apps.push(Object.assign({}, template, { id, label: 'app.' + id, dock: false }));
  }
  renderHome();
  await wait(200);

  const phone = document.getElementById('screen').getBoundingClientRect();
  const name = (n) => n ? (n.tagName.toLowerCase() + (n.id ? '#' + n.id : '') +
    (n.className ? '.' + String(n.className).split(' ')[0] : '') +
    '["' + (n.textContent || '').trim().slice(0, 16) + '"]') : '?';

  const unreachable = (root) => {
    const bad = [];
    for (const n of root.querySelectorAll('button, input, select, textarea, .row, [data-key], [role="switch"]')) {
      const cs = getComputedStyle(n);
      if (cs.display === 'none' || cs.visibility === 'hidden' || n.closest('.hidden')) continue;
      const r = n.getBoundingClientRect();
      if (!r.width || !r.height) { bad.push({ why: 'zero size', what: name(n) }); continue; }

      // The scroller test comes FIRST. A chip sitting past the right edge of the phone because
      // its strip is scrolled is not "outside the phone", it is scrolled away - and putting the
      // bezel test above this reported four of the store's categories as lost when they are one
      // drag from view. Order between two rules that can both match is not a detail.

      // Anything a scroll would bring into view is reachable, and scrolling is a gesture the
      // phone has - vertically always, and sideways since the strip handler was added. So a
      // control is only judged where it CURRENTLY sits inside every scrolling ancestor: testing
      // one that is merely scrolled away is what produced a false "covered by the home bar" and
      // a false "covered by the tab bar" over the lottery's number grid.
      // Judged at its CENTRE, not at its edges. `elementFromPoint` is asked about one point,
      // and that point is the centre - so a row half over the fold, with its top inside the
      // scroller and its middle below it, was tested at a pixel that belongs to whatever is
      // painted under the scroller. That is not "unreachable", it is "scrolled away by half a
      // row", and it reported three controls as lost that one flick of the wheel reveals:
      // the last Settings row, the bottom line of the lottery grid, and Cipher's second PIN
      // box. Fully-outside was the old test and it could not see the straddle.
      const mx = r.left + r.width / 2, my = r.top + r.height / 2;
      let p = n.parentElement, away = false;
      while (p && p !== root.parentElement) {
        const ps = getComputedStyle(p);
        const scrolls = /(auto|scroll)/.test(ps.overflowX + ' ' + ps.overflowY);
        if (scrolls && (p.scrollWidth > p.clientWidth + 1 || p.scrollHeight > p.clientHeight + 1)) {
          const pr = p.getBoundingClientRect();
          if (mx < pr.left + 1 || mx > pr.right - 1 ||
              my < pr.top + 1 || my > pr.bottom - 1) { away = true; break; }
        }
        p = p.parentElement;
      }
      if (away) continue;
      if (r.right < phone.left || r.left > phone.right) { bad.push({ why: 'outside the phone', what: name(n) }); continue; }

      const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      if (cy < phone.top || cy > phone.bottom || cx < phone.left || cx > phone.right) continue;
      const hit = document.elementFromPoint(cx, cy);
      if (hit && hit !== n && !n.contains(hit) && !hit.contains(n)) {
        bad.push({ why: 'covered by ' + name(hit), what: name(n) });
      }
    }
    return bad;
  };

  // The list is captured, and put back before each app. Several renderers call `refresh()`,
  // which replaces `state.apps` with the server's own - so the twelve installed above vanished
  // partway through and the sweep quietly finished on twenty-one of thirty-three.
  const all = (state.apps || []).slice();
  const problems = [];
  for (const app of all) {
    const before = errors.length;
    const row = { app: app.id };
    if (!(state.apps || []).some((a) => a.id === app.id)) state.apps.push(app);
    try {
      await enterApp(app, null);
      await wait(280);
    } catch (e) { row.crashed = e.message; }

    const body = document.getElementById('appbody');
    const text = (body ? body.textContent : '').trim();
    if (body && body.innerHTML.trim().length < 40) row.empty = true;
    const key = text.match(/\b(?:ph|app)\.[a-z0-9_]+/); if (key) row.rawLocaleKey = key[0];
    const junk = text.match(/\bundefined\b|\bNaN\b|\[object Object\]/); if (junk) row.printed = junk[0];
    if (body && body.scrollWidth > body.clientWidth + 1) row.scrollsSideways = body.scrollWidth - body.clientWidth;
    const out = body ? unreachable(body) : [];
    if (out.length) row.unreachable = out;
    const threw = errors.slice(before); if (threw.length) row.threw = threw;
    if (Object.keys(row).length > 1) problems.push(row);

    try { goHome(); } catch { /* already home */ }
    await wait(70);
  }

  window.removeEventListener('error', onError);
  window.removeEventListener('unhandledrejection', onReject);
  console.error = realError;
  return { apps: all.length, clean: all.length - problems.length, problems };
}
