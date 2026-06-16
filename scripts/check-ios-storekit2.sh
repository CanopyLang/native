#!/usr/bin/env bash
# check-ios-storekit2.sh — L-I5 structural gate for the iOS StoreKit 2 paywall. NO Mac and NO Apple
# account required.
#
# L-I5 mirrors L-A4 (Play Billing) on iOS: a StoreKit 2 non-consumable (`lifetime_unlock`) → a
# verified entitlement → the gate the Lumen paywall reads. StoreKit 2 (Product / Transaction /
# VerificationResult) is a Swift-only async/await API, so the store logic lives in a Swift driver
# (CanopyBillingStoreKit2.swift) that CanopyBillingModule.mm forwards the three one-shots to, with a
# StoreKit-1 / fake-store fallback so the paywall is exercisable before a store is wired. The iOS host
# cannot be COMPILED off macOS (StoreKit + Xcode are Apple-only), so this gate proves — device-free, by
# structural assertion — that the WHOLE StoreKit 2 paywall is correctly wired:
#
#   (A) SWIFT DRIVER — CanopyBillingStoreKit2.swift exists, is @objc-visible, drives the three
#       one-shots through the StoreKit 2 APIs (Product.products / product.purchase /
#       Transaction.currentEntitlements / Transaction.updates), VERIFIES every transaction
#       (VerificationResult / .verified) and fails closed on .unverified, and surfaces the SAME wire
#       contract (productId / transactionId / entitlement / {isActive,productId} / the Product fields).
#   (B) .MM WIRING — CanopyBillingModule.mm imports the generated Swift header (guarded), owns a driver
#       instance constructed under @available(iOS 15), forwards getProducts/purchase/restore to it, and
#       routes its entitlement-change callback into the portable stream (canopy::billingEmitEntitlement)
#       — AND keeps the fake-store fallback so getProducts never hard-fails.
#   (C) PRODUCT-ID PARITY — the product id `lifetime_unlock` is IDENTICAL across the Swift driver, the
#       .mm, the .storekit config, and (cross-checked) the Android BillingModule.java — so the same
#       Canopy paywall code drives both stores.
#   (D) STOREKIT CONFIG — CanopyHostApp/Products.storekit is a well-formed StoreKit config declaring the
#       one NonConsumable `lifetime_unlock` product, the scheme attaches it to the run + test actions
#       (storeKitConfiguration), and it is NOT compiled into / bundled with the shipped .app.
#   (E) ENTITLEMENTS — the in-app-purchase entitlement is present in BOTH the Debug and Release
#       entitlements (StoreKit 2 needs it), and the deployment floor is iOS 15 (the StoreKit 2 floor).
#   (F) TESTS — the device-free Billing XCTest legs (CanopyCapabilityParityTests.mm) pin the dispatch
#       contract + the getProducts/purchase/restore wire shapes, and the Simulator paywall run is
#       documented (BUILD-AND-VALIDATE.md / docs).
#
# Pure bash + grep + /usr/bin/python3 (parses the .storekit JSON on Linux — no Xcode needed).
# Usage:  bash scripts/check-ios-storekit2.sh
# Exit: 0 = the iOS StoreKit 2 paywall is wired + verified + store-parity · 1 = a leg drifted.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"

SWIFT="$IOS/CanopyHostCore/Modules/CanopyBillingStoreKit2.swift"
MM="$IOS/CanopyHostCore/Modules/CanopyBillingModule.mm"
STOREKIT="$IOS/CanopyHostApp/Products.storekit"
PROJECT="$IOS/project.yml"
ENT_DEBUG="$IOS/CanopyHostApp/CanopyHost.entitlements"
ENT_RELEASE="$IOS/CanopyHostApp/CanopyHostRelease.entitlements"
TEST="$IOS/Tests/CanopyHostCoreTests/CanopyCapabilityParityTests.mm"
ANDROID_BILLING="$ROOT/host/android/app/src/main/java/com/canopyhost/modules/BillingModule.java"
BUILDDOC="$IOS/BUILD-AND-VALIDATE.md"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

# need <label> <file> <pattern...> — every ERE pattern must be present in the file.
need() {
  local label="$1" file="$2"; shift 2
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#"$ROOT"/}"; status=1; return; fi
  local miss=()
  for pat in "$@"; do
    grep -qE -- "$pat" "$file" || miss+=("$pat")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    red "    FAIL — $label (${file#"$ROOT"/}) is missing:"
    for m in "${miss[@]}"; do echo "        · $m"; done
    status=1
  else
    green "    OK  — $label"
  fi
}

