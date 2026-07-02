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

  if (_animationController.isZoomInteractive) {
    // The zoom drag drives the screen pose manually; the carrier here only holds the
    // dimming + UIKit progress. Continue it linearly so it completes in one flight
    // duration (durationFactor scales the FULL timeline — (1 - fraction) yields a
    // constant real remaining time, matching the manual flight; anything larger makes
    // the dim crawl for duration/(1 - fraction)). Cancel matches the 360ms spring.
    UICubicTimingParameters *linearTiming =
        [[UICubicTimingParameters alloc] initWithAnimationCurve:UIViewAnimationCurveLinear];
    CGFloat durationFactor = 1 - animator.fractionComplete;
    if (cancelled) {
      durationFactor *= [_animationController zoomCancelDurationScale];
    }
    [animator pauseAnimation];
    [animator setReversed:shouldReverseAnimation];
    [animator continueAnimationWithTimingParameters:linearTiming durationFactor:durationFactor];
    _animationController = nil;
    return;
  }

  id<UITimingCurveProvider> timingParams = [_animationController timingParamsForAnimationCompletion];

  [animator pauseAnimation];
  [animator setReversed:shouldReverseAnimation];
  [animator continueAnimationWithTimingParameters:timingParams durationFactor:(1 - animator.fractionComplete)];

  // System retains it & we don't need it anymore.
  _animationController = nil;
}

@end
