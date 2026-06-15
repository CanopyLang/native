// CanopyDevClient.java — DEV-6: the host's debug-only dev-loop WebSocket client.
//
// This file lives in src/debug/ so it is compiled into the DEBUG variant ONLY — a release build
// never sees it (no okhttp, no socket, no cleartext path in the shipped APK). It is the device
// half of the Metro-class fast-refresh loop: it connects to the DEV-5 dev server
// (tool/canopy-dev-server.js), receives pushed bundles over a WebSocket, and turns them into the
// DEV-4 in-process reload (CanopyHost.reload → nativeReload: re-eval on the SAME Hermes runtime,
// state-preserving), while compile errors become a CanopyRedBox.
//
//   src/Main.can edit ─▶ dev server build+push ─▶ {type:"reload",bundle} ─▶ CanopyDevClient
//                                                                              │
//                                              reload(bundle) ──▶ in-process state-preserving reload
//
// WIRE PROTOCOL (one JSON object per WS text frame, server → host; mirror of canopy-dev-server.js):
//   {"type":"hello",    "buildId":<string|null>, "runtimeVersion":<string>}   on connect
//   {"type":"building", "buildId":<prev|null>}                                rebuild started
//   {"type":"reload",   "buildId":<sha256>, "bundle":<js>, "map":<json|null>} rebuild OK + changed
//   {"type":"nochange", "buildId":<sha256>}                                   rebuild OK, same buildId
//   {"type":"error",    "report":<compiler stderr/stdout>}                    rebuild FAILED
//
// CONNECTION URL: from the CANOPY_DEV_HOST app-meta / env baked by `canopy-native run`
//   (tool dev-client glue) — host:port of the dev server, reached via `adb reverse tcp:<port>`
//   (USB/emulator) or the box's LAN IP (DEV-7). Defaults to 10.0.2.2:8099 (the emulator's alias
//   for the host loopback) so a bare `canopy-native run` against an emulator works with no config.
//
// SECURITY: the dev server speaks cleartext ws:// (no TLS in the loop). We only ever dial a host
// on the LOCALHOST / private-LAN allowlist (isCleartextAllowed) — a public hostname is refused, so
// even a mis-baked CANOPY_DEV_HOST can't turn the debug build into an open cleartext sink. The
// network_security_config (src/debug/res/xml) scopes cleartext to exactly these domains; this
// allowlist is the belt to that config's braces. Release is unaffected — this whole file is gone.
//
// TESTABILITY: every routing/parse decision is a PURE static method (classify, parseFrame,
// isCleartextAllowed, backoffMs, deriveWsUrl) so tool's CanopyDevClientTest exercises the message
// handling device-free on the JVM. The okhttp WebSocket + reconnect loop are the thin I/O shell.

package com.canopyhost;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import org.json.JSONObject;

import java.lang.reflect.Method;
import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

/** Debug-only dev-loop WebSocket client (DEV-6). Connects to the DEV-5 dev server, applies pushed
 *  bundles via the DEV-4 in-process reload, and surfaces build errors as a red-box. */
public final class CanopyDevClient {

  static final String TAG = "CanopyDev";

  /** Default endpoint: the Android emulator aliases the host loopback as 10.0.2.2; the dev server
   *  listens on 8099. A USB device uses `adb reverse tcp:8099` so 127.0.0.1 also resolves; a LAN
   *  box bakes its own IP into CANOPY_DEV_HOST (DEV-7). */
  static final String DEFAULT_HOST = "10.0.2.2";
  static final int DEFAULT_PORT = 8099;

  // Reconnect backoff: a small floor, doubling to a ceiling, so a downed/未started dev server is
  // retried politely (no tight spin) and a server that comes up is picked up within a few seconds.
  static final long BACKOFF_MIN_MS = 500L;
  static final long BACKOFF_MAX_MS = 10_000L;

  // ---- action classification (PURE — unit-tested) -------------------------------------------

  /** What a received frame asks the host to do. */
  enum Action { HELLO, BUILDING, RELOAD, NOCHANGE, ERROR, IGNORE }

  /** A parsed dev-server frame: the action + the payload fields the host acts on (bundle/report/
   *  buildId). Immutable; produced by parseFrame, consumed by the I/O shell + the tests. */
  static final class Frame {
    final Action action;
    final String buildId;   // hello / building / reload / nochange
    final String bundle;    // reload only (the JS source to re-eval)
    final String report;    // error only (the compiler output)
    Frame(Action a, String buildId, String bundle, String report) {
      this.action = a; this.buildId = buildId; this.bundle = bundle; this.report = report;
    }
  }

