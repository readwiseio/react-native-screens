#pragma once

#import "RNSScreen.h"

@interface RNSScreenStackAnimator : NSObject <UIViewControllerAnimatedTransitioning>

/// This property is filled whenever there is an ongoing animation and cleared on animation end.
@property (nonatomic, strong, nullable, readonly) UIViewPropertyAnimator *inFlightAnimator;

- (nonnull instancetype)initWithOperation:(UINavigationControllerOperation)operation;

/// In case of interactive / interruptible transition (e.g. swipe back gesture) this method should return
/// timing parameters expected by animator to be used for animation completion (e.g. when user's
/// gesture had ended).
///
/// @return timing curve provider expected to be used for animation completion or nil,
/// when there is no interactive transition running.
- (nullable id<UITimingCurveProvider>)timingParamsForAnimationCompletion;

+ (BOOL)isCustomAnimation:(RNSScreenStackAnimation)animation;

#pragma mark - Zoom interactive dismissal

/// YES while an interactive zoom pop is being driven manually by the drag.
@property (nonatomic, readonly) BOOL isZoomInteractive;

/// Duration factor (relative to the transition duration) the interaction controller
/// should use when continuing the progress-carrier animator after a CANCELLED drag,
/// so it completes together with the cancel spring driven here. (The finish factor is
/// computed inline in RNSPercentDrivenInteractiveTransition.)
- (CGFloat)zoomCancelDurationScale;

/// Applies the live drag pose (finger-follow + eased shrink + corner morph) to the
/// dismissing screen. progress is the normalized drag reach [0..1].
- (void)applyZoomDragPoseWithTranslation:(CGPoint)translation progress:(CGFloat)progress;

/// Runs the close flight from the current drag pose to the source rect (commit).
- (void)startZoomCommitFlightFromTranslation:(CGPoint)translation progress:(CGFloat)progress;

/// Springs the screen back to identity (cancelled drag).
- (void)startZoomCancelSpring;

@end
