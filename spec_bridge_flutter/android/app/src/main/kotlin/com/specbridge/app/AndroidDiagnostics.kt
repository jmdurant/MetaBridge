package com.specbridge.app

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

/** Read-only system observations. Never changes the audio route or records audio. */
internal object AndroidDiagnostics {
    fun snapshot(context: Context): Map<String, Any?> {
        val stats = mutableMapOf<String, Any?>(
            "platform" to "android",
            "phoneModel" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "androidVersion" to Build.VERSION.RELEASE,
            "androidApiLevel" to Build.VERSION.SDK_INT,
            "metaDatVersion" to BuildConfig.META_DAT_VERSION
        )
        try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            stats["appVersion"] = info.versionName
            stats["appBuild"] = info.longVersionCode
        } catch (_: Exception) { /* Report absent metadata as unknown. */ }
        try {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val device = audio.communicationDevice // App minimum is Android 12 / API 31.
            stats["audioRouteObserved"] = true
            stats["audioMode"] = when (audio.mode) {
                AudioManager.MODE_NORMAL -> "normal"
                AudioManager.MODE_IN_COMMUNICATION -> "inCommunication"
                AudioManager.MODE_IN_CALL -> "inCall"
                AudioManager.MODE_RINGTONE -> "ringtone"
                else -> "other"
            }
            stats["communicationDeviceType"] = when (device?.type) {
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speakerphone"
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetoothSco"
                AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetoothLeHeadset"
                AudioDeviceInfo.TYPE_BLE_SPEAKER -> "bluetoothLeSpeaker"
                AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wiredHeadset"
                AudioDeviceInfo.TYPE_USB_HEADSET -> "usbHeadset"
                null -> null
                else -> "other"
            }
            // Selection is observable; it does not prove which microphone WebRTC captures.
            stats["bluetoothCommunicationSelected"] = device?.let {
                it.type in setOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                    AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER)
            }
        } catch (_: Exception) {
            stats["audioRouteObserved"] = false
        }
        return stats
    }
}