  /** Map a frame's "type" string to an Action. An unknown/missing type is IGNORE (forward-compat:
   *  a newer server type never crashes an older host — it is logged and dropped). */
  static Action classify(String type) {
    if (type == null) return Action.IGNORE;
    switch (type) {
      case "hello":    return Action.HELLO;
      case "building": return Action.BUILDING;
      case "reload":   return Action.RELOAD;
      case "nochange": return Action.NOCHANGE;
      case "error":    return Action.ERROR;
      default:         return Action.IGNORE;
    }
  }

  /** Parse a raw WS text frame into a Frame. Malformed JSON, or a reload that carries no bundle,
   *  degrades to an IGNORE frame (never throws) so a stray/partial message can't kill the loop. */
  static Frame parseFrame(String text) {
    if (text == null) return new Frame(Action.IGNORE, null, null, null);
    JSONObject o;
    try { o = new JSONObject(text); }
    catch (Exception e) { return new Frame(Action.IGNORE, null, null, null); }
    Action a = classify(o.optString("type", null));
    String buildId = o.has("buildId") && !o.isNull("buildId") ? o.optString("buildId", null) : null;
    if (a == Action.RELOAD) {
      String bundle = o.isNull("bundle") ? null : o.optString("bundle", null);
      // A reload with no bundle bytes is meaningless — treat it as ignore rather than re-eval "".
      if (bundle == null || bundle.isEmpty()) return new Frame(Action.IGNORE, buildId, null, null);
      return new Frame(Action.RELOAD, buildId, bundle, null);
    }
    if (a == Action.ERROR) {
      String report = o.isNull("report") ? "" : o.optString("report", "");
      return new Frame(Action.ERROR, null, null, report);
    }
    return new Frame(a, buildId, null, null);
  }

  // ---- cleartext host allowlist (PURE — unit-tested) ----------------------------------------

  /** True iff `host` is a loopback or RFC-1918 / link-local LAN address we permit cleartext ws://
   *  to. A public hostname/IP is refused — the dev loop is for a machine on the same desk/LAN, and
   *  refusing anything else keeps a mis-baked CANOPY_DEV_HOST from opening a cleartext channel to
   *  the internet. (The network_security_config enforces the same set at the platform layer.) */
  static boolean isCleartextAllowed(String host) {
    if (host == null) return false;
    String h = host.trim().toLowerCase(java.util.Locale.ROOT);
    if (h.isEmpty()) return false;
    // Strip an IPv6 bracket form ([::1]) if present.
    if (h.startsWith("[") && h.endsWith("]")) h = h.substring(1, h.length() - 1);
    if (h.equals("localhost")) return true;
    if (h.equals("::1")) return true;                 // IPv6 loopback
    if (h.equals("10.0.2.2") || h.equals("10.0.3.2")) return true; // emulator host alias (AVD / Genymotion)
    // IPv4 dotted-quad ranges.
    int[] q = parseIpv4(h);
    if (q == null) return false;                      // a non-IPv4, non-allowlisted name → refuse
    if (q[0] == 127) return true;                     // 127.0.0.0/8 loopback
    if (q[0] == 10) return true;                      // 10.0.0.0/8 private
    if (q[0] == 192 && q[1] == 168) return true;      // 192.168.0.0/16 private
    if (q[0] == 172 && q[1] >= 16 && q[1] <= 31) return true; // 172.16.0.0/12 private
    if (q[0] == 169 && q[1] == 254) return true;      // 169.254.0.0/16 link-local
    return false;
  }

  /** Parse a dotted-quad IPv4 string into its four octets, or null if it is not a valid IPv4. */
  static int[] parseIpv4(String h) {
    String[] parts = h.split("\\.", -1);
    if (parts.length != 4) return null;
    int[] q = new int[4];
    for (int i = 0; i < 4; i++) {
      if (parts[i].isEmpty() || parts[i].length() > 3) return null;
      int v = 0;
      for (int j = 0; j < parts[i].length(); j++) {
        char c = parts[i].charAt(j);
        if (c < '0' || c > '9') return null;
        v = v * 10 + (c - '0');
      }
      if (v > 255) return null;
      q[i] = v;
    }
    return q;
  }

  // ---- reconnect backoff schedule (PURE — unit-tested) --------------------------------------

