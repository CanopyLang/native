// StorageSecureModule.java — the Android host module behind canopy/storage-secure
// (module "StorageSecure").
//
// Reached via the shared JNI-module mechanism: C++ canopy::JniModule("StorageSecure").invoke(ctx)
// parks ctx.complete keyed by callId and calls this class's static invoke(method, argsJson,
// callId). We do the real work — get/set/remove against SharedPreferences (ns "local") or
// EncryptedSharedPreferences (ns "secure") — on a worker thread, and call
// CanopyHostJni.resolveModule(callId, errJson, resultJson) when done. This mirrors
// ImageModule.java exactly; only the work differs (durable key/value strings, no Bitmap, no
// blob bridge — this capability never touches binary).
//
// Threading: invoke() returns immediately; the work runs on a single-thread executor so the
// JS/main thread is never blocked by disk I/O or the (one-time, expensive) Keystore master-key
// generation EncryptedSharedPreferences does on first open. resolveModule hops the completion
// back onto the JS thread (the C1 worker->JS-thread hop), so it is safe to call from here.
//
// Namespaces:
//   "local"  -> getSharedPreferences("canopy_local",  MODE_PRIVATE)             (unencrypted)
//   "secure" -> EncryptedSharedPreferences("canopy_secure", AES256_SIV/AES256_GCM)  (Keystore)
// The "secure" store is the billing-entitlement cache: the decoded entitlement record is
// written here so the paywall resolves offline and a prefs reader cannot forge it.
//
// Wire contract (must match storage-secure.js / Storage/Secure.can):
//   get    {ns,key}        -> {value:<string>|null}   (absent key => {value:null}, success)
//   set    {ns,key,value}  -> null
//   remove {ns,key}        -> null

package com.canopyhost.modules;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.security.crypto.EncryptedSharedPreferences;
import androidx.security.crypto.MasterKey;

import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONObject;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class StorageSecureModule {

  private static final String LOCAL_PREFS = "canopy_local";
  private static final String SECURE_PREFS = "canopy_secure";

  // One worker so reads/writes serialize against the same prefs files and the first-open
  // Keystore key generation never lands on the JS/main thread.
  private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();

  // The EncryptedSharedPreferences instance is cached after first construction: opening it
  // generates/loads the Keystore-backed master key (tens of ms the first time), so we do it
  // once and reuse. Guarded by the single-thread executor, so no extra synchronization.
  private static SharedPreferences sSecure = null;

  /** Entry point the C++ JniModule calls. Dispatches off the JS thread. */
  public static void invoke(String method, String argsJson, String callId) {
    EXEC.execute(() -> {
      try {
        JSONObject args = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
        switch (method) {
          case "get":    doGet(args, callId); break;
          case "set":    doSet(args, callId); break;
          case "remove": doRemove(args, callId); break;
          default:       reject(callId, "module_not_found", "StorageSecure." + method);
        }
      } catch (Throwable t) {
        reject(callId, "rejected", String.valueOf(t.getMessage()));
      }
    });
  }

  // ---- get ------------------------------------------------------------------

  private static void doGet(JSONObject args, String callId) throws Exception {
    String ns = args.getString("ns");
    String key = args.getString("key");
    SharedPreferences prefs = prefsFor(ns);
    // contains() distinguishes an absent key (-> null) from a stored empty string (-> "").
    String value = prefs.contains(key) ? prefs.getString(key, null) : null;

    JSONObject out = new JSONObject();
    if (value == null) {
      out.put("value", JSONObject.NULL);
    } else {
      out.put("value", value);
    }
    resolve(callId, out.toString());
  }

  // ---- set ------------------------------------------------------------------

  private static void doSet(JSONObject args, String callId) throws Exception {
    String ns = args.getString("ns");
    String key = args.getString("key");
    String value = args.getString("value");
    // commit() (synchronous) so a resolve() the caller sees implies the write is durable —
    // important for the entitlement cache, which the paywall reads back immediately after.
    boolean ok = prefsFor(ns).edit().putString(key, value).commit();
    if (!ok) { reject(callId, "rejected", "prefs commit failed for ns=" + ns); return; }
    resolve(callId, "null");
  }

  // ---- remove (idempotent) --------------------------------------------------

  private static void doRemove(JSONObject args, String callId) throws Exception {
    String ns = args.getString("ns");
    String key = args.getString("key");
    prefsFor(ns).edit().remove(key).commit();  // removing an absent key still succeeds
    resolve(callId, "null");
  }

  // ---- backing-store resolution ---------------------------------------------

  private static SharedPreferences prefsFor(String ns) throws Exception {
    Context ctx = context();
    if ("secure".equals(ns)) {
      return securePrefs(ctx);
    }
    // default + "local"
    return ctx.getSharedPreferences(LOCAL_PREFS, Context.MODE_PRIVATE);
  }

  private static SharedPreferences securePrefs(Context ctx) throws Exception {
    if (sSecure != null) { return sSecure; }
    MasterKey masterKey = new MasterKey.Builder(ctx)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build();
    sSecure = EncryptedSharedPreferences.create(
        ctx,
        SECURE_PREFS,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM);
    return sSecure;
  }

  private static Context context() {
    Context c = MainActivity.appContext();
    if (c == null) { throw new IllegalStateException("StorageSecure: no app context"); }
    // EncryptedSharedPreferences keys live in the Android Keystore (device-bound), so the
    // application context is the right, process-lifetime owner.
    return c.getApplicationContext();
  }

  // ---- resolve / reject (identical to ImageModule) --------------------------

  private static void resolve(String callId, String resultJson) {
    CanopyHostJni.resolveModule(callId, "", resultJson);  // "" err => success
  }

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

  private StorageSecureModule() {}
}
