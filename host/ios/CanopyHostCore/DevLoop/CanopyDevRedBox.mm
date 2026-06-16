// CanopyDevRedBox.mm — DEV-12: the iOS dev-loop red-box overlay (impl).
//
// A direct port of Android's CanopyRedBox.show(dev=true) (host/android/.../CanopyRedBox.java): a
// crimson scrim, a bold title, the one-line message, a scrollable mono stack, and a button row
// (Dismiss + Reload when non-fatal, Reload only when fatal). Single overlay at a time. Pure UIKit —
// no Hermes/JSI/Yoga — so it carries no RN coupling and survives a renderer crash.

#import "CanopyDevRedBox.h"

@implementation CanopyDevRedBox

// The single live overlay (replaced on each new error), matching Android's static `current` field.
static UIView *gCurrentOverlay = nil;
static void (^gReload)(NSString *_Nullable) = nil;

+ (void)showOnView:(UIView *)hostView
             title:(NSString *)title
           message:(nullable NSString *)message
             stack:(nullable NSString *)stack
             fatal:(BOOL)fatal
            reload:(nullable void (^)(NSString *_Nullable))reload {
  if (hostView == nil) return;
  [self dismiss];  // collapse to the most recent error
  gReload = [reload copy];

  UIView *overlay = [[UIView alloc] initWithFrame:hostView.bounds];
  overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  // Crimson scrim (dev), opaque enough to swallow taps to the broken tree underneath.
  overlay.backgroundColor = [UIColor colorWithRed:0.69 green:0.0 blue:0.13 alpha:0.95];
  overlay.userInteractionEnabled = YES;  // swallow taps

  UIStackView *col = [[UIStackView alloc] init];
  col.axis = UILayoutConstraintAxisVertical;
  col.spacing = 12.0;
  col.translatesAutoresizingMaskIntoConstraints = NO;
  [overlay addSubview:col];

  UILabel *titleLabel = [[UILabel alloc] init];
  titleLabel.text = title.length ? title : @"Build failed";
  titleLabel.textColor = [UIColor whiteColor];
  titleLabel.font = [UIFont boldSystemFontOfSize:22.0];
  titleLabel.numberOfLines = 0;
  [col addArrangedSubview:titleLabel];

  UILabel *msgLabel = [[UILabel alloc] init];
  msgLabel.text = message.length ? message : @"(no message)";
  msgLabel.textColor = [UIColor colorWithRed:1.0 green:0.88 blue:0.88 alpha:1.0];
  msgLabel.font = [UIFont systemFontOfSize:15.0];
  msgLabel.numberOfLines = 0;
  [col addArrangedSubview:msgLabel];

  // Scrollable monospace detail (the compiler report / JS stack).
  UIScrollView *scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  UILabel *stackLabel = [[UILabel alloc] init];
  stackLabel.text = stack.length ? stack : @"(no detail)";
  stackLabel.textColor = [UIColor colorWithRed:0.91 green:0.93 blue:1.0 alpha:1.0];
  stackLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
  stackLabel.numberOfLines = 0;
  stackLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:stackLabel];
  [col addArrangedSubview:scroll];

  // Button row: Dismiss (non-fatal only) + Reload. A non-fatal build error leaves the last-good tree
  // up underneath, so Dismiss returns to it; a fatal reload failure has no good tree to dismiss to.
  UIStackView *row = [[UIStackView alloc] init];
  row.axis = UILayoutConstraintAxisHorizontal;
  row.spacing = 8.0;
  row.distribution = UIStackViewDistributionFillEqually;
  if (!fatal) {
    [row addArrangedSubview:[self buttonWithTitle:@"Dismiss"
                                           action:@selector(dismissTapped)
                                           target:self]];
  }
  [row addArrangedSubview:[self buttonWithTitle:@"Reload"
                                         action:@selector(reloadTapped)
                                         target:self]];
  [col addArrangedSubview:row];

  [hostView addSubview:overlay];

  UILayoutGuide *safe = overlay.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [col.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24.0],
    [col.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24.0],
    [col.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24.0],
    [col.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-24.0],
    [stackLabel.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
    [stackLabel.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
    [stackLabel.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
    [stackLabel.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
    [stackLabel.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
  ]];

  gCurrentOverlay = overlay;
}

+ (void)dismiss {
  if (gCurrentOverlay != nil) {
    [gCurrentOverlay removeFromSuperview];
    gCurrentOverlay = nil;
  }
  gReload = nil;
}

+ (void)dismissTapped {
  [self dismiss];
}

+ (void)reloadTapped {
  void (^reload)(NSString *_Nullable) = gReload;
  [self dismiss];
  // Best-effort: the dev server re-pushes a fresh bundle on the next save, so the closure is usually
  // a no-op. We pass nil (no bundle in hand) — the host treats a nil reload as "await next push".
  if (reload != nil) reload(nil);
}

+ (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action target:(id)target {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  [button setTitle:title forState:UIControlStateNormal];
  [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
  button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
  button.layer.cornerRadius = 8.0;
  button.contentEdgeInsets = UIEdgeInsetsMake(10.0, 12.0, 10.0, 12.0);
  [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
  return button;
}

@end
