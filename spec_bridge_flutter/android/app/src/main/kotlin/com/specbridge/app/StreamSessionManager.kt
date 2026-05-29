package com.specbridge.app

import com.meta.wearable.dat.camera.Stream
import com.meta.wearable.dat.camera.addStream
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamError
import com.meta.wearable.dat.camera.types.StreamState
import com.meta.wearable.dat.camera.types.VideoFrame
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.DeviceSessionError
import android.content.Context
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
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Manages video streaming from Meta glasses on Android.
 *
 * Migrated to Meta Wearables DAT SDK 0.7.0. The old `Wearables.startStreamSession(...)` factory
 * is gone; the lifecycle is now:
 *
 *     Wearables.createSession(selector)        // -> DeviceSession
 *         .onSuccess { session -> session.start() }
 *     // when session.state == STARTED:
 *     session.addStream(StreamConfiguration(...))   // -> Stream (camera Capability)
 *         .onSuccess { stream -> collect stream.videoStream; stream.start() }
 *
 * Frame output (RAW mode, the default — keeps the existing WebView/native-server pipeline working):
 *   12-byte little-endian header + I420 payload
 *     bytes 0-3   width  (uint32 LE)
 *     bytes 4-7   height (uint32 LE)
 *     bytes 8-11  capture timestamp, low 32 bits (uint32 LE)
 *   followed by I420 data (Y plane, U plane, V plane).
 *
 * COMPRESSED mode (compressVideo = true, SDK 0.6.0+ feature, opt-in / experimental):
 *   `StreamConfiguration.compressVideo` makes the SDK hand back the glasses' native HEVC bitstream
 *   (VideoFrame.isCompressed == true), skipping the on-phone decode and letting streaming continue
 *   in the background. This eliminates the decode + JPEG re-encode that causes the ~2-5s latency.
 *   The downstream WebView/WebRTC bridge does NOT yet consume HEVC — wiring that is the next step —
 *   so this defaults OFF and falls back to RAW. See JitsiFrameBridge / jitsi_bridge.js.
 *
 * The phone-side / glasses-side ABR reflection hacks from the 0.3.0 version were removed: they
 * reached into SDK internals (LatencyTracker, AbrSettings) that no longer exist in 0.7.0, and
 * 0.4.0 fixed the "stream latency degrading over time" bug they were working around.
 *
 * Based on the official CameraAccess sample (samples/CameraAccess StreamViewModel).
 */
