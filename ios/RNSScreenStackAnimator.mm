#import "RNSScreenStackAnimator.h"
#import "RNSScreenStack.h"

#import "RNSScreen.h"

#pragma mark - Constants

// Default duration for transitions in seconds. Note, that this enforces the default
// only on Paper. On Fabric the transition duration coming from JS layer
// is never null, thus it defaults to the value set in component codegen spec.
static constexpr NSTimeInterval RNSDefaultTransitionDuration = 0.5;

// Proportions for diffrent phases of more complex animations.
// The reference duration differs from default transition duration,
// because we've changed the default duration & we want to keep proportions
// in tact. Unit = seconds.
static constexpr NSTimeInterval RNSTransitionDurationForProportion = 0.35;

static constexpr float RNSSlideOpenTransitionDurationProportion = 1;
static constexpr float RNSFadeOpenTransitionDurationProportion = 0.2 / RNSTransitionDurationForProportion;
static constexpr float RNSSlideCloseTransitionDurationProportion = 0.25 / RNSTransitionDurationForProportion;
static constexpr float RNSFadeCloseTransitionDurationProportion = 0.15 / RNSTransitionDurationForProportion;
static constexpr float RNSFadeCloseDelayTransitionDurationProportion = 0.1 / RNSTransitionDurationForProportion;

// Value used for dimming view attached for tranistion time.
// Same value is used in other projects using similar approach for transistions
// and it looks the most similar to the value used by Apple
static constexpr float RNSShadowViewMaxAlpha = 0.1;

// Dimming applied over the screen below during the zoom transition.
static constexpr float RNSZoomDimMaxAlpha = 0.35;

// Faithful ports of the JS cover-zoom constants (bookwise coverZoom.tsx / dismissDrag.ts).
static constexpr CGFloat RNSZoomArc = 0.45;
// Names mirror the JS ARC_LEAD_EXP/ARC_TRAIL_EXP for port fidelity. Y leads the OPEN
// flight; on the close the same arc runs in reverse, so X leads (see
// RNSZoomArcLerpTransform).
static constexpr CGFloat RNSZoomArcLeadExp = 1 + RNSZoomArc;
static constexpr CGFloat RNSZoomArcTrailExp = 1 / (1 + RNSZoomArc);
static constexpr CGFloat RNSZoomCloseOvershoot = 1.1;
static constexpr CGFloat RNSZoomInteractiveMinScale = 0.55;
static constexpr CGFloat RNSZoomDragTranslateFactor = 0.3;
static constexpr CGFloat RNSZoomBaseReaderRadius = 16;
static constexpr CGFloat RNSZoomDeviceCornerRadius = 52;
static constexpr NSTimeInterval RNSZoomCancelSpringDuration = 0.36;
static constexpr CGFloat RNSZoomCancelSpringDamping = 0.82;
static constexpr int RNSZoomKeyframeCount = 24;
// The push backdrop (the page, behind the flying stand-in) reaches full opacity at
// this fraction of the eased progress. Ported from the legacy JS overlay's
// [0, 0.85] progress interpolation (the overlay file was deleted with the JS flight).
static constexpr CGFloat RNSZoomOpenBackdropFullAt = 0.85;

// Ease-out cubic: 1 - (1-t)^3. Ports both JS curves that shared this math —
// Easing.out(Easing.cubic) (the open flight) and easeOutDrag (the dismiss shrink).
static inline CGFloat RNSZoomEaseOutCubic(CGFloat t)
{
  const CGFloat inv = 1 - t;
  return 1 - inv * inv * inv;
}

// CLOSE_FLIGHT_EASING: back-out with a slight overshoot past the source pose.
static inline CGFloat RNSZoomCloseEasing(CGFloat t)
{
  const CGFloat p = t - 1;
  return 1 + (RNSZoomCloseOvershoot + 1) * p * p * p + RNSZoomCloseOvershoot * p * p;
}

// arcCurve: linear passthrough outside [0,1] (negative bases would NaN under pow).
static inline CGFloat RNSZoomArcCurve(CGFloat t, CGFloat exponent)
{
  if (t <= 0 || t >= 1) {
    return t;
  }
  return pow(t, exponent);
}

// CLOSE_FLIGHT_EASING gated behind the close flight delay: 0 until `delayFraction`,
// then the overshoot curve over the remaining span. Shared by both close paths.
static inline CGFloat RNSZoomDelayedCloseEasing(CGFloat t, CGFloat delayFraction)
{
  if (t <= delayFraction) {
    return 0;
  }
  return RNSZoomCloseEasing((t - delayFraction) / (1 - delayFraction));
}

static inline CGFloat RNSZoomLerp(CGFloat from, CGFloat to, CGFloat t)
{
  return from + (to - from) * t;
}

static inline CGFloat RNSZoomClamp01(CGFloat t)
{
  return MAX((CGFloat)0, MIN((CGFloat)1, t));
}

// dismissShrinkScale
static inline CGFloat RNSZoomDragScale(CGFloat dragProgress)
{
  return RNSZoomLerp(1, RNSZoomInteractiveMinScale, RNSZoomClamp01(RNSZoomEaseOutCubic(dragProgress)));
}

// dismissCornerRadius — pre-divided by the live scale so the on-screen radius lands
// near the device corner radius.
static inline CGFloat RNSZoomDragCornerRadius(CGFloat dragProgress)
{
  const CGFloat p = RNSZoomClamp01(RNSZoomEaseOutCubic(dragProgress));
  const CGFloat scale = RNSZoomLerp(1, RNSZoomInteractiveMinScale, p);
  const CGFloat radius = RNSZoomLerp(RNSZoomBaseReaderRadius, RNSZoomDeviceCornerRadius, p);
  return radius / scale;
}

static CGRect RNSZoomRectFromDictionary(NSDictionary *_Nullable dict)
{
  if (dict == nil) {
    return CGRectNull;
  }
  const CGFloat width = [dict[@"width"] doubleValue];
  const CGFloat height = [dict[@"height"] doubleValue];
  if (width <= 0 || height <= 0) {
    return CGRectNull;
  }
  return CGRectMake([dict[@"x"] doubleValue], [dict[@"y"] doubleValue], width, height);
}

// Shelf-flight geometry (getShelfFlightGeometry): the screen pose that puts the
// alignment rect exactly onto the source rect.
typedef struct {
  CGFloat shelfScale;
  CGFloat shelfTX;
  CGFloat shelfTY;
  CGRect alignmentRect;
  CGRect viewBounds;
  CGFloat maskSourceCornerRadius;
} RNSZoomScreenGeometry;

static CGRect RNSZoomLerpRect(CGRect from, CGRect to, CGFloat t)
{
  return CGRectMake(
      RNSZoomLerp(from.origin.x, to.origin.x, t),
      RNSZoomLerp(from.origin.y, to.origin.y, t),
      RNSZoomLerp(from.size.width, to.size.width, t),
      RNSZoomLerp(from.size.height, to.size.height, t));
}

// Default close timings (originally the JS cover-zoom constants). Each is overridable
// per screen via the zoom*Ms props (see RNSZoomDuration); the open/close flight
// duration itself comes from the transitionDuration prop.
static constexpr NSTimeInterval RNSZoomCloseRevealDuration = 0.2; // CLOSE_REVEAL_MS
static constexpr NSTimeInterval RNSZoomCloseFlightDelay = 0.175; // CLOSE_FLIGHT_DELAY_MS
static constexpr NSTimeInterval RNSZoomClosePageFadeDuration = 0.3; // COVER_ZOOM_CLOSE_FADE_MS
static constexpr NSTimeInterval RNSZoomCommitRevealDuration = 0.15; // cover materialise on drag commit

// Per-screen timing override: the prop carries milliseconds; non-positive keeps the default.
static inline NSTimeInterval RNSZoomDuration(CGFloat overrideMs, NSTimeInterval fallback)
{
  return overrideMs > 0 ? overrideMs / 1000.0 : fallback;
}

// Geometry for the card flight: a snapshot stand-in of the cover (the real card is
// never reparented — Fabric owns it; see zoomMakeStandInFromCardView) flies between
// the slot rect and the alignment rect.
typedef struct {
  CGRect slotRect; // the card's slot on the shelf (zoomSourceRect prop) in container coordinates
  CGRect alignmentRect; // cover box inside the reader screen
} RNSZoomCardGeometry;

typedef struct {
  CGFloat scale;
  CGFloat tx;
  CGFloat ty;
} RNSZoomPose;

// Slot pose: the transform components that map the flying view (natural frame = the
// alignment rect) onto the slot rect. Single source for zoomCardTransformForAt and
// the commit flight, so their landing targets can't drift apart.
static RNSZoomPose RNSZoomSlotPoseForGeometry(RNSZoomCardGeometry g)
{
  RNSZoomPose pose;
  pose.scale = MAX(CGRectGetWidth(g.slotRect) / MAX(CGRectGetWidth(g.alignmentRect), 1), 0.001);
  pose.tx = CGRectGetMidX(g.slotRect) - CGRectGetMidX(g.alignmentRect);
  pose.ty = CGRectGetMidY(g.slotRect) - CGRectGetMidY(g.alignmentRect);
  return pose;
}

static const RNSZoomPose RNSZoomIdentityPose = {1, 0, 0};

// Arc-split pose interpolation — the single transform builder for every zoom flight.
// Y's interpolant lags X's in `at` space (RNSZoomArcCurve), so Y leads the open
// flight (at 1 -> 0) and X leads the close (at 0 -> 1) — same arc, traversed in
// reverse; scale lerps on `at` directly. `at` may exceed 1 on the close overshoot
// (lerps extrapolate linearly).
static CGAffineTransform RNSZoomArcLerpTransform(RNSZoomPose from, RNSZoomPose to, CGFloat at)
{
  const CGFloat atY = RNSZoomArcCurve(at, RNSZoomArcLeadExp);
  const CGFloat atX = RNSZoomArcCurve(at, RNSZoomArcTrailExp);
  const CGFloat scale = MAX(RNSZoomLerp(from.scale, to.scale, at), 0.001);
  return CGAffineTransformScale(
      CGAffineTransformMakeTranslation(RNSZoomLerp(from.tx, to.tx, atX), RNSZoomLerp(from.ty, to.ty, atY)),
      scale,
      scale);
}

