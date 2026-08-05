// v-phone | server/s3.js
//
// **Uploading to S3-compatible object storage: signing, PUT, DELETE.**
//
// This is the one part of the phone that is not Lua, and the reasons are specific rather than
// preference.
//
//   * **A binary body.** FiveM's `PerformHttpRequest` hands its body to curl through
//     `CURLOPT_POSTFIELDS` without setting `CURLOPT_POSTFIELDSIZE`, so the request stops at the
//     first NUL byte. Every encoded image contains NUL bytes. Base64-encoding the body instead
//     would store a text file that no browser will draw.
//   * **TLS.** That same path disables peer and host verification. This request carries the
//     bucket's secret key; sending it down an unauthenticated tunnel is not acceptable.
//   * **Crypto.** CfxLua has no SHA-256 and no HMAC. Node has both, audited, in `node:crypto`.
//
// No npm dependencies: `node:crypto` and `fetch`, both in the runtime. `screencapture` is
// already a JS server script on any server that uses the camera, so this is a runtime the
// operator is running regardless.
//
// **The credentials never leave this file.** Lua passes them in from convars per call and they
// are used to compute a signature; nothing is emitted, logged, or returned that contains them.

const crypto = require('node:crypto');

// ══════════════════════════════════════════════════════════════
// Nothing here waits for ever
// ══════════════════════════════════════════════════════════════
// **Every `fetch` below used to have no deadline of any kind.** A host that accepts the
// connection and then stops answering - a throttled bucket, a CDN mid-incident, a network path
// that black-holes - holds the promise open indefinitely, and the only thing that ever gave up
// was the Lua poll on the other side of the export. So Lua reported a timeout, the player was
// told the photograph failed, and this process kept the request alive with nobody left to hand
// it to.
//
// **Nine seconds, and it is arithmetic rather than taste.** The rule on this path is that the
// layer closest to the work reports first, and this is the innermost layer - so its worst case
// must fit inside the poll immediately above it, not the other way round. It was twenty, which
// with one retry and a 500 ms backoff put the worst case at 40.5 s:
//
//     s3.js worst case   40.5 s      <- the innermost layer, and the LOOSEST
//     Lua upload poll    20   s      (UPLOAD_CEILING in server/media.lua)
//     handler guard      25   s
//     upload lease       35   s
//     client timer       28   s
//     V.Request          30   s
//
// Twenty seconds past the poll and five seconds past the lease means the callback below could
// be invoked with nothing on the Lua side waiting for it, on a slot already handed to a later
// photograph. Invoking a function reference across a runtime boundary after the runtime has
// stopped caring is the shape of an empty-managed-stack SIGSEGV, and it is a window that should
// simply not exist. At nine the worst case is 9 + 0.5 + 9 = 18.5 s, inside every poll above.
const FETCH_TIMEOUT = 9000;
const RETRY_PAUSE = 500;

/// **The most bytes this file will send in one request.**
///
/// Belt to server/media.lua's brace: that file refuses an oversized capture before it crosses
/// into this runtime, and this refuses one that got here anyway. A photograph on this path is
/// one to three hundred kilobytes; twelve megabytes is a broken configuration, not a picture,
/// and it should produce a line an operator can read rather than an allocation nobody bounded.
const MAX_BODY = 12 * 1024 * 1024;

/// `AbortSignal.timeout` exists from Node 17.3 and FiveM's runtime is newer than that, but this
/// file is the one part of the resource that runs outside CfxLua and a feature check costs two
/// lines. The fallback is the same thing written by hand.
function deadline(ms) {
  if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
    return { signal: AbortSignal.timeout(ms), done: () => {} };
  }
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  return { signal: ctl.signal, done: () => clearTimeout(t) };
}

const pause = (ms) => new Promise((r) => setTimeout(r, ms));

/// **Nothing is left holding a socket.**
///
/// An undici response whose body is never read or cancelled withholds its connection from the
/// pool: the retry path below used to `continue` past a 5xx without touching `res.body`, and the
/// success path returned without touching it. One leaked file descriptor per photograph is not
/// the crash, but it is the next one.
async function drain(res) {
  try {
    if (res && res.body && typeof res.body.cancel === 'function') await res.body.cancel();
  } catch (e) { /* already consumed, or never had a body */ }
}

