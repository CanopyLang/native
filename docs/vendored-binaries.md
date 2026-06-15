# Vendored `.so` storage — LFS vs fetch-script (CI-5)

The Android host links a few third-party prebuilt `.so` files. Two of them — the per-ABI
`libonnxruntime.so` — are ~27–33 MB each, so committing the full set made a fresh `git clone`
carry **~64 MB of binaries** that also churn on every React-Native / onnxruntime bump.

**Decision: do NOT use Git LFS. Keep the large, reproducible blobs out of the tree and fetch them
on demand**, byte-for-byte against the checksummed `host/vendor.lock.json`. A fresh clone now
materialises **~11 MB** of tracked content (well under the 50 MB CI-5 bar).

---

## What's committed vs fetched

| Artifact | Per-ABI size | Committed? | How it's obtained |
|---|---|---|---|
| `lib/<abi>/libhermes.so` | ~2.2 MB | **No** — fetched | `hermes-android-0.76.9-release.aar` → `jni/<abi>/libhermes.so` |
| `lib/<abi>/libjsi.so` | ~0.4 MB | **No** — fetched | `react-android-0.76.9-release.aar` → `jni/<abi>/libjsi.so` |
| `onnxruntime/lib/<abi>/libonnxruntime.so` | ~27–33 MB | **No** — fetched | `onnxruntime-android-1.26.0.aar` → `jni/<abi>/libonnxruntime.so` |
| `lib/<abi>/libfbjni.so` | ~0.17 MB | **Yes** — committed | n/a (see "Why fbjni stays" below) |
| `*-include/` header trees | ~5 MB total | **Yes** — committed | small, plain text; not worth fetching |

The three fetched families are reproducible **byte-identically** from a single public Maven
coordinate each — this was verified end-to-end (`scripts/revendor.sh fetch` re-downloads them and
`scripts/revendor.sh verify` is green afterward, with a clean `git status`). The lock records the
exact `sha256` for each, so the fetch can never silently install a wrong build.

### Why `libfbjni.so` stays committed

`libfbjni.so` is **small** (~0.35 MB total for both ABIs) and, unlike the others, is **not
reproducible** from the obvious upstream: the committed binary is a hand-stripped build whose exact
provenance was never recorded (different ELF build-id / size than fbjni 0.6.0's or react-android
0.76.9's own `libfbjni.so` — see the header of `scripts/revendor.sh`). There is nothing to fetch it
from deterministically, so it stays in git. It is excluded from the `.gitignore` rule via a `!`
un-ignore line.

---

## Restoring the blobs: `scripts/fetch-vendor.sh`

A fresh clone / CI runner restores the fetched `.so` with one toolchain-free command (needs only
`curl`, `unzip`, `sha256sum`, `jq` — **no** Haskell/stack):

```bash
./scripts/fetch-vendor.sh          # fetch every missing/mismatched fetchable .so, verify each
./scripts/fetch-vendor.sh --check  # report-only: non-zero if any are missing/drifted (no download)
./scripts/fetch-vendor.sh --force  # re-fetch even if present & matching
```

Properties:

- **Keyed to the lock.** The expected `sha256` for every file is read from `host/vendor.lock.json`;
  each extracted member is checked against it and a mismatch **aborts non-zero, naming the file**.
- **Idempotent.** A `.so` already on disk whose `sha256` matches the lock is skipped (no download).
  It only downloads the AARs whose members are actually missing/drifted.
- **Atomic.** Each file is written to `<dest>.new` then `mv`'d into place.
- **Version-overridable** for a bump: `CANOPY_RN_VERSION=… CANOPY_ONNX_VERSION=… ./scripts/fetch-vendor.sh`.

It is the lighter sibling of `scripts/revendor.sh fetch`: `revendor.sh fetch` also refreshes the
header trees and runs the full stack-based `vendor-verify`; `fetch-vendor.sh` just puts the `.so`
back with an inline per-file checksum gate — the right tool for the "bootstrap a clone" path.

---

## How CI consumes it

`.github/workflows/ci.yml` runs `scripts/fetch-vendor.sh` **before** any step that reads those
`.so` off disk:

- **`gate`** — before `scripts/revendor.sh verify` and `scripts/check-abi.sh`. (The vendor verifier
  treats a *missing* binary as a mismatch and `check-abi.sh` reads `libhermes.so`'s bytecode version,
  so both need the blobs present first.)
- **`android-release`** and **`android-instrumented`** — before the Gradle build, which packages the
  `.so` via `jniLibs.srcDirs` in `host/android/app/build.gradle`.

`jq`, `curl`, and `unzip` are preinstalled on the `ubuntu-latest` runner.

---

## Why a fetch-script, not Git LFS

- **No new infra / quota.** Git LFS needs an LFS-enabled remote and bandwidth/storage quota
  (GitHub bills LFS separately). The fetch-script reuses the public Maven mirror that already hosts
  these exact bytes — no extra hosting, no quota.
- **No smudge/clean friction.** LFS requires `git lfs install` on every clone; a missing LFS client
  silently checks out pointer files that then fail the C++ link with a confusing error. The
  fetch-script fails *loud and specific* (`sha256 drift for …`) instead.
- **Same integrity guarantee, made explicit.** The lock's `sha256` is the source of truth either
  way; the fetch-script verifies it inline on every fetch.
- **`git-lfs` is not even installed in the current dev/CI sandbox**, so an LFS path could not be
  validated here, whereas the fetch path is proven end-to-end against real upstream bytes.

LFS would only be the right call for a blob that is genuinely *unobtainable* from a stable public
URL. None of the fetched `.so` are in that category (all three resolve from Maven Central). The one
binary that *is* unobtainable-by-script — `libfbjni.so` — is tiny, so it is simply committed.

---

## Untracking & the (optional) history scrub

The blobs were untracked going forward with:

```bash
git rm --cached \
  host/android/vendor/lib/arm64-v8a/libhermes.so host/android/vendor/lib/x86_64/libhermes.so \
  host/android/vendor/lib/arm64-v8a/libjsi.so    host/android/vendor/lib/x86_64/libjsi.so \
  host/android/vendor/onnxruntime/lib/arm64-v8a/libonnxruntime.so \
  host/android/vendor/onnxruntime/lib/x86_64/libonnxruntime.so
```

…plus the `.gitignore` rules (which also block a stray `git add` from re-staging them).

`git rm --cached` stops tracking them **going forward**, but the ~63 MB still exist in historical
commits/packs. A **full clone** therefore stays large until a history rewrite; a **shallow clone**
(`git clone --depth 1`, what CI and a fresh dev box use) already drops them and is < 50 MB.

Rewriting history to reclaim the pack space is a destructive SHA-rewriting operation — **do not run
it unattended.** It is low-urgency here (the bytes are public + re-fetchable; the repo has no
remote). If a maintainer decides to scrub, do it reversibly (mirrors `docs/ci-secrets.md`):

```bash
git tag backup-pre-vendor-scrub && git branch backup-pre-vendor-scrub
pip3 install git-filter-repo   # NOT installed in the current sandbox
git filter-repo --force \
  --path host/android/vendor/lib/arm64-v8a/libhermes.so \
  --path host/android/vendor/lib/x86_64/libhermes.so \
  --path host/android/vendor/lib/arm64-v8a/libjsi.so \
  --path host/android/vendor/lib/x86_64/libjsi.so \
  --path host/android/vendor/onnxruntime/lib/arm64-v8a/libonnxruntime.so \
  --path host/android/vendor/onnxruntime/lib/x86_64/libonnxruntime.so \
  --invert-paths
git reflog expire --expire=now --all && git gc --prune=now
```
