package com.specbridge.app

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
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
import java.io.ByteArrayOutputStream

/**
 * Manages video streaming session from Meta glasses on Android
 * Based on the official CameraAccess sample app
 */
class StreamSessionManager(
    private val context: Context,
    private val wearablesManager: MetaWearablesManager
) {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var streamSession: StreamSession? = null
    private var videoJob: Job? = null
    private var stateJob: Job? = null

    private val _frameFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 1)
    val frameFlow: SharedFlow<ByteArray> = _frameFlow.asSharedFlow()

    private val _statusFlow = MutableStateFlow("stopped")
    val statusFlow: StateFlow<String> = _statusFlow.asStateFlow()

    var frameCount: Long = 0
        private set

    // MARK: - Streaming Control

    fun startStreaming(width: Int, height: Int, frameRate: Int): Boolean {
        android.util.Log.d("StreamSessionManager", "startStreaming called: ${width}x${height} @ ${frameRate}fps")

        if (streamSession != null) {
            android.util.Log.w("StreamSessionManager", "Already streaming, returning false")
            return false // Already streaming
        }

        // Launch the streaming setup in a coroutine to allow waiting for device
        scope.launch {
            startStreamingAsync(width, height, frameRate)
        }

        return true // Return true immediately, actual status will be reported via statusFlow
    }

    private suspend fun startStreamingAsync(width: Int, height: Int, frameRate: Int) {
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

            // Use MEDIUM quality and 24fps like the official sample for reliability
            // The official CameraAccess sample uses: VideoQuality.MEDIUM, 24
            val quality = VideoQuality.MEDIUM
            val fps = 24
            android.util.Log.d("StreamSessionManager", "Using video quality: $quality @ ${fps}fps (matching official sample)")

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

    // Reusable buffer to avoid allocations
    private var frameBuffer: ByteArray? = null
    private var outputStream = ByteArrayOutputStream(50000)

    private fun processFrame(videoFrame: VideoFrame) {
        frameCount++

        if (frameCount == 1L) {
            android.util.Log.d("StreamSessionManager", "First frame received from glasses: ${videoFrame.width}x${videoFrame.height}")
        }
        if (frameCount % 100 == 0L) {
            android.util.Log.d("StreamSessionManager", "Processed $frameCount frames from glasses")
        }

        try {
            // VideoFrame contains raw I420 video data in a ByteBuffer
            val buffer = videoFrame.buffer
            val dataSize = buffer.remaining()

            // Reuse buffer if possible
            if (frameBuffer == null || frameBuffer!!.size < dataSize) {
                frameBuffer = ByteArray(dataSize)
            }

            // Save current position
            val originalPosition = buffer.position()
            buffer.get(frameBuffer!!, 0, dataSize)
            // Restore position
            buffer.position(originalPosition)

            // Convert I420 to NV21 format which is supported by Android's YuvImage
            val nv21 = convertI420toNV21(frameBuffer!!, videoFrame.width, videoFrame.height)
            val yuvImage = YuvImage(nv21, ImageFormat.NV21, videoFrame.width, videoFrame.height, null)

            // Single pass: compress directly to JPEG (matching official sample approach)
            // Using 50% quality like official sample for speed
            outputStream.reset()
            yuvImage.compressToJpeg(Rect(0, 0, videoFrame.width, videoFrame.height), 50, outputStream)

            _frameFlow.tryEmit(outputStream.toByteArray())
        } catch (e: Exception) {
            if (frameCount < 10) {
                android.util.Log.e("StreamSessionManager", "Frame processing error: ${e.message}")
            }
        }
    }

    // Convert I420 (YYYYYYYY:UUVV) to NV21 (YYYYYYYY:VUVU)
    private fun convertI420toNV21(input: ByteArray, width: Int, height: Int): ByteArray {
        val output = ByteArray(input.size)
        val size = width * height
        val quarter = size / 4

        // Y plane is the same
        input.copyInto(output, 0, 0, size)

        // Interleave U and V planes (V first for NV21)
        for (n in 0 until quarter) {
            output[size + n * 2] = input[size + quarter + n] // V first
            output[size + n * 2 + 1] = input[size + n] // U second
        }
        return output
    }

    // MARK: - Cleanup

    fun dispose() {
        stopStreaming()
        scope.cancel()
    }
}
