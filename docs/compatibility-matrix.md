# canopy/native — Compatibility matrix (vs RN core + Expo SDK essentials)

> Generated from `docs/compatibility-matrix.json` by `scripts/check-compatibility-matrix.sh` — do not edit by hand.

**Capability coverage:** 18/27 essential modules = **67%** · **Component coverage:** 12/20 = **60%**

## Components

| Component | canopy | RN analog | notes |
|---|---|---|---|
| View | have | View | flexbox via Yoga |
| Text | have | Text | RCTText/RCTRawText; lone-text fast path |
| Image | have | Image | RCTImageView (declarative) + CanopyBitmap (blob) |
| ScrollView | have | ScrollView | separate Yoga content root; momentum/refresh |
| TextInput | have | TextInput | single-line; controlled value; keyboardType |
| TextInputMultiline | partial | TextInput multiline | single-line solid; multiline grow path partial |
| Switch | have | Switch | RCTSwitch → valueChange |
| Pressable/Button | have | Pressable/Button | press/longPress/pressIn/out via gesture recognizers |
| Modal | have | Modal | CanopyModalHost; transparent/animationType/visible |
| ActivityIndicator | have | ActivityIndicator |  |
| StatusBar | have | StatusBar | CanopyStatusBar / AppShell setStatusBarStyle |
| List (windowed) | have | FlatList | Native.List windowing; lazy rows → zero off-window work (RND-6) |
| SectionList | planned | SectionList |  |
| RefreshControl | partial | RefreshControl | ScrollView refresh event present; full control surface partial |
| SafeAreaView | partial | SafeAreaView/insets | container relayout from bounds; explicit safe-area inset API planned |
| KeyboardAvoidingView | planned | KeyboardAvoidingView | keyboard reflow exists on iOS; declarative component planned |
| BeforeAfter | have | (canopy-specific) | CALayer/Canvas wipe compositor — not an RN primitive |
| Slider | planned | @react-native-community/slider |  |
| Picker | planned | @react-native-picker/picker |  |
| WebView | none | react-native-webview | out of scope (the thesis is no-WebView) |

## Capabilities (native modules)

| Capability | canopy | Expo analog | notes |
|---|---|---|---|
| Http | have | expo fetch / axios | request; streaming/multipart/WS planned (S3) |
| StorageSecure | have | expo-secure-store | Keychain / EncryptedSharedPreferences |
| Photos | have | expo-image-picker | PHPicker / photo picker → blob |
| Album | have | expo-media-library | save image to library |
| ShareImage | have | expo-sharing | share sheet with a blob image |
| Notify | have | expo-notifications (local) | LOCAL only; remote push (FCM/APNs) planned (Cap M6) |
| Image | have | expo-image-manipulator | decode/encode/resize via blob registry |
| Billing | have | expo-in-app-purchases | Play Billing v6 / StoreKit 2 |
| Lifecycle | have | AppState | foreground/background/memory-pressure Sub |
| AppShell | have | expo-status-bar / appearance | status-bar style + colorScheme Sub |
| Platform | have | expo-linking + expo-clipboard | openURL + clipboard |
| Vibration | have | Vibration / expo-haptics |  |
| Haptics | have | expo-haptics | impact/selection feedback |
| Battery | have | expo-battery |  |
| Brightness | have | expo-brightness |  |
| DeviceInfo | have | expo-device |  |
| NetInfo | have | @react-native-community/netinfo | connectivity Sub |
| RestoreEngine | have | (canopy-specific ML) | Core ML / ONNX super-resolution — not an Expo module |

## Known gaps (planned / partial)

| Gap | kind | canopy | Expo analog | priority |
|---|---|---|---|---|
| Camera | capability | planned | expo-camera | high |
| Location | capability | planned | expo-location | high |
| Sensors | capability | planned | expo-sensors | medium |
| Filesystem | capability | planned | expo-file-system | high |
| Audio/Video | capability | planned | expo-av | medium |
| Contacts | capability | planned | expo-contacts | low |
| Biometrics | capability | planned | expo-local-authentication | medium |
| RemotePush | capability | planned | expo-notifications (push) | high |
| DeepLinks | capability | partial | expo-linking (universal) | medium |
