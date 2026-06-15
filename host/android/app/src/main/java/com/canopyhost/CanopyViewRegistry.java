// CanopyViewRegistry.java — the host-component registry (Phase 4, Escape-hatch M1).
//
// Maps a custom Fabric tag → a CanopyComponentFactory so third-party native views mount through
// CanopyHost.makeView's DEFAULT case — no edit to the host's hardcoded switch. Built-in tags
// (RCTView/RCTText/…) keep the fast in-switch path; only an UNKNOWN tag consults this registry.
//
// A library registers in its own init (the autolinking-equivalent is M4/M5):
//     CanopyViewRegistry.register("BlurView", ctx -> new BlurView(ctx));
//
// Thread-safe: registration happens at boot, lookup on the JS/UI thread.

package com.canopyhost;

import android.content.Context;
import android.view.View;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

public final class CanopyViewRegistry {

  private static final Map<String, CanopyComponentFactory> FACTORIES = new ConcurrentHashMap<>();

  /** Register a factory for a custom tag (idempotent; last registration wins). */
  public static void register(String tag, CanopyComponentFactory factory) {
    if (tag != null && factory != null) {
      FACTORIES.put(tag, factory);
    }
  }

  /** The factory for a tag, or null if none is registered. */
  public static CanopyComponentFactory factory(String tag) {
    return tag == null ? null : FACTORIES.get(tag);
  }

  /** Create a registered view for `tag`, or null if no factory is registered (caller falls back). */
  public static View create(String tag, Context context) {
    CanopyComponentFactory f = factory(tag);
    return f == null ? null : f.create(context);
  }

  private CanopyViewRegistry() {}
}
