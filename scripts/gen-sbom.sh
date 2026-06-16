#!/usr/bin/env bash
# gen-sbom.sh — SEC-1: emit a CycloneDX 1.5 SBOM (sbom.cdx.json) for canopy/native's supply chain.
#
# The load-bearing supply-chain risk is the VENDORED native surface (Hermes/JSI/Yoga/fbjni from React
# Native, onnxruntime) recorded in host/vendor.lock.json — package managers never see those, so a CVE
# scanner needs an SBOM to find them. This emits one CycloneDX doc covering the vendored components +
# the compiler pin; osv-scanner then scans it (and the npm/Haskell lockfiles) in the security-scan job.
#
# Output: $1 or ./sbom.cdx.json. Deterministic (no timestamps/uuids that change run-to-run).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/sbom.cdx.json}"
command -v node >/dev/null 2>&1 || { echo "gen-sbom: node required" >&2; exit 1; }

node - "$ROOT" "$OUT" <<'JS'
const fs = require('fs');
const path = require('path');
const [root, out] = process.argv.slice(2);

const lock = JSON.parse(fs.readFileSync(path.join(root, 'host/vendor.lock.json'), 'utf8'));

// Map each vendored artifact to its upstream PROJECT + version, deduped — that is the unit a CVE is
// filed against (a per-.so CVE doesn't exist; "react-native 0.76.9" / "onnxruntime 1.26.0" do).
const PURL = {
  'react-native': v => `pkg:github/facebook/react-native@v${v}`,
  'onnxruntime':  v => `pkg:github/microsoft/onnxruntime@v${v}`,
};
const projectOf = (source) =>
  /react-native|hermes|yoga|fbjni|jsi/i.test(source) ? 'react-native'
  : /onnxruntime/i.test(source) ? 'onnxruntime'
  : null;

const seen = new Map();
for (const a of lock.artifacts || []) {
  const proj = projectOf(a.source || a.relPath || '');
  if (!proj) continue;
  const key = `${proj}@${a.version}`;
  if (!seen.has(key)) seen.set(key, { proj, version: a.version, source: a.source });
}

// The pinned in-house compiler (provenance, not a CVE source, but belongs in the SBOM).
let compilerSha = '';
try {
  const pin = fs.readFileSync(path.join(root, 'scripts/compiler-pin.env'), 'utf8');
  compilerSha = (pin.match(/CANOPY_COMPILER_SHA=([0-9a-f]+)/) || [])[1] || '';
} catch {}

const components = [];
for (const { proj, version, source } of seen.values()) {
  const purlFn = PURL[proj];
  components.push({
    type: 'library',
    name: proj,
    version: String(version),
    purl: purlFn ? purlFn(version) : undefined,
    description: source,
    scope: 'required',
  });
}
if (compilerSha) {
  components.push({
    type: 'application', name: 'canopy-compiler', version: compilerSha,
    description: 'in-house Canopy compiler, pinned by SHA (scripts/compiler-pin.env)', scope: 'required',
  });
}

const sbom = {
  bomFormat: 'CycloneDX',
  specVersion: '1.5',
  version: 1,
  metadata: {
    component: { type: 'framework', name: 'canopy-native', version: '0.1.0',
                 description: 'Canopy → native iOS/Android over Hermes+JSI+Yoga' },
    properties: [{ name: 'canopy:note', value: 'vendored native surface from host/vendor.lock.json; npm/Haskell deps scanned from their lockfiles separately' }],
  },
  components: components.sort((a, b) => a.name.localeCompare(b.name)),
};

fs.writeFileSync(out, JSON.stringify(sbom, null, 2) + '\n');
console.error(`gen-sbom: wrote ${components.length} components to ${out}`);
JS
echo "SBOM: $OUT"