/// **Every answer to Lua goes through here, and it is not decoration.**
///
/// `cb` is a function reference belonging to the Lua runtime. Invoking it is a cross-runtime
/// call, and it can throw for reasons that have nothing to do with this file: the resource was
/// restarted between the request and its answer, the reference was released, the Lua side gave
/// up and the closure it pointed at is gone.
///
/// Unwrapped, that throw escapes a `.then` with no `.catch` and becomes an unhandled promise
/// rejection, which in this runtime ends the process. So the one thing a late or impossible
/// answer may never do is take the server with it: it is swallowed here, with a line saying so,
/// because by definition there is nobody left to tell.
const reply = (cb, label) => (payload) => {
  try {
    if (typeof cb !== 'function') return;
    cb(JSON.stringify(payload));
  } catch (err) {
    console.error(`[v-phone] s3: ${label} could not be answered `
      + `(${String((err && err.message) || err)}). The caller is no longer waiting.`);
  }
};

/// The error shape for a chain that threw rather than returning a result.
const thrown = (err) => ({ ok: false, error: String((err && err.message) || err) });

/// One retry, and only for the failures a retry can fix.
///
/// A connection reset part way through an upload and a 502 from a load balancer are transient by
/// definition: the same bytes sent a moment later succeed. Losing a photograph the player has
/// already taken to one of those is the worst outcome on this path, and it was the shipped one.
///
/// **A 4xx is never retried.** A refused key, a bucket that does not exist and a signature that
/// does not match are all permanent, and asking again only doubles the time before the player is
/// told. The backoff is short for the same reason - this is inside a shutter press.
///
/// `build` is a function rather than a body, because a request has to be signed with the time it
/// is actually sent: SigV4 rejects a stamp more than fifteen minutes old, and reusing the first
/// attempt's headers would send an older signature every time.
async function send(build, { retries = 1, timeout = FETCH_TIMEOUT } = {}) {
  let last = null;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    const guard = deadline(timeout);
    try {
      const { url, init } = build();
      const res = await fetch(url, { ...init, signal: guard.signal });
      guard.done();
      if (res.status >= 500 && attempt < retries) {
        // The body of the response being thrown away, or undici keeps its socket out of the
        // pool for the life of the process.
        await drain(res);
        last = null;
        await pause(RETRY_PAUSE);
        continue;
      }
      return { res };
    } catch (err) {
      guard.done();
      // Node's fetch reports every transport failure as the single word "fetch failed" and puts
      // the reason - ECONNRESET, EPIPE, ENOTFOUND, a TLS error - underneath in `cause`. The
      // wrapper tells an operator nothing they can act on, which is the whole point of printing
      // it, so the cause is unwrapped here rather than at each of the four call sites.
      const cause = err && err.cause;
      const why = (cause && (cause.code || cause.message)) || (err && err.message) || String(err);
      // **A timeout is not retried, and that is a deadline calculation rather than a taste.**
      // The Lua poll waiting on this export stops at twenty seconds (`UPLOAD_CEILING` in
      // server/media.lua) and the handler above it at twenty-five. Two attempts at nine seconds
      // with a half-second between them is 18.5 s, which fits; retrying a timeout as well would
      // put it past both, and an answer that arrives after the caller has walked away is worse
      // than no answer. A host that accepted the connection and then went quiet for nine seconds
      // is not having a blip.
      const timedOut = err && (err.name === 'TimeoutError' || err.name === 'AbortError');
      last = timedOut ? 'timeout' : String(why);
      if (!timedOut && attempt < retries) { await pause(RETRY_PAUSE); continue; }
      return { error: last };
    }
  }
  return { error: last || 'unknown' };
}

const sha256hex = (data) => crypto.createHash('sha256').update(data).digest('hex');
const hmac = (key, data) => crypto.createHmac('sha256', key).update(data).digest();