// JS <-> native contract: the app tags views with these nativeIDs so the animator can
// find them (bookwise sets both — ReaderZoomLoadingCover tags its cover box as the
// dest cover; DocumentCover tags badge overlays). DestCover = the reader's own cover
// at the landing pose; CoverBadge = card overlays that must not appear in the flight
// snapshot (only the pure cover flies).
static NSString *const RNSZoomDestCoverNativeID = @"RNSZoomDestCover";
static NSString *const RNSZoomCoverBadgeNativeID = @"RNSZoomCoverBadge";

// Fabric-only assumption: the nativeID prop lands on RCTViewComponentView's `nativeId`
// selector (duck-typed — no compile-time dependency on non-public RN headers), with
// accessibilityIdentifier as a secondary source. On Paper the selector is `nativeID`
// and nativeID doesn't feed accessibilityIdentifier (testID does), so this lookup
// would always miss and the transition silently degrades to the masked screen zoom.
static BOOL RNSZoomViewMatchesNativeID(UIView *view, NSString *nativeID)
{
  if ([view respondsToSelector:@selector(nativeId)] && [[(id)view nativeId] isEqualToString:nativeID]) {
    return YES;
  }
  return [view.accessibilityIdentifier isEqualToString:nativeID];
}

// Finds the first view matching the nativeID. Depth-capped; only WKWebView subtrees
// are skipped — everything else (including scroll views) is traversed.
static UIView *_Nullable RNSZoomFindViewByNativeID(UIView *root, NSString *nativeID, int depth)
{
  if (depth > 30 || [root isKindOfClass:NSClassFromString(@"WKWebView")]) {
    return nil;
  }
  if (RNSZoomViewMatchesNativeID(root, nativeID)) {
    return root;
  }
  for (UIView *subview in root.subviews) {
    UIView *found = RNSZoomFindViewByNativeID(subview, nativeID, depth + 1);
    if (found != nil) {
      return found;
    }
  }
  return nil;
}

// Collects every view matching the nativeID (badge overlays — there may be several).
static void RNSZoomCollectViewsByNativeID(UIView *root, NSString *nativeID, int depth, NSMutableArray<UIView *> *out)
{
  if (depth > 30 || [root isKindOfClass:NSClassFromString(@"WKWebView")]) {
    return;
  }
  if (RNSZoomViewMatchesNativeID(root, nativeID)) {
    [out addObject:root];
  }
  for (UIView *subview in root.subviews) {
    RNSZoomCollectViewsByNativeID(subview, nativeID, depth + 1, out);
  }
}

// ===== RNSZOOM DEBUG SWITCH (set NO / 1.0 before shipping) =====
// Borders: red = flying stand-in, blue = real shelf card; the reader loading cover's
// green border lives in JS (bookwise ReaderZoomLoadingCover, COVER_ZOOM_DEBUG).
// The borders (only) are also available at runtime via the screen's
// zoomShowDebugBorders prop — no rebuild needed; this compile switch additionally
// gates the entry NSLogs and the slow-motion container speed below.
static const BOOL RNSZoomDebugEnabled = NO;
static const NSInteger RNSZoomDebugCardBorderTag = 987654;
// 1.0 = real speed; 0.1 = 10x slow motion. NOTE: slow motion distorts the property
// animator's first frames (pacing rebases) — trust it for element attribution only,
// never for timing.
static const float RNSZoomDebugAnimationSpeed = 1.0;
// ===== END RNSZOOM DEBUG SWITCH =====

static NSString *const RNSZoomOpacityHoldKey = @"RNSZoomOpacityHold";
static NSString *const RNSZoomOpacityRampKey = @"RNSZoomOpacityRamp";

// Fabric owns the model opacity of the screen/card/cover views and can rewrite it on
// any commit mid-flight (a cached cover's onLoad commits within the first frames of
// the push — the reader then flashed in at full alpha). Holding/ramping the
// PRESENTATION with animator-owned, non-additive CA animations makes those writes
// visually inert: the model stays 1, so Fabric writing 1 is a no-op, and the display
// follows our animation until it's removed.
static void RNSZoomHoldOpacity(UIView *_Nullable view, CGFloat value)
{
  CABasicAnimation *hold = [CABasicAnimation animationWithKeyPath:@"opacity"];
  hold.fromValue = @(value);
  hold.toValue = @(value);
  hold.duration = 3600;
  hold.removedOnCompletion = NO;
  hold.fillMode = kCAFillModeBoth;
  [view.layer addAnimation:hold forKey:RNSZoomOpacityHoldKey];
}

static void RNSZoomReleaseOpacityHold(UIView *_Nullable view)
{
  [view.layer removeAnimationForKey:RNSZoomOpacityHoldKey];
}

// Presentation-side opacity ramp along the flight's keyframe times.
static void RNSZoomAddOpacityRamp(UIView *view, NSTimeInterval duration, CGFloat (^valueAt)(CGFloat t))
{
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:RNSZoomKeyframeCount + 1];
  for (int i = 0; i <= RNSZoomKeyframeCount; i++) {
    [values addObject:@(valueAt((CGFloat)i / RNSZoomKeyframeCount))];
  }
  CAKeyframeAnimation *ramp = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
  ramp.values = values;
  ramp.duration = duration;
  ramp.removedOnCompletion = NO;
  ramp.fillMode = kCAFillModeBoth;
  [view.layer addAnimation:ramp forKey:RNSZoomOpacityRampKey];
}

static void RNSZoomRemoveOpacityRamp(UIView *_Nullable view)
{
  [view.layer removeAnimationForKey:RNSZoomOpacityRampKey];
}

// Presentation-side page fade shared by the close flights: the page fades out over
// COVER_ZOOM_CLOSE_FADE within `duration`, and Fabric commits mid-close can't
// restore it (see RNSZoomAddOpacityRamp).
static void RNSZoomAddPageFadeRamp(UIView *view, NSTimeInterval duration, NSTimeInterval fadeDuration)
{
  const CGFloat pageFadeFraction = MIN(fadeDuration / MAX(duration, 0.01), 1.0);
  RNSZoomAddOpacityRamp(view, duration, ^CGFloat(CGFloat t) {
    return MAX(1.0 - t / pageFadeFraction, 0.0);
  });
}

@implementation RNSScreenStackAnimator {
  UINavigationControllerOperation _operation;
  NSTimeInterval _transitionDuration;
  UIViewPropertyAnimator *_Nullable _inFlightAnimator;
  __weak RNSScreenView *_Nullable _animatedScreen;
  // Zoom interactive dismissal state (all valid only while _isZoomInteractive).
  BOOL _isZoomInteractive;
  __weak UIView *_zoomAnimatedView;
  // Interactive drag corners: a bare CALayer we own, applied straight to layer.mask.
  // UIView's maskView getter must never be called on a Fabric view — RN assigns
  // layer.mask from a view it doesn't retain, so the getter can return a freed object.
  CALayer *_Nullable _zoomMaskLayer;
  __weak UIView *_zoomDimmingView;
  RNSZoomScreenGeometry _zoomScreenGeometry;
  // Card flight state (snapshot stand-in).
  RNSZoomCardGeometry _zoomCardGeometry;
  __weak UIView *_zoomCardView;
  __weak UIView *_zoomPendingCardView;
  __weak UIView *_zoomBelowView;
  // The flying stand-in is a native snapshot we own — Fabric can recycle the real
  // card mid-flight without breaking the animation.
  UIView *_Nullable _zoomStandInView;
  // The view currently carrying a zoom opacity ramp, for the defensive release in
  // animationEnded:.
  __weak UIView *_zoomRampedView;
  // Container layer slowed by the debug switch; speed restored in animationEnded:.
  __weak CALayer *_zoomSlowedLayer;
  // Destination cover inside the pushed reader screen: hidden during the open flight
  // (the flying card is the only visible cover) and revealed atomically at landing.
  __weak UIView *_zoomDestCoverView;
}

- (instancetype)initWithOperation:(UINavigationControllerOperation)operation
{
  if (self = [super init]) {
    _operation = operation;
    _transitionDuration = RNSDefaultTransitionDuration; // default duration in seconds
    _inFlightAnimator = nil;
  }
  return self;
}

