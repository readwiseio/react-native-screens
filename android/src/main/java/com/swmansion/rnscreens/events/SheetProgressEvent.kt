package com.swmansion.rnscreens.events

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.events.Event

// Sheet openness in [0,1] (1 = settled open, 0 = dismissed). Streamed like transition progress:
// coalescing key keeps the 0/1 endpoints and collapses intermediate frames (see ScreenFragment.getCoalescingKey).
class SheetProgressEvent(
    surfaceId: Int,
    viewId: Int,
    private val progress: Float,
    private val coalescingKey: Short,
) : Event<SheetProgressEvent>(surfaceId, viewId) {
    override fun getEventName(): String = EVENT_NAME

    override fun getCoalescingKey(): Short = coalescingKey

    override fun getEventData(): WritableMap? =
        Arguments.createMap().apply {
            putDouble("progress", progress.toDouble())
        }

    companion object {
        const val EVENT_NAME = "topSheetProgress"
    }
}
