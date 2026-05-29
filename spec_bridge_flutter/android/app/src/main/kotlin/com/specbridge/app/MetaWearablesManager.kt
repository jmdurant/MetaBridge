package com.specbridge.app

import android.app.Activity
import android.content.Context
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.RegistrationState
import com.meta.wearable.dat.core.types.DeviceCompatibility
import com.meta.wearable.dat.core.types.DeviceIdentifier
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.selectors.DeviceSelector
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Connection state for glasses
 */
enum class ConnectionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    ERROR
}

/**
 * Manager for Meta Wearables SDK interactions on Android.
 *
 * Migrated to Meta Wearables DAT SDK 0.7.0. Key changes vs the old 0.3.0 surface:
 *  - `RegistrationState` is now a plain enum (REGISTERED/REGISTERING/...) instead of a sealed class.
 *  - `DeviceSelector.activeDevice(devices)` is now `DeviceSelector.activeDeviceFlow()`.
 *  - `startRegistration` / `startUnregistration` take an Activity (not a Context).
 *  - Device compatibility is observed via `Wearables.devicesMetadata[id]` so we can surface a
 *    firmware-update prompt for older glasses (e.g. Ray-Ban Meta Gen 1) instead of failing silently.
 *
 * Based on the official CameraAccess sample app (samples/CameraAccess WearablesViewModel).
 */
class MetaWearablesManager(private val activity: Activity) {

    private val context: Context = activity.applicationContext

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _hasActiveDevice = MutableStateFlow(false)
    val hasActiveDevice: StateFlow<Boolean> = _hasActiveDevice.asStateFlow()

    // True when any linked device reports DeviceCompatibility.DEVICE_UPDATE_REQUIRED.
    // The plugin surfaces this to Flutter so the UI can offer a firmware-update action.
    // Important for the older Ray-Ban Meta (Gen 1) which may lag behind on firmware.
    private val _firmwareUpdateRequired = MutableStateFlow(false)
    val firmwareUpdateRequired: StateFlow<Boolean> = _firmwareUpdateRequired.asStateFlow()

    private var isConfigured = false

    // AutoDeviceSelector automatically selects the first available wearable device.
    // NOTE: deliberately NOT filtering on isDisplayCapable() — that would exclude every
    // camera-only glasses (Gen 1, Gen 2, Optics). We only need camera streaming here.
    //
    // MUST be lazy: in SDK 0.7.0 the AutoDeviceSelector constructor eagerly touches the
    // Wearables singleton, which throws "Wearables not initialized" if created before
    // configure() calls Wearables.initialize(). Lazy defers creation to first use (inside
    // configure(), after initialize()), so the required ordering holds. (0.3.0 tolerated
    // eager construction; 0.7.0 does not.)
    val deviceSelector: DeviceSelector by lazy { AutoDeviceSelector() }

    // Per-device compatibility monitoring jobs and latest known compatibility.
    private val deviceMonitoringJobs = mutableMapOf<DeviceIdentifier, Job>()
    private val deviceCompatibility = mutableMapOf<DeviceIdentifier, DeviceCompatibility>()

    // MARK: - Configuration

    fun configure(): Boolean {
        return try {
            android.util.Log.d("MetaWearablesManager", "configure() entered; calling Wearables.initialize")
            // Initialize the SDK - must be called before any other Wearables APIs
            Wearables.initialize(context)
            android.util.Log.d("MetaWearablesManager", "Wearables.initialize OK")
            isConfigured = true

            // Observe registration state (now a plain enum in 0.6.0+)
            scope.launch {
                Wearables.registrationState.collect { state ->
                    android.util.Log.d("MetaWearablesManager", "registrationState = $state")
                    _connectionState.value = when (state) {
                        RegistrationState.REGISTERED -> ConnectionState.CONNECTED
                        RegistrationState.REGISTERING -> ConnectionState.CONNECTING
                        RegistrationState.UNREGISTERING -> ConnectionState.CONNECTING
                        RegistrationState.AVAILABLE -> ConnectionState.DISCONNECTED
                        RegistrationState.UNAVAILABLE -> ConnectionState.DISCONNECTED
                    }
                }
            }

            // Observe registration errors. In 0.7.0 the error payload was moved OUT of
            // RegistrationState (now a plain enum) into this dedicated stream — without
            // observing it, a failed registration just silently hangs on "connecting".
            scope.launch {
                Wearables.registrationErrorStream.collect { error ->
                    android.util.Log.e("MetaWearablesManager", "registrationError = $error")
                    _connectionState.value = ConnectionState.ERROR
                }
            }

            // Observe the active device via the device selector (0.6.0+ flow API)
            scope.launch {
                deviceSelector.activeDeviceFlow().collect { device ->
                    _hasActiveDevice.value = device != null
                }
            }

            // Observe the set of linked devices and monitor each for compatibility/firmware state
            scope.launch {
                Wearables.devices.collect { devices ->
                    monitorDeviceCompatibility(devices)
                }
            }

            true
        } catch (e: Exception) {
            android.util.Log.e("MetaWearablesManager", "configure failed", e)
            false
        }
    }

