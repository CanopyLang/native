// CanopyDevClientTests.mm — DEV-12 device-free unit test for the iOS dev-loop WS client's MESSAGE
// HANDLING (the pure routing/parse/allowlist/backoff logic), run under XCTest on the build host (no
// device, no Simulator UI, no real dev server). The iOS twin of Android's CanopyDevClientTest.java
// (host/android/.../src/test/CanopyDevClientTest.java) — the SAME assertions, so the two clients are
// provably the same decision layer.
//
// The NSURLSessionWebSocketTask + reconnect loop are I/O glue we don't unit-test here; what IS the
// load-bearing contract — and what a regression would silently break — is the pure decision layer:
//
//   (a) parseFrame/classify  — every wire `type` maps to the right action, malformed/partial JSON
//                              degrades to Ignore (never throws), and a reload's bundle is extracted;
//   (b) isCleartextAllowed   — cleartext ws:// is permitted ONLY to localhost / RFC-1918 LAN, and a
//                              public host is refused (the security contract of the debug loop);
//   (c) deriveWsUrl          — CANOPY_DEV_HOST (host / host:port / ws://… ) → a ws:// URL, with the
//                              allowlist enforced (a disallowed host yields nil = "don't dial");
//   (d) backoffMs            — the reconnect schedule floors/doubles/ceilings deterministically.

#import <XCTest/XCTest.h>

#import "../../CanopyHostCore/DevLoop/CanopyDevClient.h"

@interface CanopyDevClientTests : XCTestCase
@end

@implementation CanopyDevClientTests

// ---- (a) parseFrame / classify -------------------------------------------------------------

- (void)testClassifyMapsEveryKnownType {
  XCTAssertEqual(CanopyDevActionHello,    [CanopyDevClient classify:@"hello"]);
  XCTAssertEqual(CanopyDevActionBuilding, [CanopyDevClient classify:@"building"]);
  XCTAssertEqual(CanopyDevActionReload,   [CanopyDevClient classify:@"reload"]);
  XCTAssertEqual(CanopyDevActionNoChange, [CanopyDevClient classify:@"nochange"]);
  XCTAssertEqual(CanopyDevActionError,    [CanopyDevClient classify:@"error"]);
}

- (void)testClassifyUnknownOrNilIsIgnore {
  XCTAssertEqual(CanopyDevActionIgnore, [CanopyDevClient classify:@"future-type"]);
  XCTAssertEqual(CanopyDevActionIgnore, [CanopyDevClient classify:nil]);
}

- (void)testParseFrameHelloCarriesBuildId {
  CanopyDevFrame *f = [CanopyDevClient parseFrame:
      @"{\"type\":\"hello\",\"buildId\":\"abc123\",\"runtimeVersion\":\"7\"}"];
  XCTAssertEqual(CanopyDevActionHello, f.action);
  XCTAssertEqualObjects(@"abc123", f.buildId);
}

- (void)testParseFrameHelloNullBuildIdIsNil {
  CanopyDevFrame *f = [CanopyDevClient parseFrame:
      @"{\"type\":\"hello\",\"buildId\":null,\"runtimeVersion\":\"7\"}"];
  XCTAssertEqual(CanopyDevActionHello, f.action);
  XCTAssertNil(f.buildId, @"a JSON null buildId decodes to nil, not the string \"null\"");
}

- (void)testParseFrameReloadExtractsBundleAndBuildId {
  CanopyDevFrame *f = [CanopyDevClient parseFrame:
      @"{\"type\":\"reload\",\"buildId\":\"deadbeef\",\"bundle\":\"(function(){})()\",\"map\":null}"];
  XCTAssertEqual(CanopyDevActionReload, f.action);
  XCTAssertEqualObjects(@"deadbeef", f.buildId);
  XCTAssertEqualObjects(@"(function(){})()", f.bundle);
}

- (void)testParseFrameReloadWithoutBundleDowngradesToIgnore {
  // A reload frame missing/empty bundle bytes must NOT re-eval "" — it degrades to Ignore.
  CanopyDevFrame *f = [CanopyDevClient parseFrame:@"{\"type\":\"reload\",\"buildId\":\"x\"}"];
  XCTAssertEqual(CanopyDevActionIgnore, f.action);
  CanopyDevFrame *g = [CanopyDevClient parseFrame:@"{\"type\":\"reload\",\"buildId\":\"x\",\"bundle\":\"\"}"];
  XCTAssertEqual(CanopyDevActionIgnore, g.action);
}

- (void)testParseFrameErrorCarriesReport {
  CanopyDevFrame *f = [CanopyDevClient parseFrame:
      @"{\"type\":\"error\",\"report\":\"TYPE ERROR at Main.can:3\"}"];
  XCTAssertEqual(CanopyDevActionError, f.action);
  XCTAssertEqualObjects(@"TYPE ERROR at Main.can:3", f.report);
}

- (void)testParseFrameNoChangeIsClassifiedNoBundle {
  CanopyDevFrame *f = [CanopyDevClient parseFrame:@"{\"type\":\"nochange\",\"buildId\":\"same\"}"];
  XCTAssertEqual(CanopyDevActionNoChange, f.action);
  XCTAssertEqualObjects(@"same", f.buildId);
  XCTAssertNil(f.bundle);
}