class StreamSessionManager(
    private val context: Context,
    private val wearablesManager: MetaWearablesManager
) {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var session: DeviceSession? = null
    private var stream: Stream? = null
    private var sessionStateJob: Job? = null
    private var sessionErrorJob: Job? = null
    private var videoJob: Job? = null
    private var streamStateJob: Job? = null
    private var streamErrorJob: Job? = null

    // Set once we've attached the Stream to the session, so we only add it on the first STARTED.
    private var streamAttached = false

    // Whether this session requested compressed HEVC frames.
    private var compressVideo = false

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

    // Encoding/processing time tracking
    private var totalEncodeTimeMs: Long = 0
    private var lastEncodeTimeMs: Long = 0

    // Frame arrival timing (to detect SDK throttling)
    private var lastFrameArrivalTime: Long = 0
    private var frameIntervalSum: Long = 0
    private var frameIntervalCount: Long = 0

    // Count of compressed frames seen (0 in raw mode)
    private var compressedFrameCount: Long = 0

    // framesSkipped is always 0 - kept for API/stats compatibility
    private val framesSkipped = 0L

    /**
     * Native server is managed by MetaWearablesPlugin, not here.
     */
    fun setNativeServerEnabled(enabled: Boolean) {
        // No-op - native server is managed by MetaWearablesPlugin
    }

    /**
     * Get current streaming stats for debugging/monitoring.
     * Keys are consumed by the Flutter stats overlay — keep them stable.
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
            "avgFrameIntervalMs" to avgFrameInterval,
            "codec" to if (compressVideo) "hevc" else "i420",
            "compressedFrames" to compressedFrameCount
        )
    }

    // MARK: - Streaming Control

    /**
     * @param compressVideo when true, request compressed HEVC frames (SDK 0.6.0+). Defaults to
     *        false so the existing raw-I420 WebView pipeline keeps working unchanged.
     */
    fun startStreaming(
        width: Int,
        height: Int,
        frameRate: Int,
        videoQualityStr: String = "medium",
        compressVideo: Boolean = false
    ): Boolean {
        android.util.Log.d(
            "StreamSessionManager",
            "startStreaming called: ${width}x${height} @ ${frameRate}fps, quality=$videoQualityStr, compress=$compressVideo"
        )

        if (session != null) {
            android.util.Log.w("StreamSessionManager", "Already streaming, returning false")
            return false
        }

        this.compressVideo = compressVideo
        scope.launch {
            startStreamingAsync(frameRate, videoQualityStr, compressVideo)
        }
        return true // actual status reported via statusFlow
    }

    private fun startStreamingAsync(frameRate: Int, videoQualityStr: String, compress: Boolean) {
        _statusFlow.value = "starting"
        frameCount = 0
        framesProcessed = 0
        compressedFrameCount = 0
        streamAttached = false

        val quality = when (videoQualityStr.lowercase()) {
            "low" -> VideoQuality.LOW
            "high" -> VideoQuality.HIGH
            else -> VideoQuality.MEDIUM
        }
        // Coerce to a frame rate the SDK accepts: 30, 24, 15, 7, 2
        val validFps = listOf(30, 24, 15, 7, 2)
        val fps = validFps.minByOrNull { kotlin.math.abs(it - frameRate) } ?: 24
        android.util.Log.d("StreamSessionManager", "Using quality=$quality @ ${fps}fps (requested $frameRate)")

        // 1) Create a DeviceSession for the selected device
        Wearables.createSession(wearablesManager.deviceSelector)
            .onSuccess { createdSession ->
                session = createdSession

                // Observe session-scoped errors (thermal/battery/app-update etc.)
                sessionErrorJob = scope.launch {
                    createdSession.errors.collect { error -> handleSessionError(error) }
                }

                // Observe session lifecycle; attach the camera Stream once STARTED
                sessionStateJob = scope.launch {
                    createdSession.state.collect { state ->
                        android.util.Log.d("StreamSessionManager", "Session state: $state")
                        if (state == DeviceSessionState.STARTED && !streamAttached) {
                            streamAttached = true
                            attachStream(createdSession, quality, fps, compress)
                        }
                    }
                }

                createdSession.start()
            }
            .onFailure { error, _ ->
                android.util.Log.e("StreamSessionManager", "createSession failed: ${error.description}")
                _statusFlow.value = "error"
            }
    }

    private fun attachStream(session: DeviceSession, quality: VideoQuality, fps: Int, compress: Boolean) {
        android.util.Log.d("StreamSessionManager", "Attaching stream (compress=$compress)...")
        session
            .addStream(
                StreamConfiguration(
                    videoQuality = quality,
                    frameRate = fps,
                    compressVideo = compress
                )
            )
            .onSuccess { addedStream ->
                stream = addedStream

                videoJob = scope.launch {
                    addedStream.videoStream.collect { processFrame(it) }
                }

                streamStateJob = scope.launch {
                    addedStream.state.collect { streamState ->
                        android.util.Log.d("StreamSessionManager", "Stream state: $streamState")
                        _statusFlow.value = when (streamState) {
                            StreamState.STARTING -> "starting"
                            StreamState.STARTED -> "starting"
                            StreamState.STREAMING -> "streaming"
                            StreamState.STOPPING -> "stopping"
                            StreamState.STOPPED -> "stopped"
                            StreamState.CLOSED -> "stopped"
                            else -> "unknown"
                        }
                    }
                }

                streamErrorJob = scope.launch {
                    addedStream.errorStream.collect { error ->
                        if (error == StreamError.STREAM_ERROR) {
                            android.util.Log.w("StreamSessionManager", "Non-critical stream error, continuing")
                            return@collect
                        }
                        android.util.Log.e("StreamSessionManager", "Stream error: ${error.description}")
                        _statusFlow.value = "error"
                    }
                }

                addedStream.start()
            }
            .onFailure { error, _ ->
                android.util.Log.e("StreamSessionManager", "addStream failed: ${error.description}")
                _statusFlow.value = "error"
            }
    }

    private fun handleSessionError(error: DeviceSessionError) {
        android.util.Log.e("StreamSessionManager", "Session error: $error")
        // Thermal/battery/app-update conditions are surfaced as session errors in 0.7.0.
        _statusFlow.value = "error"
    }

    fun stopStreaming() {
        videoJob?.cancel(); videoJob = null
        streamStateJob?.cancel(); streamStateJob = null
        streamErrorJob?.cancel(); streamErrorJob = null
        sessionStateJob?.cancel(); sessionStateJob = null
        sessionErrorJob?.cancel(); sessionErrorJob = null
        streamAttached = false

        stream?.stop()
        stream = null
        session?.stop()
        session = null
        _statusFlow.value = "stopped"
    }

    // MARK: - Frame Processing

    // Reusable buffers to avoid per-frame allocation - double buffered for thread safety
    private var frameBuffer: ByteArray? = null
    private var outputBuffer1: ByteArray? = null
    private var outputBuffer2: ByteArray? = null
    private var useBuffer1 = true

    private fun processFrame(videoFrame: VideoFrame) {
        frameCount++
        val processStartTime = System.currentTimeMillis()

        // Track inter-frame arrival interval (helps spot SDK throttling)
        if (lastFrameArrivalTime > 0) {
            frameIntervalSum += processStartTime - lastFrameArrivalTime
            frameIntervalCount++
        }
        lastFrameArrivalTime = processStartTime

        if (frameCount == 1L) {
            android.util.Log.d(
                "StreamSessionManager",
                "First frame: ${videoFrame.width}x${videoFrame.height}, compressed=${videoFrame.isCompressed}"
            )
        }
        if (frameCount % 100 == 0L) {
            val avgInterval = if (frameIntervalCount > 0) frameIntervalSum / frameIntervalCount else 0
            android.util.Log.d(
                "StreamSessionManager",
                "Frames: $frameCount received, $framesProcessed sent, avgInterval=${avgInterval}ms"
            )
        }

        try {
            if (videoFrame.isCompressed) {
                processCompressedFrame(videoFrame, processStartTime)
            } else {
                processRawI420Frame(videoFrame, processStartTime)
            }
        } catch (e: Exception) {
            if (frameCount < 10) {
                android.util.Log.e("StreamSessionManager", "Frame processing error: ${e.message}")
            }
        }
    }

    /**
     * RAW I420 path — byte-for-byte identical output to the pre-migration code so the existing
     * native frame server + WebView canvas pipeline keeps working with no downstream changes.
     */
    private fun processRawI420Frame(videoFrame: VideoFrame, processStartTime: Long) {
        val buffer = videoFrame.buffer
        val dataSize = buffer.remaining()
        val width = videoFrame.width
        val height = videoFrame.height

        // Expected I420 size: Y (w*h) + U (w*h/4) + V (w*h/4) = w*h*1.5
        val expectedSize = width * height * 3 / 2
        if (dataSize < expectedSize) {
            android.util.Log.w("StreamSessionManager", "Frame size mismatch: got $dataSize, expected $expectedSize")
            return
        }

        if (frameBuffer == null || frameBuffer!!.size < dataSize) {
            frameBuffer = ByteArray(dataSize)
        }
        val originalPosition = buffer.position()
        buffer.get(frameBuffer!!, 0, dataSize)
        buffer.position(originalPosition)

        // 12-byte header + I420 data, double-buffered to avoid per-frame allocation
        val outputSize = 12 + expectedSize
        val outputBuffer = if (useBuffer1) {
            if (outputBuffer1 == null || outputBuffer1!!.size < outputSize) outputBuffer1 = ByteArray(outputSize)
            outputBuffer1!!
        } else {
            if (outputBuffer2 == null || outputBuffer2!!.size < outputSize) outputBuffer2 = ByteArray(outputSize)
            outputBuffer2!!
        }
        useBuffer1 = !useBuffer1

        val headerBuffer = ByteBuffer.wrap(outputBuffer, 0, 12).order(ByteOrder.LITTLE_ENDIAN)
        headerBuffer.putInt(width)
        headerBuffer.putInt(height)
        headerBuffer.putInt((processStartTime and 0xFFFFFFFF).toInt())

        frameBuffer!!.copyInto(outputBuffer, 12, 0, expectedSize)

        onFrameReady?.let {
            it(outputBuffer)
            framesProcessed++
        }

        lastEncodeTimeMs = System.currentTimeMillis() - processStartTime
        totalEncodeTimeMs += lastEncodeTimeMs
    }

    /**
     * COMPRESSED HEVC path (Step 2). The SDK delivers the glasses' native HEVC bitstream (no
     * on-phone decode). We wrap it in a self-describing frame so the WebView can rebuild
     * EncodedVideoChunks and decode via WebCodecs → MediaStreamTrackGenerator → WebRTC.
     *
     * Wire format (little-endian), distinct from the I420 (12-byte) and JPEG (0xFFD8) formats:
     *   [0..3]   magic "HVC1" (0x48 0x56 0x43 0x31)
     *   [4]      flags: bit0 = isCodecConfig, bit1 = isKeyframe (IRAP NAL present)
     *   [5..12]  presentationTimeUs (int64 LE)
     *   [13..16] width  (uint32 LE)
     *   [17..20] height (uint32 LE)
     *   [21..]   HEVC bitstream (as delivered by the SDK — Annex-B expected; confirmed via logs)
     */
    private fun processCompressedFrame(videoFrame: VideoFrame, processStartTime: Long) {
        compressedFrameCount++

        val buffer = videoFrame.buffer
        val payloadSize = buffer.remaining()
        if (payloadSize <= 0) return

        val isCodecConfig = videoFrame.isCodecConfig
        val ptsUs = videoFrame.presentationTimeUs
        val width = videoFrame.width
        val height = videoFrame.height

        // Copy payload out of the SDK buffer
        val payload = ByteArray(payloadSize)
        val originalPosition = buffer.position()
        buffer.get(payload, 0, payloadSize)
        buffer.position(originalPosition)

        // Inspect NAL units (Annex-B) to detect keyframe / parameter sets.
        val nal = inspectHevcNals(payload)

        // Diagnostics for the first few frames so we can confirm the exact bitstream format.
        if (compressedFrameCount <= 5L) {
            android.util.Log.d(
                "StreamSessionManager",
                "HEVC frame #$compressedFrameCount size=$payloadSize isCodecConfig=$isCodecConfig " +
                    "key=${nal.isKeyframe} paramSets=${nal.hasParamSets} nalTypes=${nal.types} " +
                    "first16=${payload.take(16).joinToString(" ") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }}"
            )
        }

        val HEADER = 21
        val outputBuffer = ByteArray(HEADER + payloadSize)
        val hb = ByteBuffer.wrap(outputBuffer).order(ByteOrder.LITTLE_ENDIAN)
        hb.put('H'.code.toByte()); hb.put('V'.code.toByte()); hb.put('C'.code.toByte()); hb.put('1'.code.toByte())
        var flags = 0
        if (isCodecConfig || nal.hasParamSets) flags = flags or 0x01
        if (nal.isKeyframe) flags = flags or 0x02
        hb.put(flags.toByte())
        hb.putLong(ptsUs)
        hb.putInt(width)
        hb.putInt(height)
        payload.copyInto(outputBuffer, HEADER, 0, payloadSize)

        onFrameReady?.let {
            it(outputBuffer)
            framesProcessed++
        }

        lastEncodeTimeMs = System.currentTimeMillis() - processStartTime
        totalEncodeTimeMs += lastEncodeTimeMs
    }

    private data class NalInfo(val isKeyframe: Boolean, val hasParamSets: Boolean, val types: List<Int>)

    /**
     * Scan an Annex-B HEVC bitstream for NAL unit types.
     * HEVC NAL header: type = (firstByteAfterStartCode >> 1) & 0x3F.
     *  - IRAP/keyframe types: 16..21 (BLA/IDR/CRA)
     *  - Parameter sets: VPS=32, SPS=33, PPS=34
     */
    private fun inspectHevcNals(data: ByteArray): NalInfo {
        val types = ArrayList<Int>(4)
        var isKey = false
        var hasParams = false
        var i = 0
        val n = data.size
        while (i + 3 < n) {
            // Find start code 00 00 01 (allowing a leading 00 for 00 00 00 01)
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                val hdr = data[i + 3].toInt() and 0xFF
                val type = (hdr shr 1) and 0x3F
                types.add(type)
                if (type in 16..21) isKey = true
                if (type in 32..34) hasParams = true
                i += 3
            } else {
                i++
            }
            if (types.size >= 8) break // enough to classify
        }
        return NalInfo(isKey, hasParams, types)
    }

    // MARK: - Cleanup

    fun dispose() {
        stopStreaming()
        scope.cancel()
    }
}
