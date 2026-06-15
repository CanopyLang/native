# Plan 03 — Native Modules & HTTP: the effects/capability ecosystem to RN/Expo parity

> Build reference for the `native-modules-http` area. Scope: (a) a real HTTP/WebSocket
> transport on Hermes behind `canopy/http` and `canopy/websocket`; (b) a real billing
> store (Play Billing v6 + StoreKit2) replacing the fake `BillingModule`; (c) hardening
> the `__canopy_*` native-module ABI (error taxonomy, threading, cancellation, the
> streaming pattern generalized, and a **codegen path** so capabilities are scaffolded
> not hand-written); (d) the capability roadmap to Expo-level (camera, audio, video,
> geolocation, sensors, clipboard, haptics, permissions, push, deep links, biometrics,
> background tasks, files), each with its `.can` effect-module shape + Android sketch +
> iOS sketch + priority.
>
> Everything here rides the **existing, verified C1 ABI**. The headline finding from
> reading the code: the ABI is solid and general — the gap is *backings* (no real HTTP,
> a fake store, ~12% capability breadth, iOS has no project), not *plumbing*. We do not
> redesign the seam; we fill it and automate it.

---

## 0. Ground truth: how a native effect actually flows today (read this first)

The effect seam is the sibling of the render seam. Both cross JSI; both marshal
JSON+ints; binary stays native as an opaque int handle (the `BlobRegistry`).

**The ABI (3 globals, never one-global-per-method):**
- `__canopy_call(module, method, argsJson, callId) -> 0 | -1` — JS→host, installed by
  the host: `CanopyModules.cpp:installCanopyModules` (`CanopyModules.cpp:103-118`).
- `__canopy_cancel(callId) -> void` — JS→host, same installer.
- `__canopy_resolve(callId, errJson, resultJson)` — host→JS, **self-installed by JS**
  at `native-module.js:_NM_install` (`native-module.js:62-89`), the host only *calls*
  it via `canopyResolveCall` (`CanopyModules.cpp:148-162`).

**The JS surface** is `Native.Module` (`native/package/src/Native/Module.can`): `call`
(one-shot `Task Error a`), `callStreaming` (`Task Error Process.Id`, each native emit →
`Platform.sendToSelf`), `cancel`. Marshalling lives in `native-module.js`: `call`
(`:118-167`), `callStreaming` (`:178-211`), `cancel` (`:219-235`). The pending table
`_NM_pending` keys on `callId`; a streaming row stays alive until a terminal
`{"$done":true}` (`:79-82`).

**The C++ side**: `ModuleRegistry::dispatch` (`CanopyModules.cpp:43-90`) routes
`(module,method)` to a `NativeModule` (`CanopyModules.h:54-71`), builds a `CallContext`
whose `complete(errJson, resultJson)` closure **hops to the JS thread via
`postToJs`** before touching the runtime (`CanopyModules.cpp:67-78`). This is the one
invariant the whole ABI rests on: *the `jsi::Runtime` is only ever touched on its own
thread.* `postToJs` on Android = park a `std::function` + schedule a `Runnable` on the
CanopyJS Looper (`CanopyHostJni.cpp:60-69`).

**Two backing patterns already exist and both work:**

1. **`JniModule`** (`CanopyJni.h:96-110`, `CanopyJni.cpp:132-145`) — pure-Java/Kotlin
   capabilities. `invoke()` parks `ctx.complete` in a callId-keyed table
   (`jniRegisterPending`), calls `com.canopyhost.modules.<Name>Module.invoke(method,
   argsJson, callId)`; Java does async work and calls back
   `CanopyHostJni.resolveModule(callId, err, result)` → `jniResolve` → `ctx.complete`.
   **One-shot only** — `jniResolve` erases the row on first resolve
   (`CanopyJni.h:65-72`). Registered for Image/Photos/Album/ShareImage/StorageSecure/
   Notify at `CanopyHostJni.cpp:199-204`.

2. **Streaming** — two flavors that a Sub can ride:
   - **Bespoke C++ `NativeModule`** owning its sinks: `BillingModule.cpp:62-91`
     (`emit` fans an event to every `streams_[callId]`), plus a JNI `nativeEmit` export
     (`BillingModule.cpp:115-126`). RestoreEngine is the heavy-compute C++ variant
     (worker thread + cancel atomic, `RestoreEngineModule.h`).
   - **Generalized `StreamingJniModule`** (`StreamingJniModule.h`) — any
     subscription-bearing **Java** capability reuses ONE C++ class by name; Java pushes
     via `StreamingBridge.emit(module, channel, json)` (`StreamingBridge.java`). Used by
     `Lifecycle`/`AppShell` (`CanopyHostJni.cpp:215-218`).

**Cancellation**: JS kill-fn → `__canopy_cancel` → `ModuleRegistry::cancel`
(`CanopyModules.cpp:92-106`) → owning module's `cancel(callId)`. C++ modules flip a
per-callId atomic the worker polls (`EchoModule.cpp:25-29`); JniModule calls Java
`<Name>Module.cancel(callId)` if declared (`CanopyJni.cpp:147-170`).

