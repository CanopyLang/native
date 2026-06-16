#!/usr/bin/env node
// df-ios-trace-summary.mjs — DF-1: distil an iOS device-farm performance series into the SAME ledger
// shape harness/perf-report.js consumes, so the iOS perf trace is gated by the exact same relative
// regression gate as the Android frame-metrics dump (one gate, both platforms). See docs/device-farm.md §3.
//
// Inputs (one of):
//   --browserstack <appprofiling.json>  BrowserStack App Automate "App Performance" series (the JSON the
//                                        REST endpoint /appprofiling/v2 returns: fps/cpu/mem samples).
//   --xctrace <frames.json>              a frame-time array exported from an xctrace/Instruments .trace
//                                        (the Mac path: xctrace export ... -> a JSON list of frame durations).
//   --frames <a,b,c,...>                 a bare comma list of frame durations in ms (for --selftest / tests).
//
// Output: the perf-report.js dump shape on stdout or to --out:
//   { label, refreshHz, frames, jankFrames, jankFrames2x, jankFrames4x, jankPct,
//     p50Ms, p90Ms, p95Ms, p99Ms, meanMs, maxMs,
//     context: { device, abi, segment, elapsedMs, effectiveFps }, caveat }
//
// The abi is tagged "arm64" + a real-device caveat, so the gate (and a reviewer) can tell a SHIPPABLE
// arm64 number from an emulator/simulator upper bound. Run --selftest for a device-free proof.

import fs from 'node:fs'

const REFRESH_HZ = 60
const REFRESH_MS = 1000 / REFRESH_HZ

function parseArgs(argv) {
  const a = { browserstack: null, xctrace: null, frames: null, out: null, device: 'iPhone', selftest: false }
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i]
    switch (t) {
      case '--browserstack': a.browserstack = argv[++i]; break
      case '--xctrace': a.xctrace = argv[++i]; break
      case '--frames': a.frames = argv[++i]; break
      case '--out': a.out = argv[++i]; break
      case '--device': a.device = argv[++i]; break
      case '--selftest': a.selftest = true; break
      case '-h': case '--help': a.help = true; break
      default: console.error('unknown flag: ' + t); process.exit(2)
    }
  }
  return a
}

function pct(sortedAsc, p) {
  if (sortedAsc.length === 0) return 0
  const idx = Math.min(sortedAsc.length - 1, Math.max(0, Math.ceil((p / 100) * sortedAsc.length) - 1))
  return sortedAsc[idx]
}

// Convert an fps time-series (one sample per second, BrowserStack's App Performance shape) into a
// frame-time distribution: each sample's fps implies frame durations of 1000/fps ms for that second.
// Lower fps in a window => more/longer frames => higher jank, which is exactly what we want to gate.
function framesFromFps(fpsSamples) {
  const frames = []
  for (const fps of fpsSamples) {
    const f = Number(fps)
    if (!isFinite(f) || f <= 0) continue
    const dur = 1000 / f
    const count = Math.max(1, Math.round(f)) // ~f frames in that one-second window
    for (let i = 0; i < count; i++) frames.push(dur)
  }
  return frames
}

// Pull the fps series out of a BrowserStack appprofiling payload. The endpoint shape varies across
// plan tiers; we look in the documented places and fall back to scanning for an `fps` array.
function fpsFromBrowserStack(j) {
  // Common shapes: { metrics: { fps: [{ value }, ...] } } or { fps: [...] } or [{ fps }, ...]
  const tryArr = (x) => Array.isArray(x) ? x.map((s) => (s && typeof s === 'object') ? (s.value ?? s.fps ?? s.y) : s) : null
  if (j && j.metrics && tryArr(j.metrics.fps)) return tryArr(j.metrics.fps)
  if (j && tryArr(j.fps)) return tryArr(j.fps)
  if (Array.isArray(j)) {
    const xs = j.map((s) => (s && typeof s === 'object') ? (s.fps ?? s.value) : null).filter((v) => v != null)
    if (xs.length) return xs
  }
  // Deep scan: first array of numbers under a key containing "fps".
  let found = null
  const walk = (o) => {
    if (found || !o || typeof o !== 'object') return
    for (const [k, v] of Object.entries(o)) {
      if (found) return
      if (/fps/i.test(k) && Array.isArray(v)) {
        const xs = v.map((s) => (s && typeof s === 'object') ? (s.value ?? s.fps ?? s.y) : s).filter((n) => isFinite(Number(n)))
        if (xs.length) { found = xs.map(Number); return }
      }
      if (typeof v === 'object') walk(v)
    }
  }
  walk(j)
  return found || []
}

// Build the perf-report.js dump shape from a frame-duration array (ms).
function summarize(frameMs, { device }) {
  const frames = frameMs.filter((x) => isFinite(x) && x > 0)
  const n = frames.length
  const sorted = [...frames].sort((a, b) => a - b)
  const jank = frames.filter((d) => d > REFRESH_MS).length
  const jank2x = frames.filter((d) => d > REFRESH_MS * 2).length
  const jank4x = frames.filter((d) => d > REFRESH_MS * 4).length
  const sum = frames.reduce((a, b) => a + b, 0)
  const elapsedMs = sum
  return {
    label: 'list-fling',
    refreshHz: REFRESH_HZ,
    frames: n,
    jankFrames: jank,
    jankFrames2x: jank2x,
    jankFrames4x: jank4x,
    jankPct: n ? (jank / n) * 100 : 0,
    p50Ms: pct(sorted, 50),
    p90Ms: pct(sorted, 90),
    p95Ms: pct(sorted, 95),
    p99Ms: pct(sorted, 99),
    meanMs: n ? sum / n : 0,
    maxMs: n ? sorted[n - 1] : 0,
    context: {
      device,
      abi: 'arm64',
      segment: 'list-fling',
      elapsedMs,
      effectiveFps: elapsedMs > 0 ? (n / elapsedMs) * 1000 : 0,
    },
    caveat: 'real arm64 iPhone (device farm) — shippable figures, not an emulator/simulator upper bound.',
  }
}

