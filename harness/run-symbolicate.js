// run-symbolicate.js — unit-tests the source-map symbolicator in external/native.js (DX M0).
//
// Drives the REAL _Native_symbolicate against a known synthetic V3 map (deterministic
// assertions) plus the real built styletest map (integration smoke). No device, pure Node.

require('./mini-runtime'); // installs F2..F9 etc. that native.js touches at module load

let failed = 0;
const ok = (cond, msg) => { console.log('  ' + (cond ? '✓' : '✗ FAIL:') + ' ' + msg); if (!cond) failed++; };

function freshNative() {
  delete require.cache[require.resolve('../package/external/native.js')];
  delete globalThis.__canopy_sourcemap; // force the lazy index to rebuild per case
  return require('../package/external/native.js');
}

console.log('source-map symbolication (DX M0)');

// 1. Synthetic map with hand-computed positions.
//    mappings ";;AAAA;AACA;ACEA" → genLine 2 = Foo.can:1, genLine 3 = Foo.can:2, genLine 4 = Bar.can:4.
{
  const native = freshNative();
  globalThis.__canopy_sourcemap = JSON.stringify({
    version: 3, file: 'canopy.bundle.js',
    sources: ['Foo.can', 'Bar.can'], sourcesContent: ['', ''], names: [],
    mappings: ';;AAAA;AACA;ACEA',
  });
  const s = native._Native_symbolicate;
  ok(typeof s === 'function', 'symbolicate is exported');
  ok(s('at f (canopy.bundle.js:3:10)').includes('Foo.can:1'), 'bundle line 3 -> Foo.can:1');
  ok(s('at g (canopy.bundle.js:4:2)').includes('Foo.can:2'),  'bundle line 4 -> Foo.can:2');
  ok(s('at h (canopy.bundle.js:5:1)').includes('Bar.can:4'),  'bundle line 5 -> Bar.can:4');
  ok(s('at top (canopy.bundle.js:1:1)').includes('canopy.bundle.js:1:1'), 'frame before any mapping is left unchanged');
  const multi = s('Error\n  at a (canopy.bundle.js:3:1)\n  at b (canopy.bundle.js:5:9)');
  ok(multi.includes('Foo.can:1') && multi.includes('Bar.can:4'), 'rewrites every frame in a multi-line stack');
  ok(s('') === '', 'empty stack returns empty');
  ok(s('no frames here') === 'no frames here', 'a stack with no bundle frames is unchanged');
}

// 2. No embedded map → best-effort passthrough (symbolication never masks the error).
{
  const native = freshNative();
  const raw = 'at x (canopy.bundle.js:99:1)';
  ok(native._Native_symbolicate(raw) === raw, 'no embedded map -> stack returned unchanged');
}

// 3. Real built styletest map (integration smoke), if present.
{
  const fs = require('fs'), path = require('path');
  const mapPath = path.join(__dirname, '../examples/styletest/build/canopy.bundle.js.map');
  if (fs.existsSync(mapPath)) {
    const native = freshNative();
    globalThis.__canopy_sourcemap = fs.readFileSync(mapPath, 'utf8');
    const out = native._Native_symbolicate('at fn (canopy.bundle.js:200:5)');
    ok(/[A-Za-z.]+\.can:\d+/.test(out), 'real styletest map resolves a deep frame to a .can source (-> ' + out.trim() + ')');
  } else {
    console.log('  - styletest build absent, skipping real-map smoke');
  }
}

console.log(failed === 0 ? '\nALL PASS' : '\n' + failed + ' FAILED');
process.exit(failed === 0 ? 0 : 1);