#pragma mark - UIViewControllerAnimatedTransitioning

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext
{
  RNSScreenView *screen;
  if (_operation == UINavigationControllerOperationPush) {
    UIViewController *toViewController =
        [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
    screen = ((RNSScreen *)toViewController).screenView;
  } else if (_operation == UINavigationControllerOperationPop) {
    UIViewController *fromViewController =
        [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    screen = ((RNSScreen *)fromViewController).screenView;
  }

  if (screen != nil && screen.stackAnimation == RNSScreenStackAnimationNone) {
    return 0.0;
  }

  if (screen != nil && screen.transitionDuration != nil && [screen.transitionDuration floatValue] >= 0) {
    float durationInSeconds = [screen.transitionDuration floatValue] / 1000.0;
    return durationInSeconds;
  }

  return _transitionDuration;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
  UIViewController *toViewController = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
  UIViewController *fromViewController =
      [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
  toViewController.view.frame = [transitionContext finalFrameForViewController:toViewController];

  RNSScreenView *screen;
  if (_operation == UINavigationControllerOperationPush) {
    screen = ((RNSScreen *)toViewController).screenView;
  } else if (_operation == UINavigationControllerOperationPop) {
    screen = ((RNSScreen *)fromViewController).screenView;
  }

  _animatedScreen = screen;
  if (RNSZoomDebugEnabled) {
    NSLog(@"RNSZOOM animateTransition op=%ld anim=%ld", (long)_operation, (long)(screen != nil ? screen.stackAnimation : -1));
  }

  if (screen != nil) {
    if ([screen.reactSuperview isKindOfClass:[RNSScreenStackView class]] &&
        ((RNSScreenStackView *)(screen.reactSuperview)).customAnimation) {
      [self animateWithNoAnimation:transitionContext toVC:toViewController fromVC:fromViewController];
    } else if (screen.fullScreenSwipeEnabled && transitionContext.isInteractive) {
      // we are swiping with full width gesture
      if (screen.customAnimationOnSwipe) {
        [self animateTransitionWithStackAnimation:screen.stackAnimation
                                    shadowEnabled:screen.fullScreenSwipeShadowEnabled
                                transitionContext:transitionContext
                                             toVC:toViewController
                                           fromVC:fromViewController];
      } else {
        // we have to provide an animation when swiping, otherwise the screen will be popped immediately,
        // so in case of no custom animation on swipe set, we provide the one closest to the default
        [self animateSimplePushWithShadowEnabled:screen.fullScreenSwipeShadowEnabled
                               transitionContext:transitionContext
                                            toVC:toViewController
                                          fromVC:fromViewController];
      }
    } else {
      // we are going forward or provided custom animation on swipe or clicked native header back button
      [self animateTransitionWithStackAnimation:screen.stackAnimation
                                  shadowEnabled:screen.fullScreenSwipeShadowEnabled
                              transitionContext:transitionContext
                                           toVC:toViewController
                                         fromVC:fromViewController];
    }
  }
}

- (void)animationEnded:(BOOL)transitionCompleted
{
  // Defensive release: if UIKit tore the transition down without ever running our
  // animator completion, the presentation-layer holds would pin the shelf card and
  // dest cover invisible indefinitely — and Fabric can't repair them (the model is
  // already 1, so its writes are no-ops). Both calls are no-ops on the normal path,
  // where the completion already ran before completeTransition. The card alpha
  // matches the normal-path contract: session-hidden after a completed push (the
  // reader shows the identical cover), visible in every other outcome.
  const BOOL pushCompleted = _operation == UINavigationControllerOperationPush && transitionCompleted;
  [self zoomFinishCardFlightSettingCardAlpha:pushCompleted ? 0.0 : 1.0];
  RNSZoomRemoveOpacityRamp(_zoomRampedView);
  _zoomRampedView = nil;
  _zoomSlowedLayer.speed = 1.0;
  _zoomSlowedLayer = nil;
  // Same backstop for the drag state the interactive carrier normally cleans up:
  // an abnormally ended drag must not leave the drag mask or transform behind.
  if (_isZoomInteractive) {
    UIView *dragged = _zoomAnimatedView;
    if (dragged != nil) {
      if (_zoomMaskLayer != nil && dragged.layer.mask == _zoomMaskLayer) {
        dragged.layer.mask = nil;
      }
      dragged.transform = CGAffineTransformIdentity;
    }
    _zoomMaskLayer = nil;
    _isZoomInteractive = NO;
  }
  _inFlightAnimator = nil;
  _animatedScreen = nil;
}

#pragma mark - Animation implementations

- (void)animateSimplePushWithShadowEnabled:(BOOL)shadowEnabled
                         transitionContext:(id<UIViewControllerContextTransitioning>)transitionContext
                                      toVC:(UIViewController *)toViewController
                                    fromVC:(UIViewController *)fromViewController
{
  float containerWidth = transitionContext.containerView.bounds.size.width;
  float belowViewWidth = containerWidth * 0.3;

  CGAffineTransform rightTransform = CGAffineTransformMakeTranslation(containerWidth, 0);
  CGAffineTransform leftTransform = CGAffineTransformMakeTranslation(-belowViewWidth, 0);

  if (toViewController.navigationController.view.semanticContentAttribute ==
      UISemanticContentAttributeForceRightToLeft) {
    rightTransform = CGAffineTransformMakeTranslation(-containerWidth, 0);
    leftTransform = CGAffineTransformMakeTranslation(belowViewWidth, 0);
  }

  UIView *shadowView;
  if (shadowEnabled) {
    shadowView = [[UIView alloc] initWithFrame:fromViewController.view.frame];
    shadowView.backgroundColor = [UIColor blackColor];
  }

  if (_operation == UINavigationControllerOperationPush) {
    toViewController.view.transform = rightTransform;
    [[transitionContext containerView] addSubview:toViewController.view];
    if (shadowView) {
      [[transitionContext containerView] insertSubview:shadowView belowSubview:toViewController.view];
      shadowView.alpha = 0.0;
    }

    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                        timingParameters:[RNSScreenStackAnimator defaultSpringTimingParametersApprox]];

    [animator addAnimations:^{
      fromViewController.view.transform = leftTransform;
      toViewController.view.transform = CGAffineTransformIdentity;
      if (shadowView) {
        shadowView.alpha = RNSShadowViewMaxAlpha;
      }
    }];

    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      if (shadowView) {
        [shadowView removeFromSuperview];
      }
      fromViewController.view.transform = CGAffineTransformIdentity;
      toViewController.view.transform = CGAffineTransformIdentity;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
  } else if (_operation == UINavigationControllerOperationPop) {
    toViewController.view.transform = leftTransform;
    [[transitionContext containerView] insertSubview:toViewController.view belowSubview:fromViewController.view];
    if (shadowView) {
      [[transitionContext containerView] insertSubview:shadowView belowSubview:fromViewController.view];
      shadowView.alpha = RNSShadowViewMaxAlpha;
    }

    void (^animationBlock)(void) = ^{
      toViewController.view.transform = CGAffineTransformIdentity;
      fromViewController.view.transform = rightTransform;
      if (shadowView) {
        shadowView.alpha = 0.0;
      }
    };

    void (^completionBlock)(UIViewAnimatingPosition) = ^(UIViewAnimatingPosition finalPosition) {
      if (shadowView) {
        [shadowView removeFromSuperview];
      }
      fromViewController.view.transform = CGAffineTransformIdentity;
      toViewController.view.transform = CGAffineTransformIdentity;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    };

    if (!transitionContext.isInteractive) {
      UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc]
          initWithDuration:[self transitionDuration:transitionContext]
          timingParameters:[RNSScreenStackAnimator defaultSpringTimingParametersApprox]];

      [animator addAnimations:animationBlock];
      [animator addCompletion:completionBlock];
      _inFlightAnimator = animator;
      [animator startAnimation];
    } else {
      // we don't want the EaseInOut option when swiping to dismiss the view, it is the same in default animation option
      UIViewPropertyAnimator *animator =
          [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                                     curve:UIViewAnimationCurveLinear
                                                animations:animationBlock];

      [animator addCompletion:completionBlock];
      [animator setUserInteractionEnabled:YES];
      _inFlightAnimator = animator;
    }
  }
}

- (void)animateSlideFromLeftWithTransitionContext:(id<UIViewControllerContextTransitioning>)transitionContext
                                             toVC:(UIViewController *)toViewController
                                           fromVC:(UIViewController *)fromViewController
{
  float containerWidth = transitionContext.containerView.bounds.size.width;
  float belowViewWidth = containerWidth * 0.3;

  CGAffineTransform rightTransform = CGAffineTransformMakeTranslation(-containerWidth, 0);
  CGAffineTransform leftTransform = CGAffineTransformMakeTranslation(belowViewWidth, 0);

  if (toViewController.navigationController.view.semanticContentAttribute ==
      UISemanticContentAttributeForceRightToLeft) {
    rightTransform = CGAffineTransformMakeTranslation(containerWidth, 0);
    leftTransform = CGAffineTransformMakeTranslation(-belowViewWidth, 0);
  }

  if (_operation == UINavigationControllerOperationPush) {
    toViewController.view.transform = rightTransform;
    [[transitionContext containerView] addSubview:toViewController.view];

    UIViewPropertyAnimator *animator =
        [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                        timingParameters:[RNSScreenStackAnimator defaultSpringTimingParametersApprox]];

    [animator addAnimations:^{
      fromViewController.view.transform = leftTransform;
      toViewController.view.transform = CGAffineTransformIdentity;
    }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      fromViewController.view.transform = CGAffineTransformIdentity;
      toViewController.view.transform = CGAffineTransformIdentity;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
  } else if (_operation == UINavigationControllerOperationPop) {
    toViewController.view.transform = leftTransform;
    [[transitionContext containerView] insertSubview:toViewController.view belowSubview:fromViewController.view];

    void (^animationBlock)(void) = ^{
      toViewController.view.transform = CGAffineTransformIdentity;
      fromViewController.view.transform = rightTransform;
    };
    void (^completionBlock)(UIViewAnimatingPosition) = ^(UIViewAnimatingPosition finalPosition) {
      fromViewController.view.transform = CGAffineTransformIdentity;
      toViewController.view.transform = CGAffineTransformIdentity;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    };

    if (!transitionContext.isInteractive) {
      UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc]
          initWithDuration:[self transitionDuration:transitionContext]
          timingParameters:[RNSScreenStackAnimator defaultSpringTimingParametersApprox]];

      [animator addAnimations:animationBlock];
      [animator addCompletion:completionBlock];
      _inFlightAnimator = animator;
      [animator startAnimation];
    } else {
      // we don't want the EaseInOut option when swiping to dismiss the view, it is the same in default animation option
      UIViewPropertyAnimator *animator =
          [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                                     curve:UIViewAnimationCurveLinear
                                                animations:animationBlock];
      [animator addCompletion:completionBlock];
      [animator setUserInteractionEnabled:YES];
      _inFlightAnimator = animator;
    }
  }
}

