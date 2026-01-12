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
    private var jitsiBridge: JitsiFrameBridge? = null

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
                startStreaming(width, height, frameRate, result)
            }
            "stopStreaming" -> stopStreaming(result)
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
                val manager = wearablesManager
                if (manager == null) {
                    result.error("NOT_CONFIGURED", "Call configure first", null)
                    return@launch
                }

                val status = manager.requestCameraPermission()
                result.success(status)
            } catch (e: Exception) {
                result.error("PERMISSION_FAILED", e.message, null)
            }
        }
    }

    private fun startStreaming(width: Int, height: Int, frameRate: Int, result: MethodChannel.Result) {
        scope.launch {
            try {
                val manager = wearablesManager
                if (manager == null) {
                    result.error("NOT_CONFIGURED", "Call configure first", null)
                    return@launch
                }

                // Initialize Jitsi frame bridge for socket injection
                jitsiBridge = JitsiFrameBridge(activity)
                jitsiBridge!!.connect()

                // Initialize stream session manager
                streamManager = StreamSessionManager(manager)

                // Observe frames
                launch {
                    streamManager!!.frameFlow.collectLatest { frameData ->
                        // Send to Jitsi via socket injection
                        jitsiBridge?.sendFrame(frameData)

                        // Send to Flutter for preview (every 3rd frame)
                        if (streamManager!!.frameCount % 3 == 0L) {
                            sendFrame(frameData)
                        }
                    }
                }

                // Observe stream status
                launch {
                    streamManager!!.statusFlow.collectLatest { status ->
                        sendEvent(mapOf(
                            "type" to "streamStatus",
                            "status" to status
                        ))
                    }
                }

                val success = streamManager!!.startStreaming(width, height, frameRate)
                if (success) {
                    sendEvent(mapOf(
                        "type" to "streamStatus",
                        "status" to "streaming"
                    ))
                }
                result.success(success)
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

    private fun stopStreaming(result: MethodChannel.Result) {
        scope.launch {
            streamManager?.stopStreaming()
            streamManager = null

            jitsiBridge?.disconnect()
            jitsiBridge = null

            sendEvent(mapOf(
                "type" to "streamStatus",
                "status" to "stopped"
            ))
            result.success(null)
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
        activity.runOnUiThread {
            frameSink?.success(data)
        }
    }

    fun dispose() {
        scope.cancel()
        streamManager?.stopStreaming()
        jitsiBridge?.disconnect()
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
