package com.specbridge.app

import org.java_websocket.WebSocket
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.server.WebSocketServer
import java.net.InetSocketAddress
import java.nio.ByteBuffer

/**
 * Native WebSocket server for streaming video frames directly to WebView
 *
 * This bypasses Flutter's EventChannel and UI thread entirely, sending
 * raw binary frames directly from Kotlin to the WebView's JavaScript.
 *
 * Port 8766 (Flutter's FrameWebSocketServer uses 8765)
 */
class NativeFrameServer(port: Int = DEFAULT_PORT) : WebSocketServer(InetSocketAddress(port)) {

    companion object {
        const val DEFAULT_PORT = 8766
        private const val TAG = "NativeFrameServer"
    }

    @Volatile
    private var connectedClient: WebSocket? = null

    @Volatile
    private var isRunning = false

    private var framesSent = 0L
    private var framesDropped = 0L

    val hasClient: Boolean
        get() = connectedClient != null && connectedClient!!.isOpen

    // MARK: - WebSocketServer overrides

    override fun onOpen(conn: WebSocket, handshake: ClientHandshake) {
        android.util.Log.d(TAG, "Client connected from ${conn.remoteSocketAddress}")

        // Close any existing client
        connectedClient?.close()
        connectedClient = conn
    }

    override fun onClose(conn: WebSocket, code: Int, reason: String, remote: Boolean) {
        android.util.Log.d(TAG, "Client disconnected: code=$code reason=$reason")

        if (connectedClient == conn) {
            connectedClient = null
        }
    }

    override fun onMessage(conn: WebSocket, message: String) {
        // We don't expect text messages, but log if received
        android.util.Log.d(TAG, "Received text message: $message")
    }

    override fun onMessage(conn: WebSocket, message: ByteBuffer) {
        // We don't expect binary messages from client
        android.util.Log.d(TAG, "Received binary message: ${message.remaining()} bytes")
    }

    override fun onError(conn: WebSocket?, ex: Exception) {
        android.util.Log.e(TAG, "WebSocket error: ${ex.message}", ex)
    }

    override fun onStart() {
        android.util.Log.d(TAG, "Server started on port $port")
        isRunning = true
        connectionLostTimeout = 0 // Disable ping timeout
    }

    // MARK: - Frame sending

    /**
     * Send a frame to the connected client
     *
     * @param frameData Raw binary data (I420 with 8-byte header)
     * @return true if sent, false if no client or error
     */
    fun sendFrame(frameData: ByteArray): Boolean {
        val client = connectedClient

        if (client == null || !client.isOpen) {
            framesDropped++
            return false
        }

        return try {
            client.send(frameData)
            framesSent++

            if (framesSent == 1L) {
                android.util.Log.d(TAG, "Sent first frame (${frameData.size} bytes)")
            }
            if (framesSent % 100 == 0L) {
                android.util.Log.d(TAG, "Sent $framesSent frames, dropped $framesDropped")
            }

            true
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Send error: ${e.message}")
            framesDropped++
            false
        }
    }

    // MARK: - Lifecycle

    fun startServer() {
        if (isRunning) {
            android.util.Log.d(TAG, "Server already running")
            return
        }

        try {
            start()
            android.util.Log.d(TAG, "Starting server on port $port")
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Failed to start server: ${e.message}", e)
        }
    }

    fun stopServer() {
        if (!isRunning) return

        try {
            android.util.Log.d(TAG, "Stopping server...")
            stop()
            isRunning = false
            connectedClient = null
            android.util.Log.d(TAG, "Server stopped")
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Error stopping server: ${e.message}", e)
        }
    }

    fun getStats(): Map<String, Any> {
        return mapOf(
            "isRunning" to isRunning,
            "hasClient" to hasClient,
            "port" to port,
            "framesSent" to framesSent,
            "framesDropped" to framesDropped
        )
    }

    /**
     * Reset client state for clean session transition.
     * Closes any existing client and resets frame counters.
     */
    fun resetClient() {
        android.util.Log.d(TAG, "Resetting client state (framesSent=$framesSent, framesDropped=$framesDropped)")
        try {
            connectedClient?.close()
        } catch (e: Exception) {
            android.util.Log.w(TAG, "Error closing client during reset: ${e.message}")
        }
        connectedClient = null
        framesSent = 0L
        framesDropped = 0L
        android.util.Log.d(TAG, "Client state reset complete")
    }
}
