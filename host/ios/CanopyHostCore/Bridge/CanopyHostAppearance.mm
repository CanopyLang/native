// CanopyHostAppearance.mm — the appearance-seam constant + the current-scheme reader.
//
// Compiled as Objective-C++ (the .mm extension matches the rest of Bridge/); the body is plain
// ObjC. See CanopyHostAppearance.h for the contract.

#import "CanopyHostAppearance.h"

NSString *const CanopyHostColorSchemeDidChangeNotification =
    @"CanopyHostColorSchemeDidChangeNotification";

NSString *CanopyHostCurrentColorScheme(void) {
  UITraitCollection *traits = nil;

  // Prefer the foreground-active window scene's key window — that is the surface the user sees
  // and whose trait collection reflects the live light/dark setting.
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    UIWindow *window = windowScene.keyWindow ?: windowScene.windows.firstObject;
    if (window != nil) {
      traits = window.traitCollection;
      if (scene.activationState == UISceneActivationStateForegroundActive) { break; }
    }
  }
  if (traits == nil) { traits = UIScreen.mainScreen.traitCollection; }

  return (traits.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
}
