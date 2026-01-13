package com.specbridge.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import androidx.core.app.NotificationCompat

/**
 * Service that displays a floating preview overlay on top of other apps.
 * Uses SurfaceView for efficient video rendering.
 * This allows MediaProjection to capture our camera/glasses frames
 * when the user shares "Entire screen" during screen share.
 */
class FloatingPreviewService : Service(), SurfaceHolder.Callback {

    private var windowManager: WindowManager? = null
    private var surfaceView: SurfaceView? = null
    private var surfaceHolder: SurfaceHolder? = null
    @Volatile
    private var isSurfaceReady = false
    private val handler = Handler(Looper.getMainLooper())
    private val renderLock = Object()

    // For frame rendering
    private var currentBitmap: Bitmap? = null
    private var reusableBitmap: Bitmap? = null
    private val bitmapOptions = BitmapFactory.Options().apply {
        inMutable = true // Allow bitmap reuse
        inPreferredConfig = Bitmap.Config.RGB_565 // Less memory than ARGB_8888
    }
    private val paint = Paint().apply {
        isFilterBitmap = true
        isDither = false
        isAntiAlias = false // Faster
    }
    private var cachedDestRect: Rect? = null
    private var lastSurfaceWidth = 0
    private var lastSurfaceHeight = 0
    private var frameCount = 0L

    companion object {
        private const val CHANNEL_ID = "floating_preview_channel"
        private const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.specbridge.app.STOP_OVERLAY"

        @Volatile
        private var instance: FloatingPreviewService? = null

        fun getInstance(): FloatingPreviewService? = instance

        fun updateFrame(jpegData: ByteArray) {
            instance?.displayFrame(jpegData)
        }

        fun isRunning(): Boolean = instance != null
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())
        createOverlayView()
    }

    override fun onDestroy() {
        super.onDestroy()
        removeOverlayView()
        currentBitmap?.recycle()
        currentBitmap = null
        reusableBitmap?.recycle()
        reusableBitmap = null
        cachedDestRect = null
        instance = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Handle stop action from notification
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Camera Preview",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows camera preview for screen sharing"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        // Create stop action intent
        val stopIntent = Intent(this, FloatingPreviewService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SpecBridge")
            .setContentText("Camera preview active - share entire screen")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPendingIntent)
            .build()
    }

    private fun createOverlayView() {
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager

        // Create SurfaceView for efficient video rendering
        surfaceView = SurfaceView(this).apply {
            setBackgroundColor(Color.BLACK)
            setZOrderOnTop(true) // Required for surface to render on top
            holder.setFormat(PixelFormat.OPAQUE) // Fully opaque surface
            holder.addCallback(this@FloatingPreviewService)
            // Explicitly disable touch handling on the view itself
            isClickable = false
            isFocusable = false
            isLongClickable = false
        }

        // Window parameters - fullscreen overlay, fully opaque
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE,
            // Flags: not focusable, not touchable (pass through ALL touches)
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_FULLSCREEN,
            PixelFormat.OPAQUE
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }

        try {
            windowManager?.addView(surfaceView, params)
            android.util.Log.d("FloatingPreview", "SurfaceView overlay created")
        } catch (e: Exception) {
            android.util.Log.e("FloatingPreview", "Failed to create overlay: ${e.message}")
        }
    }

    private fun removeOverlayView() {
        try {
            surfaceView?.let { view ->
                view.holder.removeCallback(this)
                windowManager?.removeView(view)
            }
        } catch (e: Exception) {
            // Ignore removal errors
        }
        surfaceView = null
        surfaceHolder = null
        windowManager = null
        isSurfaceReady = false
    }

    // SurfaceHolder.Callback implementation
    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceHolder = holder
        isSurfaceReady = true
        android.util.Log.d("FloatingPreview", "Surface created and ready")

        // Draw initial black frame
        drawBlackFrame()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        android.util.Log.d("FloatingPreview", "Surface changed: ${width}x${height}")
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        isSurfaceReady = false
        surfaceHolder = null
        android.util.Log.d("FloatingPreview", "Surface destroyed")
    }

    private fun drawBlackFrame() {
        if (!isSurfaceReady) return

        try {
            val canvas = surfaceHolder?.lockCanvas() ?: return
            canvas.drawColor(Color.BLACK)
            surfaceHolder?.unlockCanvasAndPost(canvas)
        } catch (e: Exception) {
            android.util.Log.e("FloatingPreview", "Failed to draw black frame: ${e.message}")
        }
    }

    private fun displayFrame(jpegData: ByteArray) {
        if (!isSurfaceReady) return

        synchronized(renderLock) {
            val holder = surfaceHolder ?: return
            var canvas: Canvas? = null

            try {
                frameCount++

                // Try to reuse existing bitmap to reduce allocations
                bitmapOptions.inBitmap = reusableBitmap

                // Decode JPEG to bitmap (reusing memory if possible)
                val newBitmap = try {
                    BitmapFactory.decodeByteArray(jpegData, 0, jpegData.size, bitmapOptions)
                } catch (e: IllegalArgumentException) {
                    // Bitmap reuse failed (size mismatch), decode without reuse
                    bitmapOptions.inBitmap = null
                    BitmapFactory.decodeByteArray(jpegData, 0, jpegData.size, bitmapOptions)
                }

                if (newBitmap == null) {
                    return
                }

                // Lock canvas
                canvas = holder.lockCanvas()
                if (canvas == null) {
                    // Don't recycle - we'll reuse it next frame
                    reusableBitmap = newBitmap
                    return
                }

                val surfaceWidth = canvas.width
                val surfaceHeight = canvas.height

                // Only recalculate dest rect if surface size changed
                if (surfaceWidth != lastSurfaceWidth || surfaceHeight != lastSurfaceHeight || cachedDestRect == null) {
                    val bitmapWidth = newBitmap.width
                    val bitmapHeight = newBitmap.height

                    val scale = maxOf(
                        surfaceWidth.toFloat() / bitmapWidth,
                        surfaceHeight.toFloat() / bitmapHeight
                    )

                    val scaledWidth = (bitmapWidth * scale).toInt()
                    val scaledHeight = (bitmapHeight * scale).toInt()
                    val left = (surfaceWidth - scaledWidth) / 2
                    val top = (surfaceHeight - scaledHeight) / 2

                    cachedDestRect = Rect(left, top, left + scaledWidth, top + scaledHeight)
                    lastSurfaceWidth = surfaceWidth
                    lastSurfaceHeight = surfaceHeight
                }

                // Fill with black first (only needed if image doesn't cover full screen)
                canvas.drawColor(Color.BLACK)

                // Draw bitmap
                canvas.drawBitmap(newBitmap, null, cachedDestRect!!, paint)

                // Save for reuse next frame
                reusableBitmap = newBitmap
                currentBitmap = newBitmap

            } catch (e: Exception) {
                // Ignore rendering errors
            } finally {
                // Always unlock canvas if we locked it
                if (canvas != null) {
                    try {
                        holder.unlockCanvasAndPost(canvas)
                    } catch (e: Exception) {
                        // Surface may have been destroyed
                    }
                }
            }
        }
    }
}
