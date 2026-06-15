// CanopyDevClientTest.java — DEV-6 device-free unit test for the dev-loop WS client's MESSAGE
// HANDLING (the pure routing/parse/allowlist/backoff logic), run on the host JVM via
// `:app:testDebugUnitTest` (no device, no emulator, no real dev server).
//
// CanopyDevClient lives in src/debug, so it is on the classpath of the DEBUG unit-test variant.
// The okhttp WebSocket + reconnect loop are I/O glue we don't unit-test here; what IS the
// load-bearing contract — and what a regression would silently break — is the pure decision layer:
//
//   (a) parseFrame/classify  — every wire `type` maps to the right Action, malformed/partial JSON
//                              degrades to IGNORE (never throws), and a reload's bundle is extracted;
//   (b) isCleartextAllowed   — cleartext ws:// is permitted ONLY to localhost / RFC-1918 LAN, and a
//                              public host is refused (the security contract of the debug loop);
//   (c) deriveWsUrl          — CANOPY_DEV_HOST (host / host:port / ws://… ) → a ws:// URL, with the
//                              allowlist enforced (a disallowed host yields null = "don't dial");
//   (d) backoffMs            — the reconnect schedule floors/doubles/ceilings deterministically.
//
// These pin the exact behaviour the on-device client relies on, so the integration (okhttp +
// CanopyHost.nativeReload + CanopyRedBox) only has to be the thin shell it is.