- (void)animateFadeWithTransitionContext:(id<UIViewControllerContextTransitioning>)transitionContext
                                    toVC:(UIViewController *)toViewController
                                  fromVC:(UIViewController *)fromViewController
{
  toViewController.view.frame = [transitionContext finalFrameForViewController:toViewController];

  if (_operation == UINavigationControllerOperationPush) {
    [[transitionContext containerView] addSubview:toViewController.view];
    toViewController.view.alpha = 0.0;
    auto animator = [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                                               curve:UIViewAnimationCurveEaseInOut
                                                          animations:^{
                                                            toViewController.view.alpha = 1.0;
                                                          }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      toViewController.view.alpha = 1.0;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
  } else if (_operation == UINavigationControllerOperationPop) {
    [[transitionContext containerView] insertSubview:toViewController.view belowSubview:fromViewController.view];
    auto animator = [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                                               curve:UIViewAnimationCurveEaseInOut
                                                          animations:^{
                                                            fromViewController.view.alpha = 0.0;
                                                          }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      fromViewController.view.alpha = 1.0;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
  }
}

- (void)animateSlideFromBottomWithTransitionContext:(id<UIViewControllerContextTransitioning>)transitionContext
                                               toVC:(UIViewController *)toViewController
                                             fromVC:(UIViewController *)fromViewController
{
  CGAffineTransform topBottomTransform =
      CGAffineTransformMakeTranslation(0, transitionContext.containerView.bounds.size.height);

  if (_operation == UINavigationControllerOperationPush) {
    toViewController.view.transform = topBottomTransform;
    [[transitionContext containerView] addSubview:toViewController.view];

    auto animator = [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                                               curve:UIViewAnimationCurveEaseInOut
                                                          animations:^{
                                                            fromViewController.view.transform =
                                                                CGAffineTransformIdentity;
                                                            toViewController.view.transform = CGAffineTransformIdentity;
                                                          }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      fromViewController.view.transform = CGAffineTransformIdentity;
      toViewController.view.transform = CGAffineTransformIdentity;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
  } else if (_operation == UINavigationControllerOperationPop) {
    toViewController.view.transform = CGAffineTransformIdentity;
    [[transitionContext containerView] insertSubview:toViewController.view belowSubview:fromViewController.view];

    void (^animationBlock)(void) = ^{
      toViewController.view.transform = CGAffineTransformIdentity;
      fromViewController.view.transform = topBottomTransform;
    };
    void (^completionBlock)(UIViewAnimatingPosition) = ^(UIViewAnimatingPosition finalPosition) {
      fromViewController.view.transform = CGAffineTransformIdentity;
      toViewController.view.transform = CGAffineTransformIdentity;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    };

    if (!transitionContext.isInteractive) {
      auto animator = [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                                                 curve:UIViewAnimationCurveEaseInOut
                                                            animations:animationBlock];
      [animator addCompletion:completionBlock];
      _inFlightAnimator = animator;
      [animator startAnimation];
    } else {
      // we don't want the EaseInOut option when swiping to dismiss the view, it is the same in default animation option
      auto animator = [[UIViewPropertyAnimator alloc] initWithDuration:[self transitionDuration:transitionContext]
                                                                 curve:UIViewAnimationCurveLinear
                                                            animations:animationBlock];
      [animator addCompletion:completionBlock];
      _inFlightAnimator = animator;
    }
  }
}

- (void)animateFadeFromBottomWithTransitionContext:(id<UIViewControllerContextTransitioning>)transitionContext
                                              toVC:(UIViewController *)toViewController
                                            fromVC:(UIViewController *)fromViewController
{
  CGAffineTransform topBottomTransform =
      CGAffineTransformMakeTranslation(0, 0.08 * transitionContext.containerView.bounds.size.height);

  const float baseTransitionDuration = [self transitionDuration:transitionContext];

  if (_operation == UINavigationControllerOperationPush) {
    toViewController.view.transform = topBottomTransform;
    toViewController.view.alpha = 0.0;
    [[transitionContext containerView] addSubview:toViewController.view];

    // Android Nougat open animation
    // http://aosp.opersys.com/xref/android-7.1.2_r37/xref/frameworks/base/core/res/res/anim/activity_open_enter.xml
    auto slideAnimator = [[UIViewPropertyAnimator alloc]
        initWithDuration:baseTransitionDuration * RNSSlideOpenTransitionDurationProportion
                   curve:UIViewAnimationCurveEaseOut
              animations:^{
                fromViewController.view.transform = CGAffineTransformIdentity;
                toViewController.view.transform = CGAffineTransformIdentity;
              }];
    [slideAnimator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      fromViewController.view.transform = CGAffineTransformIdentity;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];

    auto fadeAnimator = [[UIViewPropertyAnimator alloc]
        initWithDuration:baseTransitionDuration * RNSFadeOpenTransitionDurationProportion
                   curve:UIViewAnimationCurveEaseOut
              animations:^{
                toViewController.view.alpha = 1.0;
              }];

    _inFlightAnimator = slideAnimator;
    [slideAnimator startAnimation];
    [fadeAnimator startAnimation];
  } else if (_operation == UINavigationControllerOperationPop) {
    toViewController.view.transform = CGAffineTransformIdentity;
    [[transitionContext containerView] insertSubview:toViewController.view belowSubview:fromViewController.view];

    // Android Nougat exit animation
    // http://aosp.opersys.com/xref/android-7.1.2_r37/xref/frameworks/base/core/res/res/anim/activity_close_exit.xml
    auto slideAnimator = [[UIViewPropertyAnimator alloc]
        initWithDuration:baseTransitionDuration * RNSSlideCloseTransitionDurationProportion
                   curve:UIViewAnimationCurveEaseIn
              animations:^{
                toViewController.view.transform = CGAffineTransformIdentity;
                fromViewController.view.transform = topBottomTransform;
              }];
    [slideAnimator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      fromViewController.view.transform = CGAffineTransformIdentity;
      toViewController.view.transform = CGAffineTransformIdentity;
      fromViewController.view.alpha = 1.0;
      toViewController.view.alpha = 1.0;
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];

    auto fadeAnimator = [[UIViewPropertyAnimator alloc]
        initWithDuration:baseTransitionDuration * RNSFadeCloseTransitionDurationProportion
                   curve:UIViewAnimationCurveLinear
              animations:^{
                fromViewController.view.alpha = 0.0;
              }];

    _inFlightAnimator = slideAnimator;
    [slideAnimator startAnimation];
    [fadeAnimator startAnimationAfterDelay:baseTransitionDuration * RNSFadeCloseDelayTransitionDurationProportion];
  }
}

// Pose along the open/close flight, in "at" space (0 = reader pose, 1 = shelf/source
// pose). X trails and Y leads via the arc curve; scale/mask lerp on `at` directly.
// `at` may exceed 1 slightly on the close overshoot — lerps extrapolate linearly.
// Used by the screen-zoom FALLBACK (source card view not found).
- (void)applyZoomFlightPose:(CGFloat)at
                     toView:(UIView *)animatedView
                   maskView:(UIView *)maskView
                dimmingView:(UIView *)dimmingView
{
  const RNSZoomScreenGeometry g = _zoomScreenGeometry;
  const RNSZoomPose shelfPose = {g.shelfScale, g.shelfTX, g.shelfTY};
  animatedView.transform = RNSZoomArcLerpTransform(RNSZoomIdentityPose, shelfPose, at);
  maskView.frame = RNSZoomLerpRect(g.viewBounds, g.alignmentRect, at);
  maskView.layer.cornerRadius = MAX(RNSZoomLerp(RNSZoomBaseReaderRadius, g.maskSourceCornerRadius, at), 0);
  dimmingView.alpha = RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(at));
}

// Uniform keyframe scaffold shared by EVERY zoom flight (card flights and masked
// fallbacks): RNSZoomKeyframeCount equal keyframes sampling `pose(t)` at t in (0..1].
// When `revealView` is non-nil an extra keyframe fades it to 1 over the first
// `revealFraction` of the animation (the close flights materialise the stand-in that way).
// Call inside a UIViewPropertyAnimator's animation block.
static void RNSZoomAddFlightKeyframes(UIView *_Nullable revealView, CGFloat revealFraction, void (^pose)(CGFloat t))
{
  [UIView animateKeyframesWithDuration:0
                                 delay:0
                               options:0
                            animations:^{
                              if (revealView != nil) {
                                [UIView addKeyframeWithRelativeStartTime:0
                                                        relativeDuration:revealFraction
                                                              animations:^{
                                                                revealView.alpha = 1.0;
                                                              }];
                              }
                              for (int i = 1; i <= RNSZoomKeyframeCount; i++) {
                                const CGFloat t = (CGFloat)i / RNSZoomKeyframeCount;
                                [UIView addKeyframeWithRelativeStartTime:(CGFloat)(i - 1) / RNSZoomKeyframeCount
                                                        relativeDuration:1.0 / RNSZoomKeyframeCount
                                                              animations:^{
                                                                pose(t);
                                                              }];
                              }
                            }
                            completion:nil];
}

// Masked screen-zoom flight — the shared fallback for push and pop when there is no
// source card / the stand-in snapshot fails. `easedAt` maps uniform time [0..1] to
// "at" space; `initialAt` is the pre-flight pose (1 = shelf for the open, 0 = reader
// for the close). maskView (not the drag path's bare-CALayer technique) is safe here:
// the invariant at the _zoomMaskLayer declaration is about reading an RN-assigned
// layer.mask mid-drag; RN never assigns its own mask to the screen view, and this
// setter runs only at transition setup/teardown.
- (void)runMaskedZoomFlightWithContext:(id<UIViewControllerContextTransitioning>)transitionContext
                          animatedView:(UIView *)animatedView
                           dimmingView:(UIView *)dimmingView
                              duration:(NSTimeInterval)duration
                             initialAt:(CGFloat)initialAt
                               easedAt:(CGFloat (^)(CGFloat t))easedAt
{
  UIView *maskView = [[UIView alloc] init];
  maskView.backgroundColor = [UIColor blackColor];
  maskView.layer.cornerCurve = kCACornerCurveContinuous;

  [UIView performWithoutAnimation:^{
    animatedView.maskView = maskView;
    [self applyZoomFlightPose:initialAt toView:animatedView maskView:maskView dimmingView:dimmingView];
  }];

  UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                                                                curve:UIViewAnimationCurveLinear
                                                                           animations:nil];
  __weak RNSScreenStackAnimator *weakSelf = self;
  [animator addAnimations:^{
    RNSZoomAddFlightKeyframes(nil, 0, ^(CGFloat t) {
      [weakSelf applyZoomFlightPose:easedAt(t) toView:animatedView maskView:maskView dimmingView:dimmingView];
    });
  }];
  [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
    animatedView.maskView = nil;
    animatedView.transform = CGAffineTransformIdentity;
    [dimmingView removeFromSuperview];
    [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
  }];
  _inFlightAnimator = animator;
  [animator startAnimation];
}

#pragma mark - Zoom card flight (snapshot stand-in)

// Transform for the flying card at "at" (0 = reader pose, 1 = shrunk onto the slot's
// cover rect). The flying view's natural frame IS the alignment rect (rendered at
// full reader resolution), so the flight only ever downscales — never a blurry
// upscale. Same per-axis arc curves as before: the visual path is unchanged.
- (CGAffineTransform)zoomCardTransformForAt:(CGFloat)at
{
  return RNSZoomArcLerpTransform(RNSZoomIdentityPose, RNSZoomSlotPoseForGeometry(_zoomCardGeometry), at);
}

// Renders a view into the current image-renderer context at destRect. Prefers the
// on-screen appearance; drawViewHierarchyInRect can silently produce a blank image
// (observed on repeat opens: BOOL result NO), so fall back to a model-tree layer
// render, which has no dependency on render-server snapshot state.
static void RNSZoomDrawViewIntoRect(UIView *view, CGRect destRect, UIGraphicsImageRendererContext *context)
{
  if ([view drawViewHierarchyInRect:destRect afterScreenUpdates:YES]) {
    return;
  }
  CGContextRef ctx = context.CGContext;
  CGContextSaveGState(ctx);
  CGContextTranslateCTM(ctx, destRect.origin.x, destRect.origin.y);
  CGContextScaleCTM(
      ctx,
      destRect.size.width / MAX(view.bounds.size.width, 1),
      destRect.size.height / MAX(view.bounds.size.height, 1));
  [view.layer renderInContext:ctx];
  CGContextRestoreGState(ctx);
}

// Builds the flying stand-in for the cover. Its natural frame is the ALIGNMENT rect
// (the reader pose), composited at full resolution: the card render (badges hidden,
// mapped so its cover rect fills the canvas) as a fallback base, and the reader's own
// destination cover render on top — the flight shows the same fully-rendered image the
// reader holds, so scaling up never blurs. The real card is never reparented (Fabric
// owns it and may recycle it mid-flight); visibility is handed off atomically at the ends.
- (UIView *_Nullable)zoomMakeStandInFromCardView:(UIView *)cardView
                                      destCover:(UIView *_Nullable)destCover
                                    inContainer:(UIView *)container
{
  const CGRect slotRect = _zoomCardGeometry.slotRect;
  const CGRect alignmentRect = _zoomCardGeometry.alignmentRect;
  CGRect wrapperInContainer = [cardView.superview convertRect:cardView.frame toView:container];
  if (CGRectIsEmpty(cardView.bounds) || CGRectIsEmpty(alignmentRect) || CGRectGetWidth(slotRect) < 1) {
    return nil;
  }
  // The transition can start while some other UIView animation block is still open on
  // the stack (e.g. the status-bar hide on reader entry). Every mutation here must be
  // immune to that: an implicitly-animated frame set makes CA render the stand-in from
  // its pre-frame pose — the card visibly flies in from (0,0) — and an implicitly
  // animated alpha turns the atomic card/stand-in handoff into a crossfade.
  __block UIView *standIn = nil;
  [UIView performWithoutAnimation:^{
    // Badge overlays (and hidden cards) are alpha-juggled for the render only: both
    // writes land in the same tick, so the display never sees them.
    NSMutableArray<UIView *> *badges = [NSMutableArray array];
    RNSZoomCollectViewsByNativeID(cardView, RNSZoomCoverBadgeNativeID, 0, badges);
    if (destCover != nil) {
      RNSZoomCollectViewsByNativeID(destCover, RNSZoomCoverBadgeNativeID, 0, badges);
    }
    NSMutableArray<NSNumber *> *badgeAlphas = [NSMutableArray arrayWithCapacity:badges.count];
    for (UIView *badge in badges) {
      [badgeAlphas addObject:@(badge.alpha)];
      badge.alpha = 0;
    }
    const CGFloat cardAlpha = cardView.alpha;
    if (cardAlpha < 1) {
      cardView.alpha = 1;
    }
    const CGFloat destAlpha = destCover.alpha;
    if (destCover != nil && destAlpha < 1) {
      destCover.alpha = 1;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    const CGRect canvas = CGRectMake(0, 0, alignmentRect.size.width, alignmentRect.size.height);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:canvas format:format];
    UIImage *cardImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
      // Base: the card wrapper positioned so its slot rect fills the canvas exactly.
      const CGFloat k = canvas.size.width / slotRect.size.width;
      const CGRect baseRect = CGRectMake(
          (CGRectGetMinX(wrapperInContainer) - CGRectGetMinX(slotRect)) * k,
          (CGRectGetMinY(wrapperInContainer) - CGRectGetMinY(slotRect)) * k,
          wrapperInContainer.size.width * k,
          wrapperInContainer.size.height * k);
      RNSZoomDrawViewIntoRect(cardView, baseRect, context);
      if (destCover != nil && !CGRectIsEmpty(destCover.bounds)) {
        RNSZoomDrawViewIntoRect(destCover, canvas, context);
      }
    }];

    if (destCover != nil && destAlpha < 1) {
      destCover.alpha = destAlpha;
    }
    if (cardAlpha < 1) {
      cardView.alpha = cardAlpha;
    }
    for (NSUInteger i = 0; i < badges.count; i++) {
      badges[i].alpha = badgeAlphas[i].doubleValue;
    }

    standIn = [[UIImageView alloc] initWithImage:cardImage];
    if (!RNSZoomDebugEnabled && !self->_animatedScreen.zoomShowDebugBorders) {
      // Borders off: drop a card border a previous debug transition left behind
      // (it lives on the Fabric-owned card and would otherwise persist until remount).
      [[cardView viewWithTag:RNSZoomDebugCardBorderTag] removeFromSuperview];
    } else {
      UIView *debugFlyingPaint = [[UIView alloc] initWithFrame:standIn.bounds];
      debugFlyingPaint.layer.borderColor = UIColor.redColor.CGColor;
      debugFlyingPaint.layer.borderWidth = 6;
      debugFlyingPaint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      debugFlyingPaint.userInteractionEnabled = NO;
      [standIn addSubview:debugFlyingPaint];
      if ([cardView viewWithTag:RNSZoomDebugCardBorderTag] == nil) {
        UIView *debugCardPaint = [[UIView alloc] initWithFrame:cardView.bounds];
        debugCardPaint.tag = RNSZoomDebugCardBorderTag;
        // Tagged as a badge so snapshot renders exclude the border itself — it would
        // otherwise be baked into every subsequent stand-in.
        debugCardPaint.accessibilityIdentifier = RNSZoomCoverBadgeNativeID;
        debugCardPaint.layer.borderColor = UIColor.blueColor.CGColor;
        debugCardPaint.layer.borderWidth = 6;
        debugCardPaint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        debugCardPaint.userInteractionEnabled = NO;
        [cardView addSubview:debugCardPaint];
      }
    }
    standIn.frame = alignmentRect;
    standIn.userInteractionEnabled = NO;
    [container addSubview:standIn];
  }];
  _zoomStandInView = standIn;
  _zoomCardView = cardView;
  return standIn;
}

