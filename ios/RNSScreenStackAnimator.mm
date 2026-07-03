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
static constexpr CGFloat RNSZoomArcLeadExp = 1 + RNSZoomArc; // Y leads the flight
static constexpr CGFloat RNSZoomArcTrailExp = 1 / (1 + RNSZoomArc); // X trails
static constexpr CGFloat RNSZoomCloseOvershoot = 1.1;
static constexpr CGFloat RNSZoomInteractiveMinScale = 0.55;
static constexpr CGFloat RNSZoomDragTranslateFactor = 0.3;
static constexpr CGFloat RNSZoomBaseReaderRadius = 16;
static constexpr CGFloat RNSZoomDeviceCornerRadius = 52;
static constexpr NSTimeInterval RNSZoomCancelSpringDuration = 0.36;
static constexpr CGFloat RNSZoomCancelSpringDamping = 0.82;
static constexpr int RNSZoomKeyframeCount = 24;

// Easing.out(Easing.cubic)
static inline CGFloat RNSZoomOpenEasing(CGFloat t)
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
static inline CGFloat RNSZoomArcCurve(CGFloat t, CGFloat exp)
{
  if (t <= 0 || t >= 1) {
    return t;
  }
  return pow(t, exp);
}

// easeOutDrag
static inline CGFloat RNSZoomEaseOutDrag(CGFloat t)
{
  const CGFloat inv = 1 - t;
  return 1 - inv * inv * inv;
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
  return RNSZoomLerp(1, RNSZoomInteractiveMinScale, RNSZoomClamp01(RNSZoomEaseOutDrag(dragProgress)));
}

// dismissCornerRadius — pre-divided by the live scale so the on-screen radius lands
// near the device corner radius.
static inline CGFloat RNSZoomDragCornerRadius(CGFloat dragProgress)
{
  const CGFloat p = RNSZoomClamp01(RNSZoomEaseOutDrag(dragProgress));
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
} RNSZoomGeometry;

static CGRect RNSZoomLerpRect(CGRect from, CGRect to, CGFloat t)
{
  return CGRectMake(
      RNSZoomLerp(from.origin.x, to.origin.x, t),
      RNSZoomLerp(from.origin.y, to.origin.y, t),
      RNSZoomLerp(from.size.width, to.size.width, t),
      RNSZoomLerp(from.size.height, to.size.height, t));
}

// JS timing constants for the close (coverZoom.tsx).
static constexpr NSTimeInterval RNSZoomCloseRevealDuration = 0.2; // CLOSE_REVEAL_MS
static constexpr NSTimeInterval RNSZoomCloseFlightDelay = 0.175; // CLOSE_FLIGHT_DELAY_MS
static constexpr NSTimeInterval RNSZoomClosePageFadeDuration = 0.3; // COVER_ZOOM_CLOSE_FADE_MS
static constexpr NSTimeInterval RNSZoomCommitRevealDuration = 0.15; // cover materialise on drag commit

// Geometry for the portal card flight: the real card view (wrapper) is reparented into
// the transition container; its cover rect maps onto the alignment rect at the reader end.
typedef struct {
  CGRect coverRect; // fitted cover rect (source rect prop) in container coordinates
  CGRect alignmentRect; // cover box inside the reader screen
} RNSZoomCardGeometry;

