package com.specbridge.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.*
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import android.view.WindowManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.io.ByteArrayOutputStream

/**
 * Manages camera capture from phone cameras (front/back) for streaming
 * Uses Camera2 API for frame capture
 */
class CameraCaptureManager(private val context: Context) {

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null

    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private val _frameFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 1)
    val frameFlow: SharedFlow<ByteArray> = _frameFlow.asSharedFlow()

    var frameCount: Long = 0
        private set

    // Match iOS: 0.8 quality (80 in Android terms)
    private val jpegQuality = 80

    // Match iOS: 0.5x scaling for bandwidth optimization
    private val scaleFactor = 0.5f

    private var useFrontCamera = false
    private var targetWidth = 1280
    private var targetHeight = 720

    // MARK: - Public Methods

    fun startCapture(width: Int, height: Int, frameRate: Int, useFront: Boolean): Boolean {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.e("CameraCaptureManager", "Camera permission not granted")
            return false
        }

        useFrontCamera = useFront
        targetWidth = width
        targetHeight = height
        frameCount = 0

        startBackgroundThread()

        return try {
            openCamera()
            true
        } catch (e: Exception) {
            android.util.Log.e("CameraCaptureManager", "Failed to start capture: ${e.message}")
            false
        }
    }

    fun stopCapture() {
        try {
            captureSession?.close()
            captureSession = null

            cameraDevice?.close()
            cameraDevice = null

            imageReader?.close()
            imageReader = null

            stopBackgroundThread()
        } catch (e: Exception) {
            android.util.Log.e("CameraCaptureManager", "Error stopping capture: ${e.message}")
        }
    }

    // Get device rotation in degrees (0, 90, 180, 270)
    private fun getDeviceRotation(): Float {
        val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val rotation = windowManager.defaultDisplay.rotation
        return when (rotation) {
            Surface.ROTATION_0 -> 0f
            Surface.ROTATION_90 -> 90f
            Surface.ROTATION_180 -> 180f
            Surface.ROTATION_270 -> 270f
            else -> 0f
        }
    }

    // MARK: - Camera Setup

    private fun openCamera() {
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = getCameraId(cameraManager)

        if (cameraId == null) {
            android.util.Log.e("CameraCaptureManager", "No suitable camera found")
            return
        }

        // Set up ImageReader for YUV frames
        imageReader = ImageReader.newInstance(
            targetWidth, targetHeight,
            ImageFormat.YUV_420_888, 2
        ).apply {
            setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage()
                image?.let {
                    processImage(it)
                    it.close()
                }
            }, backgroundHandler)
        }

        try {
            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    createCaptureSession()
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    cameraDevice = null
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    cameraDevice = null
                    android.util.Log.e("CameraCaptureManager", "Camera error: $error")
                }
            }, backgroundHandler)
        } catch (e: SecurityException) {
            android.util.Log.e("CameraCaptureManager", "Camera permission denied: ${e.message}")
        }
    }

    private fun getCameraId(cameraManager: CameraManager): String? {
        val facing = if (useFrontCamera)
            CameraCharacteristics.LENS_FACING_FRONT
        else
            CameraCharacteristics.LENS_FACING_BACK

        return cameraManager.cameraIdList.firstOrNull { id ->
            val characteristics = cameraManager.getCameraCharacteristics(id)
            characteristics.get(CameraCharacteristics.LENS_FACING) == facing
        }
    }

    private fun createCaptureSession() {
        val camera = cameraDevice ?: return
        val reader = imageReader ?: return

        val surfaces = listOf(reader.surface)

        camera.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                captureSession = session
                startRepeatingCapture()
            }

            override fun onConfigureFailed(session: CameraCaptureSession) {
                android.util.Log.e("CameraCaptureManager", "Capture session configuration failed")
            }
        }, backgroundHandler)
    }

    private fun startRepeatingCapture() {
        val camera = cameraDevice ?: return
        val session = captureSession ?: return
        val reader = imageReader ?: return

        val captureRequest = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(reader.surface)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        }

        session.setRepeatingRequest(captureRequest.build(), null, backgroundHandler)
        android.util.Log.d("CameraCaptureManager", "Camera capture started")
    }

    // MARK: - Frame Processing

    private fun processImage(image: Image) {
        frameCount++

        try {
            // Convert YUV to NV21
            val nv21 = yuv420ToNv21(image)
            val yuvImage = YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)

            // Convert to JPEG at full resolution
            val fullResStream = ByteArrayOutputStream()
            yuvImage.compressToJpeg(Rect(0, 0, image.width, image.height), 100, fullResStream)
            val fullResJpeg = fullResStream.toByteArray()

            // Decode to bitmap
            val bitmap = BitmapFactory.decodeByteArray(fullResJpeg, 0, fullResJpeg.size)

            // Apply rotation based on device orientation
            val rotationMatrix = Matrix()
            val deviceRotation = getDeviceRotation()

            if (useFrontCamera) {
                // Front camera: rotate and mirror
                rotationMatrix.postRotate((270f + deviceRotation) % 360)
                rotationMatrix.postScale(-1f, 1f) // Mirror horizontally
            } else {
                // Back camera: subtract device rotation to compensate for landscape flip
                rotationMatrix.postRotate((90f + 360f - deviceRotation) % 360)
            }

            // Apply rotation first
            val rotatedBitmap = Bitmap.createBitmap(
                bitmap, 0, 0, bitmap.width, bitmap.height, rotationMatrix, true
            )

            // Scale to 0.5x (matching iOS) - note dimensions are swapped after rotation
            val scaledWidth = (rotatedBitmap.width * scaleFactor).toInt()
            val scaledHeight = (rotatedBitmap.height * scaleFactor).toInt()
            val finalBitmap = Bitmap.createScaledBitmap(rotatedBitmap, scaledWidth, scaledHeight, true)

            // Compress to JPEG
            ByteArrayOutputStream().use { stream ->
                finalBitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, stream)
                val jpegData = stream.toByteArray()
                _frameFlow.tryEmit(jpegData)
            }

            // Clean up
            bitmap.recycle()
            if (rotatedBitmap != finalBitmap) rotatedBitmap.recycle()
            finalBitmap.recycle()
        } catch (e: Exception) {
            android.util.Log.e("CameraCaptureManager", "Frame processing error: ${e.message}")
        }
    }

    private fun yuv420ToNv21(image: Image): ByteArray {
        val width = image.width
        val height = image.height
        val ySize = width * height
        val uvSize = width * height / 2

        val nv21 = ByteArray(ySize + uvSize)

        val yBuffer = image.planes[0].buffer
        val uBuffer = image.planes[1].buffer
        val vBuffer = image.planes[2].buffer

        val yRowStride = image.planes[0].rowStride
        val uvRowStride = image.planes[1].rowStride
        val uvPixelStride = image.planes[1].pixelStride

        // Copy Y plane
        var pos = 0
        if (yRowStride == width) {
            yBuffer.get(nv21, 0, ySize)
            pos = ySize
        } else {
            for (row in 0 until height) {
                yBuffer.position(row * yRowStride)
                yBuffer.get(nv21, pos, width)
                pos += width
            }
        }

        // Copy UV planes (interleaved as VU for NV21)
        val uvHeight = height / 2
        for (row in 0 until uvHeight) {
            for (col in 0 until width / 2) {
                val uvIndex = row * uvRowStride + col * uvPixelStride
                vBuffer.position(uvIndex)
                uBuffer.position(uvIndex)
                nv21[pos++] = vBuffer.get()
                nv21[pos++] = uBuffer.get()
            }
        }

        return nv21
    }

    // MARK: - Background Thread

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("CameraBackground").also { it.start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join()
            backgroundThread = null
            backgroundHandler = null
        } catch (e: InterruptedException) {
            android.util.Log.e("CameraCaptureManager", "Error stopping background thread: ${e.message}")
        }
    }
}
