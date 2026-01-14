package com.specbridge.app

import android.content.Context
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.camera.StreamSession
import com.meta.wearable.dat.camera.startStreamSession
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamSessionState
import com.meta.wearable.dat.camera.types.VideoFrame
import com.meta.wearable.dat.camera.types.VideoQuality
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Manages video streaming session from Meta glasses on Android
 * Based on the official CameraAccess sample app
 *
 * Frame format: Raw I420 with 8-byte header
 * - Bytes 0-3: width (uint32 little-endian)
 * - Bytes 4-7: height (uint32 little-endian)
 * - Bytes 8+: I420 data (Y plane, then U plane, then V plane)
 */
class StreamSessionManager(
    private val context: Context,
    private val wearablesManager: MetaWearablesManager
) {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var streamSession: StreamSession? = null
    private var videoJob: Job? = null
    private var stateJob: Job? = null

    // Buffer capacity of 3 to allow some slack in the pipeline (glasses send 24fps)
    // Direct callback for frames - bypasses SharedFlow for lower latency
    var onFrameReady: ((ByteArray) -> Unit)? = null

    // SharedFlow kept for backwards compatibility but not used when onFrameReady is set
    private val _frameFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 3)
    val frameFlow: SharedFlow<ByteArray> = _frameFlow.asSharedFlow()

    private val _statusFlow = MutableStateFlow("stopped")
    val statusFlow: StateFlow<String> = _statusFlow.asStateFlow()

    var frameCount: Long = 0
        private set

    var framesProcessed: Long = 0
        private set

    // Encoding time tracking
    private var totalEncodeTimeMs: Long = 0
    private var lastEncodeTimeMs: Long = 0

    /**
     * Called by MetaWearablesPlugin - native server is managed there, not here
     */
    fun setNativeServerEnabled(enabled: Boolean) {
        // No-op - native server is managed by MetaWearablesPlugin
    }

    /**
     * Get current streaming stats for debugging/monitoring
     */
    fun getStats(): Map<String, Any> {
        val avgEncodeTime = if (framesProcessed > 0) totalEncodeTimeMs / framesProcessed else 0
        return mapOf(
            "framesReceived" to frameCount,
            "framesProcessed" to framesProcessed,
            "framesSkipped" to framesSkipped,
            "skipRate" to if (frameCount > 0) (framesSkipped * 100 / frameCount).toInt() else 0,
            "lastEncodeTimeMs" to lastEncodeTimeMs,
            "avgEncodeTimeMs" to avgEncodeTime
        )
    }

    // MARK: - Streaming Control

    fun startStreaming(width: Int, height: Int, frameRate: Int, videoQualityStr: String = "medium"): Boolean {
        android.util.Log.d("StreamSessionManager", "startStreaming called: ${width}x${height} @ ${frameRate}fps, quality=$videoQualityStr")

        if (streamSession != null) {
            android.util.Log.w("StreamSessionManager", "Already streaming, returning false")
            return false // Already streaming
        }

        // Launch the streaming setup in a coroutine to allow waiting for device
        scope.launch {
            startStreamingAsync(width, height, frameRate, videoQualityStr)
        }

        return true // Return true immediately, actual status will be reported via statusFlow
    }

    private suspend fun startStreamingAsync(width: Int, height: Int, frameRate: Int, videoQualityStr: String) {
        try {
            _statusFlow.value = "starting"
            frameCount = 0

            // Wait for device to be active before starting stream (matching official sample)
            android.util.Log.d("StreamSessionManager", "Waiting for active device...")
            val activeDevice = withTimeoutOrNull(10000L) {
                wearablesManager.deviceSelector.activeDevice(Wearables.devices).first { it != null }
            }

            if (activeDevice == null) {
                android.util.Log.e("StreamSessionManager", "No active device found within timeout")
                _statusFlow.value = "error"
                return
            }
            android.util.Log.d("StreamSessionManager", "Active device found: $activeDevice")

            // Map quality string to Meta SDK VideoQuality enum
            val quality = when (videoQualityStr.lowercase()) {
                "low" -> VideoQuality.LOW
                "high" -> VideoQuality.HIGH
                else -> VideoQuality.MEDIUM
            }
            val fps = 24
            android.util.Log.d("StreamSessionManager", "Using video quality: $quality @ ${fps}fps")

            // Create stream session exactly like the official sample
            android.util.Log.d("StreamSessionManager", "Creating stream session...")
            val session = Wearables.startStreamSession(
                context,
                wearablesManager.deviceSelector,
                StreamConfiguration(videoQuality = quality, fps)
            )
            streamSession = session
            android.util.Log.d("StreamSessionManager", "Stream session created successfully")

            // Observe session state
            stateJob = scope.launch {
                session.state.collect { state ->
                    android.util.Log.d("StreamSessionManager", "Stream state changed: $state")
                    _statusFlow.value = when (state) {
                        StreamSessionState.STARTING -> "starting"
                        StreamSessionState.STREAMING -> "streaming"
                        StreamSessionState.STOPPING -> "stopping"
                        StreamSessionState.STOPPED -> "stopped"
                        else -> "unknown"
                    }
                }
            }

            // Collect video frames
            android.util.Log.d("StreamSessionManager", "Starting to collect video frames...")
            videoJob = scope.launch {
                session.videoStream.collect { frame ->
                    processFrame(frame)
                }
            }

            android.util.Log.d("StreamSessionManager", "Stream setup complete, waiting for frames...")
        } catch (e: Exception) {
            android.util.Log.e("StreamSessionManager", "startStreamingAsync failed", e)
            _statusFlow.value = "error"
        }
    }

    fun stopStreaming() {
        videoJob?.cancel()
        videoJob = null
        stateJob?.cancel()
        stateJob = null
        streamSession?.close()
        streamSession = null
        _statusFlow.value = "stopped"
    }

    // MARK: - Frame Processing

    // Reusable buffers to avoid allocations - double buffer for thread safety
    private var frameBuffer: ByteArray? = null
    private var outputBuffer1: ByteArray? = null
    private var outputBuffer2: ByteArray? = null
    private var useBuffer1 = true

    // Frame rate limiting - process all frames, let JS drop if needed
    private var framesSkipped = 0L

    private fun processFrame(videoFrame: VideoFrame) {
        frameCount++
        val processStartTime = System.currentTimeMillis()

        // Log first frame and every 100 frames
        if (frameCount == 1L) {
            android.util.Log.d("StreamSessionManager", "First frame received from glasses: ${videoFrame.width}x${videoFrame.height} (sending raw I420)")
        }
        if (frameCount % 100 == 0L) {
            android.util.Log.d("StreamSessionManager", "Frames: $frameCount received, $framesProcessed sent (raw I420)")
        }

        try {
            // VideoFrame contains raw I420 video data in a ByteBuffer
            val buffer = videoFrame.buffer
            val dataSize = buffer.remaining()
            val width = videoFrame.width
            val height = videoFrame.height

            // Calculate expected I420 size: Y (w*h) + U (w*h/4) + V (w*h/4) = w*h*1.5
            val expectedSize = width * height * 3 / 2
            if (dataSize < expectedSize) {
                android.util.Log.w("StreamSessionManager", "Frame data size mismatch: got $dataSize, expected $expectedSize")
                return
            }

            // Reuse frame buffer if possible
            if (frameBuffer == null || frameBuffer!!.size < dataSize) {
                frameBuffer = ByteArray(dataSize)
            }

            // Save current position and read data
            val originalPosition = buffer.position()
            buffer.get(frameBuffer!!, 0, dataSize)
            buffer.position(originalPosition)

            // Create output buffer: 12-byte header + I420 data
            // Header: width (4), height (4), timestamp (4)
            // Use double buffering to avoid allocation every frame
            val outputSize = 12 + expectedSize
            val outputBuffer = if (useBuffer1) {
                if (outputBuffer1 == null || outputBuffer1!!.size < outputSize) {
                    outputBuffer1 = ByteArray(outputSize)
                }
                outputBuffer1!!
            } else {
                if (outputBuffer2 == null || outputBuffer2!!.size < outputSize) {
                    outputBuffer2 = ByteArray(outputSize)
                }
                outputBuffer2!!
            }
            useBuffer1 = !useBuffer1  // Swap for next frame

            // Write header (width, height, timestamp as little-endian uint32)
            val headerBuffer = ByteBuffer.wrap(outputBuffer, 0, 12).order(ByteOrder.LITTLE_ENDIAN)
            headerBuffer.putInt(width)
            headerBuffer.putInt(height)
            headerBuffer.putInt((System.currentTimeMillis() and 0xFFFFFFFF).toInt())  // Low 32 bits of timestamp

            // Copy I420 data after header
            frameBuffer!!.copyInto(outputBuffer, 12, 0, expectedSize)

            // Send the buffer directly - no copyOf()!
            val frameData = outputBuffer

            // Use direct callback if available (bypasses SharedFlow)
            val callback = onFrameReady
            if (callback != null) {
                callback(frameData)
                framesProcessed++
            } else {
                // Fall back to SharedFlow
                val emitted = _frameFlow.tryEmit(frameData)
                if (emitted) {
                    framesProcessed++
                } else {
                    framesSkipped++
                    if (framesSkipped == 1L || framesSkipped % 50 == 0L) {
                        android.util.Log.w("StreamSessionManager", "SharedFlow buffer full! Dropped $framesSkipped frames total (tryEmit=false)")
                    }
                }
            }

            // Track processing time
            lastEncodeTimeMs = System.currentTimeMillis() - processStartTime
            totalEncodeTimeMs += lastEncodeTimeMs
        } catch (e: Exception) {
            if (frameCount < 10) {
                android.util.Log.e("StreamSessionManager", "Frame processing error: ${e.message}")
            }
        }
    }

    // MARK: - Cleanup

    fun dispose() {
        stopStreaming()
        scope.cancel()
    }
}