// Finds the source card view (tagged via nativeID from JS) in the screen below.
// On Fabric the nativeID prop lands on RCTViewComponentView.nativeId (testID is what
// feeds accessibilityIdentifier), so check both. Skips webview internals; scroll
// views are searched (cards live inside lists).
static UIView *_Nullable RNSZoomFindViewByNativeID(UIView *root, NSString *nativeID, int depth)
{
  if (depth > 30 || [root isKindOfClass:NSClassFromString(@"WKWebView")]) {
    return nil;
  }
  if ([root respondsToSelector:@selector(nativeId)]) {
    NSString *nativeId = [(id)root nativeId];
    if ([nativeId isEqualToString:nativeID]) {
      return root;
    }
  }
  if ([root.accessibilityIdentifier isEqualToString:nativeID]) {
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

// Collects every view carrying the nativeID (badge overlays tagged by JS so the
// flight snapshot can hide them — only the pure cover flies).
static void RNSZoomCollectViewsByNativeID(UIView *root, NSString *nativeID, int depth, NSMutableArray<UIView *> *out)
{
  if (depth > 30 || [root isKindOfClass:NSClassFromString(@"WKWebView")]) {
    return;
  }
  BOOL matches = NO;
  if ([root respondsToSelector:@selector(nativeId)]) {
    matches = [[(id)root nativeId] isEqualToString:nativeID];
  }
  if (!matches && [root.accessibilityIdentifier isEqualToString:nativeID]) {
    matches = YES;
  }
  if (matches) {
    [out addObject:root];
  }
  for (UIView *subview in root.subviews) {
    RNSZoomCollectViewsByNativeID(subview, nativeID, depth + 1, out);
  }
}


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
  RNSZoomGeometry _zoomGeometry;
  // Portal card flight state.
  RNSZoomCardGeometry _zoomCardGeometry;
  __weak UIView *_zoomCardView;
  __weak UIView *_zoomPendingCardView;
  __weak UIView *_zoomBelowView;
  // The flying stand-in is a native snapshot we own — Fabric can recycle the real
  // card mid-flight without breaking the animation.
  UIView *_Nullable _zoomFlyingCardView;
  CGFloat _zoomCardOriginalAlpha;
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
  const RNSZoomGeometry g = _zoomGeometry;
  const CGFloat atY = RNSZoomArcCurve(at, RNSZoomArcLeadExp);
  const CGFloat atX = RNSZoomArcCurve(at, RNSZoomArcTrailExp);
  const CGFloat scale = RNSZoomLerp(1, g.shelfScale, at);
  animatedView.transform = CGAffineTransformScale(
      CGAffineTransformMakeTranslation(atX * g.shelfTX, atY * g.shelfTY), MAX(scale, 0.001), MAX(scale, 0.001));
  maskView.frame = RNSZoomLerpRect(g.viewBounds, g.alignmentRect, at);
  maskView.layer.cornerRadius = MAX(RNSZoomLerp(RNSZoomBaseReaderRadius, g.maskSourceCornerRadius, at), 0);
  dimmingView.alpha = RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(at));
}

// Keyframed flight sampling the exact JS easing + arc math. `easedAt` maps uniform
// time [0..1] to "at" space.
- (void)addZoomFlightKeyframesToView:(UIView *)animatedView
                            maskView:(UIView *)maskView
                         dimmingView:(UIView *)dimmingView
                             easedAt:(CGFloat (^)(CGFloat t))easedAt
{
  [UIView animateKeyframesWithDuration:0
                                 delay:0
                               options:0
                            animations:^{
                              for (int i = 1; i <= RNSZoomKeyframeCount; i++) {
                                const CGFloat t = (CGFloat)i / RNSZoomKeyframeCount;
                                [UIView addKeyframeWithRelativeStartTime:(CGFloat)(i - 1) / RNSZoomKeyframeCount
                                                        relativeDuration:1.0 / RNSZoomKeyframeCount
                                                              animations:^{
                                                                [self applyZoomFlightPose:easedAt(t)
                                                                                   toView:animatedView
                                                                                 maskView:maskView
                                                                              dimmingView:dimmingView];
                                                              }];
                              }
                            }
                            completion:nil];
}

#pragma mark - Zoom card flight (native portal)

