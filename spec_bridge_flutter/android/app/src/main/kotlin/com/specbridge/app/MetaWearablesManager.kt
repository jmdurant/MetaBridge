package com.specbridge.app

import android.content.Context
import com.meta.wearable.Wearables
import com.meta.wearable.Permission
import com.meta.wearable.RegistrationState
import com.meta.wearable.Device
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
 */
class MetaWearablesManager(private val context: Context) {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    private val _connectionState = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private var isConfigured = false
    private var currentDevice: Device? = null

    // MARK: - Configuration

    suspend fun configure(): Boolean {
        return try {
            // Initialize the SDK
            Wearables.initialize(context)
            isConfigured = true

            // Observe registration state
            scope.launch {
                Wearables.registrationState.collect { state ->
                    _connectionState.value = when (state) {
                        RegistrationState.REGISTERED -> ConnectionState.CONNECTED
                        RegistrationState.REGISTERING -> ConnectionState.CONNECTING
                        RegistrationState.UNREGISTERED -> ConnectionState.DISCONNECTED
                        else -> ConnectionState.DISCONNECTED
                    }
                }
            }

            // Observe available devices
            scope.launch {
                Wearables.devices.collect { devices ->
                    currentDevice = devices.firstOrNull()
                }
            }

            true
        } catch (e: Exception) {
            false
        }
    }

    // MARK: - Registration

    suspend fun startRegistration(): Boolean {
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

    suspend fun handleCallback(url: String): Boolean {
        // On Android, the callback is handled automatically by the SDK
        // when the Meta AI app returns. This method is for compatibility
        // with the iOS implementation.
        return _connectionState.value == ConnectionState.CONNECTED
    }

    // MARK: - Camera Permissions

    suspend fun checkCameraPermission(): String {
        return try {
            val status = Wearables.checkPermissionStatus(Permission.CAMERA)
            when {
                status.isGranted -> "granted"
                status.isDenied -> "denied"
                else -> "notDetermined"
            }
        } catch (e: Exception) {
            "unknown"
        }
    }

    suspend fun requestCameraPermission(): String {
        return try {
            // Use the RequestPermissionContract for camera permission
            val contract = Wearables.RequestPermissionContract()
            // Note: This requires ActivityResultLauncher setup in the activity
            // For now, return the current status
            checkCameraPermission()
        } catch (e: Exception) {
            "denied"
        }
    }

    // MARK: - Streaming

    fun getDevice(): Device? = currentDevice

    // MARK: - Cleanup

    fun disconnect() {
        scope.launch {
            try {
                Wearables.startUnregistration(context)
            } catch (e: Exception) {
                // Ignore unregistration errors
            }
        }
        _connectionState.value = ConnectionState.DISCONNECTED
    }
}
