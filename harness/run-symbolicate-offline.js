// run-symbolicate-offline.js — AND-10 unit test for the OFFLINE release-crash symbolicator.
//
// Proves that a doubly-unreadable release crash — optimized JS frames (`canopy.bundle.js:L:C`,
// no in-app map) + R8-obfuscated Java frames (`com.canopyhost.x.b(SourceFile:45)`) — retraces
// to BOTH a `.can` source line AND an `OriginalClass.method(File.java:line)`, fully offline and
// device-free, against committed fixtures (a JS `.map` + an R8 `mapping.txt`). The JS half drives
// the REAL `_Native_symbolicate` from package/external/native.js (same VLQ logic the device uses).
//
// Mirrors harness/run-symbolicate.js. Pure Node, no compiler, no emulator. Exits non-zero on any
// failure so scripts/ci-test.sh treats it as a hard gate.

'use strict';

const fs = require('fs');
const path = require('path');
const {
  symbolicateOffline,
  symbolicateJava,
  parseR8Mapping,
  retraceJavaFrame,
} = require('./symbolicate-offline');

let failed = 0;
const ok = (cond, msg) => { console.log('  ' + (cond ? '✓' : '✗ FAIL:') + ' ' + msg); if (!cond) failed++; };

console.log('offline release symbolication (AND-10)');

// Committed hermetic fixtures: a JS source map + an R8 mapping.txt carrying real source lines.
const mapText = fs.readFileSync(path.join(__dirname, 'fixtures/canopy.testbuild.map'), 'utf8');
const mappingText = fs.readFileSync(path.join(__dirname, 'fixtures/mapping.txt'), 'utf8');

// 1. JS frame retrace via the archived map (the proven native.js VLQ path).
//    The fixture map's mappings ";;AAAA;AACA;ACEA" => bundle line 3 -> Counter.can:1,
//    line 4 -> Counter.can:2, line 5 -> Util.can:4 (Hermes frames are 1-based).
{
  const out = symbolicateOffline('at draw (canopy.bundle.js:3:10)', { mapText });
  ok(out.includes('Counter.can:1'), 'JS frame canopy.bundle.js:3 -> Counter.can:1 (-> ' + out.trim() + ')');
  const out2 = symbolicateOffline('at f (canopy.bundle.js:5:1)', { mapText });
  ok(out2.includes('Util.can:4'), 'JS frame canopy.bundle.js:5 -> Util.can:4 (-> ' + out2.trim() + ')');
}

// 2. Java frame retrace via mapping.txt: obfuscated com.canopyhost.x.b(SourceFile:45) is
//    CanopyHostJni.onJsError; obf range 42:48 -> src 142:148, so line 45 -> 142+(45-42)=145.
{
  const parsed = parseR8Mapping(mappingText);
  ok(Object.keys(parsed.byObfClass).length >= 3, 'mapping.txt parsed all fixture classes');
  const frame = retraceJavaFrame('com.canopyhost.x.b(SourceFile:45)', parsed);
  ok(frame === 'com.canopyhost.CanopyHostJni.onJsError(CanopyHostJni.java:145)',
     'obfuscated x.b(:45) -> CanopyHostJni.onJsError(CanopyHostJni.java:145) (-> ' + frame + ')');
  const frameStart = retraceJavaFrame('com.canopyhost.x.b(SourceFile:42)', parsed);
  ok(frameStart.includes('CanopyHostJni.java:142'), 'range start :42 -> :142 (linear retrace) (-> ' + frameStart + ')');
  const frameY = retraceJavaFrame('com.canopyhost.y.a(SourceFile:15)', parsed);
  ok(frameY === 'com.canopyhost.CanopyHost.boot(CanopyHost.java:93)',
     'obfuscated y.a(:15) -> CanopyHost.boot(CanopyHost.java:93) (-> ' + frameY + ')');
}

// 3. The headline AND-10 assertion: ONE captured obfuscated stack with a known .can-origin JS
//    frame AND a known obfuscated Java method+line retraces BOTH frames in a single pass.
{
  const captured = [
    'Error: restore failed',
    '    at draw (canopy.bundle.js:4:7)',           // JS: known .can line (Counter.can:2)
    '    at com.canopyhost.x.b(SourceFile:45)',     // Java: known obfuscated method+line
    '    at com.canopyhost.y.a(SourceFile:20)',     // Java: a second obfuscated frame
  ].join('\n');
  const out = symbolicateOffline(captured, { mapText, mappingText });
  ok(out.includes('Counter.can:2'),
     'combined stack: JS frame -> Counter.can:2');
  ok(out.includes('com.canopyhost.CanopyHostJni.onJsError(CanopyHostJni.java:145)'),
     'combined stack: Java frame -> CanopyHostJni.onJsError(CanopyHostJni.java:145)');
  ok(out.includes('com.canopyhost.CanopyHost.boot(CanopyHost.java:98)'),
     'combined stack: 2nd Java frame -> CanopyHost.boot(CanopyHost.java:98)');
  // Best-effort invariant: an unknown frame is passed through untouched (never masks the crash).
  const unknown = symbolicateOffline('    at com.unknown.Z.q(SourceFile:9)', { mapText, mappingText });
  ok(unknown.includes('com.unknown.Z.q'), 'an unmapped Java frame is left unchanged');
  const noFrames = symbolicateOffline('plain text, no frames', { mapText, mappingText });
  ok(noFrames === 'plain text, no frames', 'a stack with no resolvable frames is unchanged');
}

// 4. Real archived-map smoke (integration): if a release build of styletest archived a
//    buildId-keyed canopy.<buildId>.map, prove a deep JS frame resolves to a real .can source.
{
  const buildDir = path.join(__dirname, '../examples/styletest/build');
  let archived = null;
  try {
    archived = fs.readdirSync(buildDir).find(f => /^canopy\.[0-9a-f]{64}\.map$/.test(f));
  } catch (e) { /* build dir absent */ }
  if (archived) {
    const real = fs.readFileSync(path.join(buildDir, archived), 'utf8');
    const out = symbolicateOffline('at fn (canopy.bundle.js:200:5)', { mapText: real });
    ok(/[A-Za-z.]+\.can:\d+/.test(out),
       'real archived buildId map resolves a deep JS frame to a .can source (-> ' + out.trim() + ')');
  } else {
    console.log('  - no archived release map present, skipping real-map smoke (run a --release build to populate)');
  }
}

console.log(failed === 0 ? '\nALL PASS' : '\n' + failed + ' FAILED');
process.exit(failed === 0 ? 0 : 1);
