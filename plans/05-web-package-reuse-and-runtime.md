# 05 — Web-Package Reuse & Runtime Hardening

**Area:** package-reuse-runtime
**Goal:** Maximize reuse of the *same* `canopy/*` packages web Canopy ships, on the bare
Hermes+JSI+Yoga native host — by providing native backings behind each package's *existing*
effect-manager / FFI seam, plus the Hermes global shims the runtime and those packages need to
run **unmodified**. This document is the build reference.

> Grounding read before editing: `native/docs/c1-native-module-abi.md`,
> `native/docs/architecture.md`, `native/tool/src/Canopy/Native/Bundle.hs`,
> `native/package/external/native-module.js`, `native/host/shared/cpp/CanopyModules.h`,
> `native/host/shared/cpp/CanopyBlobs.h`.

---

## 0. The thesis in one paragraph

Web Canopy already proved the "third walker": the **same** `core/runtime.js` TEA loop and the
**same** VirtualDom node shape render three ways (DOM / SSR HTML / native Fabric-shaped JSI
mutations). The render seam is solved (`native/package/external/native.js`, 949 lines). The
**effect seam** is *also* already solved as an ABI: `external/native-module.js` turns a Canopy
`Task`/`Sub` into `__canopy_call(module,method,argsJson,callId)` over JSI, with completions
hopping back via `__canopy_resolve` (`native-module.js:120-191`). **The missing piece for
package reuse is not the ABI — it is the web globals each package's FFI was written against.**
`http/external/http.js:50` does `new XMLHttpRequest()`; `storage/external/storage.js:20` does
`window.localStorage`; `web-crypto/external/crypto.js:283` does `crypto.subtle.digest`. Hermes
has none of these. So the reuse strategy is: **inject a thin web-compat global layer** (a new
package `canopy/native-webcompat` + a tiny addition to the `Bundle.hs` preamble) whose globals
are backed by the `__canopy_*` ABI we already have. Then `http.js`, `storage.js`,
`crypto.js`, `url.js`, `encoding.js` run **byte-for-byte unmodified** — the only thing that
changed is what `XMLHttpRequest`/`localStorage`/`crypto.subtle`/`URL`/`TextEncoder` resolve to
at runtime. That converts the biggest, most valuable packages from "needs-native-backing" to
"reusable-unmodified" without forking a single `.can` or `.js` file.

---

## 1. Current state (file:line evidence)

### 1.1 What the preamble shims today — and what it is missing

`native/tool/src/Canopy/Native/Bundle.hs` is the *only* place Hermes globals are guaranteed.
`hermesPreamble` (`Bundle.hs:37-56`) shims **only**:

- `global` / `self` aliasing (`Bundle.hs:43-44`)
- `setTimeout` / `clearTimeout` off the microtask queue (`Bundle.hs:46-50`) — note the shim is
  a naive FIFO with `Promise.resolve().then(_pump)`, **ignores the delay arg** (`_ms` unused,
  line 48), so `Process.sleep 1000` fires on the next microtask, not after 1 s.
- `console.{log,warn,error}` as no-ops if absent (`Bundle.hs:51-53`)
- The F2..F9 / A2..A9 currying ABI (`abiHelpers`, `Bundle.hs:63-93`)

**Missing globals the runtime + reusable packages reference (audited):**

| Global | Used by (file:line) | Hermes native? |
|---|---|---|
| `queueMicrotask` | scheduler patterns; safer than `Promise.then` | **No** (shim) |
| `performance.now` | `browser/`, `performance/`, `test/external` | **No** |
| `TextEncoder` | `encoding/external/encoding.js:65`, `web-crypto`, `streams`, `auth` | **No** |
| `TextDecoder` | `encoding.js:126`, `bytes/external/bytes.js`, `web-crypto`, `streams` | **No** |
| `atob` / `btoa` | `auth`, `web-audio`, `webauthn` | **No** |
| `structuredClone` | not currently in any reused FFI; needed for deep-copy patterns | **No** |
| `XMLHttpRequest` | `http/external/http.js:50` | **No** |
| `FormData` | `http.js:285`, `beacon` | **No** |
| `Blob` | `http.js:307`, `file`, `web-apis-clipboard`, `beacon` | **No** |
| `URL` | `url/external/url.js:55`, `virtual-dom`, `browser` | **No** |
| `crypto.getRandomValues` / `crypto.subtle` | `web-crypto/external/crypto.js:225,283` | **No** (Hermes has neither) |
| `localStorage` / `sessionStorage` | `storage/external/storage.js:20,33` | **No** |
| `setInterval` / `clearInterval` | `time/`, animation loops | **No** |

