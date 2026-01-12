package com.specbridge.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
import kotlinx.coroutines.launch
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

    private val jpegQuality = 70

    // MARK: - Streaming Control

    fun startStreaming(width: Int, height: Int, frameRate: Int): Boolean {
        if (streamSession != null) {
            return false // Already streaming
        }

        return try {
            _statusFlow.value = "starting"
            frameCount = 0

            // Determine video quality based on resolution
            val quality = when {
                width >= 1280 -> VideoQuality.HIGH      // 720×1280
                width >= 504 -> VideoQuality.MEDIUM     // 504×896
                else -> VideoQuality.LOW                // 360×640
            }

            // Create stream session using the extension function
            val session = Wearables.startStreamSession(
                context,
                wearablesManager.deviceSelector,
                StreamConfiguration(videoQuality = quality, frameRate)
            )
            streamSession = session

            // Observe session state
            stateJob = scope.launch {
                session.state.collect { state ->
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
            videoJob = scope.launch {
                session.videoStream.collect { frame ->
                    processFrame(frame)
                }
            }

            true
        } catch (e: Exception) {
            _statusFlow.value = "error"
            false
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

    private fun processFrame(videoFrame: VideoFrame) {
        frameCount++

        try {
            // VideoFrame contains raw I420 video data in a ByteBuffer
            val buffer = videoFrame.buffer
            val dataSize = buffer.remaining()
            val byteArray = ByteArray(dataSize)

            // Save current position
            val originalPosition = buffer.position()
            buffer.get(byteArray)
            // Restore position
            buffer.position(originalPosition)

            // Convert I420 to NV21 format which is supported by Android's YuvImage
            val nv21 = convertI420toNV21(byteArray, videoFrame.width, videoFrame.height)
            val image = YuvImage(nv21, ImageFormat.NV21, videoFrame.width, videoFrame.height, null)

            ByteArrayOutputStream().use { stream ->
                image.compressToJpeg(Rect(0, 0, videoFrame.width, videoFrame.height), jpegQuality, stream)
                val jpegData = stream.toByteArray()
                _frameFlow.tryEmit(jpegData)
            }
        } catch (e: Exception) {
            // Ignore frame processing errors
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