function selftest() {
  let ok = 0, bad = 0
  const eq = (name, cond) => { if (cond) { ok++; console.log('  \x1b[32m✓\x1b[0m ' + name) } else { bad++; console.log('  \x1b[31m✗\x1b[0m ' + name) } }

  // A smooth fling: 120 frames all ~16ms => ~0% jank.
  const smooth = summarize(Array(120).fill(16), { device: 'iPhone 15' })
  eq('smooth: 0% jank', smooth.jankPct === 0)
  eq('smooth: arm64 abi tag', smooth.context.abi === 'arm64')
  eq('smooth: real-device caveat present', /real arm64/.test(smooth.caveat))
  eq('smooth: p95 within one refresh', smooth.p95Ms <= REFRESH_MS + 0.001)

  // A janky fling: a third of frames at 40ms (a missed vsync) => 33% jank, severe.
  const jankFrames = [...Array(80).fill(16), ...Array(40).fill(40)]
  const janky = summarize(jankFrames, { device: 'iPhone 15' })
  eq('janky: ~33% jank', Math.abs(janky.jankPct - (40 / 120) * 100) < 0.5)
  eq('janky: 40 severe (>2x) frames', janky.jankFrames2x === 40)
  eq('janky: p95 is the slow tail (40ms)', janky.p95Ms === 40)

  // fps series -> frames: 60fps for 2s then 20fps for 1s.
  const fr = framesFromFps([60, 60, 20])
  const fromFps = summarize(fr, { device: 'iPhone 15' })
  eq('fps->frames: the 20fps second is janky', fromFps.jankFrames > 0)
  eq('fps->frames: 60fps seconds are smooth', fromFps.frames > fromFps.jankFrames)

  // BrowserStack payload extraction (a couple of documented shapes).
  eq('bs: metrics.fps shape', JSON.stringify(fpsFromBrowserStack({ metrics: { fps: [{ value: 60 }, { value: 30 }] } })) === '[60,30]')
  eq('bs: bare fps array', JSON.stringify(fpsFromBrowserStack({ fps: [60, 45] })) === '[60,45]')
  eq('bs: deep-scan fallback', JSON.stringify(fpsFromBrowserStack({ session: { perf: { fpsSeries: [55, 58] } } })) === '[55,58]')

  // The output validates against perf-report.js's expected fields (shape contract).
  const required = ['label', 'refreshHz', 'frames', 'jankFrames', 'jankFrames2x', 'jankFrames4x',
    'jankPct', 'p50Ms', 'p90Ms', 'p95Ms', 'p99Ms', 'meanMs', 'maxMs', 'context', 'caveat']
  eq('output has every perf-report.js field', required.every((k) => k in smooth))

  console.log('\n' + (bad === 0 ? `\x1b[32mdf-ios-trace-summary selftest OK (${ok}/${ok})\x1b[0m`
    : `\x1b[31mdf-ios-trace-summary selftest FAILED (${bad} of ${ok + bad})\x1b[0m`))
  process.exit(bad === 0 ? 0 : 1)
}

function main() {
  const a = parseArgs(process.argv)
  if (a.help) { console.log('usage: df-ios-trace-summary.mjs [--browserstack f|--xctrace f|--frames a,b,c] [--out f] [--device name] [--selftest]'); return }
  if (a.selftest) return selftest()

  let frameMs = []
  if (a.frames) {
    frameMs = a.frames.split(',').map(Number)
  } else if (a.browserstack) {
    const j = JSON.parse(fs.readFileSync(a.browserstack, 'utf8'))
    frameMs = framesFromFps(fpsFromBrowserStack(j))
  } else if (a.xctrace) {
    const j = JSON.parse(fs.readFileSync(a.xctrace, 'utf8'))
    // An xctrace export is a list of frame durations (ms) or {duration}/{value} objects.
    const arr = Array.isArray(j) ? j : (j.frames || j.samples || [])
    frameMs = arr.map((s) => (s && typeof s === 'object') ? Number(s.durationMs ?? s.duration ?? s.value) : Number(s))
  } else {
    console.error('one of --browserstack / --xctrace / --frames is required (or --selftest)')
    process.exit(2)
  }

  if (frameMs.filter((x) => isFinite(x) && x > 0).length === 0) {
    console.error('no usable frame/fps samples found in the input — cannot summarize')
    process.exit(1)
  }

  const dump = summarize(frameMs, { device: a.device })
  const out = JSON.stringify(dump, null, 2)
  if (a.out) { fs.writeFileSync(a.out, out + '\n'); console.error('wrote ' + a.out) }
  else process.stdout.write(out + '\n')
}

main()
