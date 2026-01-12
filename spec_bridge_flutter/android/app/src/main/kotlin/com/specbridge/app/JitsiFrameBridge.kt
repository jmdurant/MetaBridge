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
import java.nio.charset.StandardCharsets

/**
 * Bridge for injecting video frames into Jitsi screen share on Android
 * Uses Unix domain socket to communicate with Jitsi SDK's broadcast upload mechanism
 *
 * Frame format matches iOS SampleUploader: HTTP/1.1 response with JPEG body
 */
class JitsiFrameBridge(private val context: Context) {

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var socket: LocalSocket? = null
    private var outputStream: OutputStream? = null

    @Volatile
    private var isConnected = false

    @Volatile
    private var isReady = true

    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 5

    // Default orientation (up)
    private val defaultOrientation = 1

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
            isReady = true
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
        isReady = true
    }

    // MARK: - Frame Injection

    fun sendFrame(jpegData: ByteArray) {
        if (!isConnected || !isReady) {
            // Try to reconnect if not connected
            if (!isConnected && reconnectAttempts < maxReconnectAttempts) {
                connect()
            }
            return
        }

        isReady = false

        scope.launch {
            sendFrameInternal(jpegData)
        }
    }

    private fun sendFrameInternal(jpegData: ByteArray) {
        try {
            // Build HTTP response message (matching iOS CFHTTPMessageCreateResponse format)
            val message = buildHttpResponse(jpegData)

            outputStream?.let { stream ->
                stream.write(message)
                stream.flush()
            }

            isReady = true
        } catch (e: Exception) {
            android.util.Log.e("JitsiFrameBridge", "Frame send failed: ${e.message}")
            isConnected = false
            isReady = true

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

    /**
     * Build HTTP/1.1 response message matching iOS CFHTTPMessageCreateResponse format
     *
     * Format:
     * HTTP/1.1 200 OK\r\n
     * Content-Length: <size>\r\n
     * Buffer-Orientation: <orientation>\r\n
     * \r\n
     * <jpeg-data>
     */
    private fun buildHttpResponse(jpegData: ByteArray): ByteArray {
        val headers = StringBuilder()
            .append("HTTP/1.1 200 OK\r\n")
            .append("Content-Length: ${jpegData.size}\r\n")
            .append("Buffer-Orientation: $defaultOrientation\r\n")
            .append("\r\n")
            .toString()

        val headerBytes = headers.toByteArray(StandardCharsets.UTF_8)

        // Combine headers and body
        val message = ByteArray(headerBytes.size + jpegData.size)
        System.arraycopy(headerBytes, 0, message, 0, headerBytes.size)
        System.arraycopy(jpegData, 0, message, headerBytes.size, jpegData.size)

        return message
    }

    // MARK: - Cleanup

    fun dispose() {
        disconnectInternal()
        scope.cancel()
    }
}