// Transform for the flying card at "at" (0 = reader pose, 1 = shrunk onto the slot's
// cover rect). The flying view's natural frame IS the alignment rect (rendered at
// full reader resolution), so the flight only ever downscales — never a blurry
// upscale. Same per-axis arc curves as before: the visual path is unchanged.
- (CGAffineTransform)zoomCardTransformForAt:(CGFloat)at
{
  const RNSZoomCardGeometry g = _zoomCardGeometry;
  const CGFloat atY = RNSZoomArcCurve(at, RNSZoomArcLeadExp);
  const CGFloat atX = RNSZoomArcCurve(at, RNSZoomArcTrailExp);
  const CGFloat slotScale = CGRectGetWidth(g.coverRect) / MAX(CGRectGetWidth(g.alignmentRect), 1);
  const CGFloat scale = MAX(RNSZoomLerp(1, slotScale, at), 0.001);
  const CGFloat slotTX = CGRectGetMidX(g.coverRect) - CGRectGetMidX(g.alignmentRect);
  const CGFloat slotTY = CGRectGetMidY(g.coverRect) - CGRectGetMidY(g.alignmentRect);
  return CGAffineTransformScale(
      CGAffineTransformMakeTranslation(slotTX * atX, slotTY * atY), scale, scale);
}

