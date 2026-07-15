package com.swmansion.rnscreens

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.util.Log
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import com.swmansion.rnscreens.utils.RNSLog
import kotlin.math.abs

/**
 * Readwise: native interactive edge-swipe-back for Android, mirroring the iOS
 * interactive pop (RNSScreenStack.mm).
 *
 * Detection: DOWN within the edge band (50dp — master's reader gesture
 * hitSlop) on a screen whose [Screen.isGestureEnabled] is set (native-stack
 * maps androidEdgeSwipeBack/gestureEnabled/beforeRemove into it), activation
 * after a platform-touch-slop pull (~8dp) of horizontal-dominant travel.
 * Tracking: top screen translationX 1:1; screen below parallaxes from
 * -0.3*width to 0 (RNSScreenStackAnimator.mm:542).
 * Commit: translation + 0.3*velocity > width/2 (RNSScreenStack.mm:1139-1140),
 * then notifyTopDetached() -> ScreenDismissedEvent -> JS StackActions.pop().
 * Cancel: settle back, detachBelowTop(), transforms reset.
 */
internal class EdgeSwipeBackController(
    private val stack: ScreenStack,
) {
    private enum class State { IDLE, ARMED, DRAGGING, SETTLING }

    private var state = State.IDLE
    private var downX = 0f
    private var downY = 0f
    private var velocityTracker: VelocityTracker? = null
    private var topScreenView: Screen? = null
    private var belowScreenView: Screen? = null
    private var settleAnimator: ValueAnimator? = null

    private val density = stack.resources.displayMetrics.density
    private val edgeRegionPx = EDGE_REGION_DP * density

    // Activation distance: the platform drag threshold (~8dp), matching how
    // eagerly UIKit's pan hysteresis (~10pt) engages on iOS. The
    // horizontal-dominance check below keeps scroll intents safe.
    private val touchSlopPx = ViewConfiguration.get(stack.context).scaledTouchSlop.toFloat()
    private val activationPx = touchSlopPx

    val isInteracting: Boolean
        get() = state == State.DRAGGING || state == State.SETTLING

    fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (state == State.SETTLING) {
                    // Eat taps while the settle animation finishes.
                    return true
                }
                state = State.IDLE
                val top = stack.topScreen
                // isGestureEnabled is the arming signal: native-stack maps
                // androidEdgeSwipeBack + gestureEnabled + beforeRemove into it.
                val enabled = top?.isGestureEnabled == true
                val pairOk = stack.resolveEdgeSwipeScreenPair() != null
                val pushOk = top?.stackPresentation == Screen.StackPresentation.PUSH
                if (enabled && pairOk && pushOk && ev.x <= edgeRegionPx) {
                    state = State.ARMED
                    downX = ev.x
                    downY = ev.y
                    velocityTracker?.recycle()
                    velocityTracker = VelocityTracker.obtain()
                    velocityTracker?.addMovement(ev)
                    RNSLog.d(TAG, "armed at x=${ev.x} (edge=${edgeRegionPx}px)")
                } else if (ev.x <= edgeRegionPx) {
                    RNSLog.d(
                        TAG,
                        "down in band but not armed: enabled=$enabled pair=$pairOk push=$pushOk",
                    )
                }
            }
            MotionEvent.ACTION_MOVE -> {
                velocityTracker?.addMovement(ev)
                if (state == State.ARMED) {
                    val dx = ev.x - downX
                    val dy = ev.y - downY
                    if (dx >= activationPx && dx > abs(dy)) {
                        // Deliberate horizontal pull from the edge — steal the
                        // stream (children get ACTION_CANCEL, like UIKit).
                        startDrag()
                    } else if (abs(dy) > touchSlopPx && abs(dy) > dx) {
                        // Vertical intent — the content scroll wins.
                        RNSLog.d(TAG, "vertical bail dx=$dx dy=$dy")
                        state = State.IDLE
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                if (state == State.ARMED) {
                    // UP = lifted without an activating pull; CANCEL = an ancestor
                    // or the system claimed the stream before we activated.
                    RNSLog.d(
                        TAG,
                        "armed released without activation (${if (ev.actionMasked == MotionEvent.ACTION_CANCEL) "cancelled" else "lifted"})",
                    )
                    state = State.IDLE
                }
        }
        return state == State.DRAGGING
    }

    fun onTouchEvent(ev: MotionEvent): Boolean {
        if (state != State.DRAGGING) {
            return state == State.SETTLING
        }
        velocityTracker?.addMovement(ev)
        when (ev.actionMasked) {
            MotionEvent.ACTION_MOVE -> track(ev.x - downX)
            MotionEvent.ACTION_UP -> {
                velocityTracker?.computeCurrentVelocity(1000)
                val vx = velocityTracker?.xVelocity ?: 0f
                val dx = (ev.x - downX).coerceIn(0f, stack.width.toFloat())
                // iOS commit rule — RNSScreenStack.mm:1139-1140.
                val commit = dx + 0.3f * vx > stack.width / 2f
                RNSLog.d(TAG, "release dx=$dx vx=$vx commit=$commit")
                settle(dx, commit)
            }
            MotionEvent.ACTION_CANCEL -> {
                RNSLog.d(TAG, "cancelled by ancestor/system mid-drag")
                settle((ev.x - downX).coerceIn(0f, stack.width.toFloat()), false)
            }
        }
        return true
    }

    private fun startDrag() {
        // Resolving the pair also revalidates the positional invariant
        // attachBelowTop() relies on (it may have changed since ARMED).
        val (top, below) = stack.resolveEdgeSwipeScreenPair() ?: run {
            RNSLog.d(TAG, "active pair unresolvable at activation; aborting drag")
            state = State.IDLE
            return
        }
        try {
            stack.attachBelowTop()
        } catch (e: RuntimeException) {
            Log.w(TAG, "attachBelowTop failed; aborting drag", e)
            state = State.IDLE
            return
        }
        // The Screen views persist across attachBelowTop's fragment re-add
        // (view recycling), so the pair resolved above stays valid.
        topScreenView = top
        belowScreenView = below
        state = State.DRAGGING
        // Keep ancestors (incl. the RNGH root) from intercepting mid-drag.
        stack.parent?.requestDisallowInterceptTouchEvent(true)
        track(0f)
        RNSLog.d(TAG, "drag started top=${topScreenView?.id} below=${belowScreenView?.id}")
    }

    private fun track(rawDx: Float) {
        val width = stack.width.toFloat()
        val dx = rawDx.coerceIn(0f, width)
        topScreenView?.translationX = dx
        // Below screen parallax — RNSScreenStackAnimator.mm:542.
        belowScreenView?.translationX = -PARALLAX_FACTOR * (width - dx)
    }

    private fun settle(
        fromDx: Float,
        commit: Boolean,
    ) {
        state = State.SETTLING
        val width = stack.width.toFloat()
        val target = if (commit) width else 0f
        // Base 0.5s (RNSDefaultTransitionDuration), proportional to remaining distance.
        val remaining = abs(target - fromDx) / width
        val duration = (BASE_DURATION_MS * remaining).toLong().coerceIn(80L, BASE_DURATION_MS.toLong())
        settleAnimator?.cancel()
        settleAnimator =
            ValueAnimator.ofFloat(fromDx, target).apply {
                this.duration = duration
                // Approximates iOS's overdamped nav spring (ratio ~4.56).
                interpolator = DecelerateInterpolator(1.5f)
                addUpdateListener { track(it.animatedValue as Float) }
                addListener(
                    object : AnimatorListenerAdapter() {
                        // cancel() still delivers onAnimationEnd; the abort path
                        // (onStackChildrenChanged) does its own cleanup and must
                        // not double-dispatch finish(): a committed finish would
                        // fire a second ScreenDismissedEvent against a stack
                        // React is already mutating.
                        private var cancelled = false

                        override fun onAnimationCancel(animation: Animator) {
                            cancelled = true
                        }

                        override fun onAnimationEnd(animation: Animator) {
                            if (!cancelled) {
                                finish(commit)
                            }
                        }
                    },
                )
                start()
            }
    }

    private fun finish(commit: Boolean) {
        RNSLog.d(TAG, "finish commit=$commit")
        velocityTracker?.recycle()
        velocityTracker = null
        settleAnimator = null
        if (commit) {
            // ScreenDismissedEvent -> native-stack onDismissed -> StackActions.pop().
            // The JS pop removes the top fragment; reset the below screen so it
            // sits at identity when it becomes top.
            stack.notifyTopDetached()
            belowScreenView?.translationX = 0f
        } else {
            try {
                stack.detachBelowTop()
            } catch (e: RuntimeException) {
                Log.w(TAG, "detachBelowTop failed on cancel", e)
            }
            topScreenView?.translationX = 0f
            belowScreenView?.translationX = 0f
        }
        topScreenView = null
        belowScreenView = null
        state = State.IDLE
    }

    /**
     * Button-initiated variant of a committed swipe (hardware/system back):
     * the same live-view slide-out from dx=0, then the same
     * notifyTopDetached -> onDismissed -> JS pop handshake — so React unmounts
     * the screen only after it is fully off-screen. Returns false when this
     * stack can't handle the dismissal (caller falls through to the default
     * back handling); returns true when a dismissal started, or when one is
     * already in flight so repeated presses are swallowed mid-animation.
     */
    fun dismissTopWithAnimation(): Boolean {
        if (state == State.DRAGGING || state == State.SETTLING) {
            return true
        }
        val top = stack.topScreen
        val enabled = top?.isGestureEnabled == true
        val pushOk = top?.stackPresentation == Screen.StackPresentation.PUSH
        val pair = stack.resolveEdgeSwipeScreenPair()
        if (!enabled || pair == null || !pushOk || stack.width <= 0) {
            return false
        }
        try {
            stack.attachBelowTop()
        } catch (e: RuntimeException) {
            Log.w(TAG, "attachBelowTop failed; deferring to default back handling", e)
            return false
        }
        topScreenView = pair.first
        belowScreenView = pair.second
        track(0f)
        RNSLog.d(TAG, "programmatic dismiss (back button)")
        settle(0f, commit = true)
        return true
    }

    /**
     * The stack's children changed under an active gesture (e.g. hardware back
     * popped mid-drag). Abort and restore consistent transforms.
     */
    fun onStackChildrenChanged() {
        if (state == State.DRAGGING || state == State.SETTLING) {
            RNSLog.d(TAG, "stack changed mid-gesture; aborting")
            settleAnimator?.cancel()
            settleAnimator = null
            topScreenView?.translationX = 0f
            belowScreenView?.translationX = 0f
            topScreenView = null
            belowScreenView = null
            velocityTracker?.recycle()
            velocityTracker = null
            state = State.IDLE
        }
    }

    companion object {
        private const val TAG = "[EdgeSwipeBack]"

        // Master's reader gesture band: useNavigationGestures hitSlop
        // {left: 0, width: 50}. The Android system back gesture owns the
        // outermost ~30dp of this on gesture-nav devices (by design — we
        // don't fight it; a bezel swipe does a plain system back, which
        // also pops); the strip beyond it is the interactive drag.
        private const val EDGE_REGION_DP = 50f

        // RNSScreenStackAnimator.mm:542.
        private const val PARALLAX_FACTOR = 0.3f

        // RNSDefaultTransitionDuration — RNSScreenStackAnimator.mm:11.
        private const val BASE_DURATION_MS = 500f
    }
}
