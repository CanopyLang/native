# iOS TestFlight upload (IOS-11)

This page is the operational runbook for the **TestFlight** half of the iOS release pipeline: how the
signed `.ipa` produced by IOS-10 is uploaded to App Store Connect and lands on an internal TestFlight
group, what Apple account / Mac you need, and how the whole chain is driveable from the Linux dev box.

IOS-11 **builds on IOS-10**. IOS-10 produces a signed, App-Store-clean `CanopyHost.ipa`
(`host/ios/remote-build.sh archive` → `export`). IOS-11 adds the **upload**:
`host/ios/remote-build.sh testflight` (and the all-in-one `release`).

> **Honest status (2026-06):** like every iOS step, this is **Mac-gated** — `xcrun altool` only runs
> on macOS — and additionally **gated on a paid Apple Developer account** with an App Store Connect
> **app record** for `com.canopyhost.app`. There is no Mac and no Apple account wired to this repo, so
> the upload has **never run**. What IS verified on Linux: the pipeline is wired + fail-closed + leak-
> free (`scripts/check-ios-testflight.sh`, in the device-free gate), and the workflow is
> actionlint-clean. This page is the checklist to flip it green on a real Mac + account.

---

## What you need (the gates, stated plainly)

| Requirement | Why | Where it bites if missing |
|---|---|---|
| **A Mac with Xcode** | `xcrun altool` (the ASC upload CLI) is macOS-only; it ships with Xcode (no extra install). | The Linux box cannot upload — drive a Mac over SSH (`remote-build.sh`) or use a macOS CI runner. |
| **A paid Apple Developer account** | Required for a distribution cert + a real App ID + App Store Connect access. Same gate as IOS-10. | IOS-10 `archive` already fails LOUD without `APPLE_TEAM_ID`. |
| **An App Store Connect *app record*** for `com.canopyhost.app` | The upload targets an existing app; ASC rejects an `.ipa` whose bundle id has no app record. | `altool --upload-app` errors: no app found for the bundle id. Create it once in App Store Connect ▸ My Apps ▸ +. |
| **An App Store Connect *API key* (.p8)** with the **App Manager** (or Admin) role | The CI-friendly, 2FA-proof auth altool uses (`--apiKey`/`--apiIssuer`). NOT an Apple-ID password. | Without the three creds (`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_API_KEY_P8`) the upload `die`s up front. |
| **A *unique* build number** (`CFBundleVersion`) per upload | ASC rejects a build number it has already seen for that marketing version. | `altool --upload-app` errors on a duplicate. Bump `CURRENT_PROJECT_VERSION` in `host/ios/project.yml` each upload. |

### Why an API key, not an Apple-ID password

altool can authenticate two ways: an Apple-ID + app-specific password (`-u`/`-p`), or an **App Store
Connect API key** (`--apiKey`/`--apiIssuer` + the `.p8` private key). We use the **API key** because it
is 2FA-proof (no interactive prompt), revocable independently of any human's Apple ID, and the standard
for CI. The pipeline never references the password path.

### Why altool (not Transporter / Fastlane / notarytool)

- **altool** ships with Xcode, speaks the ASC API key directly, and `--validate-app` runs the **same**
  pre-upload App-Store-Connect validation the Organizer GUI runs — so a bad build is caught before it
  consumes an upload slot. It is the lowest-dependency path.
- **notarytool** notarizes a *Developer-ID* app (a directly-distributed `.app`/`.dmg`), **not** an App
  Store `.ipa`. App Store builds are not notarized by you — Apple processes them server-side. So
  notarytool is intentionally **not** used here.
- **Fastlane/Transporter** would add a toolchain to install on the Mac for no gain over altool.

---

## Minting the App Store Connect API key (one-time)

1. App Store Connect ▸ **Users and Access** ▸ **Integrations** ▸ **App Store Connect API**.
2. Create a key with the **App Manager** role (Admin also works; a weaker role cannot upload builds).
3. Note the **Key ID** (10 chars, e.g. `ABC1234XYZ`) and the **Issuer ID** (a UUID at the top of the
   tab) — these become `ASC_KEY_ID` and `ASC_ISSUER_ID`.
4. **Download the `.p8`** — *you can only download it once.* It is named `AuthKey_<KeyID>.p8`. Keep it
   off the repo; put it somewhere on the Mac and point `ASC_API_KEY_P8` at that path.

The `.p8`, the Key ID, and the Issuer ID together are the full credential. Treat the `.p8` like a
password. The repo refuses to track it: `host/ios/.gitignore` excludes `*.p8`, `AuthKey_*.p8`, and the
`private_keys/` dir, and `scripts/check-ios-testflight.sh` fails the gate if a `.p8` ever appears under
`host/ios`.

---

## Uploading from the Linux dev box (the automated path)

The same `host/ios/remote-build.sh` harness that drives the simulator build and the IOS-10 archive also
drives the upload over SSH to your Mac. Set the creds in the gitignored `host/ios/.remote-build.env`:

