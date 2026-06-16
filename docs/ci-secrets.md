# CI secrets & the release keystore

The Android **release keystore is never committed** to the repo. It is `.gitignore`d
(`*.jks` + the explicit `host/android/canopy-release.jks` line) and was untracked with
`git rm --cached host/android/canopy-release.jks`. This page is the single source of truth for:

1. regenerating the dev keystore locally (so a signed release APK builds out of the box), and
2. the GitHub Actions secrets the `android-release` job materializes the keystore from.

---

## 1. The dev keystore (local builds)

For local validation `host/android/app/build.gradle` falls back to `../canopy-release.jks`
with the public dev password `canopypass`. That file is **not** in the repo on a fresh clone —
regenerate the identical throwaway, self-signed dev cert once:

```bash
keytool -genkeypair \
  -keystore host/android/canopy-release.jks \
  -storetype PKCS12 \
  -alias canopy \
  -storepass canopypass \
  -keypass canopypass \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Canopy Native, OU=Dev, O=Canopy, L=, ST=, C=US"
```

This is a **development** key only. It is deliberately weak (public password) and is fine to lose:
it never signs anything published to Play. The real Play upload/app-signing key must be a separate,
secret keystore that is supplied to CI via the secrets below and **never** written to disk in the repo.

> Honest risk note: because the previously-committed `canopy-release.jks` was a throwaway
> self-signed dev key with an already-public password (`canopypass`, documented in
> `app/build.gradle`) and the repo was never pushed to a remote, untracking it going forward is
> sufficient hygiene. A full git-history scrub of the blob is *optional* defense-in-depth, not a
> leaked-production-key emergency. See "History scrub (optional, human-gated)" below.

---

## 2. GitHub Actions secrets

Set these four repository secrets (Settings → Secrets and variables → Actions). The
`android-release` job decodes the keystore from base64 and passes the passwords through to Gradle.

| Secret | Contents |
|---|---|
| `CANOPY_KEYSTORE_BASE64` | base64-encoded `.jks` file (see command below) |
| `CANOPY_STORE_PASSWORD`  | keystore (store) password |
| `CANOPY_KEY_ALIAS`       | key alias (e.g. `canopy`) |
| `CANOPY_KEY_PASSWORD`    | key (alias) password |

### Encode the keystore for the `CANOPY_KEYSTORE_BASE64` secret

```bash
# macOS / Linux — produces a single base64 line with no wrapping
base64 -w0 host/android/canopy-release.jks            # GNU coreutils (Linux)
base64    host/android/canopy-release.jks | tr -d '\n'  # BSD/macOS (no -w flag)
```

Paste the resulting string as the value of `CANOPY_KEYSTORE_BASE64`.

### How CI consumes them

The `android-release` job (`.github/workflows/ci.yml`) writes the keystore to disk from the secret
and hands signing to Gradle via project properties — `app/build.gradle`'s
`signingConfigs.release` already reads exactly these property names:

```yaml
- name: Materialize the release keystore from the base64 secret
  working-directory: host/android
  run: echo "$CANOPY_KEYSTORE_BASE64" | base64 -d > canopy-release.jks
  env:
    CANOPY_KEYSTORE_BASE64: ${{ secrets.CANOPY_KEYSTORE_BASE64 }}

- name: Assemble signed release (R8 shrink + sign)
  working-directory: host/android
  run: |
    ./gradlew :app:assembleRelease --console=plain \
      -PCANOPY_STORE_FILE=../canopy-release.jks \
      -PCANOPY_STORE_PASSWORD="$CANOPY_STORE_PASSWORD" \
      -PCANOPY_KEY_ALIAS="$CANOPY_KEY_ALIAS" \
      -PCANOPY_KEY_PASSWORD="$CANOPY_KEY_PASSWORD"
  env:
    CANOPY_STORE_PASSWORD: ${{ secrets.CANOPY_STORE_PASSWORD }}
    CANOPY_KEY_ALIAS: ${{ secrets.CANOPY_KEY_ALIAS }}
    CANOPY_KEY_PASSWORD: ${{ secrets.CANOPY_KEY_PASSWORD }}
```