Hermes **does** provide: `Promise` (+ microtask drain on the host's call to
`drainMicrotasks()`), all **TypedArrays** (`ArrayBuffer`, `DataView`, `Uint8Array`,
`Uint32Array` — used by `bytes.js:58`, `crypto.js:56-69`, `encoding.js`), `JSON`,
`encodeURIComponent`/`decodeURIComponent` (so `url.js:17,33` `percentEncode/Decode` already
work — only `resolveReference`'s `new URL` at `url.js:55` is missing), `Math`, `Date`, `RegExp`.
This is why the binary marshalling for http/crypto/encoding is *cheap*: the data containers
(`DataView`/`Uint8Array`) already exist; only the I/O endpoints (`XMLHttpRequest`,
`crypto.subtle`) need backing.

### 1.2 The effect ABI that backs everything (already built + on-device verified)

- `native/package/external/native-module.js` — the JS side: `call` (one-shot Task,
  `native-module.js:120-152`), `callStreaming` (Sub, `:167-191`), `cancel` (`:205-214`),
  self-installs `__canopy_resolve` (`:57-77`). **Marshalling discipline:** JSON strings + ints
  on the control plane; **binary stays native as an opaque int handle** (`native-module.js:24-29`).
- `native/host/shared/cpp/CanopyModules.{h,cpp}` — `ModuleRegistry` + `NativeModule` +
  `CallContext` (`CanopyModules.h:44-100`). `setPostToJs` (`:80`) is the worker→JS-thread hop;
  `dispatch` (`:88`), `cancel` (`:92`). `installCanopyModules` (`:106`), `canopyResolveCall`
  (`:112`).
- `native/host/shared/cpp/CanopyBlobs.{h,cpp}` — refcounted opaque binary registry
  (`CanopyBlobs.h:34-60`): `put`/`get`/`retain`/`release`, `BlobHandle = int32_t`. **This is
  the Blob/ArrayBuffer-of-bulk-bytes story for native** — http response bodies, file contents,
  decoded images all live here as int handles, never as base64 JSON.
- `native/harness/mock-native-modules.js` — in-memory `ModuleRegistry` modelling the
  worker→JS hop with a drainable `jsQueue` (`mock-native-modules.js:46-51,77-80`). **This is
  the unit-test substrate** for every native-backed shim.

### 1.3 Package classification (full `canopy/*` sweep)

Sweep method: `grep` each package's `external/*.js` for browser-global tokens. Result buckets:

**PURE (no JS externals, or externals touch no web globals) — reusable unmodified, zero work:**
`album, billing, datetime, debug, error-boundary, html, image, inference, json, log,
navigation, parser, photos, regex, router, share-image, ssr, storage-secure, svg, time`,
plus NOJS-only packages `accessible-html, analytics, chart, code, codec, color, color-ui,
css, date-ui, debounce-throttle, error-tracking, feature-flags, form, graphql, html-parser,
http-data, http-middleware, markdown, query, random, table, theme-ui, toast`.
(`random/` has **no** `external/` — `Random.can` is pure; it does **not** depend on
`crypto.getRandomValues`, so it is reusable as-is.)

**WEB-LOAD-BEARING (FFI touches web globals; high value; MUST move to bucket 1):**
`http` (XHR/FormData/Blob), `storage` (localStorage), `web-crypto` (crypto.subtle), `url`
(new URL), `encoding` (TextEncoder/Decoder), `bytes` (TextDecoder).

**WEB-NICE-TO-HAVE (FFI touches web globals; medium value):**
`auth` (atob/crypto/localStorage — composes http+crypto+storage), `i18n` (navigator.language),
`beacon` (navigator.sendBeacon→http), `streams` (TextEncoder/Decoder), `keyboard`
(navigator.platform), `share` (navigator.share — native share exists as `share-image`),
`performance` (performance API), `server-sent-events` (EventSource→http long-poll).

**WEB-IMPOSSIBLE-OR-RE-BACK (deeply browser/DOM/hardware bound — re-implement against native
modules, NOT shim):** `browser` (history/location/DOM — native nav is `canopy/navigation`),
`virtual-dom` (the DOM walker — native uses `external/native.js` instead; **the node *data* is
reused, the walker is not**), `audio/web-audio/media/media-recorder/mse/hls/eme` (media stack),
`camera/speech` (getUserMedia/SpeechRecognition → native capability modules),
`canvas/svg-render` (Canvas2D), `webrtc/websocket/broadcast-channel/web-worker`
(transport/threading — websocket is *feasible* later via a native module),
`drag-and-drop/fullscreen/wake-lock/page-visibility/web-apis-*/headless-ui/rich-text/
web-component-export/indexed-db/notify(web)/pwa/dash/test(dom)`. Native equivalents already
exist for the ones Lumen needs: `notify` (native), `storage-secure`, `share-image`, `album`,
`photos`, `billing`, `navigation`.

---

## 2. Target design — the web-compat global layer

### 2.1 Principle: shim the *global*, back it with the *ABI*

Every load-bearing package's FFI calls a **web global**. We make that global exist on Hermes
and route its work through the `__canopy_*` ABI to a registered `NativeModule`. The package's
`.can` and `.js` stay **untouched**. Two delivery mechanisms, chosen per-global:

1. **Pure-JS shims** (no host round-trip): `TextEncoder`, `TextDecoder`, `atob`, `btoa`,
   `URL`, `FormData`, `Blob`, `structuredClone`, `queueMicrotask`, `performance.now`,
   `setInterval`. These are computed entirely in JS on Hermes (TypedArrays + string ops). They
   go in a new package `canopy/native-webcompat` (a JS file injected into the preamble).
2. **ABI-backed shims** (need the host): `XMLHttpRequest` → `Http` native module,
   `crypto.getRandomValues`/`crypto.subtle` → `Crypto` native module, `localStorage` →
   `KeyValue` native module. These are thin JS objects whose methods call `__canopy_call` and
   resolve on `__canopy_resolve`. They also live in `canopy/native-webcompat`, but their
   backings are C++/Kotlin/Swift `NativeModule`s.

### 2.2 Where the shim layer is injected

The Canopy compiler **inlines** FFI externals into the IIFE (the `foreign import javascript`
bodies become functions in the bundle). The preamble runs **before** the IIFE
(`Bundle.hs:25-32`: `preamble ++ compiledJs ++ bootTail`). So a global referenced inside an
inlined FFI body (e.g. `new XMLHttpRequest()` from `http.js`) is resolved **lazily at call
time** against `globalThis`. Therefore: **install the web-compat globals in the preamble**, and
`http.js`'s `new XMLHttpRequest()` transparently finds our shim. No compiler change.

**Decision:** the web-compat JS is large (~600 lines). Do **not** hand-inline it into
`Bundle.hs` as `T.unlines` (unmaintainable). Instead:

- Create `canopy/native-webcompat/external/webcompat.js` — the full shim source.
- Add a build step in `native/tool/src/Canopy/Native/Build.hs` that reads this file and
  splices it into the preamble between the ABI helpers and the compiled IIFE.
- Keep `Bundle.hs`'s tiny critical shims (`global`, `setTimeout`, `console`, F/A ABI) where
  they are (they must exist even if webcompat is stripped); move the *rest* (TextEncoder etc.)
  into `webcompat.js`.

### 2.3 Data flow for an ABI-backed global (XHR example)

```
Canopy: Http.get {...}                                   (app code, unchanged)
  → Http effect manager (http/src/Http.can, unchanged)
  → HttpFFI.toTask  (http/external/http.js:42, unchanged) → new XMLHttpRequest()
  → OUR shim XMLHttpRequest (webcompat.js)
      .open/.setRequestHeader/.send  → buffer config
      .send → __canopy_call("Http","request", argsJson, callId)   [native-module ABI]
  → host: HttpModule::invoke (C++/OkHttp on Android, URLSession on iOS) on a worker thread
  → response body (bytes) → BlobRegistry.put → handle; headers/status as JSON
  → ctx.complete("", {"status":200,"headers":{...},"bodyHandle":42})
  → postToJs → __canopy_resolve(callId, "", resultJson)
  → OUR shim fires xhr 'load' event → http.js _Http_toResponse(...) (unchanged)
  → response body materialized: for responseType "" read handle as UTF-8 string;
    for "arraybuffer" wrap handle bytes in a real ArrayBuffer (http.js:237 toDataView)
  → Canopy msg delivered through the TEA loop (core/runtime.js, unchanged)
```

The genius: **`http.js` thinks it talked to a browser XHR.** We satisfy its exact contract
(`open`, `setRequestHeader`, `timeout`, `responseType`, `withCredentials`, `send`, `abort`,
`status`, `statusText`, `response`, `responseURL`, `getAllResponseHeaders`, `addEventListener`
for `load`/`error`/`timeout`/`progress`, `upload.addEventListener`). Everything `http.js`
reads (`http.js:106-175`) we provide.

---

## 3. File-by-file implementation

### 3.1 New package: `canopy/native-webcompat`

```
canopy/native-webcompat/
  canopy.json                    # package manifest (name canopy/native-webcompat)
  external/webcompat.js          # the entire shim layer (injected into preamble)
  src/NativeWebCompat.can        # tiny .can with a no-op `install : () -> ()` FFI so the
                                 # package is importable + the JS gets linked; mostly the JS
                                 # is preamble-injected, this is the typed handle
  README.md
```

`webcompat.js` is organized in sections. **Pure-JS section (no host):**

```js
// ---- webcompat.js (excerpt: structure + the load-bearing shims) ----
(function (g) {
  'use strict';

  // queueMicrotask — Hermes has Promise; back it with that.
  if (!g.queueMicrotask) {
    g.queueMicrotask = function (cb) { Promise.resolve().then(cb); };
  }

  // performance.now — monotonic-ish via Date; host may override with a real clock global.
  if (!g.performance) {
    var _t0 = Date.now();
    g.performance = { now: function () { return Date.now() - _t0; } };
  }

  // setInterval/clearInterval on top of the preamble's setTimeout (Bundle.hs:46).
  if (!g.setInterval) {
    var _iv = {}; var _ivId = 1;
    g.setInterval = function (fn, ms) {
      var id = _ivId++; _iv[id] = true;
      var tick = function () { if (_iv[id]) { fn(); g.setTimeout(tick, ms); } };
      g.setTimeout(tick, ms); return id;
    };
    g.clearInterval = function (id) { delete _iv[id]; };
  }

  // TextEncoder/TextDecoder — UTF-8 only, pure JS over TypedArrays (Hermes has those).
  if (!g.TextEncoder) {
    g.TextEncoder = function () {};
    g.TextEncoder.prototype.encode = function (str) { /* UTF-8 encode → Uint8Array */ };
  }
  if (!g.TextDecoder) {
    g.TextDecoder = function (enc) { this._enc = (enc||'utf-8').toLowerCase(); };
    g.TextDecoder.prototype.decode = function (buf) { /* UTF-8 decode TypedArray → str */ };
  }

  // atob/btoa — base64 in pure JS (no DOM).
  if (!g.btoa) { g.btoa = function (bin) { /* base64 encode */ }; }
  if (!g.atob) { g.atob = function (b64) { /* base64 decode */ }; }

  // structuredClone — deep clone for plain objects/arrays/typed-arrays (no DOM types).
  if (!g.structuredClone) { g.structuredClone = function (v) { /* recursive clone */ }; }

  // URL — minimal WHATWG parser sufficient for url.js:55 (resolveReference → .href) and
  // virtual-dom's absolute-URL checks. Parses scheme/host/path/query/fragment + resolves
  // relative refs against a base. NOT a full WHATWG impl; covers the reused call sites.
  if (!g.URL) { g.URL = function (input, base) { /* parse + .href/.origin/... */ }; }

  // FormData — http.js:285 only does new FormData() + .append(name,value). Model as an
  // ordered list of parts; the XHR shim serializes it (multipart) when sending.
  if (!g.FormData) {
    g.FormData = function () { this._parts = []; };
    g.FormData.prototype.append = function (k, v) { this._parts.push([k, v]); };
  }

  // Blob — http.js:307 new Blob([bytes],{type}); file.js wraps bytes. Hold parts + type;
  // the XHR shim/native side reads ._parts to get the bytes.
  if (!g.Blob) {
    g.Blob = function (parts, opts) { this._parts = parts||[]; this.type=(opts&&opts.type)||''; };
  }
  // ... ABI-backed section below (XMLHttpRequest, crypto, localStorage) ...
})(typeof globalThis !== 'undefined' ? globalThis : this);
```

**ABI-backed section (same file):** these reuse the *exact* pending-table + `__canopy_resolve`
plumbing as `native-module.js`. To avoid two pending tables, `webcompat.js` calls the same
host globals (`__canopy_call`, `__canopy_cancel`) and **installs its own resolve handler under a
distinct global** (`__canopy_resolve` is shared; we register XHR/crypto/KV callIds in the same
`_NM_pending` namespace by *reusing native-module.js's table* — see §3.6 for the
single-table decision).

```js
  // XMLHttpRequest — satisfies http.js's full contract (open/send/abort/events/status/...).
  g.XMLHttpRequest = function () {
    this._headers = {}; this._listeners = {};
    this.upload = { _listeners: {}, addEventListener: addUpload };
    this.readyState = 0; this.status = 0; this.statusText = '';
    this.response = null; this.responseText = ''; this.responseType = '';
    this.responseURL = ''; this.timeout = 0; this.withCredentials = false;
    this.__isAborted = false;
  };
  XHRp.open = function (m, url) { this._method=m; this._url=url; this.readyState=1; };
  XHRp.setRequestHeader = function (k,v) { this._headers[k]=v; };
  XHRp.addEventListener = function (ev, cb) { (this._listeners[ev]=this._listeners[ev]||[]).push(cb); };
  XHRp.getAllResponseHeaders = function () { return this._rawHeaders || ''; };
  XHRp.send = function (body) {
    var self = this;
    var args = { method:this._method, url:this._url, headers:this._headers,
                 timeout:this.timeout, responseType:this.responseType,
                 withCredentials:this.withCredentials, body: serializeBody(body) };
    self._callId = _WC_call('Http', 'request', JSON.stringify(args), {
      onProgress: function (p) { self._emit(p.phase==='up'?self.upload:self, 'progress', p); },
      onResolve: function (res) {
        self.status=res.status; self.statusText=res.statusText||'';
        self._rawHeaders = res.rawHeaders||''; self.responseURL=res.url||self._url;
        // materialize body from the BlobRegistry handle per responseType:
        self.response = materializeBody(res.bodyHandle, self.responseType, res.bodyText);
        self.readyState=4; self._emit(self,'load',{});
      },
      onError: function (kind) {
        if (kind==='timeout') self._emit(self,'timeout',{}); else self._emit(self,'error',{});
      }
    });
  };
  XHRp.abort = function () { this.__isAborted=true; if(this._callId) _WC_cancel(this._callId); };

  // crypto — getRandomValues (sync) + subtle (async via ABI).
  g.crypto = g.crypto || {};
  g.crypto.getRandomValues = function (typedArray) { /* fill via Crypto.random ABI sync-cache
                                                        OR a fast JS PRNG seeded once from
                                                        Crypto.seed; see §3.4 */ return typedArray; };
  g.crypto.randomUUID = function () { /* v4 from getRandomValues */ };
  g.crypto.subtle = {
    digest: function (algo, data) { return _WC_promise('Crypto','digest', {algo, data}); },
    sign:   function (algo, key, data) { return _WC_promise('Crypto','sign', {...}); },
    verify: function (algo, key, sig, data) { return _WC_promise('Crypto','verify', {...}); },
    generateKey: function (algo, ext, usages) { return _WC_promise('Crypto','generateKey', {...}); },
    importKey:   function (...) { return _WC_promise('Crypto','importKey', {...}); },
    exportKey:   function (...) { return _WC_promise('Crypto','exportKey', {...}); },
    encrypt: ..., decrypt: ...
  };

  // localStorage — synchronous in the web API, but native KV is async. Bridge: a write-through
  // in-memory cache hydrated ONCE at boot (KeyValue.snapshot → all pairs), with async
  // write-back. storage.js uses getItem/setItem/removeItem/clear/length/key + Object.keys.
  g.localStorage = makeStorageArea('local');
  g.sessionStorage = makeStorageArea('session');  // session = in-memory, cleared on boot
```

> **`crypto.subtle` returns a Promise**, but `crypto.js:283` does
> `crypto.subtle.digest(...).then(...)` inside a `_Scheduler_binding`. Hermes has `Promise`, so
> `_WC_promise` (a Promise that resolves on `__canopy_resolve`) satisfies that `.then` chain
> with **zero change to crypto.js**. This is the single most important compatibility fact for
> web-crypto reuse.

### 3.2 `Bundle.hs` changes

`native/tool/src/Canopy/Native/Bundle.hs`:

- **Keep** `hermesPreamble` critical shims (`global/self`, `setTimeout/clearTimeout`,
  `console`, `abiHelpers`).
- **Fix** the `setTimeout` shim to honor the delay (`Bundle.hs:46-50`): the current
  microtask-only shim breaks `Process.sleep`, `Time.every`, debounce/throttle, and the
  `setInterval` shim built on it. Replace with a host-backed timer if available
  (`g.__canopy_setTimeout(ms)` JSI global), falling back to the microtask version only when the
  host provides none. **Add a host timer JSI global** (see §3.5).
- **Add** a splice point: `assembleBundle` becomes
  `preamble ++ webcompatJs ++ compiledJs ++ bootTail`. Thread `webcompatJs :: Text` through
  `BundleInputs` (new field `biWebCompatJs`), read from
  `canopy/native-webcompat/external/webcompat.js` in `Build.hs:finishBundle`.

`native/tool/src/Canopy/Native/Build.hs`:

- In `finishBundle` (`Build.hs:76-87`), locate `native-webcompat/external/webcompat.js`
  (resolved relative to the installed package set or a vendored copy under
  `native/package/external/webcompat.js`), read it, pass into `BundleInputs`. If absent, log a
  warning and proceed with an empty string (so existing apps that need no web packages still
  build).

### 3.3 Native module: `Http` (the highest-value backing)

**Shared C++ (portable signature):** `native/host/shared/cpp/HttpModule.{h,cpp}`

```cpp
// HttpModule.h — NativeModule "Http". Method "request": argsJson {method,url,headers,
// timeout,responseType,withCredentials,body}. Async on a worker thread; result
// {status,statusText,url,rawHeaders,bodyHandle?,bodyText?}. body bytes → BlobRegistry.
class HttpModule : public NativeModule {
 public:
  std::string name() const override { return "Http"; }
  bool invoke(CallContext& ctx) override;     // routes "request"; runs on a worker thread
  void cancel(const std::string& callId) override;
 private:
  // platform transport injected at construction (OkHttp on Android via JNI, URLSession on iOS)
  std::shared_ptr<HttpTransport> transport_;
};
```

The C++ is a thin router; the *transport* is platform:

- **Android:** `HttpModule` is a **pure-Java `JniModule`** instead (cheaper than going through
  C++→JNI→OkHttp). New file
  `native/host/android/app/src/main/java/com/canopyhost/modules/HttpModule.java` extending the
  existing `JniModule` pattern (see `StorageSecureModule.java`,
  `host/shared/cpp/CanopyJni.{h,cpp}`). Use **OkHttp** (already a transitive dep, or add
  `com.squareup.okhttp3:okhttp`). Run on OkHttp's dispatcher thread; on completion read the
  body bytes → `globalBlobRegistry().put(...)` → return the handle as JSON via the JniModule
  completion. Streaming progress (`http.js:329-342`) → `callStreaming` events.
- **iOS (blocked on project bring-up — see §9):** `native/host/ios/CanopyHost/HttpModule.mm`
  using `NSURLSession`. `dataTask` completion on a background queue → `BlobRegistry.put` →
  `ctx.complete` → `postToJs` (`dispatch_async(main)`). Cancel via `NSURLSessionTask.cancel`.

**Body materialization (the binary discipline):** for `responseType === ""` (text), the host
returns `bodyText` inline in JSON when small (< 256 KB) OR a handle the shim reads as UTF-8.
For `responseType === "arraybuffer"`, the host **always** returns a `bodyHandle`; the shim's
`materializeBody` calls a new sync JSI global `__canopy_blob_read(handle) → ArrayBuffer`
(reads the registry bytes into a real Hermes ArrayBuffer, then `release`s the handle). This is
the one place bulk bytes enter JS — and only because `http.js`/Bytes genuinely need an
`ArrayBuffer` (`http.js:237` `new DataView(arrayBuffer)`). For large downloads that go
straight to a file (image download → decode), the app should use the **native Image/File path**
and never materialize into JS at all.

### 3.4 Native module: `Crypto`

Backs `web-crypto/external/crypto.js` unmodified.

- **`crypto.getRandomValues` (sync!):** the web API is synchronous, but the ABI is async. Two
  options: (a) **seed-once**: at boot, one `Crypto.seed` ABI call fills a JS-side CSPRNG
  (ChaCha20 in JS, seeded from platform entropy) and `getRandomValues` runs in pure JS
  thereafter — fast, synchronous, good enough for UUIDs/nonces; (b) a synchronous JSI global
  `__canopy_random(n) → ArrayBuffer` installed by the host (platform `SecureRandom` /
  `SecRandomCopyBytes`). **Decision: (b) for true CSPRNG** — add a sync `__canopy_random` JSI
  global (cheap, no thread hop, entropy is fast). `crypto.randomUUID` derives from it.
- **`crypto.subtle.*` (async):** route each method to `Crypto` ABI methods
  (`digest/sign/verify/generateKey/importKey/exportKey/encrypt/decrypt`). Keys are **opaque**
  on the JS side (`crypto.js:6-8` notes the CryptoKey object *is* the value) — so the shim
  returns an **opaque key handle** (an int from a key registry, or a JSON `{__cryptoKey:id}`)
  and passes it back on subsequent calls. Android: `javax.crypto` (`MessageDigest`, `Mac`,
  `KeyGenerator`, `Cipher`). iOS: `CryptoKit`/`CommonCrypto`.
- Data crosses as base64 in JSON for small payloads, or as a `BlobHandle` for large ones
  (the shim converts the `DataView`/`Uint8Array` arg — `crypto.js:56-69` — to base64 or a
  handle).

### 3.5 Host timer + sync JSI globals (preamble correctness)

The naive `setTimeout` shim (`Bundle.hs:48`) is a latent bug for `Process.sleep`/`Time.every`.
Add host-installed JSI globals in `CanopyHostJni.cpp` (Android) / the iOS controller:

- `__canopy_setTimeout(callId, ms)` + `__canopy_clearTimeout(callId)` — host schedules a
  delayed `postToJs` that calls a JS-side `__canopy_fireTimer(callId)`. Real wall-clock delay.
  The preamble's `setTimeout` becomes a thin wrapper over these when present.
- `__canopy_random(n) → ArrayBuffer` — sync CSPRNG (§3.4).
- `__canopy_blob_read(handle) → ArrayBuffer` and `__canopy_blob_release(handle)` — sync bulk
  read for the few JS sites that truly need bytes (XHR arraybuffer, Bytes from a file).

These are installed next to `installCanopyModules` (`CanopyModules.h:106`), at
`CanopyHostJni.cpp:193` where the registry is wired.

### 3.6 KeyValue / storage backing (single-table decision)

`storage/external/storage.js` expects a **synchronous** `localStorage` (`getItem` returns the
value directly, `:57`). Native KV (SQLite/`SharedPreferences`/`NSUserDefaults`) is async. The
shim resolves this with a **boot-hydrated in-memory mirror**:

- New native module `KeyValue` (Android: `KeyValueModule.java` over SQLite or
  `MMKV`/`SharedPreferences`; iOS: SQLite/`NSUserDefaults`). Methods: `snapshot` (→ all pairs
  as JSON, called once at boot), `set`, `remove`, `clear`.
- `webcompat.js`'s `makeStorageArea('local')` holds a `Map`, hydrated from one `snapshot` call
  during `__canopy_boot` (before the app's `init`). `getItem`/`length`/`key`/`Object.keys`
  read the Map synchronously (satisfying `storage.js:57,156,177,205`). `setItem`/`removeItem`/
  `clear` update the Map **and** fire a fire-and-forget `__canopy_call('KeyValue','set',...)`.
  This matches localStorage semantics (sync reads, durable writes) closely enough for app
  state. Cross-tab `storage` events (`storage.js:239`) become a no-op on native (single
  process) — `storageWindow` (`storage.js:225`) already degrades gracefully to a stub
  `addEventListener`.

> Note: `storage-secure` is the **PURE** native package already shipping
> (`StorageSecureModule.java`, EncryptedSharedPreferences, GATE 6 green). `KeyValue` is the
> *web-compat* path so unmodified `storage/` works; secure storage stays on the native package.

**Single pending-table decision:** `webcompat.js` must **not** duplicate `native-module.js`'s
`_NM_pending` table or re-install `__canopy_resolve`. Instead, `native-webcompat` exposes a
tiny internal `_WC_call(module, method, argsJson, handlers)` that **delegates to the same
mechanism** — the cleanest implementation makes `native-module.js` export its pending registry
on `globalThis.__canopy_nm` (an internal handle) and `webcompat.js` reuses it. Concretely:
add to `native-module.js` (one line in `_NM_install`):
`host.__canopy_nm = { pending: _NM_pending, nextId: function(){ return String(_NM_nextId++); } };`
Then `_WC_call` registers its `{resolve,reject,streaming}` row in that shared table and calls
`host.__canopy_call`. One resolve handler, one id space, no races. **Load order:** ensure
`native-module.js` is linked (it always is — `Native.Module` is imported by every capability)
OR have `webcompat.js` self-install a fallback `__canopy_resolve` guarded by
`if (!host.__canopy_resolve)`.

### 3.7 URL / Blob / FormData / encoding — pure-JS, no host

- `url.js:55` `new URL(reference, base).href` → our minimal WHATWG URL parser. `percentEncode`/
  `percentDecode` (`url.js:17,33`) already work on Hermes (`encodeURIComponent` is built in).
  So **`url/` is reusable after only the `URL` shim** — no native module.
- `encoding.js` needs `TextEncoder`/`TextDecoder` only → pure-JS shims → **reusable, no host**.
- `bytes.js` needs `TextDecoder` only → **reusable after the TextDecoder shim**.
- `Blob`/`FormData` are pure-JS holders consumed by the XHR shim's `serializeBody`
  (multipart for FormData, raw bytes for Blob). No host beyond Http.

---

## 4. Android vs iOS, per backing

| Backing | Android (buildable now) | iOS (blocked on Xcode project bring-up, §9) |
|---|---|---|
| webcompat pure-JS (TextEncoder/atob/URL/Blob/FormData/structuredClone/queueMicrotask/perf/setInterval) | runs on Hermes — **platform-agnostic, works on both once linked** | same JS, no host work |
| `__canopy_setTimeout` / `__canopy_random` / `__canopy_blob_read` JSI globals | `CanopyHostJni.cpp` + Looper / `SecureRandom` / `BlobRegistry` | iOS controller `.mm` + `dispatch_after` / `SecRandomCopyBytes` / `BlobRegistry` |
| `Http` | `HttpModule.java` (OkHttp) over `JniModule` | `HttpModule.mm` (`NSURLSession`) |
| `Crypto` | `CryptoModule.java` (`javax.crypto`, `SecureRandom`) | `CryptoModule.mm` (`CryptoKit`/`CommonCrypto`) |
| `KeyValue` | `KeyValueModule.java` (SQLite/`SharedPreferences`) | `KeyValueModule.mm` (SQLite/`NSUserDefaults`) |

iOS is **blocked on the host project** (the iOS host is loose `.mm` files with no Xcode
project — per the audit and `native/docs/c1-native-module-abi.md:77`). The *design* above is
iOS-ready (the shared C++ ABI + `BlobRegistry` are portable); the *implementation* of the iOS
`NativeModule`s waits on `plan 04`'s iOS project bring-up. Every native module above gets an
iOS `.mm` stub registered in the controller's boot (mirroring `EchoModule` at
`c1-native-module-abi.md:79`).

---

## 5. Web-package reuse: reuse vs re-back (the decision table)

| Package | Bucket today | Action | Native backing needed |
|---|---|---|---|
| `http` | web-load-bearing | **reuse unmodified** | `Http` module + XHR/FormData/Blob shims |
| `web-crypto` | web-load-bearing | **reuse unmodified** | `Crypto` module + `crypto` shim + `__canopy_random` |
| `storage` | web-load-bearing | **reuse unmodified** | `KeyValue` module + `localStorage` shim (boot snapshot) |
| `url` | web-load-bearing | **reuse unmodified** | `URL` shim only (pure JS) |
| `encoding` | web-load-bearing | **reuse unmodified** | TextEncoder/Decoder shim (pure JS) |
| `bytes` | web-load-bearing | **reuse unmodified** | TextDecoder shim (pure JS) |
| `auth` | web-nice | **reuse** after http+crypto+storage land | composes the above; verify |
| `streams` | web-nice | **reuse** | TextEncoder/Decoder shim (pure JS) |
| `beacon` | web-nice | **re-back to http** | route `sendBeacon`→`Http.request` (fire-and-forget) |
| `i18n` | web-nice | **shim `navigator.language`** | host global `__canopy_locale()` |
| `server-sent-events` | web-nice | **re-back later** | `Http` streaming long-poll module |
| `random` | pure | **reuse as-is** | none (pure `.can`) |
| `json,regex,parser,datetime,time,html,svg,markdown,...` | pure | **reuse as-is** | none |
| `image,inference,photos,album,share-image,storage-secure,notify,billing,navigation` | native pkgs | already native | done / per other plans |
| `virtual-dom` | impossible (DOM walker) | **NOT reused — node *data* reused via `external/native.js`** | n/a |
| `browser` | impossible | **re-back**: history/location → `canopy/navigation`; visibility → app-state Sub | nav/lifecycle modules |
| `audio,web-audio,media,media-recorder,mse,hls,eme,camera,speech,webrtc,canvas` | impossible | **re-back per capability** when needed; not for Lumen | future native modules |
| `websocket` | impossible-now | **re-back later** as a `WebSocket` native module (OkHttp WS / `URLSessionWebSocketTask`) | future |
| `indexed-db` | impossible | **superseded** by `KeyValue`/SQLite | n/a |
| `web-apis-*, drag-and-drop, fullscreen, wake-lock, page-visibility, rich-text, pwa, dash` | impossible | **drop on native** (DOM-only) or re-back the few Lumen needs | n/a |

**Reuse score:** of the load-bearing six, **all six become reusable-unmodified** with one new
package + three native modules + the JSI globals. That moves `http, web-crypto, storage, url,
encoding, bytes` (and downstream `auth, streams`) from bucket 2 → bucket 1.

---

## 6. Runtime / architecture hardening

These keep `core/runtime.js` + the virtual-dom node shape reusable as native grows.

### 6.1 Threading model (the one invariant)
- **Single-threaded Hermes runtime; everything heavy on worker threads.** The ABI already
  enforces this: modules run off the JS thread and hop completions via `postToJs`
  (`CanopyModules.h:80`, `c1-native-module-abi.md:38-40`). **Rule for every new module**
  (`Http`, `Crypto`, `KeyValue`): never touch `jsi::Runtime` off the JS thread; only
  `ctx.complete` (→ `postToJs` → `__canopy_resolve`) crosses back. The sync JSI globals
  (`__canopy_random`, `__canopy_blob_read`, `__canopy_setTimeout`) run **on** the JS thread and
  must be fast/non-blocking (entropy + memcpy only).
- **Microtask drain:** Hermes does not auto-drain microtasks; the host must call
  `drainMicrotasks()` after each `postToJs` and after the boot eval (the `Promise.then`-based
  `queueMicrotask`/`subtle` chains depend on it). Verify this is wired in `CanopyHostJni.cpp`
  and add it to the iOS controller. **Action item:** audit that every `postToJs` callsite ends
  with a drain; the `__canopy_resolve` path that fires a Promise `.then` (crypto.subtle) is
  inert without it.

### 6.2 Native handle memory / GC
- Hermes GC never sees native bytes (`CanopyBlobs.h:13-15`). Lifetime is **manual refcount**
  (`put`=1, `retain`, `release`). **Risk:** a handle materialized into JS (XHR arraybuffer)
  then leaked. **Rule:** `__canopy_blob_read(handle)` **copies into an ArrayBuffer and releases
  the handle in the same call** (read-once semantics) unless the caller passes a `keep` flag.
  Document the retain/release contract per module (e.g. an image handle consumed by both
  "display" and "save" must be retained twice — already noted `CanopyBlobs.h:13`).
- **Handle harmonization (open from the memory state):** each capability currently mints its
  own opaque handle type. Standardize on the **single `BlobRegistry` int handle** as the cross
  package currency (http body, file bytes, decoded image, tensor) so packages compose without
  per-pair int bridges. Track this as a cross-cutting cleanup.

### 6.3 Keeping `core/runtime.js` + virtual-dom reuse intact
- **Never fork `core/runtime.js`.** Its only host deps are `setTimeout` (`runtime.js:700`),
  `clearTimeout` (`:704`), and `console` (`:419,1180`) — all shimmed in the preamble. Keep it
  that way: any new runtime need is satisfied by a **preamble/webcompat shim**, never an edit to
  `core/`. This is the contract that lets web and native share one runtime.
- **Never fork the virtual-dom node shape.** Native reads the same node data via
  `external/native.js`; the `virtual-dom` *package* (the DOM walker) is simply not linked on
  native. New node kinds must be added to the shared shape, rendered by all three walkers.
- **Bundle determinism:** the preamble + webcompat are prepended verbatim; keep them
  idempotent (`if (!g.X)` guards everywhere) so a future RN-Fabric-mount host that already has
  `setTimeout`/`fetch` does not get clobbered.

### 6.4 The blob registry as the binary spine
- One process-wide `globalBlobRegistry()` (already exists, `CanopyJni.{h,cpp}`). Http/File/
  Image/Inference all `put`/`get` against it. This is the *only* sanctioned way bulk binary
  exists; JSON/int is the only control plane (`native-module.js:24-29`). Enforce in review.

---

## 7. Testing strategy

### 7.1 Mock-fabric / mock-native unit tests (run here, no device)
- Extend `native/harness/mock-native-modules.js` with mock `Http`, `Crypto`, `KeyValue`
  modules. A test boots the real compiled `http/` (or `storage/`, `web-crypto/`) bundle with
  `webcompat.js` injected, registers the mock module, drives a `Cmd`, `flushJs()`
  (`mock-native-modules.js:77`), asserts the resolved msg. **This proves the shim ↔ ABI ↔ .can
  reuse path end-to-end in Node.** Add `harness/run-http.js`, `run-storage.js`,
  `run-crypto.js` mirroring `run-echo.js`.
- **Pure-JS shim unit tests** (no ABI): a Node test that loads `webcompat.js` and asserts
  `TextEncoder`/`atob`/`URL`/`Blob`/`FormData`/`structuredClone` behavior against known vectors
  (compare to Node's built-ins). Fast, deterministic, catches encoding bugs.
- **Reuse the existing package test suites:** `http/tests/Test/Http.can`,
  `storage/`, `web-crypto/` tests — run them on Hermes-shaped harness with the shims to prove
  the *unmodified* packages pass their own suites against native backings.

### 7.2 Device E2E (Android now, iOS after bring-up)
- `Http`: a probe app does `Http.get "https://httpbin.org/get"` → assert 200 + body in logcat
  (extend `native/examples/lumen-probe`). Offline → assert `NetworkError`. Timeout path.
  arraybuffer download → `Bytes` length.
- `Crypto`: `digest SHA-256` of known input → assert hex; `randomUUID` format; HMAC sign/verify
  round-trip.
- `KeyValue`/`storage`: set→get→remove round-trip across an app restart (durability).
- These slot into the existing GATE harness (the memory state's 6-of-9 gates). Add **GATE 9
  (http), GATE 10 (crypto), GATE 11 (storage-web)**.

---

## 8. Milestones (effort S/M/L/XL, ordered)

1. **M0 — Preamble correctness + webcompat skeleton (S).** Fix the `setTimeout` delay bug
   (`Bundle.hs:46`), add the `Bundle.hs`/`Build.hs` splice for `webcompat.js`, create
   `canopy/native-webcompat` with the **pure-JS** shims (TextEncoder/Decoder, atob/btoa, URL,
   Blob, FormData, structuredClone, queueMicrotask, performance, setInterval). Unit-test them in
   Node. *Unblocks `url`, `encoding`, `bytes` reuse immediately (no host).*
2. **M1 — Sync JSI globals + host timer (M, Android).** `__canopy_setTimeout/clearTimeout`,
   `__canopy_random`, `__canopy_blob_read/release` in `CanopyHostJni.cpp`; wire
   `drainMicrotasks` after every `postToJs`. *Unblocks correct sleep/timers + arraybuffer + CSPRNG.*
3. **M2 — `Http` module + XHR shim (L, Android).** `HttpModule.java` (OkHttp), XHR/Blob/
   FormData serialization, body materialization via BlobRegistry, progress streaming.
   `run-http.js` mock test + device GATE 9. *Moves `http` (and `beacon`) into bucket 1.*
4. **M3 — `KeyValue` + `localStorage` shim (M, Android).** Boot snapshot hydration, write-back.
   `run-storage.js` + device GATE 11. *Moves `storage` into bucket 1.*
5. **M4 — `Crypto` module + `crypto` shim (L, Android).** subtle digest/sign/verify/keys,
   opaque key handles, `getRandomValues` over `__canopy_random`. `run-crypto.js` + GATE 10.
   *Moves `web-crypto` (and downstream `auth`) into bucket 1.*
6. **M5 — Downstream reuse validation (S).** Run `auth`, `streams`, `i18n` (locale global),
   `beacon` against the new backings; fix any residual global gaps. Document the reuse matrix
   as shipped.
7. **M6 — iOS backings (XL, BLOCKED on iOS project bring-up).** Port `Http`/`Crypto`/`KeyValue`
   to `.mm` (`NSURLSession`/`CryptoKit`/SQLite), the sync JSI globals to the controller, and
   re-run the harness on a device/sim. Gated on plan 04.
8. **M7 — Hardening cleanup (M).** Handle harmonization to the single `BlobRegistry` currency;
   audit microtask drains; document the retain/release contract per module; CI job that runs
   the Node reuse suites on every change to `webcompat.js`/the modules.

**Critical path:** M0 → M1 → (M2 ∥ M3 ∥ M4) → M5; M6 parallel once iOS unblocks; M7 last.

---

## 9. Risks & open questions

- **R1 — `setTimeout` delay bug is live today.** `Bundle.hs:48` ignores `_ms`. Any reused
  package using `Process.sleep`/`Time.every`/`debounce-throttle` mis-fires on native *now*.
  M0/M1 must fix it before timer-dependent packages are trusted.
- **R2 — Microtask drain not confirmed wired.** `crypto.subtle`'s `.then` chains and
  `queueMicrotask` are **inert** without a `drainMicrotasks()` after each JS-thread entry.
  Confirm in `CanopyHostJni.cpp`; if missing, web-crypto reuse silently hangs. **Verify first.**
- **R3 — `localStorage` sync-over-async semantic gap.** The boot-snapshot mirror assumes the
  app's storage fits in memory and that no other process writes it. True for a single-process
  app; document the limitation. Large/binary values should use `File`/`KeyValue` directly, not
  `localStorage`.
- **R4 — Two pending tables / double resolve.** If `webcompat.js` re-installs
  `__canopy_resolve` independently of `native-module.js`, callId spaces collide. The §3.6
  single-shared-table decision must be implemented carefully (load order + the
  `__canopy_nm` export). Cover with a Node test that drives an `Http` (webcompat) call and a
  `Native.Module.call` concurrently.
- **R5 — Body size threshold.** The text/handle cutoff for HTTP bodies (§3.3) is a tuning knob;
  too low = excessive handle churn, too high = JS-string OOM. Start at 256 KB; measure.
- **R6 — `crypto.getRandomValues` synchronicity.** Chosen path (b) needs a sync JSI global; if
  a future host cannot install sync host functions cheaply, fall back to path (a) seed-once
  CSPRNG. Both are designed; pick per host.
- **R7 — URL shim fidelity.** A hand-rolled URL parser will diverge from WHATWG on edge cases.
  Scope it to the *reused* call sites (`url.js:55` resolveReference, virtual-dom absolute
  checks) and test against those; do not claim full WHATWG conformance.
- **R8 — iOS is the long pole.** Everything is iOS-ready by design (portable C++ ABI +
  BlobRegistry), but no line of iOS backing can be *validated* until the Xcode project exists
  (plan 04). The Android path is fully unblocked on this box.
- **Open Q1:** Should `websocket` and `server-sent-events` get native modules now, or defer?
  (Lumen needs neither; defer — but the `Http` streaming substrate makes SSE cheap later.)
- **Open Q2:** Do we vendor `webcompat.js` into `native/package/external/` (so the tool always
  finds it) or resolve it from an installed `canopy/native-webcompat`? Vendoring is simpler for
  the bootstrap; the package form is cleaner long-term. **Lean: vendor now, packageize in M7.**
- **Open Q3:** Handle harmonization (§6.2) touches several shipped capability packages — is a
  breaking change to their handle types acceptable now, or do we keep per-package handles and
  add int bridges? (Recommend harmonize early, before more packages depend on bespoke handles.)
