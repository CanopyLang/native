# App Store Guideline 2.5.2 — the one real risk

The feasibility study flags this as the highest-likelihood thing to bite, and it is a
**policy** constraint, not a technical one. Treat it as a design rule from day one.

## What 2.5.2 says
Apps may not download, install, or execute code that introduces or changes features
beyond what Apple reviewed.

## Why canopy/native is fine by default
Running an interpreter / JS engine on **bundled** code is explicitly permitted — this is
exactly why React Native, Hermes, and JavaScriptCore apps pass review. `canopy/native`
has the **identical posture**:

- Canopy compiles to JS (`canopy-native build`).
- The JS ships **inside the app bundle** (`canopy.bundle.js`, packaged like any asset).
- Hermes runs it. No code is downloaded at runtime.

✅ For a normally-released app, there is **no 2.5.2 problem**. Same trail React Native
has worn smooth.

## The trap: over-the-air (OTA) Canopy code
Because Canopy can hot-deploy new screens cheaply, it is tempting to push *new* Canopy
code over the air to change app behavior. OTA JS **is** tolerated, but only within narrow
limits (the CodePush / Expo-updates precedent: bug-fix and content updates that do **not**
change the app's core purpose). Policies tighten over time.

**Rule:** do **not** let "hot-deploy new screens" become a core feature assumption.
Design for *bundled-and-reviewed* as the default; treat OTA as a constrained,
bug-fix-only capability if used at all.

## Asymmetry: Apple vs Google
Google Play is materially more permissive on OTA. **Architect to Apple's rule and Android
is automatically satisfied.**

## Own-the-stack caveat (deferred Phase 5)
An AOT / own-engine build (Static Hermes) is *also* fine when bundled, but it re-blazes a
trail Apple has not seen, versus React Native's heavily-trodden one — another reason to
start on the host and defer the own-engine path.

## Sources
- Apple Review Guidelines — https://developer.apple.com/app-store/review/guidelines/
- saagarjha, "Fixing Section 2.5.2" — https://saagarjha.com/blog/2020/11/08/fixing-section-2-5-2/
- OTA policy (Apple/Google) — https://bitrise.io/blog/post/what-app-stores-allow-with-ota-updates-apple-and-google-policy-explained
