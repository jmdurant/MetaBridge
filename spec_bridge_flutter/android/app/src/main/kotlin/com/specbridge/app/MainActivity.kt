package com.specbridge.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.result.ActivityResultLauncher
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class MainActivity : FlutterFragmentActivity() {
    private lateinit var metaWearablesPlugin: MetaWearablesPlugin
    private lateinit var bluetoothAudioPlugin: BluetoothAudioPlugin
    private lateinit var floatingPreviewPlugin: FloatingPreviewPlugin
    private lateinit var streamingServicePlugin: StreamingServicePlugin

    // Wearables permission request handling
    private var permissionContinuation: CancellableContinuation<PermissionStatus>? = null
    private val permissionMutex = Mutex()
    private lateinit var wearablesPermissionLauncher: ActivityResultLauncher<Permission>

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize Meta Wearables Plugin with reference to this activity for permissions
        metaWearablesPlugin = MetaWearablesPlugin(this, flutterEngine.dartExecutor.binaryMessenger)

        // Initialize Bluetooth Audio Plugin
        bluetoothAudioPlugin = BluetoothAudioPlugin(this, flutterEngine.dartExecutor.binaryMessenger)

        // Initialize Floating Preview Plugin
        floatingPreviewPlugin = FloatingPreviewPlugin(this, flutterEngine.dartExecutor.binaryMessenger)

        // Initialize Streaming Service Plugin (for background mode)
        streamingServicePlugin = StreamingServicePlugin(this, flutterEngine.dartExecutor.binaryMessenger)

        // Register the wearables permission launcher
        // Must be done before onStart(), configureFlutterEngine is called during onCreate
        wearablesPermissionLauncher = registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
            val permissionStatus = result.getOrDefault(PermissionStatus.Denied)
            permissionContinuation?.resume(permissionStatus)
            permissionContinuation = null
        }
    }

    // Request wearable device permission (e.g., camera) via Meta AI app
    suspend fun requestWearablesPermission(permission: Permission): PermissionStatus {
        return permissionMutex.withLock {
            suspendCancellableCoroutine { continuation ->
                permissionContinuation = continuation
                continuation.invokeOnCancellation { permissionContinuation = null }
                wearablesPermissionLauncher.launch(permission)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Handle initial deep link
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        intent?.data?.let { uri ->
            if (uri.scheme == "specbridge") {
                metaWearablesPlugin.handleIncomingUrl(uri.toString())
            }
        }
    }

    override fun onDestroy() {
        metaWearablesPlugin.dispose()
        bluetoothAudioPlugin.dispose()
        floatingPreviewPlugin.dispose()
        streamingServicePlugin.dispose()
        super.onDestroy()
    }
}