- (void)testParseFrameMalformedJsonIsIgnoreNotThrow {
  XCTAssertEqual(CanopyDevActionIgnore, [CanopyDevClient parseFrame:@"not json at all"].action);
  XCTAssertEqual(CanopyDevActionIgnore, [CanopyDevClient parseFrame:@"{\"type\":"].action);
  XCTAssertEqual(CanopyDevActionIgnore, [CanopyDevClient parseFrame:nil].action);
}

// ---- (b) isCleartextAllowed (the security allowlist) ---------------------------------------

- (void)testCleartextAllowsLoopbackAndEmulatorAlias {
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"localhost"]);
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"127.0.0.1"]);
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"127.5.5.5"]);      // 127.0.0.0/8
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"::1"]);            // IPv6 loopback
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"[::1]"]);          // bracketed form
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"10.0.2.2"]);       // emulator host alias
}

- (void)testCleartextAllowsRfc1918Lan {
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"10.0.0.5"]);       // 10/8
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"192.168.1.20"]);   // 192.168/16
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"172.16.0.1"]);     // 172.16/12 low
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"172.31.255.254"]); // 172.16/12 high
  XCTAssertTrue([CanopyDevClient isCleartextAllowed:@"169.254.10.10"]);  // link-local
}

- (void)testCleartextRefusesPublicAndOutOfRange {
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"8.8.8.8"]);        // public
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"172.15.0.1"]);     // just below 172.16/12
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"172.32.0.1"]);     // just above 172.16/12
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"172.0.0.1"]);      // 172.x outside the block
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"example.com"]);    // a public hostname
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"evil.attacker.io"]);
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:nil]);
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@""]);
}

- (void)testCleartextRejectsMalformedIpv4 {
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"10.0.0"]);         // too few octets
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"10.0.0.256"]);     // octet out of range
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"10.0.0.1.2"]);     // too many octets
  XCTAssertFalse([CanopyDevClient isCleartextAllowed:@"10.0.0.x"]);       // non-numeric
}

// ---- (c) deriveWsUrl -----------------------------------------------------------------------

- (void)testDeriveWsUrlDefaultsWhenEmpty {
  // The iOS default host is 127.0.0.1 (the Simulator shares the Mac loopback), unlike Android's
  // 10.0.2.2 emulator alias.
  XCTAssertEqualObjects(@"ws://127.0.0.1:8099/", [CanopyDevClient deriveWsUrl:nil]);
  XCTAssertEqualObjects(@"ws://127.0.0.1:8099/", [CanopyDevClient deriveWsUrl:@""]);
  XCTAssertEqualObjects(@"ws://127.0.0.1:8099/", [CanopyDevClient deriveWsUrl:@"   "]);
}

- (void)testDeriveWsUrlHostOnlyFillsDefaultPort {
  XCTAssertEqualObjects(@"ws://127.0.0.1:8099/", [CanopyDevClient deriveWsUrl:@"127.0.0.1"]);
}

- (void)testDeriveWsUrlHostPort {
  XCTAssertEqualObjects(@"ws://192.168.1.20:9000/", [CanopyDevClient deriveWsUrl:@"192.168.1.20:9000"]);
}

- (void)testDeriveWsUrlStripsSchemeAndPath {
  XCTAssertEqualObjects(@"ws://10.0.2.2:8099/", [CanopyDevClient deriveWsUrl:@"ws://10.0.2.2:8099"]);
  XCTAssertEqualObjects(@"ws://10.0.2.2:8099/", [CanopyDevClient deriveWsUrl:@"http://10.0.2.2:8099/health"]);
}

- (void)testDeriveWsUrlIpv6Loopback {
  XCTAssertEqualObjects(@"ws://[::1]:8099/", [CanopyDevClient deriveWsUrl:@"[::1]:8099"]);
}

- (void)testDeriveWsUrlRefusesDisallowedHost {
  XCTAssertNil([CanopyDevClient deriveWsUrl:@"example.com:8099"], @"a public host must not yield a URL");
  XCTAssertNil([CanopyDevClient deriveWsUrl:@"8.8.8.8"]);
}

- (void)testDeriveWsUrlRefusesBadPort {
  XCTAssertNil([CanopyDevClient deriveWsUrl:@"127.0.0.1:0"]);
  XCTAssertNil([CanopyDevClient deriveWsUrl:@"127.0.0.1:99999"]);
  XCTAssertNil([CanopyDevClient deriveWsUrl:@"127.0.0.1:notaport"]);
}

// ---- (d) backoffMs -------------------------------------------------------------------------

- (void)testBackoffFloorsDoublesAndCeilings {
  XCTAssertEqual(500L,   [CanopyDevClient backoffMs:0]);
  XCTAssertEqual(500L,   [CanopyDevClient backoffMs:-3]);  // negatives floor
  XCTAssertEqual(1000L,  [CanopyDevClient backoffMs:1]);
  XCTAssertEqual(2000L,  [CanopyDevClient backoffMs:2]);
  // far out, it saturates at the ceiling and never exceeds it
  XCTAssertEqual(10000L, [CanopyDevClient backoffMs:100]);
  XCTAssertTrue([CanopyDevClient backoffMs:50] <= 10000L);
}

@end
