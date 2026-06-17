# PATH B — on-device iOS testing from Linux

> Run the Canopy iOS host on a **physical iPhone**, driven from a **Linux** workstation.

iOS compilation + signing require a Mac (Apple's toolchain is macOS-only). Everything else —
discovering the iPhone, registering it with Apple, installing the `.ipa`, and reading device
logs — runs on Linux via [libimobiledevice](https://libimobiledevice.org/). PATH B splits the
work along exactly that line:

```
  ┌─────────────── Mac (GitHub macOS CI  OR  remote-build.sh) ───────────────┐
  │  canopy-native build  →  xcodebuild archive  →  xcodebuild -exportArchive │
  │                              (signed device .ipa)                         │
  └───────────────────────────────────┬──────────────────────────────────────┘
                                       │  artifact / scp
  ┌────────────────────────────────────▼─────────────── Linux (this repo) ───┐
  │  scripts/ios-device.sh  register → install → logs   (libimobiledevice)    │
  │                          → app running on your iPhone                      │
  └───────────────────────────────────────────────────────────────────────────┘
```

There is **no Mac-free path** for this project: the host links Hermes/Yoga (binary CocoaPods),
ObjC++/C++, and uses keychain/IAP/push entitlements — which rules out `xtool` and every Linux
cross-compiler. The Mac is unavoidable; we just keep it to the compile+sign step.

---

## Two lanes

| Lane | Cert / profile | Install | Debugging | Account |
|---|---|---|---|---|
| **adhoc** (`release-testing`) | Apple Distribution + ad-hoc profile, **production** entitlements | ✅ ideviceinstaller (UDID must be in profile) | `idevicesyslog` logs; **not** lldb-attachable | **Paid ($99/yr)** |
| **development** | Apple Development + development profile, `get-task-allow=true` | ✅ ideviceinstaller (UDID must be in profile) | logs **+ lldb attach** | Paid, or **free Apple ID** (7-day expiry, 3 apps) |

Use **adhoc** for production-like validation, **development** for deep debugging (or if you only
have a free Apple ID). Both are produced by CI and by `remote-build.sh`.

## Two build engines

- **GitHub macOS CI** — the `ios-build` job builds + signs both lanes as downloadable artifacts
  (`ios-device-ipa-adhoc`, `ios-device-ipa-development`). No Mac of your own. (Private-repo macOS
  minutes bill ~10×.)
- **Remote Mac** (`host/ios/remote-build.sh`) — drive a Mac you own/rent over SSH; faster
  iteration, no CI minutes.

---

## One-time setup

### 1. Paid Apple Developer account → CI/remote secrets

PATH B is gated on a real Team ID; the build steps **self-skip** until it is set, so CI stays green
without an account. Set the four secrets (also see [`ci-secrets.md` §3](./ci-secrets.md)):

| Secret | Needed for |
|---|---|
| `APPLE_TEAM_ID` | both lanes (signing team) — **the gate** |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_API_KEY_P8` | TestFlight upload **and** `ios-device.sh register` |

The development lane (only) also works with a **free** Apple ID via `remote-build.sh` on a Mac
signed into Xcode — but CI uses the paid team.

### 2. libimobiledevice on Linux

```bash
sudo apt install libimobiledevice-utils ideviceinstaller    # Debian/Ubuntu
# Arch: pacman -S libimobiledevice  +  AUR: ideviceinstaller
```

### 3. Connect + trust the iPhone, read its UDID

Plug in via USB, unlock, tap **Trust This Computer**, then:

```bash
scripts/ios-device.sh doctor     # checks tooling + that the phone is connected & trusted
scripts/ios-device.sh udid       # prints the UDID Apple needs
```

### 4. Register the device with Apple (so the profile signs for it)

A development/ad-hoc profile only signs for **registered** devices. CI can't register one (no
device attached), so do it once from Linux:

```bash
# Uses the ASC API key (export the same values you put in CI secrets):
export ASC_KEY_ID=ABCDE12345 ASC_ISSUER_ID=xxxx-xxxx ASC_API_KEY_P8=~/AuthKey_ABCDE12345.p8
scripts/ios-device.sh register --name "Quinten iPhone"
```

No ASC key handy? The script prints the manual fallback:
<https://developer.apple.com/account/resources/devices/add> (paste the UDID).

> After registering, the **next** signed build picks it up automatically — `-allowProvisioningUpdates`
> regenerates the profile to include all registered devices.

---

## Per-run loop

### Engine A — GitHub macOS CI

```bash
git push                                   # triggers the ios-build job (builds both lanes)
# …once the run is green:
scripts/ios-device.sh run --lane adhoc     # fetch latest artifact → install → tail logs
#   or step by step:
scripts/ios-device.sh fetch --lane development   # gh run download ios-device-ipa-development
scripts/ios-device.sh install                    # installs the freshest cached .ipa
scripts/ios-device.sh logs                       # device console, filtered to the app
```

`fetch` needs the [`gh`](https://cli.github.com/) CLI authenticated to the repo.

### Engine B — remote Mac

```bash
cp host/ios/.remote-build.env.example host/ios/.remote-build.env   # set MAC_SSH, APPLE_TEAM_ID, …
# ad-hoc (production-like):
EXPORT_METHOD=release-testing host/ios/remote-build.sh sync gen build archive export
# development (lldb-attachable / free-account):
ARCHIVE_CONFIG=Debug EXPORT_METHOD=development host/ios/remote-build.sh archive export
# the .ipa is pulled to host/ios/remote-artifacts/CanopyHost.ipa — install it from Linux:
scripts/ios-device.sh install host/ios/remote-artifacts/CanopyHost.ipa
scripts/ios-device.sh logs
```

---

## Android, for symmetry

Android needs **no Mac** — full on-device E2E runs entirely from this Linux box:

```bash
bash scripts/build-app-bundle.sh                              # build the JS bundle
cd host/android && ./gradlew :app:assembleDebug
adb install -r -g app/build/outputs/apk/debug/app-debug.apk
cd ../../e2e && npm install && bash run-appium-ci.sh          # smoke flow on the device
bash ../scripts/perf-android.sh --app ../examples/uifixture   # real-arm64 frame metrics
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `install` fails, "device not in profile" | UDID not registered → `ios-device.sh register`, then **rebuild** so the profile updates |
| App installs but won't launch / "no longer available" | free-account 7-day profile expired → rebuild + reinstall |
| `install` rejects the `.ipa` | it's a **simulator** build — use the `adhoc`/`development` device lanes, not the app-store/TestFlight artifact |
| `doctor`: device seen but name `?` | not trusted yet — unlock the phone, tap **Trust** |
| no device at all | `sudo systemctl start usbmuxd`; reseat the cable; unlock the phone |
| CI device-lane artifacts missing | `APPLE_TEAM_ID` secret not set (steps self-skip) |

## See also
- [`ci-secrets.md`](./ci-secrets.md) — the secret table
- [`device-farm.md`](./device-farm.md) — running the smoke flow on a fleet of real devices (BrowserStack)
- `host/ios/remote-build.sh` — the SSH build harness; `host/ios/BUILD-AND-VALIDATE.md` — the full iOS bring-up
- `scripts/ios-device.sh --help` — the Linux device tool