    // MARK: - Device compatibility (multi-glasses-version support)

    /**
     * Start/stop per-device metadata monitoring as devices come and go, and recompute whether a
     * firmware update is required. Mirrors the CameraAccess sample's WearablesViewModel.
     */
    private fun monitorDeviceCompatibility(devices: Set<DeviceIdentifier>) {
        // Cancel monitoring for devices that disappeared
        val removed = deviceMonitoringJobs.keys - devices
        removed.forEach { id ->
            deviceMonitoringJobs[id]?.cancel()
            deviceMonitoringJobs.remove(id)
            deviceCompatibility.remove(id)
        }
        updateFirmwareUpdateRequired()

        // Start monitoring for newly-seen devices
        val added = devices - deviceMonitoringJobs.keys
        added.forEach { id ->
            val job = scope.launch {
                Wearables.devicesMetadata[id]?.collect { metadata ->
                    deviceCompatibility[id] = metadata.compatibility
                    updateFirmwareUpdateRequired()
                    if (metadata.compatibility == DeviceCompatibility.DEVICE_UPDATE_REQUIRED) {
                        android.util.Log.w(
                            "MetaWearablesManager",
                            "Device '${metadata.name.ifEmpty { id }}' requires a firmware/app update to stream"
                        )
                    }
                }
            }
            deviceMonitoringJobs[id] = job
        }
    }

    private fun updateFirmwareUpdateRequired() {
        _firmwareUpdateRequired.value =
            deviceCompatibility.values.any { it == DeviceCompatibility.DEVICE_UPDATE_REQUIRED }
    }

    /**
     * Open the Meta AI firmware-update screen for the connected device.
     * Call this when [firmwareUpdateRequired] is true (e.g. older Gen 1 glasses on stale firmware).
     */
    fun openFirmwareUpdate(): Boolean {
        return try {
            Wearables.openFirmwareUpdate(activity)
            true
        } catch (e: Exception) {
            android.util.Log.e("MetaWearablesManager", "openFirmwareUpdate failed", e)
            false
        }
    }

    // MARK: - Registration

    fun startRegistration(): Boolean {
        if (!isConfigured) return false

        return try {
            _connectionState.value = ConnectionState.CONNECTING
            // 0.4.0+: startRegistration takes an Activity (not a Context).
            // Note: 0.4.0+ shows the registration dialog in-place rather than jumping to Meta AI.
            android.util.Log.d("MetaWearablesManager", "Calling Wearables.startRegistration(activity)")
            Wearables.startRegistration(activity)
            android.util.Log.d("MetaWearablesManager", "Wearables.startRegistration returned (awaiting registrationState/registrationError)")
            true
        } catch (e: Exception) {
            android.util.Log.e("MetaWearablesManager", "startRegistration threw", e)
            _connectionState.value = ConnectionState.ERROR
            false
        }
    }

    fun handleCallback(url: String): Boolean {
        // On Android, the callback is handled automatically by the SDK when the Meta AI app
        // returns. This method exists for parity with the iOS implementation.
        return _connectionState.value == ConnectionState.CONNECTED
    }

    // MARK: - Camera Permissions

    suspend fun checkCameraPermission(): String {
        return try {
            val result = Wearables.checkPermissionStatus(Permission.CAMERA)
            when (result.getOrNull()) {
                PermissionStatus.Granted -> "granted"
                PermissionStatus.Denied -> "denied"
                null -> "unknown"
            }
        } catch (e: Exception) {
            "unknown"
        }
    }

    /**
     * Returns the current permission status. The interactive request is driven by
     * MainActivity.requestWearablesPermission() via Wearables.RequestPermissionContract();
     * this method just reports current status for callers that don't have an Activity launcher.
     */
    suspend fun requestCameraPermission(): String {
        return checkCameraPermission()
    }

    // MARK: - Cleanup

    fun disconnect() {
        try {
            // 0.4.0+: startUnregistration takes an Activity
            Wearables.startUnregistration(activity)
        } catch (e: Exception) {
            // Ignore unregistration errors
        }
        _connectionState.value = ConnectionState.DISCONNECTED
    }
}