// SigV4's unreserved set is exactly A-Z a-z 0-9 - _ . ~ and everything else is %XX in UPPERCASE
// hex. `encodeURIComponent` leaves ! ' ( ) * alone, which is a signature that never matches and
// no explanation as to why, so those five are finished by hand.
const uriEncode = (str) =>
  encodeURIComponent(str).replace(/[!'()*]/g, (c) =>
    '%' + c.charCodeAt(0).toString(16).toUpperCase());

// The object key keeps its separators: `/` is structure, not part of a name.
const encodeKey = (key) => String(key).split('/').map(uriEncode).join('/');

/// The four-step signing key. Each HMAC is keyed by the last, so what ends up in the request is
/// scoped to one day, one region and one service and is useless anywhere else.
function signingKey(secret, day, region, service) {
  return hmac(hmac(hmac(hmac('AWS4' + secret, day), region), service), 'aws4_request');
}

/// `20260804T101530Z` and `20260804`, which is the only time format SigV4 accepts.
function stamps(now) {
  const iso = new Date(now || Date.now()).toISOString().replace(/[:-]|\.\d{3}/g, '');
  return { stamp: iso, day: iso.slice(0, 8) };
}

/// Sign a request and return the headers to send with it.
///
/// `payloadHash` is the hex SHA-256 of the body. It is computed rather than declared
/// UNSIGNED-PAYLOAD: the body is already in memory here, hashing a few hundred kilobytes in
/// native code costs nothing measurable, and a signed payload is what MEGA S4's own
/// documentation shows. It also means a truncated upload is rejected by the service rather
/// than stored as a broken file.
function signedHeaders(o) {
  const { stamp, day } = stamps(o.now);
  const scope = `${day}/${o.region}/s3/aws4_request`;
  const payloadHash = o.payloadHash || sha256hex(o.body || '');

  const headers = {
    host: o.host,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': stamp,
  };
  if (o.contentType) headers['content-type'] = o.contentType;

  const names = Object.keys(headers).sort();
  const canonicalHeaders = names.map((n) => `${n}:${String(headers[n]).trim()}\n`).join('');
  const signedList = names.join(';');

  const canonical = [
    o.method,
    '/' + encodeKey(o.key),
    o.query || '',
    canonicalHeaders,
    signedList,
    payloadHash,
  ].join('\n');

  const toSign = ['AWS4-HMAC-SHA256', stamp, scope, sha256hex(canonical)].join('\n');
  const signature = crypto
    .createHmac('sha256', signingKey(o.secret, day, o.region, 's3'))
    .update(toSign)
    .digest('hex');

  return {
    ...headers,
    Authorization:
      `AWS4-HMAC-SHA256 Credential=${o.access}/${scope}, ` +
      `SignedHeaders=${signedList}, Signature=${signature}`,
  };
}

/// Where an object lives, in both addressing styles.
///
/// Virtual-hosted puts the bucket in the hostname; path-style puts it in the path. Both are in
/// use: AWS prefers virtual-hosted, MinIO and several others need path-style, and rclone pins
/// MEGA S4 to path-style while S4's own console shows a virtual-hosted hostname. So it is a
/// setting, and `vphone_s3_test` below tries both rather than asking the operator to know.
function endpointFor(cfg, key) {
  const host = cfg.pathStyle
    ? cfg.endpoint
    : `${cfg.bucket}.${cfg.endpoint}`;
  const path = cfg.pathStyle
    ? `/${cfg.bucket}/${encodeKey(key)}`
    : `/${encodeKey(key)}`;
  // The key as the signer must see it: with path-style the bucket is part of the resource.
  const signKey = cfg.pathStyle ? `${cfg.bucket}/${key}` : key;
  return { host, url: `https://${host}${path}`, signKey };
}

/// The address a browser will load this object from.
///
/// `publicBase` exists for a bucket behind a CDN or a custom domain, where the URL a player
/// loads is not the URL the server wrote to. Left empty it is the endpoint itself, which is
/// what a bucket with public object URLs answers on.
function publicUrl(cfg, key) {
  const base = String(cfg.publicBase || '').replace(/\/+$/, '');
  if (base) return `${base}/${encodeKey(key)}`;

  // **MEGA S4 puts the account id in the path for public reads.** The S3 API address and the
  // public address share a host and differ by one segment:
  //
  //     https://bucket.s3.g.megas4.com/<key>              signature required
  //     https://bucket.s3.g.megas4.com/<accountId>/<key>  anonymous
  //
  // Everything else - Amazon, R2, MinIO - has no such segment, so this only applies when the
  // operator has set one.
  //
  // **Always the path form, whatever `pathStyle` says about the API.** Those are two
  // independent decisions: `pathStyle` picks how the SIGNED request is addressed, and this
  // picks how a browser reads the object. MEGA documents both public shapes, but the one an
  // S4 console actually hands you is
  //
  //     https://s3.g.megas4.com/<accountId>/<bucket>/<key>
  //
  // and that is the only one there is an observed example of. Composing the other shape would
  // be trusting documentation over evidence, on a URL that goes into the database with every
  // photograph and would be wrong for all of them at once.
  const account = String(cfg.accountId || '').replace(/^\/+|\/+$/g, '');
  if (account) {
    return `https://${cfg.endpoint}/${account}/${cfg.bucket}/${encodeKey(key)}`;
  }

  return endpointFor(cfg, key).url;
}

/// A `data:` URI or a bare base64 string, as bytes.
///
/// screencapture's `serverCapture` answers a data URI on the base64 path. Both shapes are
/// accepted because which one arrives has changed between its releases, and a phone that
/// stores a file containing the literal text `data:image/webp;base64,...` is a bug nobody
/// notices until they open the picture.
function decode(payload) {
  const str = String(payload || '');
  const comma = str.indexOf(',');
  const isDataUri = str.startsWith('data:');
  const b64 = isDataUri ? str.slice(comma + 1) : str;
  const mime = isDataUri ? (str.slice(5, comma).split(';')[0] || '') : '';
  return { bytes: Buffer.from(b64, 'base64'), mime };
}

/// Put one object in the bucket.
///
/// Answers `{ ok, url, key }` or `{ ok: false, error, status, body }`. The error text is meant
/// for the server console: S3 answers XML with a code like `SignatureDoesNotMatch` or
/// `AccessDenied`, and printing it is the difference between a five-minute fix and an evening.
async function putObject(cfg, key, payload, contentType) {
  const { bytes, mime } = decode(payload);
  if (!bytes.length) return { ok: false, error: 'empty' };
  // Refused here as well as in Lua. The two checks are not redundant: this one is the only one
  // that sees the DECODED length, and it is the last thing between a broken configuration and a
  // signature computed over, and a request built around, an arbitrary number of bytes.
  if (bytes.length > MAX_BODY) {
    return { ok: false, error: 'toolarge', status: 0,
             body: `${bytes.length} bytes, ceiling ${MAX_BODY}` };
  }

  const type = contentType || mime || 'application/octet-stream';
  const { url, host, signKey } = endpointFor(cfg, key);

  // **Safe to retry, and signed afresh each time.** A PUT of the same bytes under the same key
  // is idempotent - the second one overwrites the first with an identical object - so a reset
  // connection costs a moment rather than the photograph.
  const { res, error } = await send(() => ({
    url,
    init: {
      method: 'PUT',
      headers: signedHeaders({
        method: 'PUT',
        host,
        key: signKey,
        region: cfg.region,
        access: cfg.access,
        secret: cfg.secret,
        body: bytes,
        contentType: type,
      }),
      body: bytes,
    },
  }));

  // A DNS failure, a refused connection, a TLS error, a host that stopped answering. Named
  // rather than swallowed: they look identical from the phone and are four different fixes.
  if (!res) return { ok: false, error };

  if (!res.ok) {
    let body = '';
    try { body = (await res.text()).slice(0, 400); } catch (e) { body = ''; }
    return { ok: false, error: 'http', status: res.status, body };
  }
  // A PUT answers an empty body, but "empty" still has to be consumed or the socket never goes
  // back to the pool. One withheld file descriptor per photograph adds up on a busy server.
  await drain(res);
  return { ok: true, url: publicUrl(cfg, key), key };
}

async function deleteObject(cfg, key) {
  const { url, host, signKey } = endpointFor(cfg, key);
  const { res, error } = await send(() => ({
    url,
    init: {
      method: 'DELETE',
      headers: signedHeaders({
        method: 'DELETE',
        host,
        key: signKey,
        region: cfg.region,
        access: cfg.access,
        secret: cfg.secret,
        body: '',
      }),
    },
  }));
  if (!res) return { ok: false, error };
  // 204 is the success, and 404 means it is already gone - which for a sweep is the same
  // outcome and must not be reported as a failure that keeps the row alive for ever.
  return { ok: res.ok || res.status === 404, status: res.status };
}

// ══════════════════════════════════════════════════════════════
// The exports Lua calls
// ══════════════════════════════════════════════════════════════
// Every one takes the whole config per call rather than holding it in a module variable, so a
// convar changed at run time takes effect without a restart and there is no second copy of the
// credentials to keep in step.

// **Every chain below is terminated, and every `cb` is wrapped.** They were `.then(cb)` with no
// `.catch`, so anything that threw - a malformed config string, a signing failure, or the Lua
// reference no longer being callable because the resource restarted between the request and its
// answer - became an unhandled promise rejection. Node ends the process on one of those, which
// on this path means a photograph taking the server down with it.

global.exports('s3Put', (cfgJson, key, payload, contentType, cb) => {
  const answer = reply(cb, 's3Put');
  let cfg;
  // Parsed inside the guard: a config string that is not JSON used to throw straight out of the
  // export, past every deadline, leaving the Lua poll to wait out its full twenty seconds for an
  // answer that was never coming.
  try { cfg = JSON.parse(cfgJson); } catch (err) { return answer(thrown(err)); }
  putObject(cfg, key, payload, contentType).then(answer).catch((err) => answer(thrown(err)));
});

global.exports('s3Delete', (cfgJson, key, cb) => {
  const answer = reply(cb, 's3Delete');
  let cfg;
  try { cfg = JSON.parse(cfgJson); } catch (err) { return answer(thrown(err)); }
  deleteObject(cfg, key).then(answer).catch((err) => answer(thrown(err)));
});

/// **The setting-up command's engine.**
///
/// Two values cannot be read out of any documentation and have to be discovered against the
/// real bucket: the region string the service expects in the credential scope, and whether it
/// wants path-style or virtual-hosted addressing. A wrong region gives `SignatureDoesNotMatch`,
/// which reads like a wrong secret key and sends people to check the wrong thing.
///
/// So this uploads a one-pixel PNG under every plausible combination and reports which one the
/// bucket accepted, with the URL it produced. It is a few hundred bytes per attempt.
global.exports('s3Probe', (cfgJson, regions, cb) => {
  const answer = reply(cb, 's3Probe');
  let base, list;
  try {
    base = JSON.parse(cfgJson);
    list = JSON.parse(regions);
  } catch (err) { return answer(thrown(err)); }
  // A real 1x1 PNG, so a bucket that inspects content types does not reject the probe for a
  // reason that has nothing to do with the signature.
  const PIXEL =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  // **Under the phone's own prefix, not beside it.**
  //
  // This used to write to `vphone-probe/...` while real uploads go to `vphone/...`. An
  // operator who scopes their bucket policy to the prefix the phone actually uses - which is
  // the correct, least-privilege thing to do - then gets a 403 on the probe and a working
  // phone, and the command tells them their bucket is misconfigured when it is not. A test
  // that does not exercise the real path tests nothing.
  const prefix = String(base.keyPrefix || 'vphone').replace(/^\/+|\/+$/g, '') || 'vphone';
  const key = `${prefix}/probe/${Date.now()}.png`;

  (async () => {
    const tried = [];
    for (const pathStyle of [false, true]) {
      for (const region of list) {
        const cfg = { ...base, region, pathStyle };
        const r = await putObject(cfg, key, PIXEL, 'image/png');
        tried.push({
          region,
          pathStyle,
          ok: r.ok,
          status: r.status || null,
          error: r.ok ? null : String(r.body || r.error || '').slice(0, 200),
        });
        if (r.ok) {
          // **Can a browser read it?** This is the question the operator actually has, and it
          // is a different one from "did the upload work": the phone shows a photograph with
          // an <img> tag carrying no credentials, so a bucket that accepts writes and refuses
          // anonymous reads gives a gallery full of empty frames.
          //
          // Asked here rather than by telling somebody to open a URL, because the object is
          // deleted a line later - the first version printed a link to a file it had just
          // removed, so the answer was always 404 and meant nothing.
          let publicRead = null;
          const guard = deadline(FETCH_TIMEOUT);
          try {
            const probe = await fetch(r.url, { method: 'GET', signal: guard.signal });
            publicRead = probe.status;
          } catch (err) {
            // **`err.cause`, not `err.message`.** Node's fetch reports every transport failure
            // as the single word "fetch failed" and puts the actual reason - DNS, TLS, refused
            // connection - underneath. Printing the wrapper tells an operator nothing they can
            // act on, which is the whole job of this command.
            const cause = err && err.cause;
            publicRead = String(
              (cause && (cause.code || cause.message)) || (err && err.message) || err);
          }
          guard.done();

          // **Left in place when the check could not be made.** Deleting it and then saying
          // "open the URL yourself" asks somebody to open a file that has just been removed -
          // the answer is 404 whatever the bucket does, so the advice is worse than useless.
          // Removed only when the answer is known and needs no second opinion.
          const settled = typeof publicRead === 'number';
          if (settled) await deleteObject(cfg, key);
          return answer({
            ok: true, region, pathStyle, url: r.url, publicRead,
            leftBehind: settled ? null : key,
            tried,
          });
        }
      }
    }
    answer({ ok: false, tried });
  })().catch((err) => answer(thrown(err)));
});

// ══════════════════════════════════════════════════════════════
// The hosted-CDN upload, moved off the client
// ══════════════════════════════════════════════════════════════
// **This exists to stop the API key reaching players.**
//
// screencapture's `remoteUpload` emits its whole options object to the capturing client -
// `emitNet("screencapture:captureScreen", source, token, options, dataType)` - and v-phone was
// passing `headers = { Authorization = <the CDN key> }` inside it. So every photograph anybody
// took sent the operator's key to their machine, while server/media.lua's own opening comment
// promised the opposite.
//
// The capture now comes back to the server through `serverCapture`, which carries no headers at
// all, and the upload happens here where the key never leaves the process.
global.exports('mediaPost', (url, headersJson, fieldName, payload, cb) => {
  const answer = reply(cb, 'mediaPost');
  const { bytes, mime } = decode(payload);
  if (!bytes.length) return answer({ ok: false, error: 'empty' });
  // The same ceiling the bucket path has, for the same reason: this is the last measurement
  // before an arbitrary number of bytes is copied into a Blob, a FormData and a request body.
  if (bytes.length > MAX_BODY) {
    return answer({ ok: false, error: 'toolarge',
                    body: `${bytes.length} bytes, ceiling ${MAX_BODY}` });
  }

  const type = mime || 'image/jpeg';
  const ext = (type.split('/')[1] || 'jpg').replace(/[^a-z0-9]/g, '');
  let headers;
  try { headers = JSON.parse(headersJson || '{}'); } catch (err) { return answer(thrown(err)); }
  // Rebuilt per attempt. A FormData whose parts have already been consumed by a request that
  // then failed is not reliably re-sendable, and a second POST carrying an empty body would
  // turn a retryable network blip into a confusing 400.
  const build = () => {
    const form = new FormData();
    form.append(fieldName || 'file', new Blob([bytes], { type }), `capture.${ext}`);
    return { url, init: { method: 'POST', headers, body: form } };
  };

  // **Retried, and the trade-off is deliberate.** A POST is not idempotent: if the host stored
  // the file and the connection dropped before its answer arrived, the retry stores a second
  // copy and the first is orphaned on the operator's quota. Weighed against the alternative -
  // the player's photograph is gone, and `write EPIPE` from a CDN is common enough that this
  // file has a printed explanation of it - one duplicated file is much the cheaper failure.
  // Only ever one extra attempt, and never after a 4xx, so a refused key cannot multiply.
  // **The `cb` calls are inside the try, and the `.catch` cannot itself throw.** They used to sit
  // in the `.then`, so a `cb` that threw - the Lua reference gone with a restarted resource -
  // fell into the `.catch` below, which called `cb` again and threw a second time out of a chain
  // with nothing after it. That is an unhandled rejection, and an unhandled rejection here ends
  // the process. `reply` swallows both throws now, and this shape means the failure path can no
  // longer be reached from the success path.
  send(build)
    .then(async ({ res, error }) => {
      if (!res) return { ok: false, error };
      const text = await res.text().catch(() => '');
      if (!res.ok) {
        return { ok: false, error: 'http', status: res.status, body: text.slice(0, 400) };
      }
      let json = null;
      try { json = JSON.parse(text); } catch (e) { json = null; }
      return { ok: true, response: json, raw: json ? null : text.slice(0, 400) };
    })
    .then(answer)
    .catch((err) => answer(thrown(err)));
});
