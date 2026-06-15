// HttpModule.java — the Android host module behind Native.Http (module "Http").
//
// Reached via the shared JNI-module mechanism: C++ canopy::JniModule("Http").invoke(ctx) parks
// ctx.complete keyed by callId and calls this class's static invoke(method, argsJson, callId).
// We perform the real HTTP request (HttpURLConnection) on a worker thread and call
// CanopyHostJni.resolveModule(callId, errJson, resultJson) when done — the C1 worker->JS-thread
// hop. This is a fetch-equivalent: the network round-trip resolves the caller's Task exactly
// like the other one-shot capabilities (StorageSecure/Album/Photos), only the work differs.
//
// Wire contract (must match Native/Http.can):
//   request {method, url, headers:{k:v}, body}  ->  {status:Int, body:String, headers:{k:v}}
// Non-2xx is NOT an error — it resolves with the status + the error-stream body (RN/fetch
// semantics: only transport failures reject). Threading: invoke() returns immediately; the
// request runs on a small fixed pool so the JS/main thread is never blocked on the network.

package com.canopyhost.modules;

import com.canopyhost.CanopyHostJni;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;

public final class HttpModule {

  private static final ExecutorService EXEC = Executors.newFixedThreadPool(4, new ThreadFactory() {
    @Override public Thread newThread(Runnable r) {
      Thread t = new Thread(r, "canopy-http");
      t.setDaemon(true);
      return t;
    }
  });

  /** Entry point the C++ JniModule calls. Dispatches off the JS thread. */
  public static void invoke(String method, String argsJson, String callId) {
    EXEC.execute(() -> {
      if (!"request".equals(method)) { reject(callId, "module_not_found", "Http." + method); return; }
      HttpURLConnection conn = null;
      try {
        JSONObject a = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
        String urlStr = a.getString("url");
        String httpMethod = a.optString("method", "GET").toUpperCase();

        conn = (HttpURLConnection) new URL(urlStr).openConnection();
        conn.setRequestMethod(httpMethod);
        conn.setConnectTimeout(20000);
        conn.setReadTimeout(30000);
        conn.setInstanceFollowRedirects(true);

        JSONObject headers = a.optJSONObject("headers");
        if (headers != null) {
          for (Iterator<String> it = headers.keys(); it.hasNext();) {
            String k = it.next();
            conn.setRequestProperty(k, headers.optString(k));
          }
        }

        String body = a.optString("body", "");
        if (!body.isEmpty() && !"GET".equals(httpMethod) && !"HEAD".equals(httpMethod)) {
          conn.setDoOutput(true);
          byte[] payload = body.getBytes("UTF-8");
          try (OutputStream os = conn.getOutputStream()) { os.write(payload); }
        }

        int status = conn.getResponseCode();
        InputStream in = (status >= 200 && status < 400) ? conn.getInputStream() : conn.getErrorStream();
        String respBody = in != null ? readAll(in) : "";

        JSONObject result = new JSONObject();
        result.put("status", status);
        result.put("body", respBody);
        result.put("headers", responseHeaders(conn));
        CanopyHostJni.resolveModule(callId, "", result.toString());
      } catch (Throwable t) {
        reject(callId, "rejected", t.getClass().getSimpleName()
            + (t.getMessage() != null ? ": " + t.getMessage() : ""));
      } finally {
        if (conn != null) conn.disconnect();
      }
    });
  }

  private static JSONObject responseHeaders(HttpURLConnection conn) {
    JSONObject h = new JSONObject();
    try {
      for (Map.Entry<String, List<String>> e : conn.getHeaderFields().entrySet()) {
        if (e.getKey() == null || e.getValue() == null || e.getValue().isEmpty()) continue;
        h.put(e.getKey().toLowerCase(), e.getValue().get(0));
      }
    } catch (Exception ignored) {}
    return h;
  }

  private static String readAll(InputStream in) throws Exception {
    ByteArrayOutputStream out = new ByteArrayOutputStream(8192);
    byte[] buf = new byte[8192];
    int n;
    try (InputStream i = new BufferedInputStream(in)) {
      while ((n = i.read(buf)) != -1) out.write(buf, 0, n);
    }
    return out.toString("UTF-8");
  }

  // ---- resolve / reject (identical to StorageSecureModule) ------------------

  private static void reject(String callId, String code, String message) {
    try {
      JSONObject err = new JSONObject();
      err.put("code", code);
      err.put("message", message == null ? "" : message);
      CanopyHostJni.resolveModule(callId, err.toString(), "");
    } catch (Exception e) {
      CanopyHostJni.resolveModule(callId, "{\"code\":\"rejected\"}", "");
    }
  }

  private HttpModule() {}
}