# nothave <label> <file> <pattern> — the ERE pattern must be ABSENT.
nothave() {
  local label="$1" file="$2" pat="$3"
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#"$ROOT"/}"; status=1; return; fi
  if grep -qE -- "$pat" "$file"; then
    red "    FAIL — $label: forbidden pattern present in ${file#"$ROOT"/}: $pat"
    grep -nE -- "$pat" "$file" | head -3 | sed 's/^/        /'
    status=1
  else
    green "    OK  — $label"
  fi
}

echo "==> iOS StoreKit 2 paywall gate (scripts/check-ios-storekit2.sh)"
echo "    (structural — the iOS host can't be compiled off macOS; this proves the StoreKit 2 paywall is wired, verified, and store-parity with Android)"
echo

for f in "$SWIFT" "$MM" "$STOREKIT" "$PROJECT" "$ENT_DEBUG" "$ENT_RELEASE"; do
  [ -f "$f" ] || { red "    FAIL — required file missing: ${f#"$ROOT"/}"; status=1; }
done

# ── (A) the Swift StoreKit 2 driver: real StoreKit 2 APIs + verification + the wire contract ──────
echo "--> [A] CanopyBillingStoreKit2.swift drives the real StoreKit 2 APIs, verifies every transaction:"
need "the driver imports StoreKit and is @objc-visible from the .mm" "$SWIFT" \
  'import StoreKit' \
  '@objcMembers' \
  'class CanopyBillingStoreKit2'
need "getProducts uses StoreKit 2 Product.products(for:)" "$SWIFT" \
  'func getProducts' \
  'Product\.products\(for:'
need "purchase uses product.purchase() and resolves the verified Purchase wire shape" "$SWIFT" \
  'func purchase' \
  '\.purchase\(\)' \
  '"transactionId"' \
  '"entitlement"'
need "restore reads Transaction.currentEntitlements (the StoreKit-cached source of truth)" "$SWIFT" \
  'func restore' \
  'Transaction\.currentEntitlements'
need "a long-lived Transaction.updates listener catches out-of-band changes (refund / Ask-to-Buy)" "$SWIFT" \
  'Transaction\.updates'
need "every transaction is VERIFIED (VerificationResult / .verified) — fail closed on .unverified" "$SWIFT" \
  '\.verified'
need "user-cancel maps to the wire code Billing.can decodes (user_cancelled)" "$SWIFT" \
  'userCancelled' \
  'user_cancelled'
need "the driver surfaces an entitlement-change callback into the portable stream" "$SWIFT" \
  'onEntitlementChange'
echo

# ── (B) the .mm forwards the one-shots to the driver + keeps the fake-store fallback ──────────────
echo "--> [B] CanopyBillingModule.mm owns the driver (iOS 15+), forwards the one-shots, keeps the fallback:"
need "the .mm imports the generated Swift header (guarded) + branches on CANOPY_HAS_STOREKIT2" "$MM" \
  '__has_include\("CanopyHostCore-Swift.h"\)' \
  'CANOPY_HAS_STOREKIT2'
need "the driver is constructed under the iOS-15 runtime check (the StoreKit 2 floor)" "$MM" \
  '@available\(iOS 15' \
  'CanopyBillingStoreKit2 +\*'
need "getProducts / purchase / restore forward to the driver" "$MM" \
  '\)_storeKit2 getProducts:' \
  '\)_storeKit2 purchase:' \
  '\)_storeKit2 restore:'
need "the driver's entitlement callback routes into the portable stream (billingEmitEntitlement)" "$MM" \
  'onEntitlementChange' \
  'billingEmitEntitlement'
need "the StoreKit-1 / fake-store fallback is still present (paywall always renders a price)" "$MM" \
  'fallbackProductJSON' \
  'grantFakePurchase' \
  'onNoProduct'
echo

# ── (C) product-id parity: lifetime_unlock identical across the Swift / .mm / .storekit / Android ─
echo "--> [C] the product id 'lifetime_unlock' is identical across the Swift driver / .mm / .storekit / Android:"
need "the Swift driver uses the lifetime_unlock product id" "$SWIFT" 'lifetime_unlock'
need "the .mm uses the lifetime_unlock product id (kProductId)" "$MM" 'kProductId = @"lifetime_unlock"'
need "the .storekit config declares the lifetime_unlock product id" "$STOREKIT" '"productID" : "lifetime_unlock"'
if [ -f "$ANDROID_BILLING" ]; then
  need "Android BillingModule.java uses the SAME product id (cross-platform parity)" "$ANDROID_BILLING" \
    'PRODUCT_ID = "lifetime_unlock"'
