// matrix-report.mjs — aggregate the cross-platform E2E sweep (run-matrix.sh) into ONE Markdown
// report: every Android + iOS device entry in a single table with a combined PASS/FAIL verdict.
//
// E2E-2 deliverable #3 ("aggregate Android+iOS into one matrix report"). run-matrix.sh appends one
// JSON line per device entry to results.jsonl; this reads that ledger (no jq needed) and writes the
// report. Kept dependency-free + pure so the report renders on Linux for the Android leg even when
// the iOS leg ran on a separate Mac — concatenate the two ledgers and re-run this to merge them.
//
// Usage:  node matrix-report.mjs <results.jsonl> [<out.md>]
//   With no <out.md> the report goes to stdout. Exit code = number of FAILED entries (0 = all green).

import { readFileSync, writeFileSync } from 'node:fs'

const [, , jsonlPath, outPath] = process.argv
if (!jsonlPath) {
  console.error('usage: node matrix-report.mjs <results.jsonl> [<out.md>]')
  process.exit(2)
}

let rows = []
try {
  rows = readFileSync(jsonlPath, 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => JSON.parse(l))
} catch (e) {
  console.error('matrix-report: cannot read ' + jsonlPath + ': ' + ((e && e.message) || e))
  process.exit(2)
}

const PASS = '✅ pass'
const FAIL = '❌ fail'
const verdict = (rc) => (Number(rc) === 0 ? PASS : FAIL)

// Stable order: Android entries first, then iOS; preserve insertion order within a platform.
const order = { android: 0, ios: 1 }
rows = rows
  .map((r, i) => ({ ...r, _i: i }))
  .sort((a, b) => (order[a.platform] ?? 9) - (order[b.platform] ?? 9) || a._i - b._i)

const failed = rows.filter((r) => Number(r.rc) !== 0).length
const passed = rows.length - failed
const platforms = [...new Set(rows.map((r) => r.platform))]

const lines = []
lines.push('# Canopy Native — E2E device matrix report')
lines.push('')
lines.push('Cross-platform Appium sweep (`run-matrix.sh`): one spec body, selecting on the')
lines.push('`testID`→accessibility-id contract, run against each device. Android uses the')
lines.push('UIAutomator2 driver; iOS uses the XCUITest driver. Same `.mjs` spec, both platforms.')
lines.push('')
lines.push('**Verdict: ' + (failed === 0 ? PASS.toUpperCase() : FAIL.toUpperCase()) +
  '** — ' + passed + '/' + rows.length + ' device entries passed' +
  (platforms.length ? '  (platforms: ' + platforms.join(', ') + ')' : ''))
lines.push('')
lines.push('| Platform | Device | Driver | Spec | Result | Started (UTC) | Ended (UTC) |')
lines.push('|---|---|---|---|---|---|---|')
for (const r of rows) {
  const driver = r.platform === 'ios' ? 'XCUITest' : r.platform === 'android' ? 'UIAutomator2' : '?'
  lines.push('| ' + [r.platform, r.device, driver, r.spec, verdict(r.rc),
    r.started || '', r.ended || ''].join(' | ') + ' |')
}
lines.push('')
if (failed === 0 && rows.length > 0) {
  lines.push('All device entries passed — the cross-platform e2e thesis holds for this sweep.')
} else if (rows.length === 0) {
  lines.push('_No device entries were recorded._')
} else {
  lines.push('Failed entries:')
  for (const r of rows.filter((x) => Number(x.rc) !== 0)) {
    lines.push('- `' + r.platform + ':' + r.device + '` running `' + r.spec + '` (exit ' + r.rc + ')')
  }
}
lines.push('')

const out = lines.join('\n')
if (outPath) {
  writeFileSync(outPath, out)
  console.error('matrix-report → ' + outPath + ' (' + passed + '/' + rows.length + ' passed)')
} else {
  process.stdout.write(out)
}
process.exit(failed)
