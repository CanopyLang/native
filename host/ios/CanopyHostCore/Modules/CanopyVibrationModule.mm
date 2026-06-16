// CanopyVibrationModule.mm — the iOS host module behind Native.Vibration (module "Vibration").
//
// iOS analog of android/.../modules/VibrationModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 CanopyNativeModuleBridge wraps it into a canopy::NativeModule and registers it, so
// __canopy_call(module="Vibration", method, …) routes to -invokeMethod: here.
//
// Wire contract (must match Vibration.can and VibrationModule.java):
//   vibrate {ms} -> null      cancel {} -> null
//
// PLATFORM DIVERGENCE (documented per IOS-7 / contract §0.3): iOS has NO public "vibrate for N
// milliseconds" API — Android's Vibrator.vibrate(ms)/createOneShot has no UIKit equivalent. The
// faithful analog is Core Haptics (CHHapticEngine): a single CONTINUOUS haptic event whose
// duration is the requested `ms` reproduces "buzz for N ms" with the same intent (and far better
// fidelity) on every haptics-capable iPhone. On hardware WITHOUT Core Haptics (older devices, iPad,
// the Simulator), we fall back to AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) — the
// classic fixed-length system vibration — so `vibrate` always does the right thing. `cancel` stops
// the running engine (the analog of Vibrator.cancel). No permission is required on iOS (no VIBRATE
// entitlement), unlike Android's android.permission.VIBRATE.
//
// The CHHapticEngine is created lazily on first vibrate and retained so `cancel` can stop it and a
// rapid second vibrate reuses it. CoreHaptics start/playback is fast; the engine APIs are
// thread-safe, so we run on a private serial queue and resolve from there (the CanopyComplete block
// hops to JS internally — no manual main-hop).

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreHaptics/CoreHaptics.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyVibrationModule : NSObject <CanopyModule> {
  // Lazily-created Core Haptics engine, retained so cancel can stop it + a re-vibrate reuses it.
  CHHapticEngine *_engine;
  id<CHHapticPatternPlayer> _player;
  dispatch_queue_t _queue;
}
@end

@implementation CanopyVibrationModule

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.canopyhost.vibration", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSString *)moduleName { return @"Vibration"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  BOOL known = [method isEqualToString:@"vibrate"] || [method isEqualToString:@"cancel"];
  if (!known) { return NO; }  // unknown → ModuleNotFound

  NSDictionary *args = CanopyParseArgs(argsJson);

  dispatch_async(_queue, ^{
    @try {
      if ([method isEqualToString:@"cancel"]) {
        [self stopEngine];
        CanopyResolveNull(complete);
        return;
      }

      // vibrate: default 200ms (matching VibrationModule.java's optLong("ms", 200L)). Follows the
      // CanopyImageModule numeric-arg idiom: nil-check, then -doubleValue (NSNumber or numeric-string).
      double ms = args[@"ms"] ? [args[@"ms"] doubleValue] : 200.0;
      if (ms <= 0) { ms = 200.0; }
      double seconds = ms / 1000.0;

      if (![self vibrateForSeconds:seconds]) {
        // No Core Haptics on this device — fall back to the fixed-length system vibration. This is
        // the best iOS can do without CoreHaptics (the system buzz ignores `ms`), and it keeps
        // `vibrate` truthful on the Simulator / older hardware.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
      }
      CanopyResolveNull(complete);
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"Vibration: unexpected error");
    }
  });
  return YES;
}

// Run a single continuous haptic event of `seconds` on the lazily-created engine. Returns NO when
// Core Haptics is unavailable (so the caller falls back to the system vibration).
- (BOOL)vibrateForSeconds:(double)seconds {
  if (![CHHapticEngine capabilitiesForHardware].supportsHaptics) { return NO; }

  NSError *err = nil;
  if (_engine == nil) {
    _engine = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (_engine == nil || err != nil) { _engine = nil; return NO; }
  }
  if (![_engine startAndReturnError:&err] || err != nil) { return NO; }

  CHHapticEventParameter *intensity =
      [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                    value:1.0f];
  CHHapticEventParameter *sharpness =
      [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                    value:0.5f];
  CHHapticEvent *event =
      [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                    parameters:@[ intensity, sharpness ]
                                  relativeTime:0
                                      duration:seconds];

  CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ event ]
                                                          parameters:@[]
                                                               error:&err];
  if (pattern == nil || err != nil) { return NO; }

  id<CHHapticPatternPlayer> player = [_engine createPlayerWithPattern:pattern error:&err];
  if (player == nil || err != nil) { return NO; }

  _player = player;
  if (![player startAtTime:0 error:&err] || err != nil) { return NO; }
  return YES;
}

// Stop any running playback + the engine (the analog of Vibrator.cancel). Idempotent.
- (void)stopEngine {
  NSError *err = nil;
  if (_player != nil) {
    [_player stopAtTime:0 error:&err];
    _player = nil;
  }
  if (_engine != nil) {
    [_engine stopWithCompletionHandler:nil];
  }
}

// __canopy_cancel maps to cancel: stop the running buzz (best-effort, idempotent).
- (void)cancelCallId:(NSString *)callId {
  dispatch_async(_queue, ^{
    [self stopEngine];
  });
}

@end
