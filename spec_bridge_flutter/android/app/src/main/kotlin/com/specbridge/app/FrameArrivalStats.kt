package com.specbridge.app

import java.util.ArrayDeque

/** Counts SDK delivery, not radio packets or camera exposure time. Keeps no frame data. */
internal class FrameArrivalStats(private val nowMs: () -> Long) {
    private val arrivals = ArrayDeque<Long>()
    private var state = "starting"
    private var activeSince: Long? = null
    private var gapSince: Long? = null
    private var lastArrival: Long? = null
    private var lastWidth: Int? = null
    private var lastHeight: Int? = null
    private var resolutionChanges = 0
    private var longestGap = 0L
    private var stalls = 0L

    @Synchronized fun stateChanged(value: String) {
        if (state == value) return
        val now = nowMs()
        if (state == "streaming") finishGap(now)
        state = value
        arrivals.clear()
        activeSince = if (value == "streaming") now else null
        gapSince = activeSince
    }

    @Synchronized fun frame(width: Int, height: Int) {
        val now = nowMs()
        if (lastWidth != null && (lastWidth != width || lastHeight != height)) resolutionChanges++
        lastWidth = width
        lastHeight = height
        lastArrival = now
        if (state == "streaming") {
            finishGap(now)
            gapSince = now
            arrivals.addLast(now)
            trim(now)
        }
    }

    private fun trim(now: Long) {
        while (arrivals.isNotEmpty() && arrivals.first <= now - WINDOW_MS) arrivals.removeFirst()
    }

    private fun finishGap(now: Long) {
        gapSince?.let {
            val gap = (now - it).coerceAtLeast(0)
            longestGap = maxOf(longestGap, gap)
            if (gap >= STALL_MS) stalls++
        }
    }

    @Synchronized fun snapshot(): Map<String, Any?> {
        val now = nowMs()
        trim(now)
        val activeMs = activeSince?.let { (now - it).coerceAtLeast(0) }
        val gap = gapSince?.let { (now - it).coerceAtLeast(0) } ?: 0L
        val windowMs = activeMs?.coerceAtMost(WINDOW_MS)
        return mapOf(
            "captureStatus" to state,
            "sdkFrameWidth" to lastWidth,
            "sdkFrameHeight" to lastHeight,
            "sdkFps" to if (windowMs != null && windowMs >= 1000) arrivals.size * 1000.0 / windowMs else null,
            "sdkFpsWindowMs" to windowMs,
            "sdkFrameAgeMs" to lastArrival?.let { (now - it).coerceAtLeast(0) },
            "sdkCurrentGapMs" to if (activeSince != null) gap else null,
            "sdkLongestGapMs" to maxOf(longestGap, gap),
            "sdkStallCount" to stalls + if (gap >= STALL_MS) 1 else 0,
            "sdkStallThresholdMs" to STALL_MS,
            "sdkResolutionChanges" to resolutionChanges
        )
    }

    companion object {
        const val WINDOW_MS = 5000L
        const val STALL_MS = 1000L
    }
}
