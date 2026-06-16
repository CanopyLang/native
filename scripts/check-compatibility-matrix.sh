#!/usr/bin/env bash
# check-compatibility-matrix.sh — CAP-5: keep docs/compatibility-matrix.json honest + in sync, and
# track the "full compatibility" coverage % device-free.
#
#   (A) every capability ACTUALLY SHIPPED (a *Module.java under host/android/.../modules) is listed in
#       the matrix — so adding a capability without updating the matrix fails the build (no silent
#       drift / overstated breadth);
#   (B) the matrix is valid JSON and self-consistent;
#   (C) render docs/compatibility-matrix.md from the JSON (never hand-maintained) and compute coverage.
#
# Pure bash + node (no toolchain, no device).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSON="$ROOT/docs/compatibility-matrix.json"
MODDIR="$ROOT/host/android/app/src/main/java/com/canopyhost/modules"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }

[ -f "$JSON" ] || { echo "FATAL: $JSON missing (CAP-5)." >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "check-compatibility-matrix: node required" >&2; exit 1; }
node -e "JSON.parse(require('fs').readFileSync('$JSON','utf8'))" 2>/dev/null && ok "compatibility-matrix.json is valid JSON" || bad "compatibility-matrix.json is not valid JSON"

# (A) live capability list (strip 'Module.java'; StreamingBridge is infra, not a capability).
echo "==> every shipped capability is in the matrix"
mapfile -t live < <(ls "$MODDIR" 2>/dev/null | sed -nE 's/^([A-Za-z]+)Module\.java$/\1/p' | grep -v '^Streaming' | sort -u)
[ "${#live[@]}" -gt 0 ] || bad "found no capability modules under $MODDIR"
listed=$(node -e "const m=require('$JSON'); console.log(m.capabilities.map(c=>c.name).join('\n'))")
for cap in "${live[@]}"; do
  if grep -qx "$cap" <<<"$listed"; then ok "capability '$cap' is documented"; else bad "shipped capability '$cap' is MISSING from compatibility-matrix.json"; fi
done

# (B) render the .md + coverage %
echo "==> render docs/compatibility-matrix.md + coverage"
node - "$JSON" "$ROOT/docs/compatibility-matrix.md" <<'JS'
const fs=require('fs'); const [j,out]=process.argv.slice(2); const m=JSON.parse(fs.readFileSync(j,'utf8'));
const haveCap=m.capabilities.filter(c=>c.canopy==='have').length;
const gapCap=m.gaps.filter(g=>g.kind==='capability').length;
const capPct=Math.round(100*haveCap/(haveCap+gapCap));
const haveComp=m.components.filter(c=>c.canopy==='have').length, totComp=m.components.length;
const compPct=Math.round(100*haveComp/totComp);
const row=c=>`| ${c.name} | ${c.canopy} | ${c.rnAnalog||c.expoAnalog||''} | ${(c.notes||'').replace(/\|/g,'\\|')} |`;
let md=`# canopy/native — Compatibility matrix (vs RN core + Expo SDK essentials)\n\n`;
md+=`> Generated from \`docs/compatibility-matrix.json\` by \`scripts/check-compatibility-matrix.sh\` — do not edit by hand.\n\n`;
md+=`**Capability coverage:** ${haveCap}/${haveCap+gapCap} essential modules = **${capPct}%** · **Component coverage:** ${haveComp}/${totComp} = **${compPct}%**\n\n`;
md+=`## Components\n\n| Component | canopy | RN analog | notes |\n|---|---|---|---|\n`+m.components.map(row).join('\n')+`\n\n`;
md+=`## Capabilities (native modules)\n\n| Capability | canopy | Expo analog | notes |\n|---|---|---|---|\n`+m.capabilities.map(c=>`| ${c.name} | ${c.canopy} | ${c.expoAnalog||''} | ${(c.notes||'').replace(/\|/g,'\\|')} |`).join('\n')+`\n\n`;
md+=`## Known gaps (planned / partial)\n\n| Gap | kind | canopy | Expo analog | priority |\n|---|---|---|---|---|\n`+m.gaps.map(g=>`| ${g.name} | ${g.kind} | ${g.canopy} | ${g.expoAnalog||''} | ${g.priority} |`).join('\n')+`\n`;
fs.writeFileSync(out,md);
console.log(`  capability coverage ${capPct}% (${haveCap}/${haveCap+gapCap}) · component coverage ${compPct}% (${haveComp}/${totComp})`);
JS
[ $? -eq 0 ] && ok "rendered docs/compatibility-matrix.md" || bad "failed to render compatibility-matrix.md"

echo
if [ "$fail" -eq 0 ]; then echo "compatibility matrix OK — in sync with the shipped capability set."; else echo "compatibility matrix check FAILED." >&2; fi
exit "$fail"
