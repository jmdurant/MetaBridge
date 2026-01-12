package com.specbridge.app

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.OutputStream

/**
 * Bridge for injecting video frames into Jitsi screen share on Android
 * Uses Unix domain socket to communicate with Jitsi SDK's broadcast upload mechanism
 */
class JitsiFrameBridge(private val context: Context) {

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var socket: LocalSocket? = null
    private var outputStream: OutputStream? = null

    @Volatile
    private var isConnected = false

    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 5

    private var frameIndex: Long = 0
    private val boundary = "frame-boundary"

    // Socket path for Jitsi screen share
    private val socketPath: String by lazy {
        // Use the app's files directory for the socket
        "${context.filesDir.absolutePath}/rtc_SSFD"
    }

    // MARK: - Connection

    fun connect() {
        if (isConnected) return

        scope.launch {
            connectInternal()
        }
    }

    private suspend fun connectInternal() {
        try {
            // Close existing connection
            disconnectInternal()

            // Create Unix domain socket
            socket = LocalSocket().apply {
                connect(LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM))
            }

            outputStream = socket?.outputStream
            isConnected = true
            reconnectAttempts = 0

            android.util.Log.d("JitsiFrameBridge", "Socket connected")
        } catch (e: Exception) {
            android.util.Log.e("JitsiFrameBridge", "Socket connection failed: ${e.message}")
            isConnected = false

            // Attempt reconnection
            if (reconnectAttempts < maxReconnectAttempts) {
                reconnectAttempts++
                delay(1000)
                connectInternal()
            }
        }
    }

    fun disconnect() {
        scope.launch {
            disconnectInternal()
        }
    }

    private fun disconnectInternal() {
        try {
            outputStream?.close()
            socket?.close()
        } catch (e: Exception) {
            // Ignore close errors
        }

        outputStream = null
        socket = null
        isConnected = false
    }

    // MARK: - Frame Injection

    fun sendFrame(jpegData: ByteArray) {
        if (!isConnected) {
            // Try to reconnect
            if (reconnectAttempts < maxReconnectAttempts) {
                connect()
            }
            return
        }

        scope.launch {
            sendFrameInternal(jpegData)
        }
    }

    private fun sendFrameInternal(jpegData: ByteArray) {
        try {
            frameIndex++

            // Build HTTP-style multipart message
            val message = buildFrameMessage(jpegData)

            outputStream?.let { stream ->
                stream.write(message)
                stream.flush()
            }
        } catch (e: Exception) {
            android.util.Log.e("JitsiFrameBridge", "Frame send failed: ${e.message}")
            isConnected = false

            // Attempt reconnection
            if (reconnectAttempts < maxReconnectAttempts) {
                reconnectAttempts++
                scope.launch {
                    delay(1000)
                    connectInternal()
                }
            }
        }
    }

    private fun buildFrameMessage(jpegData: ByteArray): ByteArray {
        // Build HTTP-style multipart message
        // This format is what Jitsi's Broadcast Upload Extension expects

        val headers = """
            --$boundary
            Content-Type: image/jpeg
            Content-Length: ${jpegData.size}
            X-Frame-Index: $frameIndex
            X-Timestamp: ${System.currentTimeMillis() / 1000.0}

        """.trimIndent().replace("\n", "\r\n")

        val terminator = "\r\n"

        val headerBytes = headers.toByteArray(Charsets.UTF_8)
        val terminatorBytes = terminator.toByteArray(Charsets.UTF_8)

        // Combine all parts
        val message = ByteArray(headerBytes.size + jpegData.size + terminatorBytes.size)
        System.arraycopy(headerBytes, 0, message, 0, headerBytes.size)
        System.arraycopy(jpegData, 0, message, headerBytes.size, jpegData.size)
        System.arraycopy(terminatorBytes, 0, message, headerBytes.size + jpegData.size, terminatorBytes.size)

        return message
    }

    // MARK: - Cleanup

    fun dispose() {
        disconnectInternal()
        scope.cancel()
    }
}
