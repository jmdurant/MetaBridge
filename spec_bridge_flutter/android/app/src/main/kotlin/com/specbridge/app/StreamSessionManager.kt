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
import kotlinx.coroutines.delay
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
import java.util.Arrays

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

    // Frame arrival timing (to detect SDK throttling)
    private var lastFrameArrivalTime: Long = 0
    private var frameIntervalSum: Long = 0
    private var frameIntervalCount: Long = 0

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
        val avgFrameInterval = if (frameIntervalCount > 0) frameIntervalSum / frameIntervalCount else 0
        return mapOf(
            "framesReceived" to frameCount,
            "framesProcessed" to framesProcessed,
            "framesSkipped" to framesSkipped,
            "skipRate" to if (frameCount > 0) (framesSkipped * 100 / frameCount).toInt() else 0,
            "lastEncodeTimeMs" to lastEncodeTimeMs,
            "avgEncodeTimeMs" to avgEncodeTime,
            "avgFrameIntervalMs" to avgFrameInterval  // Time between frame arrivals from SDK
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
            // Use the requested frameRate, coerced to valid SDK values: 30, 24, 15, 7, 2
            val validFpsValues = listOf(30, 24, 15, 7, 2)
            val fps = validFpsValues.minByOrNull { kotlin.math.abs(it - frameRate) } ?: 15
            android.util.Log.d("StreamSessionManager", "Using video quality: $quality @ ${fps}fps (requested: ${frameRate}fps)")

            // Create stream session exactly like the official sample
            android.util.Log.d("StreamSessionManager", "Creating stream session...")
            val session = Wearables.startStreamSession(
                context,
                wearablesManager.deviceSelector,
                StreamConfiguration(videoQuality = quality, fps)
            )
            streamSession = session
            android.util.Log.d("StreamSessionManager", "Stream session created successfully")

            // ABR hacks disabled for testing - were causing overhead
            // TODO: Re-enable once we find the right reflection path
            // disablePhoneSideAbr(session)
            // scope.launch {
            //     delay(500)
            //     tryDisableGlassesSideAbr(session)
            // }

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

    // Note: framesSkipped is always 0 - kept for API compatibility
    // Direct callback path is always used (SharedFlow fallback removed)
    private var framesSkipped = 0L

    private fun processFrame(videoFrame: VideoFrame) {
        frameCount++
        val processStartTime = System.currentTimeMillis()

        // Track frame arrival interval
        if (lastFrameArrivalTime > 0) {
            val interval = processStartTime - lastFrameArrivalTime
            frameIntervalSum += interval
            frameIntervalCount++
        }
        lastFrameArrivalTime = processStartTime

        // Log first frame and every 100 frames
        if (frameCount == 1L) {
            android.util.Log.d("StreamSessionManager", "First frame received from glasses: ${videoFrame.width}x${videoFrame.height} (sending raw I420)")
        }
        if (frameCount % 100 == 0L) {
            val avgInterval = if (frameIntervalCount > 0) frameIntervalSum / frameIntervalCount else 0
            android.util.Log.d("StreamSessionManager", "Frames: $frameCount received, $framesProcessed sent, avgInterval=${avgInterval}ms (raw I420)")
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
            headerBuffer.putInt((processStartTime and 0xFFFFFFFF).toInt())  // Low 32 bits of timestamp (capture time, not send time)

            // Copy I420 data after header
            frameBuffer!!.copyInto(outputBuffer, 12, 0, expectedSize)

            // Send the buffer directly - no copyOf()!
            val frameData = outputBuffer

            // Use direct callback (always set by MetaWearablesPlugin)
            // Note: framesSkipped is kept at 0 for API compatibility - SharedFlow path is unused
            val callback = onFrameReady
            if (callback != null) {
                callback(frameData)
                framesProcessed++
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

    // MARK: - ABR Hack (disable phone-side adaptive bitrate)

    /**
     * Attempt to disable phone-side ABR by using reflection to modify
     * the LatencyTracker thresholds to very large values.
     *
     * This prevents the SDK from stepping down quality/fps based on
     * perceived latency drift on the phone side.
     *
     * Note: This doesn't affect glasses-side ABR which is firmware-controlled.
     */
    private fun disablePhoneSideAbr(session: StreamSession) {
        try {
            android.util.Log.d("StreamSessionManager", "Attempting to disable phone-side ABR via reflection...")

            // Navigate: StreamSession -> StreamSessionImpl -> internal state -> LatencyTracker
            val sessionClass = session::class.java
            android.util.Log.d("StreamSessionManager", "Session class: ${sessionClass.name}")

            // Try to find StreamingState or StreamingEventCoordinator
            // The exact path depends on SDK internals
            var latencyTrackerFound = false

            // Method 1: Look for a field containing "state" or "coordinator"
            for (field in sessionClass.declaredFields) {
                field.isAccessible = true
                val fieldValue = field.get(session) ?: continue
                android.util.Log.d("StreamSessionManager", "Field: ${field.name} = ${fieldValue::class.java.name}")

                // Try to find LatencyTracker in this object or its children
                latencyTrackerFound = tryModifyLatencyTracker(fieldValue, 0)
                if (latencyTrackerFound) break
            }

            if (!latencyTrackerFound) {
                android.util.Log.w("StreamSessionManager", "Could not find LatencyTracker via reflection")
            }
        } catch (e: Exception) {
            android.util.Log.e("StreamSessionManager", "Failed to disable phone-side ABR: ${e.message}")
        }
    }

    /**
     * Recursively search for LatencyTracker and modify its thresholds
     */
    private fun tryModifyLatencyTracker(obj: Any, depth: Int): Boolean {
        if (depth > 5) return false // Prevent infinite recursion

        val objClass = obj::class.java
        val className = objClass.name

        // Check if this IS a LatencyTracker
        if (className.contains("LatencyTracker")) {
            android.util.Log.d("StreamSessionManager", "Found LatencyTracker at depth $depth!")
            return modifyLatencyTrackerThresholds(obj)
        }

        // Check if this object might contain a LatencyTracker
        if (className.contains("StreamingState") ||
            className.contains("StreamSessionImpl") ||
            className.contains("Coordinator") ||
            className.contains("Handler")) {

            android.util.Log.d("StreamSessionManager", "Searching in: $className")

            for (field in objClass.declaredFields) {
                try {
                    field.isAccessible = true
                    val fieldValue = field.get(obj) ?: continue

                    // Check field type name
                    val fieldTypeName = fieldValue::class.java.name
                    if (fieldTypeName.contains("LatencyTracker")) {
                        android.util.Log.d("StreamSessionManager", "Found LatencyTracker in field: ${field.name}")
                        return modifyLatencyTrackerThresholds(fieldValue)
                    }

                    // Recurse into interesting objects
                    if (fieldTypeName.contains("meta.wearable") ||
                        fieldTypeName.contains("Streaming") ||
                        fieldTypeName.contains("State") ||
                        fieldTypeName.contains("Handler")) {
                        if (tryModifyLatencyTracker(fieldValue, depth + 1)) {
                            return true
                        }
                    }
                } catch (e: Exception) {
                    // Skip fields we can't access
                }
            }
        }

        return false
    }

    /**
     * Modify LatencyTracker thresholds to effectively disable ABR
     */
    private fun modifyLatencyTrackerThresholds(latencyTracker: Any): Boolean {
        try {
            val ltClass = latencyTracker::class.java

            // Modify latencyDriftAbrThreshold (default 1000ms -> 999999999ms)
            try {
                val thresholdField = ltClass.getDeclaredField("latencyDriftAbrThreshold")
                thresholdField.isAccessible = true

                // For final fields, we need to remove the final modifier
                val modifiersField = java.lang.reflect.Field::class.java.getDeclaredField("modifiers")
                modifiersField.isAccessible = true
                modifiersField.setInt(thresholdField, thresholdField.modifiers and java.lang.reflect.Modifier.FINAL.inv())

                val oldValue = thresholdField.getLong(latencyTracker)
                thresholdField.setLong(latencyTracker, 999_999_999L)
                android.util.Log.d("StreamSessionManager", "Modified latencyDriftAbrThreshold: $oldValue -> 999999999")
            } catch (e: Exception) {
                android.util.Log.w("StreamSessionManager", "Could not modify latencyDriftAbrThreshold: ${e.message}")
            }

            // Modify criticalThreshold (default 10000ms -> 999999999ms)
            try {
                val criticalField = ltClass.getDeclaredField("criticalThreshold")
                criticalField.isAccessible = true

                val modifiersField = java.lang.reflect.Field::class.java.getDeclaredField("modifiers")
                modifiersField.isAccessible = true
                modifiersField.setInt(criticalField, criticalField.modifiers and java.lang.reflect.Modifier.FINAL.inv())

                val oldValue = criticalField.getLong(latencyTracker)
                criticalField.setLong(latencyTracker, 999_999_999L)
                android.util.Log.d("StreamSessionManager", "Modified criticalThreshold: $oldValue -> 999999999")
            } catch (e: Exception) {
                android.util.Log.w("StreamSessionManager", "Could not modify criticalThreshold: ${e.message}")
            }

            android.util.Log.d("StreamSessionManager", "Successfully disabled phone-side ABR!")
            return true
        } catch (e: Exception) {
            android.util.Log.e("StreamSessionManager", "Failed to modify LatencyTracker: ${e.message}")
            return false
        }
    }

    // MARK: - Glasses-side ABR Hack

    /**
     * Attempt to disable glasses-side ABR by sending SessionSettings with AbrSettings.
     *
     * The SDK's configureSessionSettings() doesn't set AbrSettings, so glasses use firmware defaults.
     * We try to inject our own SessionSettings with AbrSettings{enableGlassesAbr=false} to prevent
     * the glasses from throttling based on their send queue.
     */
    private fun tryDisableGlassesSideAbr(session: StreamSession) {
        try {
            android.util.Log.d("StreamSessionManager", "Attempting to disable glasses-side ABR...")

            // Navigate: StreamSession -> internals -> ConnectionState -> mediaStreamChannel
            val channel = findMediaStreamChannel(session)
            if (channel == null) {
                android.util.Log.w("StreamSessionManager", "Could not find mediaStreamChannel")
                return
            }

            android.util.Log.d("StreamSessionManager", "Found mediaStreamChannel, building AbrSettings...")

            // Build AbrSettings with glasses ABR disabled and very high thresholds
            val abrSettingsBuilderClass = Class.forName("com.meta.media.stream.proto.AbrSettings\$Builder")
            val abrSettingsClass = Class.forName("com.meta.media.stream.proto.AbrSettings")
            val newBuilderMethod = abrSettingsClass.getMethod("newBuilder")
            val abrBuilder = newBuilderMethod.invoke(null)

            // Set enableGlassesAbr = false (the key setting)
            abrSettingsBuilderClass.getMethod("setEnableGlassesAbr", Boolean::class.java)
                .invoke(abrBuilder, false)

            // Set very high queue thresholds to prevent any throttling
            abrSettingsBuilderClass.getMethod("setQueueHighThreshold", Int::class.java)
                .invoke(abrBuilder, 999999)
            abrSettingsBuilderClass.getMethod("setQueueLowThreshold", Int::class.java)
                .invoke(abrBuilder, 0)
            abrSettingsBuilderClass.getMethod("setMaxSendQueueSize", Int::class.java)
                .invoke(abrBuilder, 999999)

            // Slow down monitoring/scaling intervals (less frequent checks)
            abrSettingsBuilderClass.getMethod("setMonitorIntervalMs", Int::class.java)
                .invoke(abrBuilder, 60000) // 60 seconds between checks
            abrSettingsBuilderClass.getMethod("setScaleDownIntervalMs", Int::class.java)
                .invoke(abrBuilder, 600000) // 10 minutes before scale down
            abrSettingsBuilderClass.getMethod("setScaleUpIntervalMs", Int::class.java)
                .invoke(abrBuilder, 1000) // Can scale up quickly

            val buildMethod = abrSettingsBuilderClass.getMethod("build")
            val abrSettings = buildMethod.invoke(abrBuilder)
            android.util.Log.d("StreamSessionManager", "Built AbrSettings: $abrSettings")

            // Build SessionSettings with our AbrSettings
            val sessionSettingsBuilderClass = Class.forName("com.meta.media.stream.proto.SessionSettings\$Builder")
            val sessionSettingsClass = Class.forName("com.meta.media.stream.proto.SessionSettings")
            val ssNewBuilderMethod = sessionSettingsClass.getMethod("newBuilder")
            val ssBuilder = ssNewBuilderMethod.invoke(null)

            // Set our AbrSettings
            sessionSettingsBuilderClass.getMethod("setAbrSettings", abrSettingsClass)
                .invoke(ssBuilder, abrSettings)

            val ssBuildMethod = sessionSettingsBuilderClass.getMethod("build")
            val sessionSettings = ssBuildMethod.invoke(ssBuilder)

            // Serialize to bytes
            val toByteArrayMethod = sessionSettingsClass.getMethod("toByteArray")
            val bytes = toByteArrayMethod.invoke(sessionSettings) as ByteArray
            android.util.Log.d("StreamSessionManager", "Serialized SessionSettings: ${bytes.size} bytes")

            // Get MessageType.MESSAGE_TYPE_SESSION_SETTINGS ordinal (it's 4)
            val messageTypeClass = Class.forName("com.meta.media.stream.proto.MessageType")
            val sessionSettingsTypeField = messageTypeClass.getField("MESSAGE_TYPE_SESSION_SETTINGS")
            val sessionSettingsType = sessionSettingsTypeField.get(null)
            val ordinalMethod = messageTypeClass.getMethod("ordinal")
            val typeOrdinal = ordinalMethod.invoke(sessionSettingsType) as Int
            android.util.Log.d("StreamSessionManager", "MESSAGE_TYPE_SESSION_SETTINGS ordinal: $typeOrdinal")

            // Create TypedBuffer(typeOrdinal, bytes) and send
            val typedBufferClass = Class.forName("com.facebook.wearable.datax.TypedBuffer")
            val typedBufferCtor = typedBufferClass.getConstructor(Int::class.java, ByteArray::class.java)
            val bytesCopy = Arrays.copyOf(bytes, bytes.size)
            val typedBuffer = typedBufferCtor.newInstance(typeOrdinal, bytesCopy)

            // Send via channel
            val sendMethod = channel::class.java.getMethod("send", typedBufferClass)
            sendMethod.invoke(channel, typedBuffer)

            android.util.Log.d("StreamSessionManager", "Sent SessionSettings with AbrSettings to glasses!")
            android.util.Log.d("StreamSessionManager", "Glasses-side ABR should now be disabled!")

        } catch (e: Exception) {
            android.util.Log.e("StreamSessionManager", "Failed to disable glasses-side ABR: ${e.message}", e)
        }
    }

    /**
     * Find the mediaStreamChannel by navigating through SDK internals via reflection.
     */
    private fun findMediaStreamChannel(session: StreamSession): Any? {
        try {
            // Try to find ConnectionState or StreamingStateData which has mediaStreamChannel
            return findFieldRecursive(session, "mediaStreamChannel", 0)
        } catch (e: Exception) {
            android.util.Log.e("StreamSessionManager", "Error finding mediaStreamChannel: ${e.message}")
            return null
        }
    }

    /**
     * Recursively search for a field by name in an object's fields.
     */
    private fun findFieldRecursive(obj: Any, targetFieldName: String, depth: Int): Any? {
        if (depth > 6) return null

        val objClass = obj::class.java

        // Check direct fields
        for (field in objClass.declaredFields) {
            try {
                field.isAccessible = true

                // Check if this is the field we want
                if (field.name == targetFieldName) {
                    val value = field.get(obj)
                    if (value != null) {
                        android.util.Log.d("StreamSessionManager", "Found $targetFieldName at ${objClass.simpleName}.${field.name}")
                        return value
                    }
                }

                // Recurse into meta.wearable objects
                val fieldValue = field.get(obj) ?: continue
                val fieldClassName = fieldValue::class.java.name
                if (fieldClassName.contains("meta.wearable") ||
                    fieldClassName.contains("ConnectionState") ||
                    fieldClassName.contains("StreamingState") ||
                    fieldClassName.contains("StateData")) {

                    val result = findFieldRecursive(fieldValue, targetFieldName, depth + 1)
                    if (result != null) return result
                }
            } catch (e: Exception) {
                // Skip inaccessible fields
            }
        }

        return null
    }
}
