// CanopyDevClient.h — DEV-12: the iOS host's debug-only dev-loop WebSocket client.
//
// The iOS twin of Android's CanopyDevClient.java (host/android/.../src/debug/CanopyDevClient.java).
// It is the device half of the Metro-class fast-refresh loop: it connects to the SAME DEV-5 dev
// server (tool/canopy-dev-server.js), receives pushed bundles over a WebSocket, and turns them into
// the DEV-12 in-process reload (CanopyHostViewController -reloadWithBundle:, re-eval on the SAME
// Hermes runtime, state-preserving), while compile errors become the dev red-box.
//
//   src/Main.can edit ─▶ dev server build+push ─▶ {type:"reload",bundle} ─▶ CanopyDevClient
//                                                                              │
//                                          reloadWithBundle: ──▶ in-process state-preserving reload
//
// WIRE PROTOCOL — IDENTICAL to the Android client (one JSON object per WS text frame, server→host;
// mirror of canopy-dev-server.js):
//   {"type":"hello",    "buildId":<string|null>, "runtimeVersion":<string>}   on connect
//   {"type":"building", "buildId":<prev|null>}                                rebuild started
//   {"type":"reload",   "buildId":<sha256>, "bundle":<js>, "map":<json|null>} rebuild OK + changed
//   {"type":"nochange", "buildId":<sha256>}                                   rebuild OK, same buildId
//   {"type":"error",    "report":<compiler stderr/stdout>}                    rebuild FAILED
//
// CONNECTION URL: from CANOPY_DEV_HOST (env / Info.plist) — host:port of the dev server. On the iOS
// Simulator the host loopback is reachable directly at 127.0.0.1; a LAN device bakes its own IP.
// Defaults to 127.0.0.1:8099 (the Simulator shares the Mac's loopback, unlike Android's 10.0.2.2).
//
// SECURITY: the dev server speaks cleartext ws:// (no TLS in the loop). We only ever dial a host on
// the LOCALHOST / private-LAN allowlist (isCleartextAllowed) — a public host is refused, so even a
// mis-baked CANOPY_DEV_HOST can't open a cleartext channel to the internet. ATS's
// NSAllowsLocalNetworking (the iOS analogue of Android's network_security_config) scopes cleartext to
// the local network at the platform layer; this allowlist is the belt to that brace. Release is
// unaffected — this whole client is compiled only when DEBUG is defined and never started otherwise.
//
// TESTABILITY: every routing/parse decision is a PURE class method (classify, parseFrame,
// isCleartextAllowed, backoffMs, deriveWsUrl) so CanopyDevClientTests exercises the message handling
// device-free under XCTest, exactly as CanopyDevClientTest.java does on the JVM. The
// NSURLSessionWebSocketTask + reconnect loop are the thin I/O shell.

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What a received frame asks the host to do (mirror of the Java `Action` enum).
typedef NS_ENUM(NSInteger, CanopyDevAction) {
  CanopyDevActionHello,
  CanopyDevActionBuilding,
  CanopyDevActionReload,
  CanopyDevActionNoChange,
  CanopyDevActionError,
  CanopyDevActionIgnore,
};

/// A parsed dev-server frame: the action + the payload fields the host acts on (mirror of the Java
/// `Frame`). Immutable; produced by +parseFrame:, consumed by the I/O shell + the tests.
@interface CanopyDevFrame : NSObject
@property(nonatomic, readonly) CanopyDevAction action;
@property(nonatomic, readonly, nullable) NSString *buildId;  // hello / building / reload / nochange
@property(nonatomic, readonly, nullable) NSString *bundle;   // reload only (the JS source to re-eval)
@property(nonatomic, readonly, nullable) NSString *report;   // error only (the compiler output)
@end

/// Debug-only dev-loop WebSocket client (DEV-12). Connects to the DEV-5 dev server, applies pushed
/// bundles via the DEV-12 in-process reload, and surfaces build errors as a dev red-box.
@interface CanopyDevClient : NSObject

// ---- the I/O shell ------------------------------------------------------------------------------

/// Start the dev client for `devHost` (the CANOPY_DEV_HOST value). No-op (returning nil, with a log)
/// when the host is missing/disallowed so a debug build with no dev server attached just runs
/// normally. Returns the started client, or nil when nothing was started.
+ (nullable instancetype)startWithDevHost:(nullable NSString *)devHost;

/// Stop the client and tear down the socket; no further reconnects.
- (void)stop;

// ---- PURE decision layer (unit-tested device-free; mirrors the Java statics) --------------------

/// Map a frame's "type" string to an action. Unknown/nil → Ignore (forward-compat).
+ (CanopyDevAction)classify:(nullable NSString *)type;

/// Parse a raw WS text frame into a CanopyDevFrame. Malformed JSON, or a reload with no bundle,
/// degrades to an Ignore frame (never throws) so a stray/partial message can't kill the loop.
+ (CanopyDevFrame *)parseFrame:(nullable NSString *)text;

/// True iff `host` is a loopback or RFC-1918 / link-local LAN address we permit cleartext ws:// to.
/// A public hostname/IP is refused. Identical ranges to CanopyDevClient.isCleartextAllowed (Java).
+ (BOOL)isCleartextAllowed:(nullable NSString *)host;

/// Build the ws:// URL to dial from a CANOPY_DEV_HOST value ("host", "host:port", or a full
/// ws://host:port / http://host:port). A missing scheme/port fills in ws:// + 8099. Returns nil when
/// the resolved host fails the cleartext allowlist (refuse to dial it).
+ (nullable NSString *)deriveWsUrl:(nullable NSString *)devHost;

/// Exponential backoff with a floor + ceiling: attempt 0 waits MIN, doubling per failed attempt,
/// capped at MAX. Deterministic (no jitter) so the test can pin the schedule. Milliseconds.
+ (long)backoffMs:(NSInteger)attempt;

@end

NS_ASSUME_NONNULL_END
