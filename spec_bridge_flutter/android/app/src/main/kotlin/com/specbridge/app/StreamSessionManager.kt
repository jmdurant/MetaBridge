package com.specbridge.app

import android.content.Context
import android.util.Log
import com.meta.wearable.dat.camera.addCamera
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamState
import com.meta.wearable.dat.camera.types.VideoFrame
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** DAT 1.x DeviceSession → Camera → Stream lifecycle, owned on the main thread. */
class StreamSessionManager(
    private val context: Context,
    private val wearablesManager: MetaWearablesManager
) {
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private var sessionJob: Job? = null
    private var deviceSession: DeviceSession? = null
    private val _statusFlow = MutableStateFlow("stopped")
    val statusFlow: StateFlow<String> = _statusFlow.asStateFlow()

    var onFrameReady: ((ByteArray) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    @Volatile var frameCount = 0L
        private set
    @Volatile var framesProcessed = 0L
        private set
    @Volatile private var framesSkipped = 0L
    @Volatile private var totalProcessingTimeMs = 0L
    @Volatile private var lastProcessingTimeMs = 0L
    @Volatile private var lastFrameArrivalTime = 0L
    @Volatile private var frameIntervalSum = 0L
    @Volatile private var frameIntervalCount = 0L

    fun getStats(): Map<String, Any> = mapOf(
        "framesReceived" to frameCount,
        "framesProcessed" to framesProcessed,
        "framesSkipped" to framesSkipped,
        "skipRate" to if (frameCount > 0) (framesSkipped * 100 / frameCount).toInt() else 0,
        "lastEncodeTimeMs" to lastProcessingTimeMs,
        "avgEncodeTimeMs" to if (framesProcessed > 0) totalProcessingTimeMs / framesProcessed else 0,
        "avgFrameIntervalMs" to if (frameIntervalCount > 0) frameIntervalSum / frameIntervalCount else 0
    )

    // Transport is owned by MetaWearablesPlugin.
    fun setNativeServerEnabled(enabled: Boolean) = Unit

    fun startStreaming(width: Int, height: Int, frameRate: Int, videoQualityStr: String = "medium"): Boolean {
        if (sessionJob != null) return false
        _statusFlow.value = "starting"
        frameCount = 0
        framesProcessed = 0
        framesSkipped = 0
        totalProcessingTimeMs = 0
        lastProcessingTimeMs = 0
        lastFrameArrivalTime = 0
        frameIntervalSum = 0
        frameIntervalCount = 0
        // Assign before starting, so repeated starts and stop-during-start are safe.
        sessionJob = scope.launch(start = CoroutineStart.LAZY) {
            runSession(frameRate, videoQualityStr)
        }
        sessionJob!!.start()
        return true
    }

    private suspend fun runSession(frameRate: Int, qualityName: String) {
        var failed = false
        try {
            withTimeout(10_000) {
                wearablesManager.deviceSelector.activeDeviceFlow().first { it != null }
            }
            val session = Wearables.createSession(wearablesManager.deviceSelector).getOrNull()
                ?: error("Could not create a glasses session")
            deviceSession = session
            coroutineScope {
                val sessionErrors = launch {
                    session.errors.collect { error ->
                        // Some compatibility/thermal events are warnings; let the SDK
                        // drive terminal state rather than restarting a paused session.
                        Log.w(TAG, "Device session: ${error.description}")
                    }
                }
                session.start()
                val ready = withTimeout(15_000) {
                    session.state.first {
                        it == DeviceSessionState.STARTED || it == DeviceSessionState.STOPPED
                    }
                }
                check(ready == DeviceSessionState.STARTED) { "Glasses session stopped during startup" }
                val quality = when (qualityName.lowercase()) {
                    "low" -> VideoQuality.LOW
                    "high" -> VideoQuality.HIGH
                    else -> VideoQuality.MEDIUM
                }
                val fps = listOf(30, 24, 15, 7, 2).minBy { kotlin.math.abs(it - frameRate) }
                val camera = session.addCamera(StreamConfiguration(
                    videoQuality = quality, frameRate = fps, compressVideo = false
                )).getOrNull() ?: error("Could not attach glasses camera")
                val stream = camera.stream
                val stateJob = launch {
                    var wasActive = false
                    stream.state.collect { state ->
                        val terminal = state == StreamState.STOPPED || state == StreamState.CLOSED
                        if (!terminal) wasActive = true
                        if (terminal && !wasActive) return@collect // Initial STOPPED replay.
                        _statusFlow.value = when (state) {
                            StreamState.STREAMING -> "streaming"
                            StreamState.PAUSED -> "paused"
                            StreamState.STOPPING -> "stopping"
                            StreamState.STOPPED, StreamState.CLOSED -> "stopped"
                            else -> "starting"
                        }
                        if (terminal) session.stop()
                    }
                }
                val streamErrors = launch {
                    stream.errorStream.collect { error -> Log.w(TAG, "Camera stream: ${error.description}") }
                }
                val videoJob = launch(Dispatchers.Default) {
                    stream.videoStream.collect { processFrame(it) }
                }
                try {
                    stream.start().onFailure { startError, _ -> error(startError.description) }
                    session.state.first { it == DeviceSessionState.STOPPED }
                } finally {
                    withContext(NonCancellable) {
                        videoJob.cancelAndJoin()
                        stateJob.cancelAndJoin()
                        streamErrors.cancelAndJoin()
                        sessionErrors.cancelAndJoin()
                        session.stop()
                        withTimeoutOrNull(5_000) {
                            session.state.first { it == DeviceSessionState.STOPPED }
                        }
                        camera.close()
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            // Timeouts are failures; explicit stop is normal cancellation.
            if (cancelled is TimeoutCancellationException) {
                failed = true
                onError?.invoke("Timed out starting glasses camera")
            } else {
                throw cancelled
            }
        } catch (error: Exception) {
            failed = true
            Log.e(TAG, "Glasses stream failed", error)
            onError?.invoke(error.message ?: "Glasses stream failed")
        } finally {
            deviceSession?.stop()
            deviceSession = null
            sessionJob = null
            _statusFlow.value = if (failed) "error" else "stopped"
        }
    }

    fun stopStreaming() {
        if (sessionJob == null) return
        _statusFlow.value = "stopping"
        deviceSession?.stop()
        sessionJob?.cancel()
    }

    suspend fun stopAndWait() {
        val job = sessionJob
        stopStreaming()
        job?.join()
    }

    private fun processFrame(frame: VideoFrame) {
        frameCount++
        val start = System.currentTimeMillis()
        if (lastFrameArrivalTime > 0) {
            frameIntervalSum += start - lastFrameArrivalTime
            frameIntervalCount++
        }
        lastFrameArrivalTime = start
        // This transport accepts decoded, tightly packed I420 only.
        val width = frame.width
        val height = frame.height
        val payloadSize = width.toLong() * height * 3 / 2
        if (frame.isCompressed || width <= 0 || height <= 0 || width % 2 != 0 || height % 2 != 0 ||
            payloadSize > Int.MAX_VALUE - 12 || frame.buffer.remaining() < payloadSize) {
            framesSkipped++
            return
        }
        // Own each frame until asynchronous socket / Flutter sends have finished.
        // Header: uint32 LE width, height, low 32 bits of capture time, then I420.
        val output = ByteBuffer.allocate(12 + payloadSize.toInt()).order(ByteOrder.LITTLE_ENDIAN)
        output.putInt(width).putInt(height).putInt(start.toInt())
        val pixels = frame.buffer.duplicate()
        pixels.limit(pixels.position() + payloadSize.toInt())
        output.put(pixels)
        onFrameReady?.let { callback ->
            callback(output.array())
            framesProcessed++
        }
        lastProcessingTimeMs = System.currentTimeMillis() - start
        totalProcessingTimeMs += lastProcessingTimeMs
    }

    fun dispose() {
        stopStreaming()
        scope.cancel()
    }

    companion object { private const val TAG = "StreamSessionManager" }
}