else
  red "    FAIL — Android BillingModule.java missing — can't cross-check the product id"; status=1
fi
echo

# ── (D) the .storekit Simulator config: a well-formed NonConsumable, attached to the scheme, not bundled
echo "--> [D] Products.storekit is a well-formed NonConsumable config, scheme-attached, not bundled into the .app:"
python3 - "$STOREKIT" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f: cfg = json.load(f)
except Exception as e:
    print("    \033[31mFAIL — Products.storekit is not valid JSON: %s\033[0m" % e); sys.exit(1)
fail = False
products = cfg.get('products', [])
unlock = [p for p in products if p.get('productID') == 'lifetime_unlock']
if not unlock:
    print("    \033[31mFAIL — no product with productID 'lifetime_unlock' in Products.storekit\033[0m"); fail = True
else:
    p = unlock[0]
    if p.get('type') != 'NonConsumable':
        print("    \033[31mFAIL — lifetime_unlock type is %r, expected 'NonConsumable' (a one-time unlock)\033[0m" % p.get('type')); fail = True
    else:
        print("    \033[32mOK  — lifetime_unlock is a NonConsumable (one-time unlock)\033[0m")
    if not p.get('displayPrice'):
        print("    \033[31mFAIL — lifetime_unlock has no displayPrice\033[0m"); fail = True
    else:
        print("    \033[32mOK  — lifetime_unlock has a displayPrice (%s)\033[0m" % p.get('displayPrice'))
    locs = p.get('localizations', [])
    if not (locs and locs[0].get('displayName') and locs[0].get('description')):
        print("    \033[31mFAIL — lifetime_unlock has no displayName/description localization\033[0m"); fail = True
    else:
        print("    \033[32mOK  — lifetime_unlock carries a displayName + description\033[0m")
sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || status=1
need "the scheme attaches the StoreKit config to the run + test actions" "$PROJECT" \
  'storeKitConfiguration: CanopyHostApp/Products\.storekit'
need "the .storekit config is EXCLUDED from the app target compile/bundle (Simulator-only)" "$PROJECT" \
  '"Products\.storekit"'
echo

# ── (E) the in-app-purchase entitlement + the iOS-15 StoreKit 2 floor ─────────────────────────────
echo "--> [E] the in-app-purchase entitlement is present (Debug + Release) and the deploy floor is iOS 15:"
python3 - "$ENT_DEBUG" "$ENT_RELEASE" <<'PY'
import plistlib, sys
fail = False
for label, path in (("Debug", sys.argv[1]), ("Release", sys.argv[2])):
    try:
        with open(path,'rb') as f: ent = plistlib.load(f)
    except Exception as e:
        print("    \033[31mFAIL — could not parse %s entitlements: %s\033[0m" % (label, e)); fail = True; continue
    if 'com.apple.developer.in-app-payments' in ent:
        print("    \033[32mOK  — %s entitlements carry com.apple.developer.in-app-payments (StoreKit)\033[0m" % label)
    else:
        print("    \033[31mFAIL — %s entitlements missing com.apple.developer.in-app-payments (StoreKit needs it)\033[0m" % label); fail = True
sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || status=1
need "the deployment target is iOS 15.1 (RN 0.76.9 min; ≥ the StoreKit 2 iOS-15 floor)" "$PROJECT" \
  'iOS: "15\.1"'
echo

# ── (F) the device-free Billing XCTest legs + the documented Simulator paywall run ────────────────
echo "--> [F] the device-free Billing XCTest legs pin the dispatch + wire shapes; the Simulator run is documented:"
need "CanopyCapabilityParityTests.mm pins the Billing dispatch + wire-shape legs" "$TEST" \
  'CanopyCapabilityParityTests \(Billing\)' \
  'testBillingDispatchContract' \
  'testBillingGetProductsResolvesTheContractCatalog' \
  'testBillingPurchaseRejectsUnknownProduct' \
  'testBillingRestoreResolvesTheEntitlementShape'
need "BUILD-AND-VALIDATE.md documents the StoreKit 2 paywall + the .storekit Simulator run" "$BUILDDOC" \
  'StoreKit 2' \
  'Products\.storekit'
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the iOS StoreKit 2 paywall is wired, transaction-verified, and store-parity with Android (lifetime_unlock)."
  green "            (Mac-gated: the real purchase/restore run is a Simulator with Products.storekit — or a sandbox device — per host/ios/BUILD-AND-VALIDATE.md.)"
else
  red "REGRESSION — the iOS StoreKit 2 paywall drifted. See plans/dependent/L-I5.md + host/ios/BUILD-AND-VALIDATE.md." >&2
fi
exit "$status"