  /** Exponential backoff with a floor + ceiling: attempt 0 waits MIN, doubling per failed attempt,
   *  capped at MAX. Deterministic (no jitter) so the test can pin the schedule. */
  static long backoffMs(int attempt) {
    if (attempt <= 0) return BACKOFF_MIN_MS;
    long ms = BACKOFF_MIN_MS;
    for (int i = 0; i < attempt && ms < BACKOFF_MAX_MS; i++) ms <<= 1;
    return Math.min(ms, BACKOFF_MAX_MS);
  }

  // ---- URL derivation (PURE — unit-tested) --------------------------------------------------

  /** Build the ws:// URL to dial from a CANOPY_DEV_HOST value. Accepts "host", "host:port", or a
   *  full "ws://host:port" / "http://host:port"; a missing scheme/port fills in ws:// + 8099.
   *  Returns null when the resolved host fails the cleartext allowlist (refuse to dial it). */
  static String deriveWsUrl(String devHost) {
    String spec = (devHost == null || devHost.trim().isEmpty())
        ? (DEFAULT_HOST + ":" + DEFAULT_PORT) : devHost.trim();
    // Normalise an http(s)/ws(s) scheme down to host[:port].
    String noScheme = spec;
    int s = noScheme.indexOf("://");
    if (s >= 0) noScheme = noScheme.substring(s + 3);
    // Drop any trailing path.
    int slash = noScheme.indexOf('/');
    if (slash >= 0) noScheme = noScheme.substring(0, slash);

    String host;
    int port = DEFAULT_PORT;
    if (noScheme.startsWith("[")) {                   // bracketed IPv6: [::1]:8099
      int close = noScheme.indexOf(']');
      if (close < 0) return null;
      host = noScheme.substring(1, close);
      int colon = noScheme.indexOf(':', close);
      if (colon >= 0) { try { port = Integer.parseInt(noScheme.substring(colon + 1)); } catch (Exception e) { return null; } }
    } else {
      int colon = noScheme.lastIndexOf(':');
      if (colon >= 0 && noScheme.indexOf(':') == colon) { // exactly one colon → host:port
        host = noScheme.substring(0, colon);
        try { port = Integer.parseInt(noScheme.substring(colon + 1)); } catch (Exception e) { return null; }
      } else {
        host = noScheme;                               // bare host (or an unbracketed IPv6 → refused below)
      }
    }
    if (port <= 0 || port > 65535) return null;
    if (!isCleartextAllowed(host)) return null;
    boolean v6 = host.indexOf(':') >= 0;               // raw IPv6 literal needs brackets in a URL
    return "ws://" + (v6 ? "[" + host + "]" : host) + ":" + port + "/";
  }

  // ---- the I/O shell: okhttp WebSocket + auto-reconnect -------------------------------------

  private final String url;
  private final OkHttpClient http;
  private final Handler main = new Handler(Looper.getMainLooper());
  private volatile boolean stopped = false;
  private int attempt = 0;
  private WebSocket socket;
  private String lastBuildId;

  private CanopyDevClient(String url) {
    this.url = url;
    // No read timeout (a WS is idle between pushes); a short connect timeout so a downed server
    // fails fast into the reconnect backoff. okhttp pings keep the socket warm through NAT idle.
    this.http = new OkHttpClient.Builder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(15, TimeUnit.SECONDS)
        .build();
  }

  /** Start the dev client for `devHost` (the CANOPY_DEV_HOST value). No-op (with a log) when the
   *  host is missing/disallowed so a debug build with no dev server attached just runs normally.
   *  Idempotent: a second start() is ignored. Returns the client, or null when nothing was started. */
  public static CanopyDevClient start(String devHost) {
    String url = deriveWsUrl(devHost);
    if (url == null) {
      Log.i(TAG, "dev client not started — CANOPY_DEV_HOST '" + devHost
          + "' is missing or not on the cleartext allowlist (localhost/LAN only)");
      return null;
    }
    CanopyDevClient c = new CanopyDevClient(url);
    c.connect();
    Log.i(TAG, "dev client connecting to " + url);
    return c;
  }

  /** Stop the client and tear down the socket; no further reconnects. */
  public void stop() {
    stopped = true;
    main.removeCallbacksAndMessages(null);
    WebSocket ws = socket;
    if (ws != null) { try { ws.close(1000, "client stop"); } catch (Exception ignored) {} }
    socket = null;
  }