**Error taxonomy** today (`Native.Module.Error`, `Module.can:40-53`): `ModuleNotFound`,
`Rejected String`, `Decode String`, `Cancelled`. Native side returns
`{"code":"...","message":"..."}`; `_NM_error` maps it (`native-module.js:99-109`).
`Rejected` smuggles a sub-code as `"code:message"` and capabilities re-parse it
(Billing's `toBillingError`/`codeOf`, `Billing.can`).

**The render seam is irrelevant to this plan** beyond the fact that effects reuse the
*same* `postToJs` hop the renderer's `requestFrame` uses (`CanopyHostJni.cpp:99-104`).

**iOS reality** (`native/host/ios/CanopyHost/`): two loose `.mm` files
(`CanopyHostFabric.mm`, `CanopyHostViewController.mm`), **no Xcode project, no
`CanopyModules` installer, no module registry**. Every iOS sketch below is **blocked on
the iOS project bring-up** (covered in the host/iOS plan); here we specify the
`NativeModule` shapes so they're ready to drop in.

**Codegen tool today** (`native/tool/src/Canopy/Native/`): `Codegen.hs` emits the
*render* component manifest (JSON/C++/TS) from `Component.hs:defaultComponents`;
`Scaffold.hs` scaffolds an *app*. **There is no capability/module scaffolder** — every
module above was hand-written. That is the automation gap (§4).

---

## PART A — HTTP & WebSocket transport on Hermes

### A.1 Current state (file:line evidence)

- **`canopy/http` exists and is feature-complete at the Canopy level** but is
  **DOM-only**. `Http.can` is a full effect module (`Http.can:1`, `command = MyCmd,
  subscription = MySub`) with get/post/put/patch/delete, json variants, multipart, file
  bodies, bytes, `Expect`, `track`/`Progress`, `cancel`, `task`/`Resolver`,
  `riskyRequest`. Its FFI `external/http.js` is **100% `XMLHttpRequest`**:
  `new XMLHttpRequest()` (`http.js:45`), `xhr.open/send` (`:60,:67`),
  `xhr.upload.addEventListener('progress', …)` (`http.js _Http_track`), `FormData`
  (`toFormData`), `Blob` (`bytesToBlob`). **Hermes has none of these globals.**
- The effect manager binds the FFI at `Http.can:1330`:
  `Process.spawn (HttpFFI.toTask router (Platform.sendToApp router) req Dict.empty
  Dict.update)`. `toTask` is `F5(router, toTaskFn, request, dictEmpty, dictUpdate)`
  (`http.js:42`). Cancellation = the returned kill-fn aborts the XHR
  (`http.js:69`), tracked per `tracker` name in `State.reqs : Dict String Process.Id`
  (`Http.can:1283`, cancel path `Http.can:1318-1326`).
- **`canopy/websocket` exists, also DOM-only**: `WebSocket.can:1` effect module;
  `websocket.js` uses `new WebSocket(url, protocols)` (`websocket.js:25-31`), with
  reconnect/heartbeat/queue logic *in Canopy* (`WebSocket.can` openConnection, reconnect
  policy). Only the socket primitive is FFI.
- **Net effect**: on the Hermes host, any `Http.get`/`WebSocket.listen` throws
  `ReferenceError: XMLHttpRequest is not defined` → SIGABRT (no red-box yet). **This is
  the single most load-bearing gap**: no model/CDN fetch, no analytics, no
  error-tracking upload, no remote config, no GraphQL.

### A.2 Target design — RN parity, zero Canopy-surface change

**Key decision: re-back, don't re-write.** `Http.can`/`WebSocket.can` and their public
APIs do not change. We swap the FFI file the native bundle links so `toTask`/`connect`
reach a **native networking `NativeModule`** over `__canopy_call` instead of XHR.

Two viable mechanisms; we choose **(2)** as primary, with **(1)** as a thin shim:

1. **Polyfill `XMLHttpRequest`/`WebSocket`/`FormData`/`Blob` as JSI globals.** Pro: zero
   change to *any* FFI file; `http.js`/`websocket.js` run unmodified. Con: a faithful
   XHR/WS polyfill is a lot of surface (events, readyState, responseType, upload
   progress) and is exactly what RN's `whatwg-fetch`/`XMLHttpRequest` shim is — large and
   leaky.
2. **A `Net` `NativeModule` + a native-specific FFI shim.** We ship
   `native/package/external/http-native.js` and `websocket-native.js` that implement the
   **same exported functions** (`toTask`, `expect`, `toFormData`, …; `connect`,
   `sendText`, …) but build their async work on `Native.Module.call`/`callStreaming`
   instead of XHR/WS. The native build's bundler aliases `external/http.js →
   external/http-native.js` (a per-package `external` override; see A.5). Pro: small,
   explicit, uses the audited ABI, gets cancellation/threading/streaming for free. Con:
   we maintain a native twin of two FFI files.

We pick **(2)** because it rides the existing ABI (cancellation via `__canopy_cancel`,
threading via `postToJs`, streaming via the terminal-marker protocol) and keeps binary
out of JSON (response bytes can cross as a Blob handle, A.4).

**Wire contract — `Net` module** (one module, methods are HTTP + WS):

```
Net.request  {method, url, headers:[[k,v]], body:{kind, ...}, timeoutMs, responseType,
              tracker?:string}
   one-shot  -> {status, statusText, url, headers:[[k,v]], body:{kind:"text",text}|{kind:"blob",handle}}
   streaming variant Net.requestStreaming emits progress events:
             -> {phase:"sending", sent, total} | {phase:"receiving", received, total?}
                then a terminal {phase:"done", <the response record>} (NOT {$done} — the
                response IS the terminal event; the shim translates).
Net.wsOpen   {url, protocols:[string], timeoutMs} -> streaming:
             -> {ev:"open"} | {ev:"message", kind:"text"|"binary", text?|handle?}
              | {ev:"close", code, reason, wasClean} | {ev:"error", message}
Net.wsSend   {handle:wsId, kind:"text"|"binary", text?|blobHandle?} -> null
Net.wsClose  {handle:wsId, code, reason} -> null
```

`body.kind ∈ {empty, string(contentType,text), bytes(contentType,blobHandle),
multipart(parts:[{name, kind, ...}])}`. Multipart parts mirror Canopy `Part`:
string/file/bytes; a file/bytes part carries a Blob handle, never inline base64.

**Data flow (HTTP one-shot, no progress):**
`Http.get` → `HttpFFI.toTask` (native shim) builds `argsJson` from the `request` record
→ `NM.call "Net" "request" argsJson decoder` → `__canopy_call` →
`ModuleRegistry::dispatch` → `NetModule::invoke` → **OkHttp enqueue on its dispatcher
thread** → `onResponse`/`onFailure` → `ctx.complete("", resultJson)` → `postToJs` →
`__canopy_resolve` → the shim's `done(response)` rebuilds the Canopy `Response`/`Metadata`
exactly as `_Http_toResponse` does (`http.js:115-124`) and feeds `request.expect`.

**Progress** uses `requestStreaming`: OkHttp's body-write `RequestBody` wrapper emits
sending ticks, an `Interceptor`/`Source` wrapper emits receiving ticks, each →
`ctx.complete("", {"phase":"receiving",…})` → the shim re-spawns the `_Http_track`
sendToSelf exactly as `http.js _Http_track` does. The final response is the stream's
terminal event.

**Cancellation**: `Http.cancel tracker` already kills the `Process` (`Http.can:1318`),
the shim's kill-fn calls `__canopy_cancel(callId)` → `NetModule::cancel` →
`call.cancel()` on the OkHttp `Call` / `WebSocket.cancel()`.

**Timeouts**: pass `timeoutMs` into OkHttp's per-call `callTimeout`; on iOS the
`URLSessionConfiguration.timeoutIntervalForRequest`. Maps to Canopy `Timeout_`
(`http.js:13`) via an error code `{"code":"timeout"}` the shim recognizes.

### A.3 Android backing — `NetModule` (Kotlin + OkHttp), via `JniModule`+streaming

HTTP one-shots are pure `JniModule`. WS and progress are streaming, so `Net` is a
**bespoke streaming C++ module OR a `StreamingJniModule`**. **Decision: use
`StreamingJniModule`** — `Net`'s streaming methods are `requestStreaming`, `wsOpen`;
its one-shots (`request`, `wsSend`, `wsClose`) delegate to Java like any `JniModule`.
This is exactly the Lifecycle/AppShell posture and needs **no new C++** beyond
registration. WS channels key on the *callId* (one channel per open socket), which the
existing `StreamingJniModule` already does (channel = method, but we extend it to allow
a per-call sub-channel; see §4 hardening — or simpler, give each socket its own callId
and let Java route via `StreamingBridge.emit("Net", callId, json)`, treating callId as
the channel string).

Files:
- **Create `native/host/android/.../modules/NetModule.java`** (Kotlin or Java). Static
  `invoke(method, argsJson, callId)` + `cancel(callId)`. One `OkHttpClient` singleton
  (connection pool, `Dispatcher`). `request`: build `okhttp3.Request`, body from
  `body.kind` (string → `RequestBody.create`, bytes → read the Blob via the **blob
  bridge** `CanopyBlobs.getBytes(handle)` — note: the existing bridge is Bitmap-only
  (`CanopyJni.h:130-136`); we add a raw-bytes blob kind, §4), multipart →
  `MultipartBody.Builder`. `client.newCall(req).enqueue(callback)`; `onResponse` →
  `resolveModule(callId, "", responseJson)`; map non-2xx still resolves success (the
  Canopy `Response` distinguishes GoodStatus/BadStatus, not transport). `onFailure` →
  `reject` with code `timeout`/`network`/`badurl`. Store `Call` by callId for cancel.
- For **`requestStreaming`**: wrap the `RequestBody` and the response `Source` to emit
  progress via `StreamingBridge.emit("Net", callId, progressJson)`; emit the final
  response as the terminal event; then the C++ side tears the channel down.
- For **WS**: `client.newWebSocket(req, listener)`; the `WebSocketListener` callbacks
  (`onOpen/onMessage(text)/onMessage(ByteString)/onClosing/onClosed/onFailure`) →
  `StreamingBridge.emit("Net", callId, eventJson)`. `wsSend`/`wsClose` look the socket
  up by its callId-handle. Binary frames: put the bytes into a Blob, emit the handle.
- **Register** in `CanopyHostJni.cpp` boot block (`:198-204` for the one-shot half via
  `JniModule`, but since Net is streaming): add
  `g_registry->registerModule(canopy::globalStreamingModule("Net", {"requestStreaming",
  "wsOpen"}));` next to the Lifecycle/AppShell lines (`:215-218`). One-shots
  (`request`, `wsSend`, `wsClose`) are delegated to Java by `StreamingJniModule`'s
  non-streaming path (it already delegates non-channel methods to `<Name>Module.invoke`,
  `StreamingJniModule.h` "one-shot methods … delegated to Java EXACTLY like
  canopy::JniModule").
- **Gradle**: add `implementation 'com.squareup.okhttp3:okhttp:4.12.0'` to
  `build.gradle` deps (next to `:56-66`). OkHttp pulls okio; both are pure-JVM, no NDK.
- **Manifest**: `<uses-permission android:name="android.permission.INTERNET"/>` (likely
  present; verify in `AndroidManifest.xml`).

### A.4 iOS backing — `NetModule` (`NativeModule` in ObjC++, NSURLSession)
**[BLOCKED on iOS project + iOS `CanopyModules` installer]**

A bespoke `NativeModule` subclass in `native/host/ios/CanopyHost/NetModule.mm`:
- `request`: build `NSMutableURLRequest`, body/multipart via `NSData`/streamed
  `NSInputStream`; `NSURLSession` `dataTask`/`uploadTask`; completion on the session
  delegate queue → `ctx.complete`. (`ctx.complete` already hops to the JS thread via the
  iOS `postToJs`, which the iOS host must implement as a `dispatch_async` onto the JS
  run loop — the iOS twin of `CanopyHostJni.cpp:60-69`, specified in the host plan.)
- progress: `URLSessionTaskDelegate didSendBodyData` / `didReceiveData`.
- WS: `NSURLSessionWebSocketTask` (iOS 13+); `receiveMessage` loop → emit events.
- cancel: hold the `NSURLSessionTask`/WS task by callId; `[task cancel]`.
- Register in the iOS boot once it exists: `registry->registerModule(make_shared<NetModule>())`.

Because iOS has no `JniModule`/`StreamingBridge`, `NetModule` is a **direct C++/ObjC++
`NativeModule`** owning its own stream sinks (the BillingModule.cpp posture, portable).
This is the canonical "iOS implements `NativeModule` directly" path the headers already
anticipate (`CanopyModules.h` survival rule; `CanopyJni.h` "iOS capabilities implement
NativeModule directly in Objective-C++").

### A.5 The native FFI swap (the one Canopy-side change)

The bundler must, **for the native target only**, resolve `Http`'s
`foreign import javascript "external/http.js"` to the native twin. Two options:
- **(preferred) per-package `external` override in the native build**: the
  `canopy-native build` step (`tool/.../Build.hs`) already assembles the Hermes bundle;
  teach it to substitute `external/http-native.js` for `external/http.js` and
  `websocket-native.js` for `websocket.js` when present (a manifest in `canopy/native`'s
  package, or a `native.config.json` `ffiOverrides` map). This keeps `canopy/http`
  itself untouched and publishable.
- **(fallback) a `canopy/http-native` package** that re-exposes `Http` with the native
  FFI. Rejected: forks the module name, breaks `import Http`.

Create:
- **`native/package/external/http-native.js`** — exports `toTask, expect, mapExpect,
  toDataView, emptyBody, pair, toFormData, bytesToBlob` with identical signatures
  (`@canopy-type`/`@name` annotations preserved so the compiler binds them), but
  implemented over `NM.call`/`callStreaming`. `toFormData`/`bytesToBlob` become
  arg-record builders (no real `FormData`/`Blob`); the response-`Response` assembly
  reuses the same metadata/header-dict shape as `_Http_toResponse`/`_Http_parseHeaders`.
- **`native/package/external/websocket-native.js`** — `connect, sendText, sendBinary,
  closeConnection, destroy, delay` over `NM.callStreaming` (one stream per socket) +
  `NM.call` (send/close). `delay` uses `setTimeout` (Hermes has timers).

> Reuse note: `Http.can`'s `Resolver`/`task`/`expectBytesResponse` and all the
> body/part/header types are pure Canopy and need **zero** change. Only the ~10 FFI
> functions get a native twin.

---

## PART B — Real billing (Play Billing v6 + StoreKit 2)

### B.1 Current state

`BillingModule.java` is a **fake store** (`BillingModule.java:35-60`): one hardcoded
`lifetime_unlock` product, `purchase` flips a `SharedPreferences` flag + fake txn id +
`nativeEmit`, `restore` reads the flag. The **contract is already production-shaped** —
this is the key asset. `Billing.can` (products/purchase/restore one-shots + the
`entitlementChanges` streaming Sub), the C++ `BillingModule` (owns stream sinks,
`BillingModule.cpp:62-91`), the JNI `nativeEmit` (`BillingModule.cpp:115-126`), and the
error taxonomy (`UserCancelled/ItemUnavailable/AlreadyOwned/StoreError/Transport`,
`Billing.can` `toBillingError`) **all stay**. The swap is **internal to one Java file +
one Swift file**, exactly as the module docs promise ("The real Play Billing swap is
entirely internal to `BillingModule.java`").

### B.2 Target — Google Play Billing Library v6 (Android)

Rewrite `BillingModule.java`'s three methods against
`com.android.billingclient:billing:6.x`:
- **Init**: build a `BillingClient` with a `PurchasesUpdatedListener` (the async result
  of `launchBillingFlow`) and `enablePendingPurchases()`; `startConnection` lazily on
  first call, with a reconnect-on-`onBillingServiceDisconnected`.
- **`getProducts`**: `queryProductDetailsAsync(QueryProductDetailsParams)` for the SKUs
  (config-driven, see B.4); map each `ProductDetails` →
  `{id,title,description,priceText,priceMicros,currencyCode}` from the
  `OneTimePurchaseOfferDetails`/`SubscriptionOfferDetails` (`formattedPrice`,
  `priceAmountMicros`, `priceCurrencyCode`). Cache `ProductDetails` by id for purchase.
- **`purchase`**: `launchBillingFlow` needs an `Activity` → grab `MainActivity` (the host
  already exposes `MainActivity.appContext()`; add a current-`Activity` accessor or run
  on the UI thread via the activity). The result arrives **asynchronously** on
  `PurchasesUpdatedListener`, not inline — so the callId must be parked until the
  listener fires. **This breaks the synchronous `invoke`→`resolveModule` shape**: we
  store `pendingPurchaseCallId` keyed by productId, and `onPurchasesUpdated` resolves it
  (map `BillingResponseCode.USER_CANCELED` → `user_cancelled`, `ITEM_ALREADY_OWNED` →
  `already_owned`, `ITEM_UNAVAILABLE` → `item_unavailable`, else `StoreError`). On a
  successful `Purchase` in `PURCHASED` state, **acknowledge** it
  (`acknowledgePurchase` for non-consumables) — the fake `acknowledge()` no-op
  (`BillingModule.java`) becomes the real call — then persist the entitlement to
  **EncryptedSharedPreferences via the existing StorageSecure path** (the comment at
  `StorageSecureModule.java:21-24` already names this as "the billing-entitlement
  cache"), resolve the `Purchase`, and `nativeEmit` the entitlement.
- **`restore`**: `queryPurchasesAsync(QueryPurchasesParams INAPP/SUBS)`; for each owned,
  un-acknowledged purchase, acknowledge it; recompute + persist + emit the entitlement.
- **`entitlementChanges`**: unchanged — the C++ `BillingModule` owns the sinks; Java
  pushes via `nativeEmit` on every `onPurchasesUpdated` / restore / reconnect refresh.
  This now also catches **out-of-band changes** (refund, family-share revoke) on the
  next `queryPurchasesAsync`, exactly what the Sub was designed for (`Billing.can`
  "with real Play Billing — an out-of-band refund/lapse").
- **Subscriptions**: v6's `SubscriptionOfferDetails`/`PricingPhase`. Extend `Product`
  with an optional `kind: "oneTime" | "sub"` and (for subs) `period`. **Decision: add
  these as new optional fields** so `lifetime_unlock` apps don't break; Lumen needs
  one-time, so subs can be a follow-up milestone.

Gradle: `implementation 'com.android.billingclient:billing:6.2.1'`.

### B.3 Target — StoreKit 2 (iOS) **[BLOCKED on iOS project]**

`native/host/ios/CanopyHost/BillingModule.swift` implementing a `NativeModule`
(direct C++/ObjC++ bridge, no JNI):
- `getProducts`: `Product.products(for: ids)` (StoreKit2 async/await) → map
  `displayPrice`, `price` (Decimal → micros), `priceFormatStyle.currencyCode`.
- `purchase`: `try await product.purchase()`; on `.success(.verified(transaction))`
  `await transaction.finish()` (the StoreKit2 analog of acknowledge), persist to
  **Keychain** (the iOS twin of EncryptedSharedPreferences), resolve, emit. `.userCancelled`
  → `user_cancelled`; `.pending` → a distinct `pending` code (add `PurchasePending` to
  the taxonomy, B.5).
- `restore`: iterate `Transaction.currentEntitlements`; recompute + persist + emit.
- `entitlementChanges`: a `Task` listening on `Transaction.updates` for the lifetime of
  the subscription, emitting on each verified transaction (refund, renewal). This is the
  iOS analog of `onPurchasesUpdated` and maps cleanly to the streaming Sub.

### B.4 Config & entitlement persistence

- **Product IDs are config, not code.** Add a `billing` block to `native.config.json`
  (read by `tool/.../Config.hs`) with the product id list + which grant the entitlement.
  The host reads it at boot and hands it to `BillingModule` (Android: a static setter
  called from `CanopyHost` boot; iOS: from the boot path). Removes the hardcoded
  `PRODUCT_ID` (`BillingModule.java:62`).
- **Persistence**: reuse `StorageSecure` (EncryptedSharedPreferences / Keychain) rather
  than `BillingModule`'s own prefs file — the entitlement is a forgeable paywall key.
  The fake store's `prefs()`/`persist()` (`BillingModule.java`) become `StorageSecure`
  writes. **Server-side receipt validation** (Play Developer API / App Store Server API)
  is the production-correct path but out of scope here; note it as a milestone (B.5
  risk): client-trusted entitlement is acceptable for v1, server check for v2.

### B.5 Taxonomy additions

Add `PurchasePending` (iOS `.pending`, Android pending-purchase state) to
`Billing.Error` (`Billing.can`) and the `toBillingError` switch; add `ServiceUnavailable`
for `BillingResponseCode.SERVICE_DISCONNECTED/UNAVAILABLE` so a ret​yable transport
error is distinguishable from a real `StoreError`.

---

## PART C — Hardening the native-module ABI

The ABI is sound; these are sharp edges to file before breadth lands.

### C.1 Error taxonomy — make `Rejected` structured

Today native errors are `{"code","message"}` and the sub-code is smuggled in `Rejected
"code:message"` then re-split per-capability (`Billing.codeOf`). This is fragile (a
message containing `:` mis-parses) and uncodified.

- **Change `_NM_error`** (`native-module.js:99-109`) to produce a structured `Rejected`
  carrying `{code, message}` separately. **Decision:** widen `Native.Module.Error`'s
  `Rejected String` to `Rejected { code : String, message : String }` (or add
  `RejectedWith code message`). Update every consumer's `codeOf`-style parse to read
  `.code`. This is a small, mechanical breaking change across the ~6 capability packages;
  do it **before** adding the 12 new capabilities so they're born structured.
- Add standard codes used host-wide: `cancelled`, `module_not_found`, `rejected`,
  `timeout`, `network`, `permission_denied`, `unavailable`, `not_implemented`. Document
  in `Native.Module` so a capability maps a known set.

### C.2 Cancellation correctness

- The streaming `callStreaming` kill-fn already calls `__canopy_cancel`
  (`native-module.js:204-207`); confirm every streaming capability's C++ `cancel()`
  actually drops the sink (Billing does, `BillingModule.cpp:80-89`; StreamingJniModule
  does). **Add a test** (§6) that a killed Sub stops emitting *and* the C++ `streams_`
  map shrinks (no leak).
- One-shot cancel after completion is a benign no-op (`__canopy_resolve` `if (!p)
  return`, `native-module.js:72`; `jniResolve` no-ops on unknown callId). Keep; add a
  unit test for the cancel-race (cancel arriving between worker-complete and
  postToJs-resolve).

### C.3 Threading — codify the invariant + a real worker pool

- The invariant ("runtime only on the JS thread; everything else via `postToJs`") is
  correct but each C++ module spins its own `std::thread().detach()`
  (`EchoModule.cpp:37`, RestoreEngine, Net via OkHttp's pool). **Add a shared
  `canopy::WorkerPool`** (a small fixed-size thread pool in `shared/cpp`) so heavy
  capabilities don't each detach unbounded threads. Modules submit a `std::function`;
  the pool guarantees off-JS-thread execution. Optional but cheap; recommended before
  camera/inference/audio land (each can saturate threads).
- `postToJs` currently posts to the **main Looper** (`CanopyHostJni.cpp:175-178`).
  That's also the UI thread, so heavy JS work blocks the UI. Noted as a host-plan
  concern (move JS to a dedicated thread); here we just ensure module work never lands on
  the JS/main thread (it doesn't — it lands on workers/OkHttp/executors).

### C.4 The StreamingJniModule generalization (the one real ABI extension)

`StreamingJniModule` channels are **method-name keyed** (`StreamingJniModule.h`
`streams_[channel][callId]`). For `Net` WS and Billing we need **per-instance** channels
(many sockets, each its own stream). Two fixes:
- **(chosen)** Let the channel string be **the callId** for per-call streams: Java emits
  `StreamingBridge.emit("Net", callId, json)`; the C++ side already keys sinks by callId
  *within* a channel — we collapse channel==callId for these. Requires teaching
  `StreamingJniModule::invoke` to register a streaming call under a channel == its own
  callId when the method is a "per-call stream" (a second set passed to the ctor:
  `perCallStreamMethods`). Small, additive change to `StreamingJniModule.{h,cpp}`.
- Alternatively keep bespoke C++ for `Net` (BillingModule posture). The generalization is
  preferred so WS/SSE/any future per-connection stream reuses one class.

### C.5 Codegen path — capabilities are scaffolded, not hand-written

This is the highest-leverage hardening: today every module is 3-5 hand-written files
(`.can` effect module, `external/*.js` FFI, `<Name>Module.java`, optionally
`<Name>Module.{h,cpp}`, plus the boot registration line). That's why breadth is 12%.

Add **`canopy-native gen-capability <Name> --methods … --streams …`** to the tool
(`tool/src/Canopy/Native/`):
- New `Capability.hs` (sibling of `Component.hs`): a `data CapabilitySpec` =
  `{ capName, capMethods :: [Method], capStreams :: [Channel], capBacking :: Jni | Cpp |
  Streaming }`, where each `Method`/`Channel` has a name + arg/result field list.
- New `CapabilityCodegen.hs` (sibling of `Codegen.hs`, same pure-string discipline)
  emitting from one spec:
  1. **`<Name>.can`** — an `effect module` skeleton built on `Native.Module` with the
     one-shot `Cmd`s (the `callCmd` type-erasure pattern from `Billing.can`) and, if any
     streams, the `Sub` via `callStreaming` + the full `onEffects/onSelfMsg` plumbing
     (copy Billing's proven manager). Encoders/decoders generated from the field lists.
  2. **`<Name>Module.java`** — the `invoke(method,argsJson,callId)`/`cancel` skeleton
     with a worker executor + resolve/reject helpers (the StorageSecure/Billing
     boilerplate), method stubs to fill in.
  3. **`<Name>Module.swift`** stub (iOS) — the `NativeModule` ObjC++ bridge skeleton.
  4. **The boot registration line** for `CanopyHostJni.cpp` (Jni vs streaming) emitted
     into a `generated/registrations.inc` the boot `#include`s, so adding a capability
     never edits the boot file by hand.
  5. **A mock registration** for `harness/mock-native-modules.js` so unit tests see the
     module immediately.
- Wire `gen-capability` into `tool/app/Main.hs:dispatch` (next to `codegen`/`init`,
  `Main.hs:19-28`).
- Unit-test the generators (pure spec→string) the way `Codegen.hs` is tested.

This turns a new capability from a day of boilerplate into "write the spec + fill the
method bodies", which is the only realistic path to Expo breadth.

### C.6 Blob bridge — generalize beyond Bitmap

The blob bridge is **Bitmap-only** (`CanopyJni.h:130-136`,
`jniBlobPutBitmap`/`jniBlobGetBitmap`). HTTP bodies, audio buffers, video frames, file
contents are **raw bytes**. Add `jniBlobPutBytes(env, byte[])` /
`jniBlobGetBytes(handle) -> byte[]` and a `"bytes"` blob kind alongside `"rgba8"`
(`CanopyBlobs.h`). Java capabilities then move binary in/out of the same process-wide
`globalBlobRegistry()` as int handles — keeping the JSON control plane clean. Required by
Net (response bytes / multipart file parts), Files, Audio, Camera.

---

## PART D — The capability roadmap to Expo level

For each: the `.can` effect-module shape (one-shot `Cmd`s on `NM.call`, live `Sub`s on
`NM.callStreaming`), Android sketch, iOS sketch, priority. **All Android sketches use
`JniModule` (one-shot) or `StreamingJniModule` (Sub) unless noted; all are
scaffoldable by C.5 once it exists.** iOS sketches are **blocked on the iOS project**;
they list the framework + the `NativeModule` shape.

Priorities: **P0** unblocks Lumen / is load-bearing; **P1** expected-by-default Expo
surface; **P2** rounds out parity.

| # | Capability | `.can` shape (module name) | Android | iOS | Pri |
|---|-----------|----------------------------|---------|-----|-----|
| 1 | **HTTP/WS** | re-back `Http`/`WebSocket` (`Net`) | OkHttp `StreamingJniModule` | NSURLSession `NativeModule` | **P0** |
| 2 | **Billing real** | unchanged `Billing` | Play Billing v6 | StoreKit2 | **P0** |
| 3 | **Files** | re-back `canopy/file` + new `Fs` (read/write/list/delete/stat/mkdir, document-dir/cache-dir) | `JniModule`, `java.io`/SAF + bytes-blob | `NativeModule`, `FileManager` | **P0** |
| 4 | **Permissions** | new `Permissions` (`request(perm)`, `status(perm)` one-shots; result `granted/denied/blocked`) | `JniModule` → `ActivityResultContracts.RequestPermission` (needs the activity result plumbing already used by Photos) | `NativeModule` → per-framework `requestAuthorization` | **P0** |
| 5 | **Clipboard** | new `Clipboard` (`getString`/`setString`; reuse web `web-apis-clipboard`'s `.can` types) | `JniModule` → `ClipboardManager` | `NativeModule` → `UIPasteboard` | **P1** |
| 6 | **Haptics** | new `Haptics` (`impact(style)`, `notification(type)`, `selection`) | `JniModule` → `Vibrator`/`VibrationEffect` | `NativeModule` → `UIImpactFeedbackGenerator` | **P1** |
| 7 | **Geolocation** | re-back `web-apis-geolocation` + new `Location` (`getCurrent` one-shot; `watch` **Sub**) | `StreamingJniModule` → `FusedLocationProviderClient` (needs `Permissions` #4) | `NativeModule` → `CLLocationManager` (delegate → emit) | **P1** |
| 8 | **Push (remote)** | new `Push` (`register -> token` one-shot; `notifications` **Sub**; pairs with existing local-only `Notify`) | `StreamingJniModule` → FCM `FirebaseMessaging.getToken` + a `FirebaseMessagingService` emitting via `StreamingBridge` | `NativeModule` → APNs `UNUserNotificationCenter` + `didReceiveRemoteNotification` | **P1** |
| 9 | **Deep / universal links** | new `Links` (`initialUrl` one-shot; `urlOpened` **Sub**) | `StreamingJniModule` → intent-filter `VIEW`/App Links → emit on `onNewIntent` | `NativeModule` → `application(_:open:)` / `continue userActivity` | **P1** |
| 10 | **Camera** | new `Camera` (`capturePhoto`/`startRecording`/`stopRecording` one-shots returning Blob handles; a preview is a *render* component, see note) | `JniModule` + bytes-blob → CameraX `ImageCapture`/`VideoCapture` (perm via #4) | `NativeModule` → `AVCapturePhotoOutput`/`AVCaptureMovieFileOutput` | **P1** |
| 11 | **Audio record/playback** | new `Audio` (`record start/stop -> Blob`; `play(src)`/`pause`/`seek`; `playbackStatus` **Sub**) | `StreamingJniModule` → `MediaRecorder` + `MediaPlayer`/`AudioTrack` | `NativeModule` → `AVAudioRecorder`/`AVAudioPlayer` | **P2** |
| 12 | **Video** | playback is a *render* component (a `RCTVideo` Fabric view) + a `Video` control module (`play/pause/seek`; `status` **Sub**) | host view-manager + `ExoPlayer`; module via `StreamingJniModule` | `AVPlayerViewController`/`AVPlayer` + module | **P2** |
| 13 | **Sensors** | new `Sensors` (`accelerometer`/`gyroscope`/`magnetometer` each a **Sub** with a rate) | `StreamingJniModule` → `SensorManager`/`SensorEventListener` | `NativeModule` → `CMMotionManager` | **P2** |
| 14 | **Biometrics** | new `Biometrics` (`isAvailable`; `authenticate(reason) -> ok/fail/cancel`) | `JniModule` → `androidx.biometric.BiometricPrompt` | `NativeModule` → `LAContext` | **P1** |
| 15 | **Background tasks** | new `Background` (`schedule(task,interval)`; `runWhenAvailable`); inherently host-driven | `JniModule` → `WorkManager` (a `Worker` that re-enters the bundle is a large design; v1 = "register a JS callback id, host wakes the bundle") | `NativeModule` → `BGTaskScheduler` | **P2** |

**Note on render-vs-effect**: camera preview, video surface, and map are **views** (the
render seam, Plan 01/02 territory), not effect modules. They get host view-managers; the
*control* (capture, play/seek) is the effect module here. Flagged so we don't try to
stream pixels through JSON.

**Permissions is a hard dependency** for Geolocation, Camera, Audio, Push — build #4
early. The Android activity-result plumbing already exists (Photos uses it); generalize
it into a `PermissionRequester` helper the capabilities share.

---

## PART E — Web-package reuse map (reuse vs re-back vs new)

The "third walker" reuse thesis extends to effects: a Canopy effect module is a TEA
manager + an FFI file. If the public API is portable, we **re-back** (new FFI twin, same
`.can`); if it's inherently web-only or trivially small, we write **new native-only**.

**Re-back (keep the `.can`, swap/add a native FFI) — highest reuse:**
- `canopy/http` → native FFI twin over `Net` (A.5). **Big win, zero API change.**
- `canopy/websocket` → native FFI twin over `Net`. Reconnect/heartbeat logic is pure
  Canopy, fully reused.
- `canopy/file` (`file/external/file.js`) → native FFI over `Fs`. The `File` type +
  read/decode helpers are portable; the *picker* half overlaps `canopy/photos` (already
  native) — reuse the photos picker for file selection.
- `canopy/storage` (`storage/external/storage.js`, localStorage) → native FFI over the
  existing `StorageSecure` "local" namespace (`StorageSecureModule.java` already has a
  `local` unencrypted store). Reuse the `.can` API directly.
- `canopy/web-apis-geolocation`, `canopy/web-apis-clipboard` → their `.can` type
  surfaces (Position, ClipItem) are good native APIs; re-back the FFI.
- `canopy/server-sent-events` → re-back over `Net` streaming (SSE = a long GET with a
  line parser; the parser is pure Canopy).
- `canopy/analytics`, `canopy/error-tracking` → these are **transport-agnostic** (they
  build events and POST them). Once `Http` is re-backed they **work unchanged** — no
  native module needed. Confirmed: `Analytics.can`/`ErrorTracking.can` are pure event
  shaping (`@docs` show only Property/Config/encode helpers, no FFI socket). **Free wins
  the moment Part A lands.**
- `canopy/graphql` → POST-over-Http; free after Part A.

**New native-only (no meaningful web equivalent, or web API absent on device):**
- `Permissions`, `Haptics`, `Biometrics`, `Push` (remote), `Links`, `Camera`, `Audio`
  record, `Video` control, `Sensors`, `Background`. (Some have thin web cousins —
  `web-apis-notification`, `web-audio` — but the device semantics differ enough that a
  native-only `.can` is cleaner than contorting the web API.)
- `Billing` already native (re-back its *host*, not its `.can`).

**Decision rule recorded:** a capability is **re-back** iff its public `.can` API is
device-portable AND the only web-ness is in the FFI file. Otherwise **new native-only**.

---

## PART F — Testing strategy

Two tiers, both already have harness precedent.

### F.1 Mock-fabric / mock-native-modules unit tests (Node, fast, no device)

`harness/mock-native-modules.js` already models the **exact ABI** including the
worker→JS-thread hop (`jsQueue` + `flushJs()`, `mock-native-modules.js:9-18`). For each
capability:
- Register a mock module (`registerModule(name, methods)`) that mimics the wire contract
  (e.g. mock `Net.request` returns a canned response; mock `Billing.purchase` emits the
  entitlement on the stream).
- Drive the compiled `.can` through `harness/run-compiled.js` / `mini-runtime.js`,
  assert the `Msg`s the app receives, and assert **cancellation** (kill the process →
  no further `Msg`), **streaming** (multiple emits → multiple `Msg`s, terminal tears
  down), and **error mapping** (`reject(code,…)` → the right `Native.Module.Error` /
  `Billing.Error`). The Echo end-to-end test (`harness/run-echo.js`) is the template.
- **HTTP-specific**: mock `Net` to return 200/404/timeout/network and assert the
  re-backed `http-native.js` rebuilds `Response`/`Metadata`/`Error` identically to the
  XHR path. Diff against the web `http.js` behavior using the same `Http.can` decoders.
- **Codegen tests**: pure spec→string (CapabilityCodegen.hs) unit-tested like
  `Codegen.hs` — assert the generated `.can` compiles and the Java skeleton has the
  right method switch.

### F.2 Device E2E (the real backings)

- **HTTP**: a tiny test server (the existing `http/test-app/`) hit from a device build;
  assert GET/POST/multipart/timeout/cancel/progress. WS against an echo server.
- **Billing**: Play **license-testing** accounts + static test SKUs
  (`android.test.purchased`) on Android; **StoreKit Testing** `.storekit` config in the
  iOS scheme. Assert purchase→entitlement Sub fires, restore, acknowledge, user-cancel.
- **Driver dependency**: device E2E needs a working `testID` so a driver can find/tap
  elements — **`testID` is a no-op on both hosts today** (per the audit). E2E for UI-gated
  flows (the paywall purchase tap) is **blocked on the testID/testing plan**; pure-effect
  flows (HTTP, restore, sensors) can be asserted via on-screen `Msg` rendering without a
  driver.
- **iOS device E2E**: blocked on the iOS project.

---

## PART G — Milestones (ordered, with effort)

Ordering rule: HTTP first (unblocks analytics/error-tracking/GraphQL/model-fetch for
free), then the ABI hardening that every later capability rides (taxonomy + codegen +
bytes-blob), then real billing (Lumen paywall), then the P0/P1 capability fan-out.

| # | Milestone | Effort | Deliverables |
|---|-----------|--------|-------------|
| M1 | **Bytes-blob bridge + structured error taxonomy** (C.1, C.6) | **M** | `jniBlobPutBytes/GetBytes` + `"bytes"` kind; `Rejected {code,message}`; standard code set; update existing 6 capabilities' error parse |
| M2 | **HTTP re-backing** (A) | **L** | `NetModule.java` (OkHttp, request/streaming/cancel/timeout/multipart); `http-native.js`; native FFI override in `Build.hs`; registration line; mock + device tests. **Unblocks analytics/error-tracking/graphql/model-fetch for free.** |
| M3 | **WebSocket re-backing + per-call streaming** (A, C.4) | **M** | `Net.wsOpen/wsSend/wsClose`; `websocket-native.js`; `StreamingJniModule` per-call-channel extension; SSE re-back as a bonus |
| M4 | **Capability codegen** (`gen-capability`) (C.5) | **L** | `Capability.hs` + `CapabilityCodegen.hs` (emit `.can`/Java/Swift/registration/mock); wire into `Main.hs`; generator unit tests. **Every later milestone is scaffolded by this.** |
| M5 | **Real Play Billing v6** (B.2, B.4, B.5) | **L** | Rewrite `BillingModule.java`; async-purchase callId parking; acknowledge; config-driven SKUs; StorageSecure persistence; taxonomy additions; license-test E2E |
| M6 | **Permissions + Files + Clipboard + Haptics** (D #3,4,5,6) | **L** | 4 capabilities via codegen; `PermissionRequester` shared helper; re-back `file`/`storage` |
| M7 | **Geolocation + Biometrics + Push + Links** (D #7,8,9,14) | **XL** | 4 capabilities (3 streaming); FCM wiring; intent-filter/App-Links + APNs design; perm dependency on M6 |
| M8 | **Camera + Audio + Video + Sensors** (D #10,11,12,13) | **XL** | CameraX/ExoPlayer/MediaRecorder/SensorManager; the render-side view-managers for camera preview + video surface (coordinate with Plan 01/02); bytes-blob heavy |
| M9 | **StoreKit2 + all iOS `NativeModule` backings** | **XL** | **BLOCKED on iOS project + iOS `CanopyModules` installer + iOS `postToJs`.** Every Swift/ObjC++ `NativeModule` from D + Billing; ports the registration to the iOS boot |
| M10 | **Shared `WorkerPool` + server-side receipt validation + WorkManager background** (C.3, B.4, D #15) | **M** | thread pool; Play/App-Store server receipt check; background-task host design |

---

## PART H — Risks & open questions

1. **Native FFI override mechanism** (A.5) is the riskiest *design* choice: aliasing
   `external/http.js → http-native.js` at bundle time must not break the web build or the
   compiler's FFI inlining (`@canopy-type`/`@name` binding). Validate early with a
   one-function spike. Fallback: polyfill XHR/WS as JSI globals (larger but zero FFI
   forking).
2. **Async purchase parking** (B.2): Play Billing's `launchBillingFlow` result arrives on
   `PurchasesUpdatedListener`, not inline — the synchronous `invoke→resolveModule` shape
   assumes the worker resolves. We must park the callId across the activity round-trip and
   resolve from the listener. Risk: a process-death mid-purchase loses the callId →
   reconcile via `queryPurchasesAsync` on next launch (the Sub catches it).
3. **`postToJs` = main Looper** (C.3): heavy JS blocks the UI. Net/Billing don't run JS
   work off-thread, so they're fine, but Camera/Audio frame callbacks could flood the JS
   thread — rate-limit at the host. Real fix (dedicated JS thread) is a host-plan item.
4. **StreamingJniModule per-call channels** (C.4): collapsing channel==callId is clean but
   needs the C++ change to register a stream under its own callId; verify cancel still
   drops exactly that sink and primes correctly.
5. **Permissions runtime flow** needs the activity-result plumbing generalized; today only
   Photos uses it. If that's tightly coupled to picking, extracting a reusable
   `PermissionRequester` may be more work than estimated.
6. **iOS is blocked across the board** (M9): no project, no `CanopyModules` installer, no
   `postToJs`. Every iOS sketch is design-complete but un-buildable until the host plan
   lands the Xcode project + the iOS twin of the boot/hop. Sequence M9 after that.
7. **Entitlement trust** (B.4): client-persisted entitlement is forgeable. v1 accepts it
   (StorageSecure/Keychain raises the bar); a determined user roots/jailbreaks. Server
   receipt validation (M10) is the real fix; flag for any high-value purchase.
8. **Structured-error migration** (C.1) is a breaking change across 6 packages — do it
   before the 12-capability fan-out (M1, before M4) so new modules are born structured;
   doing it after means re-touching every generated capability.
9. **testID is a no-op** → UI-gated effect E2E (paywall tap) blocked on the testing plan;
   only on-screen-`Msg`-rendered effect flows are device-assertable now (F.2).
10. **WorkManager re-entering the bundle** (D #15): waking the Hermes runtime from a
    background `Worker` to run a JS callback is a large, separate design (a headless
    bundle boot). v1 should scope to host-native background work that emits into a Sub on
    next foreground, not arbitrary JS-in-background.
