package com.specbridge.app

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest

/**
 * Flutter plugin for Meta Wearables SDK integration on Android
 */
class MetaWearablesPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    private val methodChannel = MethodChannel(messenger, "com.specbridge/meta_dat")
    private val eventChannel = EventChannel(messenger, "com.specbridge/meta_dat_events")
    private val frameChannel = EventChannel(messenger, "com.specbridge/meta_dat_frames")

    private var eventSink: EventChannel.EventSink? = null
    private var frameSink: EventChannel.EventSink? = null

    private var wearablesManager: MetaWearablesManager? = null
    private var streamManager: StreamSessionManager? = null

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(EventStreamHandler())
        frameChannel.setStreamHandler(FrameStreamHandler())
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> configure(result)
            "startRegistration" -> startRegistration(result)
            "handleUrl" -> {
                val url = call.argument<String>("url")
                if (url != null) {
                    handleUrl(url, result)
                } else {
                    result.error("INVALID_ARGS", "URL required", null)
                }
            }
            "checkCameraPermission" -> checkCameraPermission(result)
            "requestCameraPermission" -> requestCameraPermission(result)
            "startStreaming" -> {
                val width = call.argument<Int>("width") ?: 1280
                val height = call.argument<Int>("height") ?: 720
                val frameRate = call.argument<Int>("frameRate") ?: 24
                val videoSource = call.argument<String>("videoSource") ?: "glasses"
                val videoQuality = call.argument<String>("videoQuality") ?: "medium"
                startStreaming(width, height, frameRate, videoSource, videoQuality, result)
            }
            "stopStreaming" -> stopStreaming(result)
            "disconnect" -> disconnect(result)
            "getStreamStats" -> getStreamStats(result)
            "setVideoSource" -> {
                val source = call.argument<String>("source") ?: "glasses"
                setVideoSource(source, result)
            }
            "setNativeServerEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                setNativeServerEnabled(enabled, result)
            }
            "isNativeServerEnabled" -> isNativeServerEnabled(result)
            "resetFrameServer" -> resetFrameServer(result)
            else -> result.notImplemented()
        }
    }

    // MARK: - Method Implementations

    private fun configure(result: MethodChannel.Result) {
        scope.launch {
            try {
                wearablesManager = MetaWearablesManager(activity)
                val success = wearablesManager!!.configure()

                // Observe connection state changes
                launch {
                    wearablesManager!!.connectionState.collectLatest { state ->
                        sendEvent(mapOf(
                            "type" to "connectionState",
                            "state" to state.name.lowercase()
                        ))
                    }
                }

                result.success(success)
            } catch (e: Exception) {
                result.error("CONFIG_FAILED", e.message, null)
            }
        }
    }

    private fun startRegistration(result: MethodChannel.Result) {
        scope.launch {
            try {
                val manager = wearablesManager
                if (manager == null) {
                    result.error("NOT_CONFIGURED", "Call configure first", null)
                    return@launch
                }

                val success = manager.startRegistration()
                result.success(success)
            } catch (e: Exception) {
                result.error("REGISTRATION_FAILED", e.message, null)
            }
        }
    }

    private fun handleUrl(url: String, result: MethodChannel.Result) {
        scope.launch {
            try {
                val manager = wearablesManager
                if (manager == null) {
                    result.error("NOT_CONFIGURED", "Call configure first", null)
                    return@launch
                }

                val success = manager.handleCallback(url)
                if (success) {
                    sendEvent(mapOf(
                        "type" to "connectionState",
                        "state" to "connected"
                    ))
                }
                result.success(success)
            } catch (e: Exception) {
                result.error("CALLBACK_FAILED", e.message, null)
            }
        }
    }

    private fun checkCameraPermission(result: MethodChannel.Result) {
        scope.launch {
            try {
                val manager = wearablesManager
                if (manager == null) {
                    result.success("unknown")
                    return@launch
                }

                val status = manager.checkCameraPermission()
                result.success(status)
            } catch (e: Exception) {
                result.success("unknown")
            }
        }
    }

    private fun requestCameraPermission(result: MethodChannel.Result) {
        scope.launch {
            try {
                if (wearablesManager == null) {
                    result.error("NOT_CONFIGURED", "Call configure first", null)
                    return@launch
                }

                // Use MainActivity's permission launcher to request via Meta AI app
                val mainActivity = activity as? MainActivity
                if (mainActivity == null) {
                    result.error("ACTIVITY_ERROR", "MainActivity not available", null)
                    return@launch
                }

                val permissionStatus = mainActivity.requestWearablesPermission(
                    com.meta.wearable.dat.core.types.Permission.CAMERA
                )

                val statusString = when (permissionStatus) {
                    com.meta.wearable.dat.core.types.PermissionStatus.Granted -> "granted"
                    com.meta.wearable.dat.core.types.PermissionStatus.Denied -> "denied"
                }
                result.success(statusString)
            } catch (e: Exception) {
                result.error("PERMISSION_FAILED", e.message, null)
            }
        }
    }

    private var cameraManager: CameraCaptureManager? = null
    private var currentVideoSource: String = "glasses"

    // Native frame server managed at plugin level for early startup
    private var nativeFrameServer: NativeFrameServer? = null
    private var useNativeServer = true

    private fun startStreaming(width: Int, height: Int, frameRate: Int, videoSource: String, videoQuality: String, result: MethodChannel.Result) {
        currentVideoSource = videoSource

        scope.launch {
            try {
                sendEvent(mapOf(
                    "type" to "streamStatus",
                    "status" to "starting"
                ))

                when (videoSource) {
                    "glasses" -> startGlassesStreaming(width, height, frameRate, videoQuality, result)
                    "backCamera" -> startCameraStreaming(width, height, frameRate, false, result)
                    "frontCamera" -> startCameraStreaming(width, height, frameRate, true, result)
                    "screenRecord" -> {
                        // Screen recording requires MediaProjection - not implemented yet
                        result.error("NOT_IMPLEMENTED", "Screen recording not yet implemented", null)
                    }
                    else -> result.error("INVALID_SOURCE", "Unknown video source: $videoSource", null)
                }
            } catch (e: Exception) {
                sendEvent(mapOf(
                    "type" to "streamStatus",
                    "status" to "error",
                    "error" to e.message
                ))
                result.error("STREAM_FAILED", e.message, null)
            }
        }
    }

    private suspend fun startGlassesStreaming(width: Int, height: Int, frameRate: Int, videoQuality: String, result: MethodChannel.Result) {
        val manager = wearablesManager
        if (manager == null) {
            result.error("NOT_CONFIGURED", "Call configure first for glasses streaming", null)
            return
        }

        // Initialize stream session manager for glasses
        streamManager = StreamSessionManager(activity, manager)

        // Use direct callback for frame delivery
        streamManager!!.onFrameReady = { frameData ->
            // Try native WebSocket first (bypasses Flutter UI thread entirely)
            val nativeServer = nativeFrameServer
            if (useNativeServer && nativeServer != null && nativeServer.hasClient) {
                nativeServer.sendFrame(frameData)
            } else {
                // Fall back to Flutter EventChannel (goes through UI thread)
                sendFrame(frameData)
            }
        }

        // Observe stream status
        scope.launch {
            streamManager!!.statusFlow.collectLatest { status ->
                sendEvent(mapOf(
                    "type" to "streamStatus",
                    "status" to status
                ))
            }
        }

        val success = streamManager!!.startStreaming(width, height, frameRate, videoQuality)
        if (success) {
            sendEvent(mapOf(
                "type" to "streamStatus",
                "status" to "streaming"
            ))
        }
        result.success(success)
    }

    private suspend fun startCameraStreaming(width: Int, height: Int, frameRate: Int, useFrontCamera: Boolean, result: MethodChannel.Result) {
        // Initialize camera capture manager
        val camera = CameraCaptureManager(activity)
        cameraManager = camera

        // Start capture first before collecting frames
        val success = camera.startCapture(width, height, frameRate, useFrontCamera)

        if (success) {
            // Observe frames from camera
            scope.launch {
                camera.frameFlow.collectLatest { frameData ->
                    // Send to floating overlay for MediaProjection capture
                    if (FloatingPreviewService.isRunning()) {
                        FloatingPreviewService.updateFrame(frameData)
                        // Skip Flutter preview - overlay covers everything anyway
                    } else {
                        // Use native WebSocket server if available (same as glasses mode)
                        // This is critical: WebView connects to native server first,
                        // so camera frames must also go through native server
                        val nativeServer = nativeFrameServer
                        if (useNativeServer && nativeServer != null && nativeServer.hasClient) {
                            nativeServer.sendFrame(frameData)
                        } else {
                            // Fallback to Flutter WebSocket
                            sendFrame(frameData)
                        }
                    }
                }
            }
            sendEvent(mapOf(
                "type" to "streamStatus",
                "status" to "streaming"
            ))
        }
        result.success(success)
    }

    private fun stopStreaming(result: MethodChannel.Result) {
        scope.launch {
            // Stop glasses streaming
            streamManager?.stopStreaming()
            streamManager = null

            // Stop camera streaming
            cameraManager?.stopCapture()
            cameraManager = null

            sendEvent(mapOf(
                "type" to "streamStatus",
                "status" to "stopped"
            ))
            result.success(null)
        }
    }

    /**
     * Set the current video source for stats tracking without starting capture.
     * Used when camera mode uses WebView's getUserMedia directly.
     */
    private fun setVideoSource(source: String, result: MethodChannel.Result) {
        currentVideoSource = source
        android.util.Log.d("MetaWearablesPlugin", "Video source set to: $source (stats only)")
        result.success(true)
    }

    private fun getStreamStats(result: MethodChannel.Result) {
        val stats = mutableMapOf<String, Any>()

        // Add video source type
        stats["videoSource"] = currentVideoSource

        // Get stream manager stats (glasses)
        streamManager?.let {
            stats.putAll(it.getStats())
        }

        // Get camera manager stats
        cameraManager?.let {
            stats["cameraFrameCount"] = it.frameCount
        }

        // Get native frame server stats
        nativeFrameServer?.let {
            val serverStats = it.getStats()
            stats["nativeServerRunning"] = serverStats["isRunning"] ?: false
            stats["nativeServerHasClient"] = serverStats["hasClient"] ?: false
            stats["nativeServerPort"] = serverStats["port"] ?: 0
            stats["nativeFramesSent"] = serverStats["framesSent"] ?: 0L
            stats["nativeFramesDropped"] = serverStats["framesDropped"] ?: 0L
        } ?: run {
            stats["nativeServerRunning"] = false
            stats["nativeServerHasClient"] = false
        }

        // Add whether native server mode is enabled
        stats["useNativeServer"] = useNativeServer

        // Add CPU usage
        try {
            val cpuUsage = getCpuUsage()
            stats["cpuUsage"] = cpuUsage
        } catch (e: Exception) {
            stats["cpuUsage"] = -1
        }

        // Add memory usage
        try {
            val runtime = Runtime.getRuntime()
            val usedMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
            val maxMemory = runtime.maxMemory() / (1024 * 1024)
            stats["memoryUsedMB"] = usedMemory
            stats["memoryMaxMB"] = maxMemory
        } catch (e: Exception) {
            // Ignore memory errors
        }

        result.success(stats)
    }

    // MARK: - Native Frame Server

    private fun setNativeServerEnabled(enabled: Boolean, result: MethodChannel.Result) {
        useNativeServer = enabled

        if (enabled && nativeFrameServer == null) {
            // Start the native server immediately so it's ready when JS connects
            nativeFrameServer = NativeFrameServer()
            nativeFrameServer?.startServer()
            android.util.Log.d("MetaWearablesPlugin", "Native frame server STARTED on port ${NativeFrameServer.DEFAULT_PORT}")
        } else if (!enabled && nativeFrameServer != null) {
            nativeFrameServer?.stopServer()
            nativeFrameServer = null
            android.util.Log.d("MetaWearablesPlugin", "Native frame server STOPPED")
        }

        // Also tell streamManager if it exists
        streamManager?.setNativeServerEnabled(enabled)
        result.success(enabled)
    }

    private fun isNativeServerEnabled(result: MethodChannel.Result) {
        result.success(useNativeServer && nativeFrameServer != null)
    }

    /**
     * Reset the native frame server client state for clean session transitions.
     * Call this when stopping streaming to ensure no stale state affects the next session.
     */
    private fun resetFrameServer(result: MethodChannel.Result) {
        android.util.Log.d("MetaWearablesPlugin", "Resetting native frame server client state")
        nativeFrameServer?.resetClient()
        result.success(true)
    }

    // CPU usage tracking
    private var lastCpuTime = 0L
    private var lastAppCpuTime = 0L

    private fun getCpuUsage(): Int {
        try {
            // Use Debug.threadCpuTimeNanos for simpler CPU tracking
            val currentCpuTime = android.os.Debug.threadCpuTimeNanos()
            val currentRealTime = System.nanoTime()

            if (lastCpuTime == 0L) {
                lastCpuTime = currentRealTime
                lastAppCpuTime = currentCpuTime
                return 0
            }

            val realTimeDelta = currentRealTime - lastCpuTime
            val cpuTimeDelta = currentCpuTime - lastAppCpuTime

            lastCpuTime = currentRealTime
            lastAppCpuTime = currentCpuTime

            if (realTimeDelta <= 0) return 0

            // CPU percentage for this thread
            val cpuPercent = ((cpuTimeDelta * 100) / realTimeDelta).toInt()
            return cpuPercent.coerceIn(0, 100)
        } catch (e: Exception) {
            android.util.Log.w("MetaWearablesPlugin", "CPU usage error: ${e.message}")
            return -1
        }
    }

    private fun disconnect(result: MethodChannel.Result) {
        scope.launch {
            try {
                // Stop any streaming first
                streamManager?.stopStreaming()
                streamManager = null
                cameraManager?.stopCapture()
                cameraManager = null

                // Disconnect from glasses
                wearablesManager?.disconnect()

                sendEvent(mapOf(
                    "type" to "connectionState",
                    "state" to "disconnected"
                ))
                result.success(null)
            } catch (e: Exception) {
                result.error("DISCONNECT_FAILED", e.message, null)
            }
        }
    }

    // MARK: - URL Handling

    fun handleIncomingUrl(url: String) {
        sendEvent(mapOf(
            "type" to "incomingUrl",
            "url" to url
        ))
    }

    // MARK: - Event Helpers

    private fun sendEvent(data: Map<String, Any?>) {
        activity.runOnUiThread {
            eventSink?.success(data)
        }
    }

    private fun sendFrame(data: ByteArray) {
        // EventSink requires UI thread
        activity.runOnUiThread {
            frameSink?.success(data)
        }
    }

    fun dispose() {
        scope.cancel()
        streamManager?.stopStreaming()
        cameraManager?.stopCapture()
        nativeFrameServer?.stopServer()
        nativeFrameServer = null
        methodChannel.setMethodCallHandler(null)
    }

    // MARK: - Stream Handlers

    private inner class EventStreamHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            eventSink = events
        }

        override fun onCancel(arguments: Any?) {
            eventSink = null
        }
    }

    private inner class FrameStreamHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            frameSink = events
        }

        override fun onCancel(arguments: Any?) {
            frameSink = null
        }
    }
}