// Atomic handoff at the flight's end: the real card's visibility flips in the same
// CATransaction that removes the snapshot, so landing is pixel-seamless. If the real
// card was recycled mid-flight, its replacement is already visible and only the
// snapshot removal happens.
- (void)zoomFinishCardFlightSettingCardAlpha:(CGFloat)alpha
{
  UIView *standIn = _zoomStandInView;
  UIView *cardView = _zoomCardView;
  UIView *destCover = _zoomDestCoverView;
  _zoomStandInView = nil;
  _zoomCardView = nil;
  _zoomDestCoverView = nil;
  if (standIn == nil && cardView == nil && destCover == nil) {
    return;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  RNSZoomReleaseOpacityHold(destCover);
  destCover.alpha = 1.0;
  if (cardView != nil) {
    RNSZoomReleaseOpacityHold(cardView);
    cardView.alpha = alpha;
  }
  [standIn.layer removeAllAnimations];
  [standIn removeFromSuperview];
  [CATransaction commit];
}

// Shared tail for every zoom transition: release the card/cover handoff (real card's
// alpha = cardAlphaOnComplete when completed, its inverse when cancelled), drop the
// page ramp, restore the page alpha, and complete the UIKit transition. Nil-tolerant:
// with a deallocated animator (practically unreachable — UIKit retains it for the
// transition) the handoff no-ops, but the static cleanup still runs so the page can't
// stay presentation-held at alpha 0.
static void RNSZoomCompleteTransition(
    RNSScreenStackAnimator *_Nullable stackAnimator,
    id<UIViewControllerContextTransitioning> transitionContext,
    UIView *animatedView,
    UIView *dimmingView,
    CGFloat cardAlphaOnComplete)
{
  const BOOL completed = ![transitionContext transitionWasCancelled];
  [stackAnimator zoomFinishCardFlightSettingCardAlpha:completed ? cardAlphaOnComplete : 1.0 - cardAlphaOnComplete];
  RNSZoomRemoveOpacityRamp(animatedView);
  animatedView.alpha = 1.0;
  [dimmingView removeFromSuperview];
  [transitionContext completeTransition:completed];
}

- (void)animateZoomWithTransitionContext:(id<UIViewControllerContextTransitioning>)transitionContext
                                    toVC:(UIViewController *)toViewController
                                  fromVC:(UIViewController *)fromViewController
{
  RNSScreenView *screen;
  UIView *animatedView;
  UIView *belowView; // the screen the zoom flies out of / back into
  if (_operation == UINavigationControllerOperationPush) {
    screen = ((RNSScreen *)toViewController).screenView;
    animatedView = toViewController.view;
    belowView = fromViewController.view;
  } else {
    screen = ((RNSScreen *)fromViewController).screenView;
    animatedView = fromViewController.view;
    belowView = toViewController.view;
  }

  UIView *container = transitionContext.containerView;
  if (RNSZoomDebugEnabled && RNSZoomDebugAnimationSpeed != 1.0f) {
    container.layer.speed = RNSZoomDebugAnimationSpeed;
    // Restored in animationEnded: — the container outlives the transition.
    _zoomSlowedLayer = container.layer;
  }
  CGRect sourceRectInWindow = RNSZoomRectFromDictionary(screen.zoomSourceRect);
  CGRect alignmentRect = RNSZoomRectFromDictionary(screen.zoomAlignmentRect);

  if (CGRectIsNull(sourceRectInWindow) || CGRectIsNull(alignmentRect)) {
    // Without valid rects there is nothing to zoom from/to — degrade to a fade.
    [self animateFadeWithTransitionContext:transitionContext toVC:toViewController fromVC:fromViewController];
    return;
  }

  if (_operation == UINavigationControllerOperationPush) {
    animatedView.frame = [transitionContext finalFrameForViewController:toViewController];
  }

  CGRect sourceRect = [container convertRect:sourceRectInWindow fromView:nil];
  const CGFloat scale = CGRectGetWidth(sourceRect) / CGRectGetWidth(alignmentRect);
  const CGRect viewFrame = animatedView.frame;
  const CGRect viewBounds = animatedView.bounds;

  // getShelfFlightGeometry: centre-to-centre deltas put the alignment rect (scaled
  // about the view centre) exactly onto the source rect. (Screen-zoom fallback.)
  RNSZoomScreenGeometry geometry;
  geometry.shelfScale = scale;
  geometry.shelfTX = CGRectGetMidX(sourceRect) - CGRectGetMidX(viewFrame) -
      scale * (CGRectGetMidX(alignmentRect) - CGRectGetMidX(viewBounds));
  geometry.shelfTY = CGRectGetMidY(sourceRect) - CGRectGetMidY(viewFrame) -
      scale * (CGRectGetMidY(alignmentRect) - CGRectGetMidY(viewBounds));
  geometry.alignmentRect = alignmentRect;
  geometry.viewBounds = viewBounds;
  // Mask radius lives in unscaled view coordinates, so pre-divide by scale to read
  // as the source view's radius on screen.
  geometry.maskSourceCornerRadius = scale > 0 ? screen.zoomSourceCornerRadius / scale : 0;
  _zoomScreenGeometry = geometry;

  // The card flight needs the real card view; fall back to the screen zoom without it.
  UIView *cardView = nil;
  if (screen.zoomSourceViewNativeID.length > 0 && belowView != nil) {
    cardView = RNSZoomFindViewByNativeID(belowView, screen.zoomSourceViewNativeID, 0);
  }
  _zoomCardGeometry.slotRect = sourceRect;
  _zoomCardGeometry.alignmentRect = alignmentRect;

  const NSTimeInterval duration = [self transitionDuration:transitionContext];
  // The commit flight and cancel-scale math read _transitionDuration later (outside
  // any transition context); keep it in sync with the screen's real duration, or the
  // carrier completes before the flight and amputates the landing overshoot.
  _transitionDuration = duration;

  if (_operation == UINavigationControllerOperationPush) {
    [self animateZoomPushWithContext:transitionContext
                        animatedView:animatedView
                            cardView:cardView
                            duration:duration];
  } else if (_operation == UINavigationControllerOperationPop) {
    [self animateZoomPopWithContext:transitionContext
                       animatedView:animatedView
                             toView:toViewController.view
                           cardView:cardView
                           duration:duration];
  }
}

- (void)animateZoomPushWithContext:(id<UIViewControllerContextTransitioning>)transitionContext
                      animatedView:(UIView *)animatedView
                          cardView:(UIView *_Nullable)cardView
                          duration:(NSTimeInterval)duration
{
  UIView *container = transitionContext.containerView;
  UIView *dimmingView = [[UIView alloc] initWithFrame:container.bounds];
  dimmingView.backgroundColor = [UIColor blackColor];
  dimmingView.alpha = 0.0;

  // performWithoutAnimation: an enclosing UIView animation block (status-bar hide)
  // must not capture these setup writes as implicit animations.
  [UIView performWithoutAnimation:^{
    [container addSubview:animatedView];
    [container insertSubview:dimmingView belowSubview:animatedView];
  }];

  UIView *destCover = nil;
  UIView *standIn = nil;
  if (cardView != nil) {
    destCover = RNSZoomFindViewByNativeID(animatedView, RNSZoomDestCoverNativeID, 0);
    standIn = [self zoomMakeStandInFromCardView:cardView destCover:destCover inContainer:container];
  }

  if (standIn != nil) {
    // Card flight: a snapshot stand-in of the cover flies up to the reader pose while
    // the pushed screen (rendering the identical cover at that pose) fades in beneath
    // it. The stand-in covers the real card exactly; hiding the card in the same
    // transaction leaves no visible seam. Its shelf slot then stays empty for the
    // whole reading session (the reader shows the identical cover instead). The
    // reader's own cover stays hidden while the stand-in flies — it must be the only
    // cover on screen — and reveals at landing.
    _zoomDestCoverView = destCover;
    [UIView performWithoutAnimation:^{
      standIn.transform = [self zoomCardTransformForAt:1];
    }];
    // Presentation-side hides/ramp (models stay 1): immune to Fabric commits
    // rewriting opacity mid-flight. Released atomically in finishCardFlight.
    RNSZoomHoldOpacity(cardView, 0);
    RNSZoomHoldOpacity(destCover, 0);
    RNSZoomAddOpacityRamp(animatedView, duration, ^CGFloat(CGFloat t) {
      // Backdrop (the page, behind the flying stand-in) fade-in ramp.
      return MIN(RNSZoomEaseOutCubic(t) / RNSZoomOpenBackdropFullAt, 1.0);
    });
    _zoomRampedView = animatedView;

    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                                                                  curve:UIViewAnimationCurveLinear
                                                                             animations:nil];
    __weak RNSScreenStackAnimator *weakSelf = self;
    [animator addAnimations:^{
      RNSZoomAddFlightKeyframes(nil, 0, ^(CGFloat t) {
        const CGFloat at = 1 - RNSZoomEaseOutCubic(t);
        standIn.transform = [weakSelf zoomCardTransformForAt:at];
        dimmingView.alpha = RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(at));
      });
    }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      // Completed: card stays session-hidden under the now-opaque reader. Cancelled:
      // it reappears exactly as the stand-in vanishes (same transaction).
      RNSZoomCompleteTransition(weakSelf, transitionContext, animatedView, dimmingView, 0.0);
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
    return;
  }

  // Fallback: masked screen zoom out of the source rect. Also the landing spot when
  // the card snapshot fails (nil stand-in) — mirrors the pop path.
  [self runMaskedZoomFlightWithContext:transitionContext
                          animatedView:animatedView
                           dimmingView:dimmingView
                              duration:duration
                             initialAt:1
                               easedAt:^CGFloat(CGFloat t) {
                                 return 1 - RNSZoomEaseOutCubic(t);
                               }];
}