  private void connect() {
    if (stopped) return;
    Request req = new Request.Builder().url(url).build();
    socket = http.newWebSocket(req, new Listener());
  }

  /** Schedule a reconnect after the current backoff, then advance the backoff. */
  private void scheduleReconnect() {
    if (stopped) return;
    long delay = backoffMs(attempt);
    attempt++;
    Log.i(TAG, "dev server unreachable — retrying in " + delay + "ms (attempt " + attempt + ")");
    main.postDelayed(this::connect, delay);
  }

  /** Apply one parsed frame. Runs on the okhttp reader thread for non-UI bookkeeping, but every
   *  host effect (reload / red-box) is marshalled to the main thread where the runtime + views live. */
  void handle(Frame f) {
    switch (f.action) {
      case HELLO:
        lastBuildId = f.buildId;
        Log.i(TAG, "connected — server buildId=" + f.buildId);
        break;
      case BUILDING:
        Log.i(TAG, "rebuilding…");
        break;
      case RELOAD:
        if (f.buildId != null && f.buildId.equals(lastBuildId)) {
          // The server only sends a fresh `reload` on a changed buildId, but guard anyway so a
          // duplicate delivery never re-evals the identical bundle (a wasted reload flicker).
          Log.i(TAG, "reload buildId unchanged — skipping");
          break;
        }
        lastBuildId = f.buildId;
        Log.i(TAG, "reload → in-process re-eval (buildId="
            + (f.buildId == null ? "?" : f.buildId.length() >= 12 ? f.buildId.substring(0, 12) : f.buildId) + ")");
        applyReload(f.bundle);
        break;
      case NOCHANGE:
        Log.i(TAG, "no change (buildId unchanged) — server short-circuited");
        break;
      case ERROR:
        Log.w(TAG, "build FAILED:\n" + f.report);
        showRedBox(f.report);
        break;
      case IGNORE:
      default:
        break;
    }
  }

  /** Drive the DEV-4 in-process reload with the pushed JS bundle. The reload entry is the static
   *  native CanopyHost.nativeReload (it re-evals on the live runtime + reuses the cached root via
   *  the C++ g_runtime/g_rootTag — no host instance needed). We reach it on the MAIN thread (where
   *  every __fabric_* mount + the runtime live) via reflection, so this debug-only tool needs no
   *  production seam in CanopyHost/CanopyHostJni (which a release build must not carry). A bad
   *  bundle is caught by the C++ reload guard → a fatal red-box, never a process crash. */
  private void applyReload(final String bundleJs) {
    main.post(() -> {
      try {
        Method m = CanopyHost.class.getDeclaredMethod("nativeReload", String.class);
        m.setAccessible(true);
        m.invoke(null, bundleJs);
      } catch (Throwable t) {
        Log.e(TAG, "in-process reload failed (" + t + ") — falling back to red-box", t);
        showRedBox("Hot reload failed to apply:\n" + t);
      }
    });
  }

  /** Surface a build/compile error as the dev red-box (non-fatal: the prior good tree stays up
   *  underneath, so dismissing returns to the last working program — DEV-11's recovery posture). */
  private void showRedBox(final String report) {
    main.post(() -> {
      Activity a = MainActivity.current();
      if (a != null) {
        CanopyRedBox.show(a, "Build failed", report == null ? "(no report)" : report,
            /*dev=*/true, /*fatal=*/false);
      }
    });
  }

  /** okhttp listener: bridges socket lifecycle → reconnect, and text frames → handle(parseFrame). */
  private final class Listener extends WebSocketListener {
    @Override public void onOpen(WebSocket ws, Response response) {
      attempt = 0; // a successful connect resets the backoff
      Log.i(TAG, "dev socket open");
    }
    @Override public void onMessage(WebSocket ws, String text) {
      try { handle(parseFrame(text)); }
      catch (Throwable t) { Log.e(TAG, "frame handling error (ignored): " + t, t); }
    }
    @Override public void onClosing(WebSocket ws, int code, String reason) {
      try { ws.close(1000, null); } catch (Exception ignored) {}
    }
    @Override public void onClosed(WebSocket ws, int code, String reason) {
      Log.i(TAG, "dev socket closed (" + code + ") " + reason);
      if (!stopped) scheduleReconnect();
    }
    @Override public void onFailure(WebSocket ws, Throwable t, Response response) {
      Log.i(TAG, "dev socket failure: " + t.getMessage());
      if (!stopped) scheduleReconnect();
    }
  }
}
