# Telemetry + the crash-free metric (TEL-1 / REL-4)

> How canopy measures reliability on real builds — privately, opt-in, and honestly. The crash floor
> (`CanopyCrashFloor.{java,mm}`) records crashes; this is what consumes them. Schema:
> [`telemetry-schema.json`](./telemetry-schema.json). Computation: `harness/crashfree-report.js`
> (device-free `--selftest`). Gate: `scripts/check-crashfree-gate.sh`.

## The metric

```
crash-free%  (per platform + buildId)
  = 100 * ( 1 - distinct(sessionId with a fatal crash) / distinct(sessionId with a session-start) )
```

- **Denominator** = `session-start` beacons (one per process launch).
- **Numerator** = sessions that recorded a `fatal` crash (a JVM `Throwable`, an `NSException`, or — when
  REL-2's signal half ships — a `native-signal`). A session that crashes more than once counts once.
- Keyed by **buildId** (the content-addressed bundle sha256) so each shipped build has its own number,
  and by **platform**. A crash that happens during boot before its beacon flushes still counts in the
  denominator (the fatal record implies the session existed).

**Honesty rule:** the headline crash-free number is computed only from `source: "device"` events. An
`emulator`/`simulator`/`unknown` source carries a `NOT-A-SHIPPED-METRIC` caveat — a pre-ship number is
never reported as the shipped one. (Today there is no real-device denominator yet — see DEV in the
production roadmap; until then the pipeline is proven by the selftest, but no number is published.)

## Privacy + the sink — OFF by default

- **No network by default.** Records are written to an on-disk **ring buffer** (capped, oldest pruned)
  in the app's private storage. Nothing leaves the device unless BOTH (a) the user has opted in
  (`optIn`) AND (b) a `telemetryEndpoint` is configured in `canopy.manifest.json`. With neither, the
  host makes **zero** network calls — the ring is read locally (e.g. by a device-farm artifact drain).
- **Anonymous.** `sessionId` is a per-launch random UUID — never device-stable, no advertising ID, no
  PII. The record carries only: platform, buildId, app/OS version, timestamps, error class/message/
  frames (symbolicated offline). See the schema for the exact fields.
- **Opt-in HTTP sink** (when enabled): newline-delimited JSON POSTed with a short timeout; on failure
  the records stay in the ring (no retry storm, no loss).

## Schema (v2)

One merged event with a common envelope (`schema`, `eventType ∈ {session-start, crash}`, `platform`,
`buildId`, `sessionId`, `timestampMs`, `appVersion`, `osVersion`, `source`, `caveatTag`); a `crash`
adds `kind`, `fatal`, `errorClass`, `message`, `frames[]`. Full JSON Schema:
[`telemetry-schema.json`](./telemetry-schema.json).

## Using the reporter

```sh
node harness/crashfree-report.js <dir-or-ndjson>...          # per platform+buildId report
node harness/crashfree-report.js --gate --floor 99.0 <in>   # CI gate: fail below the floor
node harness/crashfree-report.js --selftest                 # device-free proof of the math
```

## What is and isn't done

- ✅ The schema, the computation + `--selftest`, the device-free gate (`check-crashfree-gate.sh`,
  wired into `ci-test.sh`), and the host records (session beacon + `sessionId` + ring persistence).
- ⏳ The opt-in HTTP sink end-to-end (needs a real endpoint to validate) and the **published number**
  (needs real shipped-device sessions — DEV/SHIP in `plans/PRODUCTION-ROADMAP.md`).
