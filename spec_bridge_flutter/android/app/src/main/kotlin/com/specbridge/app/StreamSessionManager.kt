package com.specbridge.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import com.meta.wearable.Wearables
import com.meta.wearable.StreamSession
import com.meta.wearable.VideoQuality
import com.meta.wearable.StreamSessionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
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
 */
class StreamSessionManager(
    private val wearablesManager: MetaWearablesManager
) {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var streamSession: StreamSession? = null

    private val _frameFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 1)
    val frameFlow: SharedFlow<ByteArray> = _frameFlow.asSharedFlow()

    private val _statusFlow = MutableStateFlow("stopped")
    val statusFlow: StateFlow<String> = _statusFlow.asStateFlow()

    var frameCount: Long = 0
        private set

    private val jpegQuality = 70

    // MARK: - Streaming Control

    suspend fun startStreaming(width: Int, height: Int, frameRate: Int): Boolean {
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

            // Create stream session
            streamSession = Wearables.startStreamSession(
                quality = quality,
                frameRate = frameRate
            )

            // Observe session state
            scope.launch {
                streamSession?.state?.collect { state ->
                    _statusFlow.value = when (state) {
                        StreamSessionState.STARTING -> "starting"
                        StreamSessionState.STARTED -> "starting"
                        StreamSessionState.STREAMING -> "streaming"
                        StreamSessionState.STOPPING -> "stopping"
                        StreamSessionState.STOPPED -> "stopped"
                        StreamSessionState.CLOSED -> "stopped"
                        else -> "unknown"
                    }
                }
            }

            // Collect video frames
            scope.launch {
                streamSession?.videoStream?.collect { frame ->
                    processFrame(frame)
                }
            }

            _statusFlow.value = "streaming"
            true
        } catch (e: Exception) {
            _statusFlow.value = "error"
            false
        }
    }

    fun stopStreaming() {
        streamSession?.close()
        streamSession = null
        _statusFlow.value = "stopped"
    }

    // MARK: - Frame Processing

    private fun processFrame(frame: Any) {
        frameCount++

        try {
            // Convert frame to JPEG
            val jpegData = convertToJpeg(frame)
            if (jpegData != null) {
                _frameFlow.tryEmit(jpegData)
            }
        } catch (e: Exception) {
            // Ignore frame processing errors
        }
    }

    private fun convertToJpeg(frame: Any): ByteArray? {
        // The frame type depends on the SDK implementation
        // This is a placeholder that handles common frame types

        return when (frame) {
            is ByteArray -> {
                // Assume it's already JPEG or raw bytes
                if (isJpeg(frame)) {
                    frame
                } else {
                    // Try to decode and re-encode as JPEG
                    try {
                        val bitmap = BitmapFactory.decodeByteArray(frame, 0, frame.size)
                        bitmapToJpeg(bitmap)
                    } catch (e: Exception) {
                        null
                    }
                }
            }
            is Bitmap -> {
                bitmapToJpeg(frame)
            }
            else -> {
                // Unknown frame type
                null
            }
        }
    }

    private fun isJpeg(data: ByteArray): Boolean {
        return data.size >= 2 &&
                data[0] == 0xFF.toByte() &&
                data[1] == 0xD8.toByte()
    }

    private fun bitmapToJpeg(bitmap: Bitmap): ByteArray {
        val outputStream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, outputStream)
        return outputStream.toByteArray()
    }

    // MARK: - Cleanup

    fun dispose() {
        stopStreaming()
        scope.cancel()
    }
}