package com.canopyhost;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public final class CanopyDevClientTest {

  // ---- (a) parseFrame / classify -------------------------------------------------------------

  @Test public void classify_mapsEveryKnownType() {
    assertEquals(CanopyDevClient.Action.HELLO,    CanopyDevClient.classify("hello"));
    assertEquals(CanopyDevClient.Action.BUILDING, CanopyDevClient.classify("building"));
    assertEquals(CanopyDevClient.Action.RELOAD,   CanopyDevClient.classify("reload"));
    assertEquals(CanopyDevClient.Action.NOCHANGE, CanopyDevClient.classify("nochange"));
    assertEquals(CanopyDevClient.Action.ERROR,    CanopyDevClient.classify("error"));
  }

  @Test public void classify_unknownOrNullIsIgnore() {
    assertEquals(CanopyDevClient.Action.IGNORE, CanopyDevClient.classify("future-type"));
    assertEquals(CanopyDevClient.Action.IGNORE, CanopyDevClient.classify(null));
  }

  @Test public void parseFrame_helloCarriesBuildId() {
    CanopyDevClient.Frame f = CanopyDevClient.parseFrame(
        "{\"type\":\"hello\",\"buildId\":\"abc123\",\"runtimeVersion\":\"7\"}");
    assertEquals(CanopyDevClient.Action.HELLO, f.action);
    assertEquals("abc123", f.buildId);
  }

  @Test public void parseFrame_helloNullBuildIdIsNull() {
    CanopyDevClient.Frame f = CanopyDevClient.parseFrame(
        "{\"type\":\"hello\",\"buildId\":null,\"runtimeVersion\":\"7\"}");
    assertEquals(CanopyDevClient.Action.HELLO, f.action);
    assertNull("a JSON null buildId decodes to a Java null, not the string \"null\"", f.buildId);
  }

  @Test public void parseFrame_reloadExtractsBundleAndBuildId() {
    CanopyDevClient.Frame f = CanopyDevClient.parseFrame(
        "{\"type\":\"reload\",\"buildId\":\"deadbeef\",\"bundle\":\"(function(){})()\",\"map\":null}");
    assertEquals(CanopyDevClient.Action.RELOAD, f.action);
    assertEquals("deadbeef", f.buildId);
    assertEquals("(function(){})()", f.bundle);
  }

  @Test public void parseFrame_reloadWithoutBundleDowngradesToIgnore() {
    // A reload frame missing/empty bundle bytes must NOT re-eval "" — it degrades to IGNORE.
    CanopyDevClient.Frame f = CanopyDevClient.parseFrame("{\"type\":\"reload\",\"buildId\":\"x\"}");
    assertEquals(CanopyDevClient.Action.IGNORE, f.action);
    CanopyDevClient.Frame g = CanopyDevClient.parseFrame(
        "{\"type\":\"reload\",\"buildId\":\"x\",\"bundle\":\"\"}");
    assertEquals(CanopyDevClient.Action.IGNORE, g.action);
  }

  @Test public void parseFrame_errorCarriesReport() {
    CanopyDevClient.Frame f = CanopyDevClient.parseFrame(
        "{\"type\":\"error\",\"report\":\"TYPE ERROR at Main.can:3\"}");
    assertEquals(CanopyDevClient.Action.ERROR, f.action);
    assertEquals("TYPE ERROR at Main.can:3", f.report);
  }

  @Test public void parseFrame_nochangeIsClassifiedNoBundle() {
    CanopyDevClient.Frame f = CanopyDevClient.parseFrame("{\"type\":\"nochange\",\"buildId\":\"same\"}");
    assertEquals(CanopyDevClient.Action.NOCHANGE, f.action);
    assertEquals("same", f.buildId);
    assertNull(f.bundle);
  }

  @Test public void parseFrame_malformedJsonIsIgnoreNotThrow() {
    assertEquals(CanopyDevClient.Action.IGNORE, CanopyDevClient.parseFrame("not json at all").action);
    assertEquals(CanopyDevClient.Action.IGNORE, CanopyDevClient.parseFrame("{\"type\":").action);
    assertEquals(CanopyDevClient.Action.IGNORE, CanopyDevClient.parseFrame(null).action);
  }

  // ---- (b) isCleartextAllowed (the security allowlist) ---------------------------------------

  @Test public void cleartext_allowsLoopbackAndEmulatorAlias() {
    assertTrue(CanopyDevClient.isCleartextAllowed("localhost"));
    assertTrue(CanopyDevClient.isCleartextAllowed("127.0.0.1"));
    assertTrue(CanopyDevClient.isCleartextAllowed("127.5.5.5"));      // 127.0.0.0/8
    assertTrue(CanopyDevClient.isCleartextAllowed("::1"));            // IPv6 loopback
    assertTrue(CanopyDevClient.isCleartextAllowed("[::1]"));          // bracketed form
    assertTrue(CanopyDevClient.isCleartextAllowed("10.0.2.2"));       // AVD host alias
  }

  @Test public void cleartext_allowsRfc1918Lan() {
    assertTrue(CanopyDevClient.isCleartextAllowed("10.0.0.5"));       // 10/8
    assertTrue(CanopyDevClient.isCleartextAllowed("192.168.1.20"));   // 192.168/16
    assertTrue(CanopyDevClient.isCleartextAllowed("172.16.0.1"));     // 172.16/12 low
    assertTrue(CanopyDevClient.isCleartextAllowed("172.31.255.254")); // 172.16/12 high
    assertTrue(CanopyDevClient.isCleartextAllowed("169.254.10.10"));  // link-local
  }

  @Test public void cleartext_refusesPublicAndOutOfRange() {
    assertFalse(CanopyDevClient.isCleartextAllowed("8.8.8.8"));        // public
    assertFalse(CanopyDevClient.isCleartextAllowed("172.15.0.1"));     // just below 172.16/12
    assertFalse(CanopyDevClient.isCleartextAllowed("172.32.0.1"));     // just above 172.16/12
    assertFalse(CanopyDevClient.isCleartextAllowed("172.0.0.1"));      // 172.x outside the private block
    assertFalse(CanopyDevClient.isCleartextAllowed("example.com"));    // a public hostname
    assertFalse(CanopyDevClient.isCleartextAllowed("evil.attacker.io"));
    assertFalse(CanopyDevClient.isCleartextAllowed(null));
    assertFalse(CanopyDevClient.isCleartextAllowed(""));
  }

  @Test public void cleartext_rejectsMalformedIpv4() {
    assertFalse(CanopyDevClient.isCleartextAllowed("10.0.0"));         // too few octets
    assertFalse(CanopyDevClient.isCleartextAllowed("10.0.0.256"));     // octet out of range
    assertFalse(CanopyDevClient.isCleartextAllowed("10.0.0.1.2"));     // too many octets
    assertFalse(CanopyDevClient.isCleartextAllowed("10.0.0.x"));       // non-numeric
  }

  // ---- (c) deriveWsUrl -----------------------------------------------------------------------

  @Test public void deriveWsUrl_defaultsWhenEmpty() {
    assertEquals("ws://10.0.2.2:8099/", CanopyDevClient.deriveWsUrl(null));
    assertEquals("ws://10.0.2.2:8099/", CanopyDevClient.deriveWsUrl(""));
    assertEquals("ws://10.0.2.2:8099/", CanopyDevClient.deriveWsUrl("   "));
  }

  @Test public void deriveWsUrl_hostOnlyFillsDefaultPort() {
    assertEquals("ws://127.0.0.1:8099/", CanopyDevClient.deriveWsUrl("127.0.0.1"));
  }

  @Test public void deriveWsUrl_hostPort() {
    assertEquals("ws://192.168.1.20:9000/", CanopyDevClient.deriveWsUrl("192.168.1.20:9000"));
  }

  @Test public void deriveWsUrl_stripsSchemeAndPath() {
    assertEquals("ws://10.0.2.2:8099/", CanopyDevClient.deriveWsUrl("ws://10.0.2.2:8099"));
    assertEquals("ws://10.0.2.2:8099/", CanopyDevClient.deriveWsUrl("http://10.0.2.2:8099/health"));
  }

  @Test public void deriveWsUrl_ipv6Loopback() {
    assertEquals("ws://[::1]:8099/", CanopyDevClient.deriveWsUrl("[::1]:8099"));
  }

  @Test public void deriveWsUrl_refusesDisallowedHost() {
    assertNull("a public host must not yield a dialable URL", CanopyDevClient.deriveWsUrl("example.com:8099"));
    assertNull(CanopyDevClient.deriveWsUrl("8.8.8.8"));
  }

  @Test public void deriveWsUrl_refusesBadPort() {
    assertNull(CanopyDevClient.deriveWsUrl("127.0.0.1:0"));
    assertNull(CanopyDevClient.deriveWsUrl("127.0.0.1:99999"));
    assertNull(CanopyDevClient.deriveWsUrl("127.0.0.1:notaport"));
  }

  // ---- (d) backoffMs -------------------------------------------------------------------------

  @Test public void backoff_floorsDoublesAndCeilings() {
    assertEquals(CanopyDevClient.BACKOFF_MIN_MS, CanopyDevClient.backoffMs(0));
    assertEquals(CanopyDevClient.BACKOFF_MIN_MS, CanopyDevClient.backoffMs(-3)); // negatives floor
    assertEquals(CanopyDevClient.BACKOFF_MIN_MS * 2, CanopyDevClient.backoffMs(1));
    assertEquals(CanopyDevClient.BACKOFF_MIN_MS * 4, CanopyDevClient.backoffMs(2));
    // far out, it saturates at the ceiling and never exceeds it
    assertEquals(CanopyDevClient.BACKOFF_MAX_MS, CanopyDevClient.backoffMs(100));
    assertTrue(CanopyDevClient.backoffMs(50) <= CanopyDevClient.BACKOFF_MAX_MS);
  }
}