- (void)animateZoomPopWithContext:(id<UIViewControllerContextTransitioning>)transitionContext
                     animatedView:(UIView *)animatedView
                           toView:(UIView *)toView
                         cardView:(UIView *_Nullable)cardView
                         duration:(NSTimeInterval)duration
{
  UIView *container = transitionContext.containerView;
  UIView *dimmingView = [[UIView alloc] initWithFrame:container.bounds];
  dimmingView.backgroundColor = [UIColor blackColor];

  [UIView performWithoutAnimation:^{
    toView.transform = CGAffineTransformIdentity;
    [container insertSubview:toView belowSubview:animatedView];
    [container insertSubview:dimmingView belowSubview:animatedView];
    dimmingView.alpha = RNSZoomDimMaxAlpha;
  }];

  __weak RNSScreenStackAnimator *weakSelf = self;

  if (transitionContext.isInteractive) {
    // Interactive drag: the gesture drives the page pose manually (see
    // applyZoomDragPose…); this animator only carries the UIKit transition progress,
    // scrubbed by the interaction controller. The dimming stays at its resting alpha
    // for the whole drag (scrubbing it made the release visibly snap) and only fades
    // during the commit flight. The card flight happens at commit
    // (startZoomCommitFlight) if the card view is available.
    _isZoomInteractive = YES;
    _zoomAnimatedView = animatedView;
    _zoomDimmingView = dimmingView;
    _zoomPendingCardView = cardView;
    _zoomBelowView = toView;
    // A lingering cancel-spring from a previous grab must not fight the new drag.
    [animatedView.layer removeAllAnimations];
    CALayer *dragMaskLayer = [CALayer layer];
    dragMaskLayer.backgroundColor = UIColor.blackColor.CGColor;
    dragMaskLayer.cornerCurve = kCACornerCurveContinuous;
    dragMaskLayer.cornerRadius = RNSZoomBaseReaderRadius;
    dragMaskLayer.frame = animatedView.layer.bounds;
    _zoomMaskLayer = dragMaskLayer;
    animatedView.layer.mask = dragMaskLayer;

    // Invisible progress carrier: the animator needs a real animation to span the
    // transition duration (an empty animator completes instantly, ending the
    // transition before the commit flight lands), but nothing visible may ride it.
    UIView *progressCarrier = [[UIView alloc] initWithFrame:CGRectZero];
    progressCarrier.userInteractionEnabled = NO;
    [UIView performWithoutAnimation:^{
      [container addSubview:progressCarrier];
    }];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                                                                  curve:UIViewAnimationCurveLinear
                                                                             animations:^{
                                                                               progressCarrier.alpha = 0.0;
                                                                             }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      RNSScreenStackAnimator *strongSelf = weakSelf;
      if (strongSelf != nil) {
        strongSelf->_isZoomInteractive = NO;
        if (animatedView.layer.mask == strongSelf->_zoomMaskLayer) {
          animatedView.layer.mask = nil;
        }
        strongSelf->_zoomMaskLayer = nil;
      }
      animatedView.transform = CGAffineTransformIdentity;
      [progressCarrier removeFromSuperview];
      RNSZoomCompleteTransition(strongSelf, transitionContext, animatedView, dimmingView, 1.0);
    }];
    [animator setUserInteractionEnabled:YES];
    _inFlightAnimator = animator;
    return;
  }

  RNSScreenView *screenForTiming = _animatedScreen;
  const NSTimeInterval closeFlightDelay =
      RNSZoomDuration(screenForTiming.zoomCloseFlightDelayMs, RNSZoomCloseFlightDelay);
  const NSTimeInterval totalDuration = duration + closeFlightDelay;
  const CGFloat delayFraction = closeFlightDelay / totalDuration;

  // Mid-load closes still have the reader's cover mounted: render it into the
  // stand-in so the close flight starts sharp too.
  UIView *standIn = nil;
  if (cardView != nil) {
    UIView *destCover = RNSZoomFindViewByNativeID(animatedView, RNSZoomDestCoverNativeID, 0);
    standIn = [self zoomMakeStandInFromCardView:cardView destCover:destCover inContainer:container];
  }

  if (standIn != nil) {
    // Card-flight close: the page fades out in place (COVER_ZOOM_CLOSE_FADE) while the
    // snapshot stand-in materialises at the reader pose (fading in over the first
    // revealFraction of the flight) and flies home with the overshoot arc. Landing restores the real card's
    // alpha in the same transaction that removes the stand-in — seamless.
    // Re-hold the card at 0 for the flight: Fabric may have remounted/recycled it since
    // push time (resetting its model alpha to the JS value), which would show the real
    // card under the flying stand-in. Released in finishCardFlight's handoff.
    RNSZoomHoldOpacity(cardView, 0);
    [UIView performWithoutAnimation:^{
      standIn.transform = [self zoomCardTransformForAt:0];
      standIn.alpha = 0.0;
    }];

    const CGFloat revealFraction =
        MIN(RNSZoomDuration(screenForTiming.zoomCloseRevealMs, RNSZoomCloseRevealDuration) / totalDuration, 1.0);
    RNSZoomAddPageFadeRamp(
        animatedView, totalDuration, RNSZoomDuration(screenForTiming.zoomClosePageFadeMs, RNSZoomClosePageFadeDuration));
    _zoomRampedView = animatedView;

    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:totalDuration
                                                                                  curve:UIViewAnimationCurveLinear
                                                                             animations:nil];
    [animator addAnimations:^{
      RNSZoomAddFlightKeyframes(standIn, revealFraction, ^(CGFloat t) {
        const CGFloat at = RNSZoomDelayedCloseEasing(t, delayFraction);
        standIn.transform = [weakSelf zoomCardTransformForAt:at];
        dimmingView.alpha = RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(at));
      });
    }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      RNSZoomCompleteTransition(weakSelf, transitionContext, animatedView, dimmingView, 1.0);
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
    return;
  }

  // Fallback: masked screen zoom back into the source rect, with the exact
  // CLOSE_FLIGHT_EASING (overshoot) + arc after the reveal delay. Also the landing
  // spot when the card snapshot fails (nil stand-in) — mirrors the push path.
  [self runMaskedZoomFlightWithContext:transitionContext
                          animatedView:animatedView
                           dimmingView:dimmingView
                              duration:totalDuration
                             initialAt:0
                               easedAt:^CGFloat(CGFloat t) {
                                 return RNSZoomDelayedCloseEasing(t, delayFraction);
                               }];
}

