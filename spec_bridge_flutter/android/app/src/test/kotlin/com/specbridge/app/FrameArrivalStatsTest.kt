package com.specbridge.app

import org.junit.Assert.*
import org.junit.Test

class FrameArrivalStatsTest {
    @Test fun noFramesIsUnknownRatherThanSuccessfulZeroLatency() {
        var now = 0L
        val stats = FrameArrivalStats { now }
        assertNull(stats.snapshot()["sdkFrameWidth"])
        assertNull(stats.snapshot()["sdkFps"])
        assertNull(stats.snapshot()["sdkCurrentGapMs"])
        stats.stateChanged("streaming")
        now = 1500
        assertEquals(1500L, stats.snapshot()["sdkCurrentGapMs"])
        assertEquals(1L, stats.snapshot()["sdkStallCount"])
        assertEquals(0.0, stats.snapshot()["sdkFps"])
    }

    @Test fun rollingFpsDecaysToZeroWhenDeliveryStops() {
        var now = 0L
        val stats = FrameArrivalStats { now }
        stats.stateChanged("streaming")
        for (i in 1..50) {
            now = i * 100L
            stats.frame(360, 640)
        }
        assertEquals(10.0, stats.snapshot()["sdkFps"])
        now = 10000
        assertEquals(0.0, stats.snapshot()["sdkFps"])
        assertEquals(5000L, stats.snapshot()["sdkLongestGapMs"])
    }

    @Test fun pollingOneStallDoesNotCountItMoreThanOnce() {
        var now = 0L
        val stats = FrameArrivalStats { now }
        stats.stateChanged("streaming")
        stats.frame(360, 640)
        now = 2000
        repeat(5) { assertEquals(1L, stats.snapshot()["sdkStallCount"]) }
        stats.frame(360, 640)
        assertEquals(1L, stats.snapshot()["sdkStallCount"])
        now = 3000
        assertEquals(2L, stats.snapshot()["sdkStallCount"])
    }

    @Test fun intentionalPauseAndStoppedTimeAreExcludedFromGaps() {
        var now = 0L
        val stats = FrameArrivalStats { now }
        stats.stateChanged("streaming")
        stats.frame(360, 640)
        now = 100
        stats.stateChanged("paused")
        now = 60000
        assertNull(stats.snapshot()["sdkFps"])
        assertNull(stats.snapshot()["sdkCurrentGapMs"])
        assertEquals(100L, stats.snapshot()["sdkLongestGapMs"])
        stats.stateChanged("streaming")
        now += 50
        stats.frame(360, 640)
        assertEquals(0L, stats.snapshot()["sdkStallCount"])
        stats.stateChanged("stopped")
        now += 60000
        assertEquals(100L, stats.snapshot()["sdkLongestGapMs"])
    }

    @Test fun reportsActualResolutionChanges() {
        val stats = FrameArrivalStats { 0L }
        stats.frame(504, 896)
        stats.frame(504, 896)
        stats.frame(360, 640)
        assertEquals(360, stats.snapshot()["sdkFrameWidth"])
        assertEquals(640, stats.snapshot()["sdkFrameHeight"])
        assertEquals(1, stats.snapshot()["sdkResolutionChanges"])
    }
}
