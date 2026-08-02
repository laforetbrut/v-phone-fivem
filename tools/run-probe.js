/**
 * Run tools/probe.js without a browser window.
 *
 *   python tools/make-preview.py --lang fr
 *   node tools/run-probe.js
 *
 * `probe.js` was written to be pasted into a console, which means it was run when somebody
 * remembered to run it. This boots the same headless Chrome tools/probe-input.js uses, loads the
 * preview, evaluates the probe and prints its answer - so "can a cursor reach every control in
 * every app" is a command rather than a ritual.
 *
 * Exit code 1 if any app reports a problem, so it can sit in a check list with the rest.
 */
const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.dirname(__dirname);
const PREVIEW = path.join(ROOT, 'preview', 'index.html');
const PORT = 9397;
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
  async evalRaw(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression, awaitPromise: true, returnByValue: true,
    });
    if (r.result && r.result.exceptionDetails) {
      throw new Error(r.result.exceptionDetails.exception
        ? r.result.exceptionDetails.exception.description
        : r.result.exceptionDetails.text);
    }
    return r.result && r.result.result ? r.result.result.value : undefined;
  }
}

(async () => {
  if (!fs.existsSync(PREVIEW)) {
    console.error('no preview - run: python tools/make-preview.py --lang fr');
    process.exit(1);
  }
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'vphone-probe-'));
  const child = spawn(chromePath(), [
    '--headless=new', '--remote-debugging-port=' + PORT, '--user-data-dir=' + profile,
    '--no-first-run', '--no-default-browser-check', '--hide-scrollbars',
    '--force-device-scale-factor=1', '--allow-file-access-from-files',
    '--window-size=1500,1100',
    'file:///' + PREVIEW.split(path.sep).join('/'),
  ], { stdio: 'ignore' });

  let target = null;
  for (let i = 0; i < 60 && !target; i++) {
    await sleep(400);
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      target = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
    } catch { /* the browser is still starting */ }
  }
  if (!target) { child.kill(); console.error('chrome never answered'); process.exit(1); }

  const cdp = new CDP(target.webSocketDebuggerUrl);
  await cdp.ready;
  await cdp.send('Runtime.enable');
  await sleep(2500);

  await cdp.evalRaw(fs.readFileSync(path.join(ROOT, 'tools', 'probe.js'), 'utf8'));
  const out = await cdp.evalRaw('vphoneProbe()');
  child.kill();

  const problems = (out && out.problems) || [];
  console.log(`${out.clean}/${out.apps} app(s) clean`);
  if (problems.length) console.log(JSON.stringify(problems, null, 1));
  process.exit(problems.length ? 1 : 0);
})().catch((e) => { console.error('probe failed:', e.message); process.exit(2); });