```bash
cp host/ios/.remote-build.env.example host/ios/.remote-build.env
# then edit it — set MAC_SSH, REMOTE_DIR, APPLE_TEAM_ID, and the three ASC vars:
#   APPLE_TEAM_ID="ABCDE12345"
#   ASC_KEY_ID="ABC1234XYZ"
#   ASC_ISSUER_ID="11111111-2222-3333-4444-555555555555"
#   ASC_API_KEY_P8="/Users/ci/asc/AuthKey_ABC1234XYZ.p8"   # this path is ON THE MAC
```

Then, after a `gen` (Part 2 of `BUILD-AND-VALIDATE.md`), run the whole chain:

```bash
# the all-in-one: archive (IOS-10) -> export (IOS-10) -> validate (dry-run) -> testflight (upload)
./host/ios/remote-build.sh release
```

…or step-by-step, so each phase's log lands in `host/ios/remote-artifacts/`:

```bash
./host/ios/remote-build.sh archive      # IOS-10: signed Release device archive  -> CanopyHost.xcarchive
./host/ios/remote-build.sh export       # IOS-10: -exportArchive (app-store-connect) -> CanopyHost.ipa
./host/ios/remote-build.sh validate     # IOS-11: altool --validate-app (ASC dry-run; consumes no slot)
./host/ios/remote-build.sh testflight   # IOS-11: altool --upload-app -> App Store Connect / TestFlight
```

`validate` is worth running first: it runs App Store Connect's real validation **without** uploading,
so a duplicate build number / missing entitlement / unprovisioned capability surfaces before you burn
an upload. The harness pulls `validate-app.log` and `upload-app.log` back to `remote-artifacts/`.

### What the upload does under the hood

On the Mac, in the synced `ios/` dir, the harness runs (the `.p8` is staged into a per-run
`private_keys/` so altool resolves `AuthKey_<KeyID>.p8`, then deleted afterwards):

```bash
export API_PRIVATE_KEYS_DIR="$PWD/private_keys"
xcrun altool --upload-app \
  --type ios \
  --file build/export/CanopyHost.ipa \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID" \
  --output-format normal
```

`--upload-app` reads the bundle id / version / build number out of the `.ipa` itself (the single source
of truth is `host/ios/project.yml`: `PRODUCT_BUNDLE_IDENTIFIER` / `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION`) — nothing is hand-passed.

### After a successful upload

altool returns **before** TestFlight finishes processing — Apple emails you when the build is "Ready to
Test". Then:

1. App Store Connect ▸ your app ▸ **TestFlight** ▸ **Builds** — wait for the build to leave "Processing".
2. Add it to the **internal** test group (internal testers are App Store Connect users on your team; no
   Beta App Review needed — that is the fast "ships on both stores" litmus the plan calls for).
3. Testers install via the TestFlight app. Validate on a **Neural-Engine device** (the
   `RestoreEngine` Core ML path) per the IOS-11 plan note.

---

## Uploading from CI (the macOS-runner path)

The `ios-build` job in `.github/workflows/ci.yml` does IOS-10 (archive + export → `CanopyHost.ipa`)
and then, **gated on the ASC secrets**, runs the IOS-11 TestFlight upload step. It self-skips when the
secrets are absent, so a Mac runner with no Apple account still goes green. The three secrets are
documented in `docs/ci-secrets.md`:

| Secret | Contents |
|---|---|
| `ASC_KEY_ID` | the App Store Connect API **Key ID** (10 chars) |
| `ASC_ISSUER_ID` | the **Issuer ID** (UUID) for that key |
| `ASC_API_KEY_P8` | the **contents** of the `AuthKey_<KeyID>.p8` file (the job writes it to a runner-local `private_keys/` it deletes after) |

`APPLE_TEAM_ID` (the IOS-10 signing secret) must also be set, or the archive/export step that produces
the `.ipa` self-skips and there is nothing to upload.

---

## Honest scope — verified vs. not

- **Verified on the Linux dev box:** `remote-build.sh help` lists `validate`/`testflight`/`release`;
  the subcommands dispatch; the missing-creds preflight `die`s LOUD; the generated remote `altool`
  bash is syntactically valid and uses `--apiKey`/`--apiIssuer` (never a password); the export channel
  is `app-store-connect`; `.gitignore` blocks `*.p8` / `private_keys/`; no `.p8` or literal Key/Issuer
  ID is tracked; `scripts/check-ios-testflight.sh` is **green**; the workflow is actionlint-clean.
- **NOT verified here (Mac + paid-account-gated):** the real `xcrun altool --validate-app` /
  `--upload-app`, the App Store Connect ingestion, TestFlight processing, and the on-device install +
  Neural-Engine validation. There is no Mac and no Apple account on this box. The pipeline is authored
  + structurally gated; only the signed upload is Mac-and-account-bound.
</content>
