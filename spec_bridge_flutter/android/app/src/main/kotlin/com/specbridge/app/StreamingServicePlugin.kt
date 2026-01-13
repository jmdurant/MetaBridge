package com.specbridge.app

import android.app.Activity
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter plugin for managing the background streaming service.
 * Allows camera and WebView to continue running when app is in background.
 */
class StreamingServicePlugin(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    private val methodChannel = MethodChannel(messenger, "com.specbridge/streaming_service")

    init {
        methodChannel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startService" -> startService(result)
            "stopService" -> stopService(result)
            "isServiceRunning" -> result.success(StreamingForegroundService.isServiceRunning())
            else -> result.notImplemented()
        }
    }

    private fun startService(result: MethodChannel.Result) {
        try {
            val intent = Intent(activity, StreamingForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent)
            } else {
                activity.startService(intent)
            }
            android.util.Log.d("StreamingServicePlugin", "Foreground service started")
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("StreamingServicePlugin", "Failed to start service: ${e.message}")
            result.error("START_FAILED", e.message, null)
        }
    }

    private fun stopService(result: MethodChannel.Result) {
        try {
            val intent = Intent(activity, StreamingForegroundService::class.java)
            activity.stopService(intent)
            android.util.Log.d("StreamingServicePlugin", "Foreground service stopped")
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("StreamingServicePlugin", "Failed to stop service: ${e.message}")
            result.error("STOP_FAILED", e.message, null)
        }
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
    }
}
