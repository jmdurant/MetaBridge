package com.specbridge.app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter plugin for managing Bluetooth audio routing.
 * Supports routing audio to Meta glasses via Bluetooth HFP/SCO.
 */
class BluetoothAudioPlugin(
    private val context: Context,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "BluetoothAudioPlugin"
        private const val METHOD_CHANNEL = "com.specbridge/bluetooth_audio"
        private const val EVENT_CHANNEL = "com.specbridge/bluetooth_audio_events"
    }

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager?.adapter

    private var eventSink: EventChannel.EventSink? = null
    private var bluetoothReceiver: BroadcastReceiver? = null

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAvailableDevices" -> getAvailableDevices(result)
            "setAudioDevice" -> {
                val deviceId = call.argument<String>("deviceId")
                if (deviceId != null) {
                    setAudioDevice(deviceId, result)
                } else {
                    result.error("INVALID_ARGUMENT", "deviceId is required", null)
                }
            }
            "clearAudioDevice" -> clearAudioDevice(result)
            "isBluetoothAudioActive" -> isBluetoothAudioActive(result)
            else -> result.notImplemented()
        }
    }

    private fun getAvailableDevices(result: MethodChannel.Result) {
        try {
            val devices = mutableListOf<Map<String, Any>>()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+ - use getAvailableCommunicationDevices
                val commDevices = audioManager.availableCommunicationDevices
                for (device in commDevices) {
                    if (isBluetoothDevice(device)) {
                        devices.add(mapOf(
                            "id" to device.id.toString(),
                            "name" to (device.productName?.toString() ?: "Bluetooth Device"),
                            "type" to getBluetoothType(device),
                            "isConnected" to true
                        ))
                    }
                }
            } else {
                // Fallback for older Android versions
                val audioDevices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
                for (device in audioDevices) {
                    if (isBluetoothDevice(device)) {
                        devices.add(mapOf(
                            "id" to device.id.toString(),
                            "name" to (device.productName?.toString() ?: "Bluetooth Device"),
                            "type" to getBluetoothType(device),
                            "isConnected" to true
                        ))
                    }
                }
            }

            result.success(devices)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get available devices", e)
            result.error("GET_DEVICES_ERROR", e.message, null)
        }
    }

    private fun setAudioDevice(deviceId: String, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+ - use setCommunicationDevice
                val device = audioManager.availableCommunicationDevices
                    .find { it.id.toString() == deviceId }

                if (device != null) {
                    val success = audioManager.setCommunicationDevice(device)
                    Log.d(TAG, "setCommunicationDevice result: $success for ${device.productName}")
                    result.success(success)
                } else {
                    result.success(false)
                }
            } else {
                // Legacy - use startBluetoothSco
                @Suppress("DEPRECATION")
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true
                result.success(true)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set audio device", e)
            result.error("SET_DEVICE_ERROR", e.message, null)
        }
    }

    private fun clearAudioDevice(result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
            }
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear audio device", e)
            result.error("CLEAR_DEVICE_ERROR", e.message, null)
        }
    }

    private fun isBluetoothAudioActive(result: MethodChannel.Result) {
        try {
            val isActive = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val commDevice = audioManager.communicationDevice
                commDevice != null && isBluetoothDevice(commDevice)
            } else {
                audioManager.isBluetoothScoOn
            }
            result.success(isActive)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to check Bluetooth audio status", e)
            result.error("CHECK_STATUS_ERROR", e.message, null)
        }
    }

    private fun isBluetoothDevice(device: AudioDeviceInfo): Boolean {
        return device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        device.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
    }

    private fun getBluetoothType(device: AudioDeviceInfo): String {
        return when (device.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "hfp"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "a2dp"
            else -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    device.type == AudioDeviceInfo.TYPE_BLE_HEADSET) {
                    "ble"
                } else {
                    "unknown"
                }
            }
        }
    }

    // EventChannel.StreamHandler implementation
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        registerBluetoothReceiver()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        unregisterBluetoothReceiver()
    }

    private fun registerBluetoothReceiver() {
        if (bluetoothReceiver != null) return

        bluetoothReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    BluetoothDevice.ACTION_ACL_CONNECTED -> {
                        val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                        device?.let { sendDeviceConnectedEvent(it) }
                    }
                    BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                        val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                        device?.let { sendDeviceDisconnectedEvent(it) }
                    }
                    AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED -> {
                        val state = intent.getIntExtra(
                            AudioManager.EXTRA_SCO_AUDIO_STATE,
                            AudioManager.SCO_AUDIO_STATE_DISCONNECTED
                        )
                        sendRouteChangedEvent(state == AudioManager.SCO_AUDIO_STATE_CONNECTED)
                    }
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(bluetoothReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(bluetoothReceiver, filter)
        }
    }

    private fun unregisterBluetoothReceiver() {
        bluetoothReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to unregister receiver", e)
            }
            bluetoothReceiver = null
        }
    }

    private fun sendDeviceConnectedEvent(device: BluetoothDevice) {
        eventSink?.success(mapOf(
            "type" to "connected",
            "device" to mapOf(
                "id" to device.address,
                "name" to (device.name ?: "Unknown Device"),
                "type" to "hfp",
                "isConnected" to true
            )
        ))
    }

    private fun sendDeviceDisconnectedEvent(device: BluetoothDevice) {
        eventSink?.success(mapOf(
            "type" to "disconnected",
            "deviceId" to device.address
        ))
    }

    private fun sendRouteChangedEvent(isBluetoothActive: Boolean) {
        val activeDeviceId = if (isBluetoothActive && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.communicationDevice?.id?.toString()
        } else {
            null
        }

        eventSink?.success(mapOf(
            "type" to "routeChanged",
            "activeDeviceId" to activeDeviceId
        ))
    }

    fun dispose() {
        unregisterBluetoothReceiver()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }
}
