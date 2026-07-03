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

/// Restores a zoom source card the completed push left session-hidden (alpha 0).
/// Called by RNSScreenView when a zoom-marked screen leaves the window by any route
/// that bypasses the zoom pop's own handoff (non-animated pop, replace, multi-level
/// pop, changed stackAnimation). Safe no-op when the card isn't found or is visible.
+ (void)restoreZoomSourceCardWithNativeID:(nonnull NSString *)nativeID inView:(nonnull UIView *)root;

#pragma mark - Zoom interactive dismissal

/// YES for the lifetime of an interactive zoom pop — from drag begin until the
/// progress carrier completes (the commit/cancel completion flight reads it after
/// the finger lifts).
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