#pragma mark - Zoom interactive dismissal (driven from the stack's pan handler)

- (BOOL)isZoomInteractive
{
  return _isZoomInteractive;
}

// Single source for the cancel spring's duration: zoomCancelDurationScale's contract
// (the carrier completes together with the spring) depends on both readers agreeing.
- (NSTimeInterval)zoomCancelSpringDuration
{
  return RNSZoomDuration(_animatedScreen.zoomCancelSpringMs, RNSZoomCancelSpringDuration);
}

- (CGFloat)zoomCancelDurationScale
{
  // Scale a cancelled carrier's completion to match the cancel spring.
  return _transitionDuration > 0 ? [self zoomCancelSpringDuration] / _transitionDuration : 1;
}

// dismissTransform + dismissCornerRadius: finger-follow translation with the eased
// shrink about the screen centre.
- (void)applyZoomDragPoseWithTranslation:(CGPoint)translation progress:(CGFloat)progress
{
  UIView *animatedView = _zoomAnimatedView;
  CALayer *maskLayer = _zoomMaskLayer;
  if (animatedView == nil || maskLayer == nil) {
    return;
  }
  const CGFloat scale = RNSZoomDragScale(progress);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  // Fabric prop commits mid-drag (e.g. the close-target retarget once the book
  // loads) reset the screen's transform and layer.mask; re-assert both each frame.
  // Comparing/assigning bare CALayers is safe — layer.mask retains its layer.
  if (animatedView.layer.mask != maskLayer) {
    maskLayer.frame = animatedView.layer.bounds;
    animatedView.layer.mask = maskLayer;
  }
  animatedView.transform = CGAffineTransformScale(
      CGAffineTransformMakeTranslation(
          translation.x * RNSZoomDragTranslateFactor, translation.y * RNSZoomDragTranslateFactor),
      scale,
      scale);
  maskLayer.cornerRadius = RNSZoomDragCornerRadius(progress);
  [CATransaction commit];
}