// Renders a view into the current image-renderer context at destRect. Prefers the
// on-screen appearance; drawViewHierarchyInRect can silently produce a blank image
// (observed on repeat opens: BOOL result NO), so fall back to a model-tree layer
// render, which has no dependency on render-server snapshot state.
static BOOL RNSZoomDrawViewIntoRect(UIView *view, CGRect destRect, UIGraphicsImageRendererContext *context)
{
  if ([view drawViewHierarchyInRect:destRect afterScreenUpdates:YES]) {
    return YES;
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
  return NO;
}

// Builds the flying stand-in for the cover. Its natural frame is the ALIGNMENT rect
// (the reader pose), composited at full resolution: the card render (badges hidden,
// mapped so its cover rect fills the canvas) as a fallback base, and the reader's own
// destination cover render on top — the flight shows the same fully-rendered image the
// reader holds, so scaling up never blurs. The real card is never reparented (Fabric
// owns it and may recycle it mid-flight); visibility is handed off atomically at the ends.
- (UIView *_Nullable)zoomMakeFlyingCardFromView:(UIView *)cardView
                                      destCover:(UIView *_Nullable)destCover
                                    inContainer:(UIView *)container
{
  const CGRect coverRect = _zoomCardGeometry.coverRect;
  const CGRect alignmentRect = _zoomCardGeometry.alignmentRect;
  CGRect wrapperInContainer = [cardView.superview convertRect:cardView.frame toView:container];
  if (CGRectIsEmpty(cardView.bounds) || CGRectIsEmpty(alignmentRect) || CGRectGetWidth(coverRect) < 1) {
    return nil;
  }
  // The transition can start while some other UIView animation block is still open on
  // the stack (e.g. the status-bar hide on reader entry). Every mutation here must be
  // immune to that: an implicitly-animated frame set makes CA render the stand-in from
  // its pre-frame pose — the card visibly flies in from (0,0) — and an implicitly
  // animated alpha turns the atomic card/stand-in handoff into a crossfade.
  __block UIView *flyingView = nil;
  [UIView performWithoutAnimation:^{
    // Badge overlays (and hidden cards) are alpha-juggled for the render only: both
    // writes land in the same tick, so the display never sees them.
    NSMutableArray<UIView *> *badges = [NSMutableArray array];
    RNSZoomCollectViewsByNativeID(cardView, @"RNSZoomCoverBadge", 0, badges);
    if (destCover != nil) {
      RNSZoomCollectViewsByNativeID(destCover, @"RNSZoomCoverBadge", 0, badges);
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
      // Base: the card wrapper positioned so its cover rect fills the canvas exactly.
      const CGFloat k = canvas.size.width / coverRect.size.width;
      const CGRect baseRect = CGRectMake(
          (CGRectGetMinX(wrapperInContainer) - CGRectGetMinX(coverRect)) * k,
          (CGRectGetMinY(wrapperInContainer) - CGRectGetMinY(coverRect)) * k,
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

    flyingView = [[UIImageView alloc] initWithImage:cardImage];
    flyingView.frame = alignmentRect;
    flyingView.userInteractionEnabled = NO;
    [container addSubview:flyingView];
  }];
  _zoomFlyingCardView = flyingView;
  _zoomCardView = cardView;
  _zoomCardOriginalAlpha = cardView.alpha;
  return flyingView;
}

// Atomic handoff at the flight's end: the real card's visibility flips in the same
// CATransaction that removes the snapshot, so landing is pixel-seamless. If the real
// card was recycled mid-flight, its replacement is already visible and only the
// snapshot removal happens.
- (void)zoomFinishCardFlightSettingCardAlpha:(CGFloat)alpha
{
  UIView *flyingView = _zoomFlyingCardView;
  UIView *cardView = _zoomCardView;
  UIView *destCover = _zoomDestCoverView;
  _zoomFlyingCardView = nil;
  _zoomCardView = nil;
  _zoomDestCoverView = nil;
  if (flyingView == nil && cardView == nil && destCover == nil) {
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
  [flyingView.layer removeAllAnimations];
  [flyingView removeFromSuperview];
  [CATransaction commit];
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
  RNSZoomGeometry geometry;
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
  _zoomGeometry = geometry;

  // The card flight needs the real card view; fall back to the screen zoom without it.
  UIView *cardView = nil;
  if (screen.zoomSourceViewNativeID.length > 0 && belowView != nil) {
    cardView = RNSZoomFindViewByNativeID(belowView, screen.zoomSourceViewNativeID, 0);
  }
  _zoomCardGeometry.coverRect = sourceRect;
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

  if (cardView != nil) {
    // Portal flight: the real card flies up to the reader pose while the pushed
    // screen (rendering the identical cover at that pose) fades in beneath it.
    // performWithoutAnimation: an enclosing UIView animation block (status-bar hide)
    // must not capture these setup writes as implicit animations.
    [UIView performWithoutAnimation:^{
      [container addSubview:animatedView];
      [container insertSubview:dimmingView belowSubview:animatedView];
    }];
    UIView *destCover = RNSZoomFindViewByNativeID(animatedView, @"RNSZoomDestCover", 0);
    UIView *flyingCard = [self zoomMakeFlyingCardFromView:cardView destCover:destCover inContainer:container];
    if (flyingCard == nil) {
      // Snapshot failed — degrade to the masked screen zoom below.
      cardView = nil;
    } else {
      // The snapshot now covers the real card exactly; hide the card for the whole
      // session (legacy coverAway) in the same transaction — no visible seam.
      // The reader's own cover (destination pose) stays hidden while the card flies —
      // the legacy overlay was the only cover on screen — and reveals at landing.
      _zoomDestCoverView = destCover;
      [UIView performWithoutAnimation:^{
        flyingCard.transform = [self zoomCardTransformForAt:1];
      }];
      // Presentation-side hides/ramp (models stay 1): immune to Fabric commits
      // rewriting opacity mid-flight. Released atomically in finishCardFlight.
      RNSZoomHoldOpacity(cardView, 0);
      RNSZoomHoldOpacity(destCover, 0);
      RNSZoomAddOpacityRamp(animatedView, duration, ^CGFloat(CGFloat t) {
        // Backdrop ramp: JS interpolated progress [0, 0.85] -> opacity [0, 1].
        return MIN(RNSZoomOpenEasing(t) / 0.85, 1.0);
      });
    }

    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                                                                  curve:UIViewAnimationCurveLinear
                                                                             animations:nil];
    __weak RNSScreenStackAnimator *weakSelf = self;
    [animator addAnimations:^{
      [UIView animateKeyframesWithDuration:0
                                     delay:0
                                   options:0
                                animations:^{
                                  for (int i = 1; i <= RNSZoomKeyframeCount; i++) {
                                    const CGFloat t = (CGFloat)i / RNSZoomKeyframeCount;
                                    const CGFloat at = 1 - RNSZoomOpenEasing(t);
                                    [UIView addKeyframeWithRelativeStartTime:(CGFloat)(i - 1) / RNSZoomKeyframeCount
                                                            relativeDuration:1.0 / RNSZoomKeyframeCount
                                                                  animations:^{
                                                                    flyingCard.transform =
                                                                        [weakSelf zoomCardTransformForAt:at];
                                                                    dimmingView.alpha =
                                                                        RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(at));
                                                                  }];
                                  }
                                }
                                completion:nil];
    }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      const BOOL completed = ![transitionContext transitionWasCancelled];
      // Landed: the card returns to its slot natively hidden for the session — the
      // identical cover in the reader now covers that spot, and the slot stays empty
      // (like the legacy coverAway) until the close flight brings the card home.
      RNSScreenStackAnimator *strongSelf = weakSelf;
      // Completed: card stays session-hidden under the now-opaque reader. Cancelled:
      // it reappears exactly as the snapshot vanishes (same transaction).
      [strongSelf zoomFinishCardFlightSettingCardAlpha:completed ? 0.0 : 1.0];
      RNSZoomRemoveOpacityRamp(animatedView);
      animatedView.alpha = 1.0;
      [dimmingView removeFromSuperview];
      [transitionContext completeTransition:completed];
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
    return;
  }

  // Fallback: masked screen zoom out of the source rect.
  UIView *maskView = [[UIView alloc] init];
  maskView.backgroundColor = [UIColor blackColor];
  maskView.layer.cornerCurve = kCACornerCurveContinuous;

  [UIView performWithoutAnimation:^{
    [container addSubview:animatedView];
    [container insertSubview:dimmingView belowSubview:animatedView];

    animatedView.maskView = maskView;
    [self applyZoomFlightPose:1 toView:animatedView maskView:maskView dimmingView:dimmingView];
  }];

  UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                                                                curve:UIViewAnimationCurveLinear
                                                                           animations:nil];
  [animator addAnimations:^{
    [self addZoomFlightKeyframesToView:animatedView
                              maskView:maskView
                           dimmingView:dimmingView
                               easedAt:^CGFloat(CGFloat t) {
                                 return 1 - RNSZoomOpenEasing(t);
                               }];
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

  UIView *maskView = [[UIView alloc] init];
  maskView.backgroundColor = [UIColor blackColor];
  maskView.layer.cornerCurve = kCACornerCurveContinuous;

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
      const BOOL completed = ![transitionContext transitionWasCancelled];
      RNSScreenStackAnimator *strongSelf = weakSelf;
      if (strongSelf != nil) {
        strongSelf->_isZoomInteractive = NO;
        [strongSelf zoomFinishCardFlightSettingCardAlpha:completed ? 1.0 : 0.0];
        if (animatedView.layer.mask == strongSelf->_zoomMaskLayer) {
          animatedView.layer.mask = nil;
        }
        strongSelf->_zoomMaskLayer = nil;
      }
      animatedView.transform = CGAffineTransformIdentity;
      RNSZoomRemoveOpacityRamp(animatedView);
      animatedView.alpha = 1.0;
      [progressCarrier removeFromSuperview];
      [dimmingView removeFromSuperview];
      [transitionContext completeTransition:completed];
    }];
    [animator setUserInteractionEnabled:YES];
    _inFlightAnimator = animator;
    return;
  }

  if (cardView != nil) {
    // Portal close: the page fades out in place (COVER_ZOOM_CLOSE_FADE) while the
    // real card materialises at the reader pose (CLOSE_REVEAL over the flight delay)
    // and flies home with the overshoot arc. Landing re-inserts the card — seamless.
    // Mid-load closes still have the reader's cover mounted: render it into the
    // stand-in so the close flight starts sharp too.
    UIView *destCover = RNSZoomFindViewByNativeID(animatedView, @"RNSZoomDestCover", 0);
    UIView *flyingCard = [self zoomMakeFlyingCardFromView:cardView destCover:destCover inContainer:container];
    [UIView performWithoutAnimation:^{
      flyingCard.transform = [self zoomCardTransformForAt:0];
      flyingCard.alpha = 0.0;
    }];

    const NSTimeInterval totalDuration = duration + RNSZoomCloseFlightDelay;
    const CGFloat delayFraction = RNSZoomCloseFlightDelay / totalDuration;
    const CGFloat revealFraction = MIN(RNSZoomCloseRevealDuration / totalDuration, 1.0);
    const CGFloat pageFadeFraction = MIN(RNSZoomClosePageFadeDuration / totalDuration, 1.0);

    // Presentation-side page fade: Fabric commits mid-close must not restore the page.
    RNSZoomAddOpacityRamp(animatedView, totalDuration, ^CGFloat(CGFloat t) {
      return MAX(1.0 - t / pageFadeFraction, 0.0);
    });

    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:totalDuration
                                                                                  curve:UIViewAnimationCurveLinear
                                                                             animations:nil];
    [animator addAnimations:^{
      [UIView animateKeyframesWithDuration:0
                                     delay:0
                                   options:0
                                animations:^{
                                  [UIView addKeyframeWithRelativeStartTime:0
                                                          relativeDuration:revealFraction
                                                                animations:^{
                                                                  flyingCard.alpha = 1.0;
                                                                }];
                                  for (int i = 1; i <= RNSZoomKeyframeCount; i++) {
                                    const CGFloat t = (CGFloat)i / RNSZoomKeyframeCount;
                                    const CGFloat at = t <= delayFraction
                                        ? 0
                                        : RNSZoomCloseEasing((t - delayFraction) / (1 - delayFraction));
                                    [UIView addKeyframeWithRelativeStartTime:(CGFloat)(i - 1) / RNSZoomKeyframeCount
                                                            relativeDuration:1.0 / RNSZoomKeyframeCount
                                                                  animations:^{
                                                                    flyingCard.transform =
                                                                        [weakSelf zoomCardTransformForAt:at];
                                                                    dimmingView.alpha =
                                                                        RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(at));
                                                                  }];
                                  }
                                }
                                completion:nil];
    }];
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
      const BOOL completed = ![transitionContext transitionWasCancelled];
      RNSScreenStackAnimator *strongSelf = weakSelf;
      [strongSelf zoomFinishCardFlightSettingCardAlpha:completed ? 1.0 : 0.0];
      RNSZoomRemoveOpacityRamp(animatedView);
      animatedView.alpha = 1.0;
      [dimmingView removeFromSuperview];
      [transitionContext completeTransition:completed];
    }];
    _inFlightAnimator = animator;
    [animator startAnimation];
    return;
  }

  // Fallback: masked screen zoom back into the source rect, with the exact
  // CLOSE_FLIGHT_EASING (overshoot) + arc after the reveal delay.
  [UIView performWithoutAnimation:^{
    animatedView.maskView = maskView;
    [self applyZoomFlightPose:0 toView:animatedView maskView:maskView dimmingView:dimmingView];
  }];

  const NSTimeInterval totalDuration = duration + RNSZoomCloseFlightDelay;
  const CGFloat delayFraction = RNSZoomCloseFlightDelay / totalDuration;
  UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:totalDuration
                                                                                curve:UIViewAnimationCurveLinear
                                                                           animations:nil];
  [animator addAnimations:^{
    [self addZoomFlightKeyframesToView:animatedView
                              maskView:maskView
                           dimmingView:dimmingView
                               easedAt:^CGFloat(CGFloat t) {
                                 if (t <= delayFraction) {
                                   return 0;
                                 }
                                 return RNSZoomCloseEasing((t - delayFraction) / (1 - delayFraction));
                               }];
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


#pragma mark - Zoom interactive dismissal (driven from the stack's pan handler)

- (BOOL)isZoomInteractive
{
  return _isZoomInteractive;
}

- (CGFloat)zoomCancelDurationScale
{
  // Scale a cancelled carrier's completion to match the 360ms cancel spring.
  return _transitionDuration > 0 ? RNSZoomCancelSpringDuration / _transitionDuration : 1;
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

// Commit: the real card materialises embedded in the shrunken page's cover position
// (closeInteractiveStyle) and flies home along the arc while the page fades out in
// place. Falls back to flying the masked page when the card view isn't available.
- (void)startZoomCommitFlightFromTranslation:(CGPoint)translation progress:(CGFloat)progress
{
  UIView *animatedView = _zoomAnimatedView;
  CALayer *maskLayer = _zoomMaskLayer;
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
      _zoomCardGeometry.coverRect = [animatedView.superview convertRect:sourceRectInWindow fromView:nil];
      _zoomCardGeometry.alignmentRect = alignmentRect;
    }
  }

  const CGFloat pageScale = RNSZoomDragScale(progress);
  const CGFloat dragTX = translation.x * RNSZoomDragTranslateFactor;
  const CGFloat dragTY = translation.y * RNSZoomDragTranslateFactor;
  __weak RNSScreenStackAnimator *weakSelf = self;

  UIView *flyingCard = nil;
  if (cardView != nil && animatedView.window != nil) {
    UIView *container = animatedView.superview;
    UIView *destCover = RNSZoomFindViewByNativeID(animatedView, @"RNSZoomDestCover", 0);
    flyingCard = [self zoomMakeFlyingCardFromView:cardView destCover:destCover inContainer:container];
  }
  if (flyingCard != nil) {
    [UIView performWithoutAnimation:^{
      flyingCard.alpha = 0.0;
    }];

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
    const CGFloat embeddedScale = pageScale;
    const CGFloat startTX = embeddedMidX - CGRectGetMidX(g.alignmentRect);
    const CGFloat startTY = embeddedMidY - CGRectGetMidY(g.alignmentRect);
    // Slot pose (flight target), same anchor as zoomCardTransformForAt at at == 1.
    const CGFloat slotScale = MAX(CGRectGetWidth(g.coverRect) / MAX(CGRectGetWidth(g.alignmentRect), 1), 0.001);
    const CGFloat slotTX = CGRectGetMidX(g.coverRect) - CGRectGetMidX(g.alignmentRect);
    const CGFloat slotTY = CGRectGetMidY(g.coverRect) - CGRectGetMidY(g.alignmentRect);
    [UIView performWithoutAnimation:^{
      flyingCard.transform = CGAffineTransformScale(
          CGAffineTransformMakeTranslation(startTX, startTY), MAX(embeddedScale, 0.001), MAX(embeddedScale, 0.001));
    }];

    const CGFloat revealFraction = MIN(RNSZoomCommitRevealDuration / MAX(_transitionDuration, 0.01), 1.0);
    const CGFloat pageFadeFraction = MIN(RNSZoomClosePageFadeDuration / MAX(_transitionDuration, 0.01), 1.0);

    UIViewPropertyAnimator *flight = [[UIViewPropertyAnimator alloc] initWithDuration:_transitionDuration
                                                                                curve:UIViewAnimationCurveLinear
                                                                           animations:nil];
    // Presentation-side page fade: Fabric commits mid-close must not restore the page.
    RNSZoomAddOpacityRamp(animatedView, _transitionDuration, ^CGFloat(CGFloat t) {
      return MAX(1.0 - t / pageFadeFraction, 0.0);
    });
    [flight addAnimations:^{
      [UIView animateKeyframesWithDuration:0
                                     delay:0
                                   options:0
                                animations:^{
                                  [UIView addKeyframeWithRelativeStartTime:0
                                                          relativeDuration:revealFraction
                                                                animations:^{
                                                                  flyingCard.alpha = 1.0;
                                                                }];
                                  for (int i = 1; i <= RNSZoomKeyframeCount; i++) {
                                    const CGFloat t = (CGFloat)i / RNSZoomKeyframeCount;
                                    const CGFloat cp = RNSZoomCloseEasing(t);
                                    const CGFloat cpY = RNSZoomArcCurve(cp, RNSZoomArcLeadExp);
                                    const CGFloat cpX = RNSZoomArcCurve(cp, RNSZoomArcTrailExp);
                                    [UIView addKeyframeWithRelativeStartTime:(CGFloat)(i - 1) / RNSZoomKeyframeCount
                                                            relativeDuration:1.0 / RNSZoomKeyframeCount
                                                                  animations:^{
                                                                    const CGFloat s = MAX(
                                                                        RNSZoomLerp(embeddedScale, slotScale, cp),
                                                                        0.001);
                                                                    flyingCard.transform = CGAffineTransformScale(
                                                                        CGAffineTransformMakeTranslation(
                                                                            RNSZoomLerp(startTX, slotTX, cpX),
                                                                            RNSZoomLerp(startTY, slotTY, cpY)),
                                                                        s,
                                                                        s);
                                                                    dimmingView.alpha =
                                                                        RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(cp));
                                                                  }];
                                  }
                                }
                                completion:nil];
    }];
    [flight startAnimation];
    return;
  }

  // Fallback: fly the page home from the release pose (closeInteractiveStyle). The
  // drag mask layer keeps the release corners; only the transform animates.
  const RNSZoomGeometry g = _zoomGeometry;

  UIViewPropertyAnimator *flight = [[UIViewPropertyAnimator alloc] initWithDuration:_transitionDuration
                                                                              curve:UIViewAnimationCurveLinear
                                                                         animations:nil];
  [flight addAnimations:^{
    [UIView animateKeyframesWithDuration:0
                                   delay:0
                                 options:0
                              animations:^{
                                for (int i = 1; i <= RNSZoomKeyframeCount; i++) {
                                  const CGFloat t = (CGFloat)i / RNSZoomKeyframeCount;
                                  const CGFloat cp = RNSZoomCloseEasing(t);
                                  const CGFloat cpY = RNSZoomArcCurve(cp, RNSZoomArcLeadExp);
                                  const CGFloat cpX = RNSZoomArcCurve(cp, RNSZoomArcTrailExp);
                                  [UIView addKeyframeWithRelativeStartTime:(CGFloat)(i - 1) / RNSZoomKeyframeCount
                                                          relativeDuration:1.0 / RNSZoomKeyframeCount
                                                                animations:^{
                                                                  const CGFloat s = MAX(
                                                                      RNSZoomLerp(pageScale, g.shelfScale, cp), 0.001);
                                                                  animatedView.transform = CGAffineTransformScale(
                                                                      CGAffineTransformMakeTranslation(
                                                                          RNSZoomLerp(dragTX, g.shelfTX, cpX),
                                                                          RNSZoomLerp(dragTY, g.shelfTY, cpY)),
                                                                      s,
                                                                      s);
                                                                  dimmingView.alpha =
                                                                      RNSZoomDimMaxAlpha * (1 - RNSZoomClamp01(cp));
                                                                }];
                                }
                              }
                              completion:nil];
  }];
  [flight startAnimation];
  (void)weakSelf;
}

- (void)startZoomCancelSpring
{
  UIView *animatedView = _zoomAnimatedView;
  CALayer *maskLayer = _zoomMaskLayer;
  _zoomPendingCardView = nil;
  if (animatedView == nil) {
    return;
  }
  [UIView animateWithDuration:RNSZoomCancelSpringDuration
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
    radiusAnimation.duration = RNSZoomCancelSpringDuration;
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
