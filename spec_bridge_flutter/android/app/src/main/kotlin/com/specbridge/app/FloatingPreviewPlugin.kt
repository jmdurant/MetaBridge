package com.specbridge.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter plugin for managing the floating preview overlay.
 * Handles overlay permission and service lifecycle.
 */
class FloatingPreviewPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    private val methodChannel = MethodChannel(messenger, "com.specbridge/floating_preview")

    companion object {
        const val OVERLAY_PERMISSION_REQUEST_CODE = 5469
    }

    init {
        methodChannel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkOverlayPermission" -> checkOverlayPermission(result)
            "requestOverlayPermission" -> requestOverlayPermission(result)
            "startOverlay" -> startOverlay(result)
            "stopOverlay" -> stopOverlay(result)
            "isOverlayRunning" -> result.success(FloatingPreviewService.isRunning())
            else -> result.notImplemented()
        }
    }

    private fun checkOverlayPermission(result: MethodChannel.Result) {
        val hasPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(activity)
        } else {
            true // Permission not needed below Android M
        }
        result.success(hasPermission)
    }

    private fun requestOverlayPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(activity)) {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:${activity.packageName}")
                )
                activity.startActivityForResult(intent, OVERLAY_PERMISSION_REQUEST_CODE)
                // Result will be checked when user returns to app
                result.success(false)
            } else {
                result.success(true)
            }
        } else {
            result.success(true)
        }
    }

    private fun startOverlay(result: MethodChannel.Result) {
        // Check permission first
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(activity)) {
            result.error("NO_PERMISSION", "Overlay permission not granted", null)
            return
        }

        try {
            val intent = Intent(activity, FloatingPreviewService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                activity.startForegroundService(intent)
            } else {
                activity.startService(intent)
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("START_FAILED", e.message, null)
        }
    }

    private fun stopOverlay(result: MethodChannel.Result) {
        try {
            val intent = Intent(activity, FloatingPreviewService::class.java)
            activity.stopService(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("STOP_FAILED", e.message, null)
        }
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
    }
}