// Commit: a snapshot stand-in of the cover materialises embedded in the shrunken
// page's cover position (closeInteractiveStyle) and flies home along the arc while
// the page fades out in place; the real card's alpha is restored at landing. Falls
// back to flying the masked page when the card view isn't available.
- (void)startZoomCommitFlightFromTranslation:(CGPoint)translation progress:(CGFloat)progress
{
  UIView *animatedView = _zoomAnimatedView;
  UIView *cardView = _zoomPendingCardView;
  // The dim is held at its resting alpha through the whole drag; the commit flight
  // owns its fade-out (keyframed with the flight below).
  UIView *dimmingView = _zoomDimmingView;
  _zoomPendingCardView = nil;
  if (animatedView == nil) {
    return;
  }

  // The card captured at drag-begin can be recycled away mid-gesture (the shelf
  // re-renders when the book finishes loading). Re-find it by the screen's CURRENT
  // nativeID — the JS retarget keeps that pointing at the live cell — and refresh
  // the geometry from the current props.
  RNSScreenView *screen = _animatedScreen;
  UIView *belowView = _zoomBelowView;
  if (cardView == nil && screen != nil && screen.zoomSourceViewNativeID.length > 0 && belowView != nil) {
    cardView = RNSZoomFindViewByNativeID(belowView, screen.zoomSourceViewNativeID, 0);
  }
  if (cardView != nil && screen != nil && animatedView.superview != nil) {
    CGRect sourceRectInWindow = RNSZoomRectFromDictionary(screen.zoomSourceRect);
    CGRect alignmentRect = RNSZoomRectFromDictionary(screen.zoomAlignmentRect);
    if (!CGRectIsNull(sourceRectInWindow) && !CGRectIsNull(alignmentRect)) {
      _zoomCardGeometry.slotRect = [animatedView.superview convertRect:sourceRectInWindow fromView:nil];
      _zoomCardGeometry.alignmentRect = alignmentRect;
    }
  }

  const CGFloat pageScale = RNSZoomDragScale(progress);
  const CGFloat dragTX = translation.x * RNSZoomDragTranslateFactor;
  const CGFloat dragTY = translation.y * RNSZoomDragTranslateFactor;

  UIView *standIn = nil;
  if (cardView != nil && animatedView.window != nil) {
    UIView *container = animatedView.superview;
    UIView *destCover = RNSZoomFindViewByNativeID(animatedView, RNSZoomDestCoverNativeID, 0);
    standIn = [self zoomMakeStandInFromCardView:cardView destCover:destCover inContainer:container];
  }
  if (standIn != nil) {
    // The cover's embedded pose inside the shrunken, dragged page: the page scales
    // about the screen centre, so every point moves the same way. The flying view's
    // natural frame is the alignment rect, so the embedded scale is just the page
    // scale, about its own centre.
    const RNSZoomCardGeometry g = _zoomCardGeometry;
    const CGRect pageBounds = animatedView.bounds;
    const CGFloat screenMidX = CGRectGetMidX(pageBounds);
    const CGFloat screenMidY = CGRectGetMidY(pageBounds);
    const CGFloat embeddedMidX = screenMidX + pageScale * (CGRectGetMidX(g.alignmentRect) - screenMidX) + dragTX;
    const CGFloat embeddedMidY = screenMidY + pageScale * (CGRectGetMidY(g.alignmentRect) - screenMidY) + dragTY;
    const RNSZoomPose releasePose = {
        pageScale, embeddedMidX - CGRectGetMidX(g.alignmentRect), embeddedMidY - CGRectGetMidY(g.alignmentRect)};
    // Slot pose (flight target) — the same target zoomCardTransformForAt lands on.
    const RNSZoomPose slot = RNSZoomSlotPoseForGeometry(g);
    // Re-hold the re-found card at 0 for the flight (same rationale as the
    // non-interactive close: a Fabric remount since push resets its model alpha).
    RNSZoomHoldOpacity(cardView, 0);
    [UIView performWithoutAnimation:^{
      standIn.alpha = 0.0;
      standIn.transform = RNSZoomArcLerpTransform(releasePose, slot, 0);
    }];

    const CGFloat revealFraction = MIN(
        RNSZoomDuration(screen.zoomCommitRevealMs, RNSZoomCommitRevealDuration) / MAX(_transitionDuration, 0.01), 1.0);
    RNSZoomAddPageFadeRamp(
        animatedView, _transitionDuration, RNSZoomDuration(screen.zoomClosePageFadeMs, RNSZoomClosePageFadeDuration));
    _zoomRampedView = animatedView;

    UIViewPropertyAnimator *flight = [[UIViewPropertyAnimator alloc] initWithDuration:_transitionDuration
                                                                                curve:UIViewAnimationCurveLinear
                                                                           animations:nil];
    [flight addAnimations:^{
      RNSZoomAddFlightKeyframes(standIn, revealFraction, ^(CGFloat t) {
        const CGFloat cp = RNSZoomCloseEasing(t);
        standIn.transform = RNSZoomArcLerpTransform(releasePose, slot, cp);
        dimmingView.alpha = RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(cp));
      });
    }];
    [flight startAnimation];
    return;
  }

  // Fallback: fly the page home from the release pose (closeInteractiveStyle). The
  // drag mask layer keeps the release corners; only the transform animates.
  const RNSZoomScreenGeometry g = _zoomScreenGeometry;
  const RNSZoomPose releasePose = {pageScale, dragTX, dragTY};
  const RNSZoomPose shelfPose = {g.shelfScale, g.shelfTX, g.shelfTY};

  UIViewPropertyAnimator *flight = [[UIViewPropertyAnimator alloc] initWithDuration:_transitionDuration
                                                                              curve:UIViewAnimationCurveLinear
                                                                         animations:nil];
  [flight addAnimations:^{
    RNSZoomAddFlightKeyframes(nil, 0, ^(CGFloat t) {
      const CGFloat cp = RNSZoomCloseEasing(t);
      animatedView.transform = RNSZoomArcLerpTransform(releasePose, shelfPose, cp);
      dimmingView.alpha = RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(cp));
    });
  }];
  [flight startAnimation];
}

- (void)startZoomCancelSpring
{
  UIView *animatedView = _zoomAnimatedView;
  CALayer *maskLayer = _zoomMaskLayer;
  _zoomPendingCardView = nil;
  if (animatedView == nil) {
    return;
  }
  const NSTimeInterval springDuration = [self zoomCancelSpringDuration];
  [UIView animateWithDuration:springDuration
                        delay:0
       usingSpringWithDamping:RNSZoomCancelSpringDamping
        initialSpringVelocity:0
                      options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     animatedView.transform = CGAffineTransformIdentity;
                   }
                   completion:nil];
  if (maskLayer != nil) {
    CABasicAnimation *radiusAnimation = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];
    radiusAnimation.fromValue = @(maskLayer.presentationLayer.cornerRadius);
    radiusAnimation.toValue = @(RNSZoomBaseReaderRadius);
    radiusAnimation.duration = springDuration;
    radiusAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    maskLayer.cornerRadius = RNSZoomBaseReaderRadius;
    [CATransaction commit];
    [maskLayer addAnimation:radiusAnimation forKey:@"rns-zoom-cancel-radius"];
  }
}

- (void)animateWithNoAnimation:(id<UIViewControllerContextTransitioning>)transitionContext
                          toVC:(UIViewController *)toViewController
                        fromVC:(UIViewController *)fromViewController
{
  if (_operation == UINavigationControllerOperationPush) {
    [[transitionContext containerView] addSubview:toViewController.view];
    [UIView animateWithDuration:[self transitionDuration:transitionContext]
        animations:^{
        }
        completion:^(BOOL finished) {
          [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
        }];
  } else if (_operation == UINavigationControllerOperationPop) {
    [[transitionContext containerView] insertSubview:toViewController.view belowSubview:fromViewController.view];

    [UIView animateWithDuration:[self transitionDuration:transitionContext]
        animations:^{
        }
        completion:^(BOOL finished) {
          [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
        }];
  }
}

- (void)animateNoneWithTransitionContext:(id<UIViewControllerContextTransitioning>)transitionContext
                                    toVC:(UIViewController *)toViewController
                                  fromVC:(UIViewController *)fromViewController
{
  toViewController.view.frame = [transitionContext finalFrameForViewController:toViewController];

  if (_operation == UINavigationControllerOperationPush) {
    [[transitionContext containerView] addSubview:toViewController.view];
    toViewController.view.alpha = 0.0;
    [UIView animateWithDuration:[self transitionDuration:transitionContext]
        animations:^{
          toViewController.view.alpha = 1.0;
        }
        completion:^(BOOL finished) {
          toViewController.view.alpha = 1.0;
          [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
        }];
  } else if (_operation == UINavigationControllerOperationPop) {
    [[transitionContext containerView] insertSubview:toViewController.view belowSubview:fromViewController.view];

    [UIView animateWithDuration:[self transitionDuration:transitionContext]
        animations:^{
          fromViewController.view.alpha = 0.0;
        }
        completion:^(BOOL finished) {
          fromViewController.view.alpha = 1.0;

          [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
        }];
  }
}

#pragma mark - Public API

- (nullable id<UITimingCurveProvider>)timingParamsForAnimationCompletion
{
  if (_isZoomInteractive) {
    // The zoom progress carrier is an invisible dummy view — linear keeps its
    // completion proportional to real time (the visible flight is keyframed manually).
    return [[UICubicTimingParameters alloc] initWithAnimationCurve:UIViewAnimationCurveLinear];
  }
  return [RNSScreenStackAnimator defaultSpringTimingParametersApprox];
}

+ (BOOL)isCustomAnimation:(RNSScreenStackAnimation)animation
{
  return (animation != RNSScreenStackAnimationFlip && animation != RNSScreenStackAnimationDefault);
}

#pragma mark - Helpers

- (void)animateTransitionWithStackAnimation:(RNSScreenStackAnimation)animation
                              shadowEnabled:(BOOL)shadowEnabled
                          transitionContext:(id<UIViewControllerContextTransitioning>)transitionContext
                                       toVC:(UIViewController *)toVC
                                     fromVC:(UIViewController *)fromVC
{
  switch (animation) {
    case RNSScreenStackAnimationSimplePush:
      [self animateSimplePushWithShadowEnabled:shadowEnabled
                             transitionContext:transitionContext
                                          toVC:toVC
                                        fromVC:fromVC];
      return;
    case RNSScreenStackAnimationSlideFromLeft:
      [self animateSlideFromLeftWithTransitionContext:transitionContext toVC:toVC fromVC:fromVC];
      return;
    case RNSScreenStackAnimationFade:
      [self animateFadeWithTransitionContext:transitionContext toVC:toVC fromVC:fromVC];
      return;
    case RNSScreenStackAnimationSlideFromBottom:
      [self animateSlideFromBottomWithTransitionContext:transitionContext toVC:toVC fromVC:fromVC];
      return;
    case RNSScreenStackAnimationFadeFromBottom:
      [self animateFadeFromBottomWithTransitionContext:transitionContext toVC:toVC fromVC:fromVC];
      return;
    case RNSScreenStackAnimationNone:
      [self animateNoneWithTransitionContext:transitionContext toVC:toVC fromVC:fromVC];
      return;
    case RNSScreenStackAnimationZoom:
      [self animateZoomWithTransitionContext:transitionContext toVC:toVC fromVC:fromVC];
      return;
    default:
      // simple_push is the default custom animation
      [self animateSimplePushWithShadowEnabled:shadowEnabled
                             transitionContext:transitionContext
                                          toVC:toVC
                                        fromVC:fromVC];
  }
}

+ (UISpringTimingParameters *)defaultSpringTimingParametersApprox
{
  // Default curve provider is as defined below, however spring timing defined this way
  // ignores the requested duration of the animation, effectively impairing our `animationDuration` prop.
  // We want to keep `animationDuration` functional.
  // id<UITimingCurveProvider> timingCurveProvider = [[UISpringTimingParameters alloc] init];

  // According to "Programming iOS 14" by Matt Neuburg, the params for the default spring are as follows:
  // mass = 3, stiffness = 1000, damping = 500. Damping ratio is computed using formula
  // ratio = damping / (2 * sqrt(stiffness * mass)) ==> default damping ratio should be ~= 4,56.
  // I've found afterwards that this is even indicated here:
  // https://developer.apple.com/documentation/uikit/uispringtimingparameters/1649802-init?language=objc

  return [[UISpringTimingParameters alloc] initWithDampingRatio:4.56];
}

@end
