package com.specbridge.app

import android.content.Context
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.RegistrationState
import com.meta.wearable.dat.core.types.DeviceIdentifier
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.selectors.DeviceSelector
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
 * Manager for Meta Wearables SDK interactions on Android
 * Based on the official CameraAccess sample app
 */
class MetaWearablesManager(private val context: Context) {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _hasActiveDevice = MutableStateFlow(false)
    val hasActiveDevice: StateFlow<Boolean> = _hasActiveDevice.asStateFlow()

    private var isConfigured = false

    // AutoDeviceSelector automatically selects the first available wearable device
    val deviceSelector: DeviceSelector = AutoDeviceSelector()

    // MARK: - Configuration

    fun configure(): Boolean {
        return try {
            // Initialize the SDK - must be called before any other Wearables APIs
            Wearables.initialize(context)
            isConfigured = true

            // Observe registration state
            scope.launch {
                Wearables.registrationState.collect { state ->
                    _connectionState.value = when (state) {
                        is RegistrationState.Registered -> ConnectionState.CONNECTED
                        is RegistrationState.Registering -> ConnectionState.CONNECTING
                        is RegistrationState.Unavailable -> ConnectionState.DISCONNECTED
                        else -> ConnectionState.DISCONNECTED
                    }
                }
            }

            // Observe available devices via device selector
            scope.launch {
                deviceSelector.activeDevice(Wearables.devices).collect { device ->
                    _hasActiveDevice.value = device != null
                }
            }

            true
        } catch (e: Exception) {
            false
        }
    }

    // MARK: - Registration

    fun startRegistration(): Boolean {
        if (!isConfigured) return false

        return try {
            _connectionState.value = ConnectionState.CONNECTING
            Wearables.startRegistration(context)
            true
        } catch (e: Exception) {
            _connectionState.value = ConnectionState.ERROR
            false
        }
    }

    fun handleCallback(url: String): Boolean {
        // On Android, the callback is handled automatically by the SDK
        // when the Meta AI app returns. This method is for compatibility
        // with the iOS implementation.
        return _connectionState.value == ConnectionState.CONNECTED
    }

    // MARK: - Camera Permissions

    suspend fun checkCameraPermission(): String {
        return try {
            val result = Wearables.checkPermissionStatus(Permission.CAMERA)
            result.getOrNull()?.let { status ->
                when (status) {
                    PermissionStatus.Granted -> "granted"
                    PermissionStatus.Denied -> "denied"
                }
            } ?: "unknown"
        } catch (e: Exception) {
            "unknown"
        }
    }

    // Note: Full permission request requires ActivityResultLauncher setup in MainActivity
    // This is a simplified version that returns current status
    suspend fun requestCameraPermission(): String {
        // In a full implementation, this would use Wearables.RequestPermissionContract()
        // with an ActivityResultLauncher. For now, just return current status.
        return checkCameraPermission()
    }

    // MARK: - Cleanup

    fun disconnect() {
        try {
            Wearables.startUnregistration(context)
        } catch (e: Exception) {
            // Ignore unregistration errors
        }
        _connectionState.value = ConnectionState.DISCONNECTED
    }
}
