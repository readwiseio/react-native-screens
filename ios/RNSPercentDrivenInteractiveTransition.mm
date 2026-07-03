#import "RNSPercentDrivenInteractiveTransition.h"

@implementation RNSPercentDrivenInteractiveTransition {
  RNSScreenStackAnimator *_animationController;
}

#pragma mark - UIViewControllerInteractiveTransitioning

- (void)startInteractiveTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
  [super startInteractiveTransition:transitionContext];
}

#pragma mark - UIPercentDrivenInteractiveTransition

// `updateInteractiveTransition`, `finishInteractiveTransition`,
// `cancelInteractiveTransition` are forwared by superclass to
// corresponding methods in transition context. In case
// of "classical CA driven animations", such as UIView animation blocks
// or direct utilization of CoreAnimation API, context drives the animation,
// however in case of UIViewPropertyAnimator it does not. We need
// to drive animation manually and this is exactly what happens below.

- (void)updateInteractiveTransition:(CGFloat)percentComplete
{
  if (_animationController != nil) {
    [_animationController.inFlightAnimator setFractionComplete:percentComplete];
  }
  [super updateInteractiveTransition:percentComplete];
}

- (void)finishInteractiveTransition
{
  [self finalizeInteractiveTransitionWithAnimationWasCancelled:NO];
  [super finishInteractiveTransition];
}

- (void)cancelInteractiveTransition
{
  [self finalizeInteractiveTransitionWithAnimationWasCancelled:YES];
  [super cancelInteractiveTransition];
}

#pragma mark - Helpers

- (void)finalizeInteractiveTransitionWithAnimationWasCancelled:(BOOL)cancelled
{
  if (_animationController == nil) {
    return;
  }

  UIViewPropertyAnimator *_Nullable animator = _animationController.inFlightAnimator;
  if (animator == nil) {
    return;
  }

  BOOL shouldReverseAnimation = cancelled;

  id<UITimingCurveProvider> timingParams = [_animationController timingParamsForAnimationCompletion];

  CGFloat durationFactor = 1 - animator.fractionComplete;
  if (cancelled && _animationController.isZoomInteractive) {
    // The zoom drag drives the screen pose manually; the carrier (an invisible dummy
    // view) only holds the UIKit progress, and timingParamsForAnimationCompletion
    // returns linear for it. VERIFIED with a timing probe (readwise fork PR #1,
    // review round 4 — deep-drag commit at fraction 0.888): despite how the
    // continueAnimation docs read, the
    // observed remaining run time here is durationFactor x originalDuration
    // / (1 - fractionComplete) — so the default (1 - fraction) factor above yields a
    // CONSTANT remaining time of one full duration, matching the commit flight
    // (factor 1.0 held the transition open for D / (1 - fraction) ~= 3.8s). Only the
    // cancel case is scaled, to match the cancel spring instead.
    durationFactor *= [_animationController zoomCancelDurationScale];
  }

  [animator pauseAnimation];
  [animator setReversed:shouldReverseAnimation];
  [animator continueAnimationWithTimingParameters:timingParams durationFactor:durationFactor];

  // System retains it & we don't need it anymore.
  _animationController = nil;
}

@end