The materialized `canopy-release.jks` is git-ignored, so it can never be accidentally committed back.

---

## 3. iOS signing + TestFlight secrets (IOS-10 / IOS-11)

The iOS `.ipa` is signed (IOS-10) and uploaded to TestFlight (IOS-11) by the `ios-build` job. Like the
Android keystore, **no Apple credential is ever committed**: the Team ID is injected at archive time
and the App Store Connect API key is materialized from secrets into a runner-local path the job
deletes. All of these self-skip when unset, so a Mac runner with no Apple account stays green.

| Secret | Used by | Contents |
|---|---|---|
| `APPLE_TEAM_ID` | IOS-10 archive/export | the 10-char Apple Developer Team ID (the signing team) |
| `ASC_KEY_ID` | IOS-11 TestFlight upload | the App Store Connect API **Key ID** (10 chars) |
| `ASC_ISSUER_ID` | IOS-11 TestFlight upload | the **Issuer ID** (UUID) for that key |
| `ASC_API_KEY_P8` | IOS-11 TestFlight upload | the **contents** of the `AuthKey_<KeyID>.p8` private key |

Set these as repository secrets (Settings → Secrets and variables → Actions). Mint the API key (and the
`.p8`) per `docs/ios-testflight.md` — it needs the **App Manager** role. How CI consumes them:

```yaml
# IOS-10: the Team ID is surfaced into the job env so a step-level `if:` can gate on it.
env:
  APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
  ASC_KEY_ID:    ${{ secrets.ASC_KEY_ID }}
  ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}

# IOS-11: write the .p8 from the secret to a runner-local private_keys/ altool resolves, then upload,
# then delete the key. Gated on the ASC creds so it self-skips when no account is configured.
- name: Upload to TestFlight (IOS-11 — gated on the App Store Connect API key)
  if: ${{ env.APPLE_TEAM_ID != '' && env.ASC_KEY_ID != '' }}
  working-directory: host/ios
  env:
    ASC_API_KEY_P8: ${{ secrets.ASC_API_KEY_P8 }}
  run: |
    mkdir -p private_keys
    printf '%s' "$ASC_API_KEY_P8" > "private_keys/AuthKey_${ASC_KEY_ID}.p8"
    export API_PRIVATE_KEYS_DIR="$PWD/private_keys"
    trap 'rm -f "private_keys/AuthKey_${ASC_KEY_ID}.p8"' EXIT
    xcrun altool --upload-app --type ios --file build/export/CanopyHost.ipa \
      --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format normal
```

The `private_keys/` dir is git-ignored (`host/ios/.gitignore`) and deleted on step exit, so the `.p8`
never persists. `scripts/check-ios-testflight.sh` fails the device-free gate if any `.p8` is ever
tracked under `host/ios`.

---

## History scrub (optional, human-gated)

`git rm --cached` stops tracking the keystore **going forward** but the blob still exists in the 6
historical commits. Removing it from history rewrites every commit SHA and is therefore a destructive,
human-sign-off operation — **do not run it unattended**. It is also low-urgency here (throwaway dev key,
public password, repo never pushed).

If a maintainer decides to scrub it, do it reversibly:

```bash
# 1. Make it reversible
git tag    backup-pre-scrub
git branch backup-pre-scrub

# 2. Preferred tool (NOT installed in the current sandbox; install first)
pip3 install git-filter-repo
git filter-repo --path host/android/canopy-release.jks --invert-paths --force

# 2b. Fallback if git-filter-repo is unavailable
git filter-branch --index-filter \
  'git rm --cached --ignore-unmatch host/android/canopy-release.jks' \
  --prune-empty -- --all
git reflog expire --expire=now --all && git gc --prune=now

# 3. Verify the blob is gone from ALL history (must print nothing)
for c in $(git rev-list --all); do
  git cat-file -e "$c:host/android/canopy-release.jks" 2>/dev/null && echo "LEAK $c"
done
git fsck
```

Because there is currently **no git remote**, the scrub is local-only and reversible via the backup
tag/branch — but the SHA rewrite still warrants a human in the loop before it lands.
