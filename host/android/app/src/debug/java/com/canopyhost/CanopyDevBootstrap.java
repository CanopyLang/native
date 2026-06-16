// CanopyDevBootstrap.java — DEV-6: the debug-only auto-start for the dev-loop WS client.
//
// A no-op ContentProvider exists for ONE reason: Android instantiates every declared provider at
// process start (before Application.onCreate), which gives us a hook to kick off CanopyDevClient
// with NO edit to the production MainActivity/Application. This file is in src/debug, so it (and
// the provider declaration in the debug manifest overlay) exist only in the DEBUG build.
//
// The dev-server endpoint (host:port) is resolved, in priority order, from:
//   1. the `debug.canopy.devhost` system property  (adb shell setprop debug.canopy.devhost <h:p>)
//   2. the CANOPY_DEV_HOST <meta-data> in the manifest  (baked by `canopy-native run`)
//   3. the default 10.0.2.2:8099  (the emulator's host-loopback alias + the dev server's port)
// so a plain `canopy-native run` against an emulator needs no configuration, while a LAN/USB box
// overrides via the meta-data (DEV-7) or a one-line setprop.

package com.canopyhost;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;

/** Debug-only zero-row ContentProvider whose sole job is to start the dev client at process boot. */
public final class CanopyDevBootstrap extends ContentProvider {

  private static volatile CanopyDevClient client;

  @Override
  public boolean onCreate() {
    String devHost = resolveDevHost();
    try {
      client = CanopyDevClient.start(devHost);
      // DEV-11: register the active client so the red-box "Reload" button (CanopyHostJni.reload, which
      // the debug build redirects) can recover to the last-known-good bundle after a failed reload.
      CanopyDevClient.setActive(client);
    } catch (Throwable t) {
      // Never let a dev-tooling failure block app boot — log and move on.
      Log.w(CanopyDevClient.TAG, "dev client failed to start (ignored): " + t);
    }
    return true;
  }

  /** Resolve CANOPY_DEV_HOST: system property → manifest meta-data → null (CanopyDevClient then
   *  falls back to its built-in 10.0.2.2:8099 default). */
  private String resolveDevHost() {
    // 1. a live override (no rebuild needed): `adb shell setprop debug.canopy.devhost 192.168.1.20:8099`
    String prop = systemProperty("debug.canopy.devhost");
    if (prop != null && !prop.isEmpty()) return prop;
    // 2. the value baked by `canopy-native run` into the manifest.
    try {
      ApplicationInfo ai = getContext().getPackageManager()
          .getApplicationInfo(getContext().getPackageName(), PackageManager.GET_META_DATA);
      if (ai.metaData != null) {
        Object v = ai.metaData.get("CANOPY_DEV_HOST");
        if (v != null) return String.valueOf(v);
      }
    } catch (Throwable ignored) { /* no meta-data — fall through */ }
    return null; // CanopyDevClient.start(null) → its default host:port
  }

  /** Read a system property via the hidden android.os.SystemProperties (reflection; debug-only). */
  private static String systemProperty(String key) {
    try {
      Class<?> sp = Class.forName("android.os.SystemProperties");
      return (String) sp.getMethod("get", String.class).invoke(null, key);
    } catch (Throwable t) {
      return null;
    }
  }

  // ---- ContentProvider stubs: this provider serves no data --------------------------------------

  @Override public Cursor query(Uri u, String[] p, String s, String[] a, String o) { return null; }
  @Override public String getType(Uri u) { return null; }
  @Override public Uri insert(Uri u, ContentValues v) { return null; }
  @Override public int delete(Uri u, String s, String[] a) { return 0; }
  @Override public int update(Uri u, ContentValues v, String s, String[] a) { return 0; }
  @Override public Bundle call(String method, String arg, Bundle extras) { return null; }
}
