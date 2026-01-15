/**
 * SpecBridge lib-jitsi-meet Bridge
 *
 * This script handles the connection to Jitsi servers and manages
 * video tracks from canvas frames sent by Flutter.
 */

// Global state
let connection = null;
let conference = null;
let localAudioTrack = null;
let localVideoTrack = null;
let isJoined = false;
let isAudioMuted = false;
let isVideoMuted = false;
let isE2EEEnabled = false;

// Frame processing stats
let framesDrawn = 0;
let framesDroppedJs = 0;
let framesDroppedStale = 0;  // Frames dropped due to being too old (timestamp check)
const MAX_FRAME_AGE_MS = 150;  // Max frame age before dropping (prevents backlog)
let totalDecodeTimeMs = 0;
let lastDecodeTimeMs = 0;
let isProcessingFrame = false;
let lastFrameArrivalTime = 0;
let frameArrivalIntervals = [];
// pendingFrameData removed - we now drop frames immediately to stay current

// E2E Latency tracking (native capture → JS receive)
let lastFrameLatencyMs = 0;
let totalFrameLatencyMs = 0;
let maxFrameLatencyMs = 0;
let latencyMeasurements = 0;

// WebRTC encoder stats (updated periodically from RTCPeerConnection.getStats)
let rtcFramesEncoded = 0;
let rtcFramesSent = 0;
let rtcFramesDropped = 0;  // framesEncoded - framesSent = pending in encoder
let rtcQualityLimitationReason = 'none';
let rtcEncoderImpl = 'unknown';
let rtcEncodeWidth = 0;
let rtcEncodeHeight = 0;
let rtcEncodeFps = 0;
let rtcBytesSent = 0;
let rtcPacketsSent = 0;
let rtcRetransmittedPackets = 0;
let rtcStatsCollectorInterval = null;

// Stats tracking (must be declared before use in handleBinaryFrame)
let frameCount = 0;
let lastFrameTime = Date.now();
let lastStatsTime = Date.now();
let lastStatsFrameCount = 0;
let currentFps = 0;
let totalBytesReceived = 0;
let lastBytesReceived = 0;
let currentBitrate = 0;

// E2EE config (stored from joinRoom call)
let e2eeConfig = { enabled: false, passphrase: '' };

// Participant tracking for lazy captureStream
let remoteParticipantCount = 0;
let videoTrackStarted = false;

// Session watcher intervals (cleared on leave)
let jvbCheckInterval = null;
let p2pCheckInterval = null;

// Video source mode: 'canvas' (for glasses) or 'camera' (direct getUserMedia)
let videoSourceMode = 'canvas';
let cameraStream = null;  // getUserMedia stream for camera mode

// Camera preview video element
const cameraPreview = document.getElementById('cameraPreview');

// Canvas setup - use WebGL for I420 YUV rendering
const canvas = document.getElementById('videoCanvas');
let canvasStream = null;

// WebGL state for I420 rendering
let gl = null;
let glProgram = null;
let yTexture = null;
let uTexture = null;
let vTexture = null;
let positionBuffer = null;
let texCoordBuffer = null;

// Fallback 2D context (for JPEG if needed)
let ctx = null;

// Pre-allocated buffers to reduce GC pressure
// Max size for 1280x720: Y=921600, UV=230400 each, total ~1.4MB
// We'll allocate for up to 1920x1080 to be safe: Y=2073600, UV=518400
const MAX_Y_SIZE = 2073600;
const MAX_UV_SIZE = 518400;
let preAllocatedY = new Uint8Array(MAX_Y_SIZE);
let preAllocatedU = new Uint8Array(MAX_UV_SIZE);
let preAllocatedV = new Uint8Array(MAX_UV_SIZE);
let preAllocatedDataView = null; // Will be created on first frame
let lastFrameWidth = 0;
let lastFrameHeight = 0;

// Initialize WebGL for I420 YUV rendering
function initWebGL() {
  gl = canvas.getContext('webgl2') || canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
  if (!gl) {
    console.warn('[JitsiBridge] WebGL not supported, falling back to 2D canvas');
    ctx = canvas.getContext('2d');
    return false;
  }

  // Log GPU info to verify hardware acceleration
  const debugInfo = gl.getExtension('WEBGL_debug_renderer_info');
  if (debugInfo) {
    const vendor = gl.getParameter(debugInfo.UNMASKED_VENDOR_WEBGL);
    const renderer = gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL);
    console.log('[JitsiBridge] WebGL GPU Vendor:', vendor);
    console.log('[JitsiBridge] WebGL GPU Renderer:', renderer);
  }
  const isWebGL2 = gl instanceof WebGL2RenderingContext;
  console.log('[JitsiBridge] WebGL initialized (version:', isWebGL2 ? 'WebGL2' : 'WebGL1', ')');

  // Vertex shader - just passes through positions and tex coords
  const vertexShaderSource = `
    attribute vec2 a_position;
    attribute vec2 a_texCoord;
    varying vec2 v_texCoord;
    void main() {
      gl_Position = vec4(a_position, 0.0, 1.0);
      v_texCoord = a_texCoord;
    }
  `;

  // Fragment shader - converts I420 YUV to RGB
  const fragmentShaderSource = `
    precision mediump float;
    varying vec2 v_texCoord;
    uniform sampler2D u_textureY;
    uniform sampler2D u_textureU;
    uniform sampler2D u_textureV;

    void main() {
      float y = texture2D(u_textureY, v_texCoord).r;
      float u = texture2D(u_textureU, v_texCoord).r - 0.5;
      float v = texture2D(u_textureV, v_texCoord).r - 0.5;

      // YUV to RGB conversion (BT.601)
      float r = y + 1.402 * v;
      float g = y - 0.344 * u - 0.714 * v;
      float b = y + 1.772 * u;

      gl_FragColor = vec4(r, g, b, 1.0);
    }
  `;

  // Compile shaders
  const vertexShader = gl.createShader(gl.VERTEX_SHADER);
  gl.shaderSource(vertexShader, vertexShaderSource);
  gl.compileShader(vertexShader);
  if (!gl.getShaderParameter(vertexShader, gl.COMPILE_STATUS)) {
    console.error('[JitsiBridge] Vertex shader error:', gl.getShaderInfoLog(vertexShader));
    return false;
  }

  const fragmentShader = gl.createShader(gl.FRAGMENT_SHADER);
  gl.shaderSource(fragmentShader, fragmentShaderSource);
  gl.compileShader(fragmentShader);
  if (!gl.getShaderParameter(fragmentShader, gl.COMPILE_STATUS)) {
    console.error('[JitsiBridge] Fragment shader error:', gl.getShaderInfoLog(fragmentShader));
    return false;
  }

  // Link program
  glProgram = gl.createProgram();
  gl.attachShader(glProgram, vertexShader);
  gl.attachShader(glProgram, fragmentShader);
  gl.linkProgram(glProgram);
  if (!gl.getProgramParameter(glProgram, gl.LINK_STATUS)) {
    console.error('[JitsiBridge] Program link error:', gl.getProgramInfoLog(glProgram));
    return false;
  }
  gl.useProgram(glProgram);

  // Set up vertex positions (full-screen quad)
  positionBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
    -1, -1,  1, -1,  -1, 1,
    -1,  1,  1, -1,   1, 1
  ]), gl.STATIC_DRAW);
  const positionLoc = gl.getAttribLocation(glProgram, 'a_position');
  gl.enableVertexAttribArray(positionLoc);
  gl.vertexAttribPointer(positionLoc, 2, gl.FLOAT, false, 0, 0);

  // Set up texture coordinates (flip Y for correct orientation)
  texCoordBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, texCoordBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
    0, 1,  1, 1,  0, 0,
    0, 0,  1, 1,  1, 0
  ]), gl.STATIC_DRAW);
  const texCoordLoc = gl.getAttribLocation(glProgram, 'a_texCoord');
  gl.enableVertexAttribArray(texCoordLoc);
  gl.vertexAttribPointer(texCoordLoc, 2, gl.FLOAT, false, 0, 0);

  // Create textures for Y, U, V planes
  yTexture = createTexture(0);
  uTexture = createTexture(1);
  vTexture = createTexture(2);

  // Set texture uniforms
  gl.uniform1i(gl.getUniformLocation(glProgram, 'u_textureY'), 0);
  gl.uniform1i(gl.getUniformLocation(glProgram, 'u_textureU'), 1);
  gl.uniform1i(gl.getUniformLocation(glProgram, 'u_textureV'), 2);

  console.log('[JitsiBridge] WebGL I420 renderer initialized');
  return true;
}

function createTexture(unit) {
  const texture = gl.createTexture();
  gl.activeTexture(gl.TEXTURE0 + unit);
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return texture;
}

// Render I420 frame using WebGL
function renderI420Frame(yData, uData, vData, width, height) {
  if (!gl) return false;

  // Resize canvas if needed
  if (canvas.width !== width || canvas.height !== height) {
    console.log('[JitsiBridge] Resizing canvas to ' + width + 'x' + height);
    canvas.width = width;
    canvas.height = height;
    gl.viewport(0, 0, width, height);
  }

  const uvWidth = width / 2;
  const uvHeight = height / 2;

  // Upload Y plane (full resolution)
  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, yTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, width, height, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, yData);

  // Upload U plane (quarter resolution)
  gl.activeTexture(gl.TEXTURE1);
  gl.bindTexture(gl.TEXTURE_2D, uTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, uvWidth, uvHeight, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, uData);

  // Upload V plane (quarter resolution)
  gl.activeTexture(gl.TEXTURE2);
  gl.bindTexture(gl.TEXTURE_2D, vTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, uvWidth, uvHeight, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, vData);

  // Draw
  gl.drawArrays(gl.TRIANGLES, 0, 6);

  // Force GPU to complete and check for errors (for debugging)
  const error = gl.getError();
  if (error !== gl.NO_ERROR) {
    console.error('[JitsiBridge] WebGL error:', error);
  }

  return true;
}

// GPU timing stats
let gpuTimeTotal = 0;
let gpuTimeCount = 0;

// CPU profiling - track time spent in different stages
let profileStats = {
  blobRead: { total: 0, count: 0 },
  webglRender: { total: 0, count: 0 },
  gpuSync: { total: 0, count: 0 },
  captureStream: { total: 0, count: 0 },
  total: { total: 0, count: 0 }
};

function logProfileStats() {
  const stats = {};
  for (const [key, val] of Object.entries(profileStats)) {
    if (val.count > 0) {
      stats[key] = {
        avg: (val.total / val.count).toFixed(2) + 'ms',
        total: val.total.toFixed(0) + 'ms',
        count: val.count
      };
    }
  }
  console.log('[JitsiBridge] === CPU PROFILE ===');
  console.log('[JitsiBridge] blobRead:', stats.blobRead?.avg || 'N/A');
  console.log('[JitsiBridge] webglRender:', stats.webglRender?.avg || 'N/A');
  console.log('[JitsiBridge] gpuSync:', stats.gpuSync?.avg || 'N/A');
  console.log('[JitsiBridge] total frame:', stats.total?.avg || 'N/A');
  console.log('[JitsiBridge] ====================');
}

// Measure actual GPU time by forcing sync
function measureGpuTime() {
  if (!gl) return 0;
  const start = performance.now();
  gl.finish(); // Force GPU to complete all pending operations
  return performance.now() - start;
}

// WebSocket for receiving frames from Flutter
let frameSocket = null;
let wsConnected = false;
let wsReconnectTimer = null;
let usingNativeServer = false;

// Native server port (Kotlin, bypasses Flutter UI thread)
const NATIVE_WS_PORT = 8766;
// Flutter server port (goes through EventChannel/UI thread)
const FLUTTER_WS_PORT = 8765;

function connectWebSocket() {
  if (frameSocket && frameSocket.readyState === WebSocket.OPEN) {
    return; // Already connected
  }

  // Try native server first (port 8766), then fall back to Flutter (port 8765)
  tryConnectToServer(NATIVE_WS_PORT, true);
}

function tryConnectToServer(port, tryFallback) {
  console.log(`[JitsiBridge] Connecting to WebSocket on port ${port}...`);
  updateStatus(`Connecting to frame server (port ${port})...`);

  try {
    // Use 127.0.0.1 explicitly - localhost may not resolve correctly in WebView
    frameSocket = new WebSocket(`ws://127.0.0.1:${port}`);
    frameSocket.binaryType = 'blob';

    // Set a connection timeout
    const connectionTimeout = setTimeout(() => {
      if (frameSocket.readyState !== WebSocket.OPEN) {
        console.log(`[JitsiBridge] Connection timeout on port ${port}`);
        frameSocket.close();
        if (tryFallback && port === NATIVE_WS_PORT) {
          console.log('[JitsiBridge] Falling back to Flutter server...');
          tryConnectToServer(FLUTTER_WS_PORT, false);
        }
      }
    }, 2000);

    frameSocket.onopen = () => {
      clearTimeout(connectionTimeout);
      usingNativeServer = (port === NATIVE_WS_PORT);
      const serverType = usingNativeServer ? 'NATIVE' : 'FLUTTER';
      console.log(`[JitsiBridge] WebSocket connected (${serverType} server, port ${port})`);
      updateStatus(`Frame server connected (${serverType})`);
      wsConnected = true;
      notifyFlutter('wsConnected', { native: usingNativeServer, port: port });
    };

    frameSocket.onmessage = (event) => {
      // Receive binary blob directly - no base64 decoding needed!
      handleBinaryFrame(event.data);
    };

    frameSocket.onclose = () => {
      clearTimeout(connectionTimeout);
      console.log('[JitsiBridge] WebSocket disconnected');
      wsConnected = false;
      usingNativeServer = false;
      notifyFlutter('wsDisconnected', {});
      // Retry connection after delay - start with native server again
      if (!wsReconnectTimer) {
        wsReconnectTimer = setTimeout(() => {
          wsReconnectTimer = null;
          connectWebSocket();
        }, 2000);
      }
    };

    frameSocket.onerror = (error) => {
      clearTimeout(connectionTimeout);
      console.log(`[JitsiBridge] WebSocket error on port ${port}`);
      wsConnected = false;
      // If native server failed and we should try fallback
      if (tryFallback && port === NATIVE_WS_PORT) {
        console.log('[JitsiBridge] Native server unavailable, trying Flutter server...');
        tryConnectToServer(FLUTTER_WS_PORT, false);
      }
    };
  } catch (e) {
    console.error('[JitsiBridge] WebSocket connection failed:', e);
    wsConnected = false;
    if (tryFallback && port === NATIVE_WS_PORT) {
      tryConnectToServer(FLUTTER_WS_PORT, false);
    }
  }
}

// Single-frame buffer - always keep only the latest frame
let latestFrameBlob = null;

// Handle binary frame from WebSocket
function handleBinaryFrame(blob) {
  frameCount++;
  totalBytesReceived += blob.size;

  // Track frame arrival timing
  const arrivalTime = Date.now();
  if (lastFrameArrivalTime > 0) {
    const interval = arrivalTime - lastFrameArrivalTime;
    frameArrivalIntervals.push(interval);
    // Keep only last 100 intervals
    if (frameArrivalIntervals.length > 100) {
      frameArrivalIntervals.shift();
    }
  }
  lastFrameArrivalTime = arrivalTime;

  // Calculate FPS and bitrate every second
  const now = Date.now();
  const elapsed = now - lastStatsTime;
  if (elapsed >= 1000) {
    const framesDelta = framesDrawn - lastStatsFrameCount;
    currentFps = Math.round(framesDelta * 1000 / elapsed);

    const bytesDelta = totalBytesReceived - lastBytesReceived;
    currentBitrate = Math.round(bytesDelta * 8 / elapsed); // kbps

    lastStatsTime = now;
    lastStatsFrameCount = framesDrawn;
    lastBytesReceived = totalBytesReceived;

    // Debug logging - calculate avg arrival interval and latency
    const avgInterval = frameArrivalIntervals.length > 0
      ? Math.round(frameArrivalIntervals.reduce((a, b) => a + b, 0) / frameArrivalIntervals.length)
      : 0;
    const avgLatency = latencyMeasurements > 0 ? Math.round(totalFrameLatencyMs / latencyMeasurements) : 0;
    console.log('[JitsiBridge] Stats: recv=' + frameCount + ' drawn=' + framesDrawn + ' dropQ=' + framesDroppedJs + ' dropStale=' + framesDroppedStale + ' arrivalMs=' + avgInterval + ' latencyMs=' + lastFrameLatencyMs + '/' + avgLatency + '/' + maxFrameLatencyMs + ' (last/avg/max)');
  }

  // Single-frame buffer pattern: always keep only the latest frame
  // This ensures we always show the freshest frame, skipping all intermediate ones
  const hadPendingFrame = latestFrameBlob !== null;
  latestFrameBlob = blob;

  if (hadPendingFrame) {
    // A frame was waiting but not yet processed - it's now replaced
    framesDroppedJs++;
  }

  // If not currently processing, start the processing loop
  if (!isProcessingFrame) {
    processLatestFrame();
  }
}

// Process the latest frame, then check for newer ones
async function processLatestFrame() {
  while (latestFrameBlob !== null) {
    const blob = latestFrameBlob;
    latestFrameBlob = null;  // Clear so new arrivals go to latestFrameBlob

    isProcessingFrame = true;
    await detectAndProcessFrame(blob);
    isProcessingFrame = false;

    // Loop will continue if a newer frame arrived during processing
  }
}

// Detect frame format and route to appropriate processor
async function detectAndProcessFrame(blob) {
  isProcessingFrame = true;

  try {
    // Read first 2 bytes to detect format
    const headerSlice = blob.slice(0, 2);
    const headerBuffer = await headerSlice.arrayBuffer();
    const headerBytes = new Uint8Array(headerBuffer);

    // JPEG magic bytes: 0xFF 0xD8
    if (headerBytes[0] === 0xFF && headerBytes[1] === 0xD8) {
      await processJpegFrame(blob);
    } else {
      await processI420FrameInternal(blob);
    }
  } catch (e) {
    console.error('[JitsiBridge] Frame detection error:', e);
  }

  isProcessingFrame = false;
}

// WebGL texture for JPEG rendering (reused across frames)
let jpegTexture = null;

// Process JPEG frame (from phone camera) using WebGL texture
async function processJpegFrame(blob) {
  const decodeStart = Date.now();

  try {
    if (!gl) {
      console.error('[JitsiBridge] WebGL not available for JPEG rendering');
      return;
    }

    // Create image from blob
    const imageUrl = URL.createObjectURL(blob);
    const img = new Image();

    await new Promise((resolve, reject) => {
      img.onload = resolve;
      img.onerror = reject;
      img.src = imageUrl;
    });

    URL.revokeObjectURL(imageUrl);

    // Resize canvas if needed
    if (canvas.width !== img.width || canvas.height !== img.height) {
      console.log('[JitsiBridge] JPEG: Resizing canvas to ' + img.width + 'x' + img.height);
      canvas.width = img.width;
      canvas.height = img.height;
      gl.viewport(0, 0, img.width, img.height);
    }

    // Create JPEG texture program if not exists (simpler than I420 - just RGB passthrough)
    if (!jpegTexture) {
      jpegTexture = gl.createTexture();
    }

    // Upload image as texture and render
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, jpegTexture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);

    // For JPEG, we need a simpler shader that just renders RGB texture
    // Reuse the Y texture uniform (it expects luminance but RGBA works too with some color shift)
    // Actually, let's just render directly - the shader expects YUV but we can hack it
    // by putting the image in all 3 texture slots with specific values

    // Simpler approach: use gl.LUMINANCE trick - upload same image to Y,U,V
    // But this won't give correct colors. Better to create a separate JPEG shader.

    // For now, use drawImage via a temporary 2D canvas, then copy to WebGL
    // This is slower but works correctly
    const tempCanvas = document.createElement('canvas');
    tempCanvas.width = img.width;
    tempCanvas.height = img.height;
    const tempCtx = tempCanvas.getContext('2d');
    tempCtx.drawImage(img, 0, 0);

    // Get image data and extract Y, U, V planes (convert RGB to YUV)
    const imageData = tempCtx.getImageData(0, 0, img.width, img.height);
    const rgbaData = imageData.data;

    const ySize = img.width * img.height;
    const uvSize = (img.width / 2) * (img.height / 2);
    const yData = new Uint8Array(ySize);
    const uData = new Uint8Array(uvSize);
    const vData = new Uint8Array(uvSize);

    // Convert RGBA to I420 YUV
    for (let y = 0; y < img.height; y++) {
      for (let x = 0; x < img.width; x++) {
        const rgbaIdx = (y * img.width + x) * 4;
        const r = rgbaData[rgbaIdx];
        const g = rgbaData[rgbaIdx + 1];
        const b = rgbaData[rgbaIdx + 2];

        // RGB to Y (BT.601)
        const yVal = 0.299 * r + 0.587 * g + 0.114 * b;
        yData[y * img.width + x] = Math.round(yVal);

        // Subsample U and V (every 2x2 block)
        if (y % 2 === 0 && x % 2 === 0) {
          const uvIdx = (y / 2) * (img.width / 2) + (x / 2);
          // RGB to U, V (BT.601)
          const uVal = -0.169 * r - 0.331 * g + 0.5 * b + 128;
          const vVal = 0.5 * r - 0.419 * g - 0.081 * b + 128;
          uData[uvIdx] = Math.round(Math.max(0, Math.min(255, uVal)));
          vData[uvIdx] = Math.round(Math.max(0, Math.min(255, vVal)));
        }
      }
    }

    // Render using existing I420 WebGL pipeline
    renderI420Frame(yData, uData, vData, img.width, img.height);

    // Track timing
    lastDecodeTimeMs = Date.now() - decodeStart;
    totalDecodeTimeMs += lastDecodeTimeMs;
    framesDrawn++;
    lastFrameTime = Date.now();

    if (framesDrawn % 100 === 0) {
      console.log('[JitsiBridge] JPEG frame timing: total=' + lastDecodeTimeMs + 'ms');
    }
  } catch (e) {
    console.error('[JitsiBridge] JPEG processing error:', e);
  }
}
// Process I420 frame with WebGL (internal, called after format detection)
async function processI420FrameInternal(blob) {
  const decodeStart = Date.now();

  try {
    // Read blob as ArrayBuffer - track timing
    const blobReadStart = performance.now();
    const buffer = await blob.arrayBuffer();
    const blobReadTime = performance.now() - blobReadStart;
    profileStats.blobRead.total += blobReadTime;
    profileStats.blobRead.count++;

    // Parse header: width (4 bytes), height (4 bytes), timestamp (4 bytes), then I420 data
    if (buffer.byteLength < 12) {
      console.warn('[JitsiBridge] Frame too small:', buffer.byteLength);
      isProcessingFrame = false;
      return;
    }

    // Reuse DataView if possible, create only on first frame
    if (!preAllocatedDataView || preAllocatedDataView.buffer !== buffer) {
      preAllocatedDataView = new DataView(buffer);
    }
    const width = preAllocatedDataView.getUint32(0, true);  // little-endian
    const height = preAllocatedDataView.getUint32(4, true);
    const frameTimestamp = preAllocatedDataView.getUint32(8, true);  // low 32 bits of sender timestamp

    // Check frame age - drop if too old (prevents backlog from accumulating)
    const now = Date.now() & 0xFFFFFFFF;  // Low 32 bits for comparison
    let frameAge = now - frameTimestamp;
    // Handle wraparound (timestamp wraps every ~49 days, but we only care about small deltas)
    if (frameAge < 0) frameAge += 0x100000000;
    if (frameAge > MAX_FRAME_AGE_MS && frameAge < 0x80000000) {  // Sanity check: ignore huge values (wraparound)
      framesDroppedStale++;
      if (framesDroppedStale === 1 || framesDroppedStale % 50 === 0) {
        console.log('[JitsiBridge] Dropped stale frame: age=' + frameAge + 'ms, total dropped=' + framesDroppedStale);
      }
      isProcessingFrame = false;
      return;
    }

    // Track E2E latency (frame passed age check, so frameAge is valid)
    if (frameAge < 0x80000000) {  // Valid measurement (not a wraparound artifact)
      lastFrameLatencyMs = frameAge;
      totalFrameLatencyMs += frameAge;
      latencyMeasurements++;
      if (frameAge > maxFrameLatencyMs) {
        maxFrameLatencyMs = frameAge;
      }
    }

    // Calculate expected I420 size
    const ySize = width * height;
    const uvSize = (width / 2) * (height / 2);
    const expectedSize = 12 + ySize + uvSize * 2;

    if (buffer.byteLength < expectedSize) {
      console.warn('[JitsiBridge] Frame data incomplete: got ' + buffer.byteLength + ', expected ' + expectedSize);
      isProcessingFrame = false;
      return;
    }

    // Check if frame size changed
    if (width !== lastFrameWidth || height !== lastFrameHeight) {
      console.log('[JitsiBridge] Frame size changed to ' + width + 'x' + height + ', ySize=' + ySize + ', uvSize=' + uvSize);
      lastFrameWidth = width;
      lastFrameHeight = height;
    }

    // Use pre-allocated buffers - direct views into the blob's ArrayBuffer
    // We create typed array views directly on the buffer (no copying, just pointer math)
    // These view objects are small and short-lived, but the actual data is in the blob's buffer
    const yData = new Uint8Array(buffer, 12, ySize);
    const uData = new Uint8Array(buffer, 12 + ySize, uvSize);
    const vData = new Uint8Array(buffer, 12 + ySize + uvSize, uvSize);

    // Note: The blob's ArrayBuffer will be GC'd after this frame, but that's unavoidable
    // without changing the WebSocket transport. The typed array views above are cheap
    // (just ~24 bytes each for the object metadata).

    // Render using WebGL - track timing
    const renderStart = performance.now();
    if (gl) {
      renderI420Frame(yData, uData, vData, width, height);
    } else {
      // Fallback: would need to convert to RGB manually (not implemented)
      console.warn('[JitsiBridge] WebGL not available, cannot render I420');
    }
    const renderTime = performance.now() - renderStart;
    profileStats.webglRender.total += renderTime;
    profileStats.webglRender.count++;

    // Track timing
    lastDecodeTimeMs = Date.now() - decodeStart;
    totalDecodeTimeMs += lastDecodeTimeMs;
    framesDrawn++;
    lastFrameTime = Date.now();

    // Measure GPU sync time (forces GPU to finish, shows actual GPU load)
    const gpuSyncTime = measureGpuTime();
    gpuTimeTotal += gpuSyncTime;
    gpuTimeCount++;
    profileStats.gpuSync.total += gpuSyncTime;
    profileStats.gpuSync.count++;
    profileStats.total.total += lastDecodeTimeMs;
    profileStats.total.count++;

    // Log detailed timing every 100 frames
    if (framesDrawn % 100 === 0) {
      const avgGpuTime = gpuTimeCount > 0 ? (gpuTimeTotal / gpuTimeCount).toFixed(1) : 0;
      console.log('[JitsiBridge] Frame timing: blobRead=' + blobReadTime.toFixed(1) + 'ms, render=' + renderTime.toFixed(1) + 'ms, gpuSync=' + gpuSyncTime.toFixed(1) + 'ms (avg=' + avgGpuTime + 'ms), total=' + lastDecodeTimeMs + 'ms');
    }

    // Log CPU profile every 500 frames
    if (framesDrawn % 500 === 0) {
      logProfileStats();
    }

  } catch (e) {
    console.error('[JitsiBridge] Frame processing error:', e);
  }
  // Note: isProcessingFrame is set to false in detectAndProcessFrame wrapper
}

// Status display
const statusEl = document.getElementById('status');
function updateStatus(msg) {
  console.log('[JitsiBridge] ' + msg);
  if (statusEl) statusEl.textContent = msg;
}

// Flutter communication
function notifyFlutter(event, data) {
  if (window.flutter_inappwebview) {
    window.flutter_inappwebview.callHandler('jitsiEvent', event, JSON.stringify(data || {}));
  } else {
    console.log('[JitsiBridge] Flutter handler not available:', event, data);
  }
}

// Video layout management for 1:1 calls
// When peer joins: remote video = main, local = thumbnail
// When alone: local = main, hide remote
function updateVideoLayout(hasPeer) {
  const remoteVideo = document.getElementById('remoteVideo');
  const localCanvas = document.getElementById('videoCanvas');
  const cameraPreview = document.getElementById('cameraPreview');
  const waitingMessage = document.getElementById('waitingMessage');

  console.log('[JitsiBridge] Updating video layout, hasPeer:', hasPeer);

  if (hasPeer) {
    // Peer connected: show remote as main, local as thumbnail
    if (remoteVideo) remoteVideo.classList.add('active');
    if (localCanvas) localCanvas.classList.add('thumbnail');
    if (cameraPreview) cameraPreview.classList.add('thumbnail');
    if (waitingMessage) waitingMessage.classList.remove('active');
  } else {
    // Alone: show local as main, hide remote
    if (remoteVideo) remoteVideo.classList.remove('active');
    if (localCanvas) localCanvas.classList.remove('thumbnail');
    if (cameraPreview) cameraPreview.classList.remove('thumbnail');
    // Show waiting message only if we're in a room
    if (waitingMessage && isJoined) waitingMessage.classList.add('active');
  }
}

// Show waiting message when we join a room
function showWaitingForPeer() {
  const waitingMessage = document.getElementById('waitingMessage');
  if (waitingMessage && remoteParticipantCount === 0) {
    waitingMessage.classList.add('active');
  }
}

// Initialize lib-jitsi-meet
function initJitsi() {
  try {
    // Initialize WebGL for I420 YUV rendering
    if (!initWebGL()) {
      console.warn('[JitsiBridge] WebGL init failed, will try fallback');
    }

    JitsiMeetJS.init({
      disableAudioLevels: true,
      disableSimulcast: false
    });
    JitsiMeetJS.setLogLevel(JitsiMeetJS.logLevels.WARN);
    updateStatus('lib-jitsi-meet initialized');

    // Connect to WebSocket for frame transfer
    connectWebSocket();

    notifyFlutter('initialized', { success: true });
  } catch (e) {
    updateStatus('Init failed: ' + e.message);
    notifyFlutter('error', { message: 'Failed to initialize: ' + e.message });
  }
}

// Join a room
// usePhoneMic: when true, forces phone's built-in mic instead of Bluetooth
//              to avoid competing with glasses video stream for BT bandwidth
async function joinRoom(server, room, displayName, enableE2EE = false, e2eePassphrase = '', usePhoneMic = true) {
  updateStatus('Connecting to ' + server + '...');

  // Store E2EE config for use after joining
  e2eeConfig = { enabled: enableE2EE, passphrase: e2eePassphrase };
  console.log('[JitsiBridge] E2EE config:', enableE2EE ? 'enabled' : 'disabled');

  try {
    // Parse server URL
    const serverUrl = new URL(server);
    const domain = serverUrl.hostname;

    // Connection options
    const options = {
      hosts: {
        domain: domain,
        muc: 'conference.' + domain,
        focus: 'focus.' + domain
      },
      serviceUrl: server.replace('https://', 'wss://') + '/xmpp-websocket',
      clientNode: 'https://jitsi.org/jitsimeet'
    };

    // Create connection
    connection = new JitsiMeetJS.JitsiConnection(null, null, options);

    // Connection event listeners
    connection.addEventListener(
      JitsiMeetJS.events.connection.CONNECTION_ESTABLISHED,
      () => onConnectionEstablished(room, displayName)
    );

    connection.addEventListener(
      JitsiMeetJS.events.connection.CONNECTION_FAILED,
      (error) => {
        updateStatus('Connection failed: ' + error);
        notifyFlutter('connectionFailed', { error: String(error) });
      }
    );

    connection.addEventListener(
      JitsiMeetJS.events.connection.CONNECTION_DISCONNECTED,
      () => {
        updateStatus('Disconnected');
        notifyFlutter('disconnected', {});
      }
    );

    connection.connect();
  } catch (e) {
    updateStatus('Join error: ' + e.message);
    notifyFlutter('error', { message: e.message });
  }
}

async function onConnectionEstablished(room, displayName) {
  updateStatus('Connected, joining room: ' + room);

  try {
    // Initialize conference with E2EE support and codec preferences for hardware encoding
    // Pixel 9a and newer devices have hardware AV1 encoding support
    conference = connection.initJitsiConference(room.toLowerCase(), {
      openBridgeChannel: true,
      p2p: {
        enabled: true
      },
      e2ee: {
        enabled: e2eeConfig.enabled
      },
      // Video quality settings with codec preferences for hardware encoding
      // IMPORTANT: Only H264 has reliable hardware encoder support on Android
      // - VP9: Uses libvpx (software) - no HW encoding on most Android devices
      // - AV1: Uses libaom (software) - Chrome/WebView doesn't expose HW encoder
      // - VP8: Uses libvpx (software)
      videoQuality: {
        // Only offer H264 - it's the only codec with hardware encoding on Android
        codecPreferenceOrder: ['H264'],
        mobileCodecPreferenceOrder: ['H264'],
        // Screenshare codec - use H264 for hardware encoding
        screenshareCodec: 'H264',
        mobileScreenshareCodec: 'H264',
        // Enable adaptive mode to handle CPU overuse
        enableAdaptiveMode: true,
        // H264 config - the only codec we want to use
        h264: {
          maxBitratesVideo: {
            low: 200000,
            standard: 500000,
            high: 1500000,
            fullHd: 3000000,
            ultraHd: 6000000,
            ssHigh: 2500000
          },
          scalabilityModeEnabled: true
        }
      }
    });

    // Create audio track from microphone
    // Note: When usePhoneMic=true, native code has already forced speakerphone mode,
    // so WebRTC will use the phone's built-in mic instead of Bluetooth.
    // This preserves Bluetooth bandwidth for glasses video streaming.
    try {
      console.log('[JitsiBridge] Creating audio track (usePhoneMic=' + usePhoneMic + ')');
      const audioTracks = await JitsiMeetJS.createLocalTracks({
        devices: ['audio'],
      });
      localAudioTrack = audioTracks[0];
      updateStatus('Audio track created');
      console.log('[JitsiBridge] Audio track created successfully');
    } catch (audioError) {
      console.warn('[JitsiBridge] Audio track creation failed:', audioError);
      // Continue without audio if it fails
    }

    // Create video track immediately - captureStream creates a LIVE stream
    // that automatically updates as frames are drawn to the canvas
    // This must happen BEFORE conference.join() so video is part of SDP negotiation
    await startVideoTrack();
    console.log('[JitsiBridge] Video track created');

    // Watch for JVB session creation - this is key for video transmission
    // Clear any existing intervals first
    if (jvbCheckInterval) clearInterval(jvbCheckInterval);
    if (p2pCheckInterval) clearInterval(p2pCheckInterval);

    jvbCheckInterval = setInterval(() => {
      if (conference && conference.jvbJingleSession) {
        console.log('[JitsiBridge] >>> JVB SESSION CREATED <<<');
        console.log('[JitsiBridge] JVB peerconnection:', !!conference.jvbJingleSession.peerconnection);
        clearInterval(jvbCheckInterval);
        jvbCheckInterval = null;
      }
    }, 500);

    // Also watch for P2P session
    p2pCheckInterval = setInterval(() => {
      if (conference && conference.p2pJingleSession) {
        console.log('[JitsiBridge] >>> P2P SESSION CREATED <<<');
        clearInterval(p2pCheckInterval);
        p2pCheckInterval = null;
      }
    }, 500);

    // Clear intervals after 30s to avoid memory leak
    setTimeout(() => {
      if (jvbCheckInterval) { clearInterval(jvbCheckInterval); jvbCheckInterval = null; }
      if (p2pCheckInterval) { clearInterval(p2pCheckInterval); p2pCheckInterval = null; }
    }, 30000);

    // Conference event listeners
    conference.on(JitsiMeetJS.events.conference.CONFERENCE_JOINED, async () => {
      isJoined = true;
      console.log('[JitsiBridge] === CONFERENCE_JOINED ===');
      console.log('[JitsiBridge] localVideoTrack exists:', !!localVideoTrack);
      console.log('[JitsiBridge] videoTrackStarted:', videoTrackStarted);
      console.log('[JitsiBridge] jvbJingleSession:', !!conference.jvbJingleSession);
      console.log('[JitsiBridge] p2pJingleSession:', !!conference.p2pJingleSession);
      updateStatus('Joined room: ' + room);

      // Show waiting message if we're alone in the room
      showWaitingForPeer();

      // Log codec information for debugging
      try {
        const localTracks = conference.getLocalTracks();
        console.log('[JitsiBridge] Local tracks:', localTracks.length);
        localTracks.forEach(track => {
          console.log('[JitsiBridge] Track type:', track.getType(), 'videoType:', track.videoType);
        });

        // Try to get codec info from peer connection (may not be immediately available)
        setTimeout(() => {
          logCodecInfo();
        }, 3000);

        // Run full diagnosis after 5 seconds to capture state for debugging intermittent issues
        setTimeout(() => {
          diagnosePeerConnection();
        }, 5000);
      } catch (e) {
        console.log('[JitsiBridge] Could not log track info:', e);
      }

      // Set sender video constraint to match canvas resolution
      // This helps Jitsi's quality controller know what resolution we're sending
      if (videoSourceMode === 'canvas' && canvas.width > 0) {
        try {
          const senderHeight = canvas.height || 720;
          console.log('[JitsiBridge] Setting sender video constraint:', senderHeight);
          conference.setSenderVideoConstraint(senderHeight);
        } catch (e) {
          console.warn('[JitsiBridge] Could not set sender constraint:', e);
        }
      }

      // Enable E2EE if configured
      if (e2eeConfig.enabled && e2eeConfig.passphrase) {
        try {
          await setupE2EE(e2eeConfig.passphrase);
        } catch (e) {
          console.error('[JitsiBridge] E2EE setup failed:', e);
          notifyFlutter('e2eeError', { message: e.message || String(e) });
        }
      }

      // Start WebRTC stats collector to track encoder performance
      startRtcStatsCollector();

      notifyFlutter('joined', { room: room, e2ee: e2eeConfig.enabled });
    });

    conference.on(JitsiMeetJS.events.conference.CONFERENCE_LEFT, () => {
      isJoined = false;
      stopRtcStatsCollector();  // Stop WebRTC stats collection
      updateStatus('Left room');
      notifyFlutter('left', {});
    });

    conference.on(JitsiMeetJS.events.conference.CONFERENCE_FAILED, (error) => {
      updateStatus('Conference failed: ' + error);
      notifyFlutter('conferenceFailed', { error: String(error) });
    });

    conference.on(JitsiMeetJS.events.conference.USER_JOINED, (id, user) => {
      remoteParticipantCount++;
      console.log('[JitsiBridge] === USER_JOINED ===');
      console.log('[JitsiBridge] Peer joined, count:', remoteParticipantCount, 'id:', id);
      console.log('[JitsiBridge] At USER_JOINED - jvbJingleSession:', !!conference.jvbJingleSession);
      console.log('[JitsiBridge] At USER_JOINED - p2pJingleSession:', !!conference.p2pJingleSession);
      notifyFlutter('participantJoined', {
        id: id,
        displayName: user.getDisplayName() || 'Guest'
      });
    });

    conference.on(JitsiMeetJS.events.conference.USER_LEFT, (id) => {
      remoteParticipantCount = Math.max(0, remoteParticipantCount - 1);
      console.log('[JitsiBridge] Peer left, count:', remoteParticipantCount);
      notifyFlutter('participantLeft', { id: id });

      // If no more peers, switch back to full-screen local video
      if (remoteParticipantCount === 0) {
        updateVideoLayout(false);
      }
    });

    conference.on(JitsiMeetJS.events.conference.TRACK_ADDED, (track) => {
      if (track.isLocal()) return;
      console.log('[JitsiBridge] === REMOTE TRACK_ADDED ===');
      console.log('[JitsiBridge] Remote track type:', track.getType(), 'from:', track.getParticipantId());
      console.log('[JitsiBridge] At TRACK_ADDED - jvbJingleSession:', !!conference.jvbJingleSession);

      // Attach remote video track to the video element
      if (track.getType() === 'video') {
        const remoteVideo = document.getElementById('remoteVideo');
        if (remoteVideo) {
          track.attach(remoteVideo);
          console.log('[JitsiBridge] Remote video attached');
          updateVideoLayout(true);
        }
      }

      // Attach remote audio track (will play through default audio output)
      if (track.getType() === 'audio') {
        // Create a temporary audio element for remote audio
        const audioEl = document.createElement('audio');
        audioEl.id = 'remoteAudio_' + track.getParticipantId();
        audioEl.autoplay = true;
        document.body.appendChild(audioEl);
        track.attach(audioEl);
        console.log('[JitsiBridge] Remote audio attached');
      }

      notifyFlutter('remoteTrackAdded', {
        participantId: track.getParticipantId(),
        type: track.getType()
      });
    });

    conference.on(JitsiMeetJS.events.conference.TRACK_REMOVED, (track) => {
      if (track.isLocal()) return;

      // Detach remote video
      if (track.getType() === 'video') {
        const remoteVideo = document.getElementById('remoteVideo');
        if (remoteVideo) {
          track.detach(remoteVideo);
          console.log('[JitsiBridge] Remote video detached');
        }
      }

      // Remove remote audio element
      if (track.getType() === 'audio') {
        const audioEl = document.getElementById('remoteAudio_' + track.getParticipantId());
        if (audioEl) {
          track.detach(audioEl);
          audioEl.remove();
          console.log('[JitsiBridge] Remote audio detached');
        }
      }

      notifyFlutter('remoteTrackRemoved', {
        participantId: track.getParticipantId(),
        type: track.getType()
      });
    });

    // ICE connection state changes - helps diagnose connectivity issues
    conference.on(JitsiMeetJS.events.conference.CONNECTION_INTERRUPTED, () => {
      console.log('[JitsiBridge] CONNECTION_INTERRUPTED - ICE connection lost');
      notifyFlutter('connectionInterrupted', {});
    });

    conference.on(JitsiMeetJS.events.conference.CONNECTION_RESTORED, () => {
      console.log('[JitsiBridge] CONNECTION_RESTORED - ICE connection restored');
      notifyFlutter('connectionRestored', {});
    });

    // Data channel events
    conference.on(JitsiMeetJS.events.conference.DATA_CHANNEL_OPENED, () => {
      console.log('[JitsiBridge] DATA_CHANNEL_OPENED - bridge channel ready');
    });

    // Add audio track to conference
    if (localAudioTrack) {
      await conference.addTrack(localAudioTrack);
    }

    // Set display name
    if (displayName) {
      conference.setDisplayName(displayName);
    }

    // Join the conference
    // Give server a moment after connection before joining - helps with rapid reconnections
    await new Promise(resolve => setTimeout(resolve, 500));
    console.log('[JitsiBridge] === Calling conference.join() ===');
    console.log('[JitsiBridge] Pre-join state:');
    console.log('[JitsiBridge]   localVideoTrack:', !!localVideoTrack);
    console.log('[JitsiBridge]   localAudioTrack:', !!localAudioTrack);
    console.log('[JitsiBridge]   videoTrackStarted:', videoTrackStarted);
    console.log('[JitsiBridge]   videoSourceMode:', videoSourceMode);
    console.log('[JitsiBridge]   cameraStream:', !!cameraStream);
    conference.join();

  } catch (e) {
    updateStatus('Conference error: ' + e.message);
    notifyFlutter('error', { message: e.message });
  }
}

// Get current stats
function getStats() {
  const avgDecodeMs = framesDrawn > 0 ? Math.round(totalDecodeTimeMs / framesDrawn) : 0;
  const totalDropped = framesDroppedJs + framesDroppedStale;
  const jsDropRate = frameCount > 0 ? Math.round(totalDropped * 100 / frameCount) : 0;
  const avgArrivalMs = frameArrivalIntervals.length > 0
    ? Math.round(frameArrivalIntervals.reduce((a, b) => a + b, 0) / frameArrivalIntervals.length)
    : 0;
  const avgLatencyMs = latencyMeasurements > 0 ? Math.round(totalFrameLatencyMs / latencyMeasurements) : 0;

  // For camera mode, get resolution from camera track
  let resolution = canvas.width + 'x' + canvas.height;
  let width = canvas.width;
  let height = canvas.height;
  if (videoSourceMode === 'camera' && cameraStream) {
    const videoTrack = cameraStream.getVideoTracks()[0];
    if (videoTrack) {
      const settings = videoTrack.getSettings();
      width = settings.width || 0;
      height = settings.height || 0;
      resolution = width + 'x' + height;
    }
  }

  return {
    resolution: resolution,
    width: width,
    height: height,
    fps: currentFps,
    bitrate: currentBitrate,
    totalFrames: frameCount,
    framesDrawn: framesDrawn,
    framesDroppedJs: framesDroppedJs,
    framesDroppedStale: framesDroppedStale,
    jsDropRate: jsDropRate,
    lastDecodeMs: lastDecodeTimeMs,
    avgDecodeMs: avgDecodeMs,
    avgArrivalMs: avgArrivalMs,
    lastLatencyMs: lastFrameLatencyMs,
    avgLatencyMs: avgLatencyMs,
    maxLatencyMs: maxFrameLatencyMs,
    totalBytes: totalBytesReceived,
    isJoined: isJoined,
    hasAudioTrack: localAudioTrack !== null,
    hasVideoTrack: localVideoTrack !== null,
    isE2EEEnabled: isE2EEEnabled,
    wsConnected: wsConnected,
    videoSourceMode: videoSourceMode,
    hasCameraStream: cameraStream !== null,
    // WebRTC encoder stats (shows where backup may occur)
    rtcFramesEncoded: rtcFramesEncoded,
    rtcFramesSent: rtcFramesSent,
    rtcFramesPending: Math.max(0, rtcFramesEncoded - rtcFramesSent),  // Frames in encoder queue
    rtcQualityLimitation: rtcQualityLimitationReason,
    rtcEncoderImpl: rtcEncoderImpl,
    rtcEncodeWidth: rtcEncodeWidth,
    rtcEncodeHeight: rtcEncodeHeight,
    rtcEncodeFps: rtcEncodeFps,
    rtcBytesSent: rtcBytesSent,
    rtcRetransmits: rtcRetransmittedPackets
  };
}

// Collect WebRTC encoder stats from peer connection
async function collectRtcStats() {
  if (!conference || !isJoined) return;

  try {
    // Try multiple paths to find the RTCPeerConnection
    let pc = null;

    // Path 1: JVB Jingle session (most common for server-based calls)
    const jvbSession = conference.jvbJingleSession;
    if (jvbSession?.peerconnection) {
      pc = jvbSession.peerconnection.peerconnection || jvbSession.peerconnection;
    }

    // Path 2: P2P Jingle session
    if (!pc) {
      const p2pSession = conference.p2pJingleSession;
      if (p2pSession?.peerconnection) {
        pc = p2pSession.peerconnection.peerconnection || p2pSession.peerconnection;
      }
    }

    // Path 3: conference.rtc.peerConnections (lib-jitsi-meet internal)
    if (!pc && conference.rtc?.peerConnections) {
      // peerConnections is a Map, get first one
      const peerConns = conference.rtc.peerConnections;
      if (peerConns.size > 0) {
        const firstEntry = peerConns.values().next().value;
        if (firstEntry) {
          pc = firstEntry.peerconnection || firstEntry;
        }
      }
    }

    if (!pc || typeof pc.getStats !== 'function') return;

    const stats = await pc.getStats();
    let foundOutboundVideo = false;
    stats.forEach(report => {
      if (report.type === 'outbound-rtp' && report.kind === 'video') {
        foundOutboundVideo = true;
        // Core encoder stats
        rtcFramesEncoded = report.framesEncoded || 0;
        rtcFramesSent = report.framesSent || 0;
        rtcQualityLimitationReason = report.qualityLimitationReason || 'none';
        rtcEncoderImpl = report.encoderImplementation || 'unknown';
        rtcEncodeWidth = report.frameWidth || 0;
        rtcEncodeHeight = report.frameHeight || 0;
        rtcEncodeFps = report.framesPerSecond || 0;
        rtcBytesSent = report.bytesSent || 0;
        rtcPacketsSent = report.packetsSent || 0;
        rtcRetransmittedPackets = report.retransmittedPacketsSent || 0;

        // Debug log once per 10 collections when we have stats
        if (rtcFramesEncoded > 0 && rtcFramesEncoded % 100 < 10) {
          console.log('[JitsiBridge] RTC stats: enc=' + rtcFramesEncoded + ' sent=' + rtcFramesSent +
            ' encoder=' + rtcEncoderImpl + ' ' + rtcEncodeWidth + 'x' + rtcEncodeHeight);
        }
      }
    });

    // Debug: log if no outbound video found (only first few times)
    if (!foundOutboundVideo && rtcFramesEncoded === 0) {
      // Count types of stats we have
      let statTypes = {};
      stats.forEach(r => {
        statTypes[r.type] = (statTypes[r.type] || 0) + 1;
      });
      if (Math.random() < 0.1) {  // 10% chance to log to avoid spam
        console.log('[JitsiBridge] No outbound-rtp video. Stats types:', JSON.stringify(statTypes));
      }
    }
  } catch (e) {
    console.log('[JitsiBridge] RTC stats error:', e.message);
  }
}

// Start periodic WebRTC stats collection
function startRtcStatsCollector() {
  stopRtcStatsCollector();  // Clear any existing
  rtcStatsCollectorInterval = setInterval(collectRtcStats, 1000);  // Every 1 second
  console.log('[JitsiBridge] Started WebRTC stats collector');
}

// Stop WebRTC stats collection
function stopRtcStatsCollector() {
  if (rtcStatsCollectorInterval) {
    clearInterval(rtcStatsCollectorInterval);
    rtcStatsCollectorInterval = null;
  }
}

// Set canvas resolution
function setResolution(width, height) {
  canvas.width = width;
  canvas.height = height;
  updateStatus('Resolution set to ' + width + 'x' + height);
  notifyFlutter('resolutionChanged', { width: width, height: height });
}

// Audio controls
function setAudioMuted(muted) {
  isAudioMuted = muted;
  if (localAudioTrack) {
    if (muted) {
      localAudioTrack.mute();
    } else {
      localAudioTrack.unmute();
    }
    notifyFlutter('audioMutedChanged', { muted: muted });
  }
}

function toggleAudio() {
  setAudioMuted(!isAudioMuted);
  return isAudioMuted;
}

// Video controls
// Note: For canvas-based video (desktop type), we just mute/unmute the existing track
// We never try to re-acquire a camera device
async function setVideoMuted(muted) {
  console.log('[JitsiBridge] setVideoMuted called:', muted, 'videoSourceMode:', videoSourceMode);
  isVideoMuted = muted;

  if (!localVideoTrack) {
    console.warn('[JitsiBridge] No localVideoTrack to mute/unmute!');
    return;
  }

  try {
    if (muted) {
      // Muting - just mute the track
      console.log('[JitsiBridge] Muting video track...');
      localVideoTrack.mute();
    } else {
      // Unmuting - check if track is dead and needs recreation
      const underlyingTrack = localVideoTrack.getTrack ? localVideoTrack.getTrack() : null;
      console.log('[JitsiBridge] Underlying track state:', underlyingTrack?.readyState);

      if (underlyingTrack?.readyState === 'ended') {
        // Track is dead, need to recreate
        console.log('[JitsiBridge] Track ended, recreating for mode:', videoSourceMode);

        if (videoSourceMode === 'camera') {
          // Camera mode - get fresh getUserMedia
          if (cameraStream) {
            cameraStream.getTracks().forEach(track => track.stop());
          }
          cameraStream = await navigator.mediaDevices.getUserMedia({
            video: { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 720 } },
            audio: false
          });

          // Update camera preview
          const cameraPreview = document.getElementById('cameraPreview');
          if (cameraPreview) {
            cameraPreview.srcObject = cameraStream;
          }

          // Create new JitsiLocalTrack
          const newTracks = await JitsiMeetJS.createLocalTracks({
            devices: ['video'],
            cameraDeviceId: cameraStream.getVideoTracks()[0].getSettings().deviceId
          });

          const newVideoTrack = newTracks.find(t => t.getType() === 'video');
          if (newVideoTrack && conference) {
            await conference.removeTrack(localVideoTrack);
            localVideoTrack.dispose();
            localVideoTrack = newVideoTrack;
            await conference.addTrack(localVideoTrack);
            console.log('[JitsiBridge] Camera track recreated and added to conference');
          }
        } else {
          // Canvas/glasses mode - get fresh captureStream
          if (canvasStream) {
            canvasStream.getTracks().forEach(track => track.stop());
          }
          canvasStream = canvas.captureStream(24);
          console.log('[JitsiBridge] Fresh canvasStream created');

          // Create new JitsiLocalTrack using createLocalTracksFromMediaStreams (same as initial creation)
          const videoTrackInfo = [{
            stream: canvasStream,
            sourceType: 'canvas',
            mediaType: 'video',
            videoType: 'camera'  // Must be 'camera' - 'desktop' not supported in WebView
          }];
          const newTracks = JitsiMeetJS.createLocalTracksFromMediaStreams(videoTrackInfo);
          const newVideoTrack = newTracks[0];

          if (newVideoTrack && conference) {
            await conference.removeTrack(localVideoTrack);
            localVideoTrack.dispose();
            localVideoTrack = newVideoTrack;
            await conference.addTrack(localVideoTrack);
            console.log('[JitsiBridge] Canvas track recreated and added to conference');
          }
        }
      } else {
        // Track is still alive, just unmute
        console.log('[JitsiBridge] Unmuting video track...');
        localVideoTrack.unmute();
      }
    }
    console.log('[JitsiBridge] Video muted state:', localVideoTrack.isMuted());
  } catch (e) {
    console.error('[JitsiBridge] Video mute/unmute error:', e);
  }
  notifyFlutter('videoMutedChanged', { muted: muted });
}

async function toggleVideo() {
  console.log('[JitsiBridge] toggleVideo called, current isVideoMuted:', isVideoMuted);
  await setVideoMuted(!isVideoMuted);
  console.log('[JitsiBridge] toggleVideo done, new isVideoMuted:', isVideoMuted);
  return isVideoMuted;
}

// E2EE functions
async function setupE2EE(passphrase) {
  if (!conference) {
    throw new Error('Not in a conference');
  }

  try {
    console.log('[JitsiBridge] Setting up E2EE...');

    // Set the encryption key from passphrase
    await conference.setMediaEncryptionKey({
      encryptionKey: passphrase,
      index: 0
    });

    // Enable E2EE
    await conference.toggleE2EE(true);

    isE2EEEnabled = true;
    updateStatus('E2EE enabled');
    notifyFlutter('e2eeEnabled', {});

    console.log('[JitsiBridge] E2EE enabled successfully');
    return true;
  } catch (e) {
    console.error('[JitsiBridge] E2EE enable failed:', e);
    isE2EEEnabled = false;
    throw e;
  }
}

async function disableE2EE() {
  if (!conference) return;

  try {
    await conference.toggleE2EE(false);
    isE2EEEnabled = false;
    updateStatus('E2EE disabled');
    notifyFlutter('e2eeDisabled', {});
  } catch (e) {
    console.error('[JitsiBridge] E2EE disable failed:', e);
  }
}

function isE2EE() {
  return isE2EEEnabled;
}

// Leave the room
async function leaveRoom() {
  updateStatus('Leaving room...');
  console.log('[JitsiBridge] === LEAVE ROOM START ===');

  try {
    // Clear session watcher intervals first
    if (jvbCheckInterval) {
      clearInterval(jvbCheckInterval);
      jvbCheckInterval = null;
      console.log('[JitsiBridge] Cleared JVB check interval');
    }
    if (p2pCheckInterval) {
      clearInterval(p2pCheckInterval);
      p2pCheckInterval = null;
      console.log('[JitsiBridge] Cleared P2P check interval');
    }

    // Dispose tracks before leaving conference
    if (localAudioTrack) {
      console.log('[JitsiBridge] Disposing audio track');
      localAudioTrack.dispose();
      localAudioTrack = null;
    }
    if (localVideoTrack) {
      console.log('[JitsiBridge] Disposing video track');
      localVideoTrack.dispose();
      localVideoTrack = null;
    }

    // Leave conference and wait for it to complete
    if (conference) {
      console.log('[JitsiBridge] Leaving conference...');
      try {
        await conference.leave();
        console.log('[JitsiBridge] Conference left successfully');
      } catch (leaveErr) {
        console.warn('[JitsiBridge] Conference leave error (non-fatal):', leaveErr);
      }
      conference = null;
    }

    // Disconnect connection and wait for it to complete
    if (connection) {
      console.log('[JitsiBridge] Disconnecting...');
      try {
        connection.disconnect();
        console.log('[JitsiBridge] Connection disconnected');
      } catch (disconnectErr) {
        console.warn('[JitsiBridge] Disconnect error (non-fatal):', disconnectErr);
      }
      connection = null;
    }

    // Reset all state
    isJoined = false;
    isE2EEEnabled = false;
    e2eeConfig = { enabled: false, passphrase: '' };
    remoteParticipantCount = 0;
    videoTrackStarted = false;

    // Reset video layout to local-only mode
    updateVideoLayout(false);
    const waitingMessage = document.getElementById('waitingMessage');
    if (waitingMessage) waitingMessage.classList.remove('active');

    // Stop canvas stream if exists
    if (canvasStream) {
      console.log('[JitsiBridge] Stopping canvas stream tracks');
      canvasStream.getTracks().forEach(track => track.stop());
      canvasStream = null;
    }

    // Clean up camera stream and preview
    if (cameraStream) {
      console.log('[JitsiBridge] Stopping camera stream tracks');
      cameraStream.getTracks().forEach(track => track.stop());
      cameraStream = null;
    }
    if (cameraPreview) {
      cameraPreview.srcObject = null;
      document.body.classList.remove('camera-mode');
    }
    videoSourceMode = 'canvas';

    console.log('[JitsiBridge] === LEAVE ROOM COMPLETE ===');
    updateStatus('Left room');
    notifyFlutter('left', {});
  } catch (e) {
    console.error('[JitsiBridge] Leave error:', e);
    notifyFlutter('left', { error: e.message });
  }
}

// Get current state
function getState() {
  return {
    isJoined: isJoined,
    isAudioMuted: isAudioMuted,
    isVideoMuted: isVideoMuted,
    hasAudioTrack: localAudioTrack !== null,
    hasVideoTrack: localVideoTrack !== null
  };
}

// Log codec info from WebRTC stats
async function logCodecInfo() {
  console.log('[JitsiBridge] logCodecInfo called, conference:', !!conference);

  if (!conference) {
    console.log('[JitsiBridge] No conference to get codec info from');
    return;
  }

  try {
    // Try different ways to get the peer connection
    console.log('[JitsiBridge] Checking for peer connections...');
    console.log('[JitsiBridge] conference keys:', Object.keys(conference).join(', '));
    console.log('[JitsiBridge] jvbJingleSession:', !!conference.jvbJingleSession);
    console.log('[JitsiBridge] p2pJingleSession:', !!conference.p2pJingleSession);
    console.log('[JitsiBridge] rtc:', !!conference.rtc);
    console.log('[JitsiBridge] _location:', !!conference._location);

    // Get peer connection from conference - lib-jitsi-meet uses different property names
    const jvbSession = conference.jvbJingleSession;
    const p2pSession = conference.p2pJingleSession;

    const logPeerStats = async (name, session) => {
      console.log('[JitsiBridge] Checking ' + name + ' session:', !!session);
      if (!session) return;

      // Try different property names for peer connection
      let pc = null;
      if (session.peerconnection) {
        pc = session.peerconnection.peerconnection || session.peerconnection;
      }
      if (!pc && session.pc) {
        pc = session.pc;
      }

      console.log('[JitsiBridge] ' + name + ' peer connection found:', !!pc);
      if (!pc || typeof pc.getStats !== 'function') {
        console.log('[JitsiBridge] ' + name + ' has no getStats method');
        return;
      }

      const stats = await pc.getStats();
      let foundVideo = false;
      stats.forEach(report => {
        if (report.type === 'outbound-rtp' && report.kind === 'video') {
          foundVideo = true;
          console.log('[JitsiBridge] === ' + name + ' VIDEO ENCODER STATS ===');
          console.log('[JitsiBridge] codecId:', report.codecId);
          console.log('[JitsiBridge] encoderImplementation:', report.encoderImplementation);
          console.log('[JitsiBridge] qualityLimitationReason:', report.qualityLimitationReason);
          console.log('[JitsiBridge] frameWidth:', report.frameWidth, 'frameHeight:', report.frameHeight);
          console.log('[JitsiBridge] framesPerSecond:', report.framesPerSecond);
          console.log('[JitsiBridge] bytesSent:', report.bytesSent);
          console.log('[JitsiBridge] =====================================');
        }
        if (report.type === 'codec' && report.mimeType && report.mimeType.includes('video')) {
          console.log('[JitsiBridge] ' + name + ' Video codec mimeType:', report.mimeType);
        }
      });
      if (!foundVideo) {
        console.log('[JitsiBridge] ' + name + ' No video outbound-rtp stats found');
      }
    };

    await logPeerStats('JVB', jvbSession);
    await logPeerStats('P2P', p2pSession);

    // Try via rtc property
    if (conference.rtc) {
      console.log('[JitsiBridge] rtc keys:', Object.keys(conference.rtc).join(', '));
      if (conference.rtc.peerConnections) {
        console.log('[JitsiBridge] peerConnections:', conference.rtc.peerConnections);
        for (const [id, pc] of conference.rtc.peerConnections) {
          await logPeerStats('RTC-' + id, { peerconnection: pc });
        }
      }
    }

    // Check encoderImplementation to see if hardware encoding is used
    // Values like "ExternalEncoder" or containing "HW" indicate hardware
    // Values like "libvpx" or "OpenH264" indicate software encoding
  } catch (e) {
    console.log('[JitsiBridge] Error getting codec stats:', e.message);
    console.log('[JitsiBridge] Stack:', e.stack);
  }
}

// Periodically log codec stats (every 30 seconds)
setInterval(() => {
  if (isJoined) {
    logCodecInfo();
  }
}, 30000);

// Track current camera facing mode for front/back switching
let currentCameraFacing = null;  // 'user' or 'environment'

// Set video source mode: 'glasses', 'frontCamera', or 'backCamera'
// For camera modes, we use getUserMedia directly (much more efficient)
// For glasses mode, we use canvas captureStream (frames from native)
async function setVideoSource(source) {
  console.log('[JitsiBridge] ========== setVideoSource START ==========');
  console.log('[JitsiBridge] setVideoSource called with:', source);
  console.log('[JitsiBridge] Current videoSourceMode:', videoSourceMode);
  console.log('[JitsiBridge] Current videoTrackStarted:', videoTrackStarted);
  console.log('[JitsiBridge] Current cameraFacing:', currentCameraFacing);

  const isCameraMode = source === 'frontCamera' || source === 'backCamera';
  const newMode = isCameraMode ? 'camera' : 'canvas';
  const newFacing = source === 'frontCamera' ? 'user' : (source === 'backCamera' ? 'environment' : null);
  console.log('[JitsiBridge] isCameraMode:', isCameraMode, 'newMode:', newMode, 'newFacing:', newFacing);

  // Stop track if mode is changing OR if camera facing is changing
  const modeChanging = newMode !== videoSourceMode;
  const facingChanging = isCameraMode && currentCameraFacing !== null && currentCameraFacing !== newFacing;

  if ((modeChanging || facingChanging) && videoTrackStarted) {
    console.log('[JitsiBridge] Video source changing - stopping current track (modeChanging:', modeChanging, 'facingChanging:', facingChanging, ')');
    await stopVideoTrack();
  }

  videoSourceMode = newMode;
  currentCameraFacing = newFacing;
  console.log('[JitsiBridge] videoSourceMode set to:', videoSourceMode);

  if (isCameraMode) {
    // Get camera stream via getUserMedia
    const facingMode = source === 'frontCamera' ? 'user' : 'environment';
    console.log('[JitsiBridge] Requesting camera with facingMode:', facingMode);

    try {
      // Stop any existing camera stream
      if (cameraStream) {
        console.log('[JitsiBridge] Stopping existing camera stream');
        cameraStream.getTracks().forEach(track => track.stop());
        cameraStream = null;
      }

      console.log('[JitsiBridge] Calling navigator.mediaDevices.getUserMedia...');
      console.log('[JitsiBridge] navigator.mediaDevices available:', !!navigator.mediaDevices);
      console.log('[JitsiBridge] getUserMedia available:', !!navigator.mediaDevices?.getUserMedia);

      cameraStream = await navigator.mediaDevices.getUserMedia({
        video: {
          facingMode: facingMode,
          width: { ideal: 1280 },
          height: { ideal: 720 },
          frameRate: { ideal: 30 }
        },
        audio: false  // Audio handled separately
      });

      const videoTrack = cameraStream.getVideoTracks()[0];
      const settings = videoTrack ? videoTrack.getSettings() : {};
      console.log('[JitsiBridge] Camera stream obtained!');
      console.log('[JitsiBridge] Video track:', videoTrack?.label);
      console.log('[JitsiBridge] Settings:', JSON.stringify(settings));

      // Show camera preview in video element
      if (cameraPreview) {
        cameraPreview.srcObject = cameraStream;
        document.body.classList.add('camera-mode');
        console.log('[JitsiBridge] Camera preview enabled');
      }

      notifyFlutter('cameraReady', { source: source });
      console.log('[JitsiBridge] ========== setVideoSource SUCCESS ==========');
      return true;
    } catch (e) {
      console.error('[JitsiBridge] getUserMedia FAILED:', e.name, e.message);
      console.error('[JitsiBridge] Error stack:', e.stack);
      notifyFlutter('error', { message: 'Camera access failed: ' + e.message });
      console.log('[JitsiBridge] ========== setVideoSource FAILED ==========');
      return false;
    }
  } else {
    // Canvas mode for glasses - release camera if we had one
    if (cameraStream) {
      console.log('[JitsiBridge] Releasing camera stream for canvas mode');
      cameraStream.getTracks().forEach(track => track.stop());
      cameraStream = null;
    }

    // Hide camera preview, show canvas
    if (cameraPreview) {
      cameraPreview.srcObject = null;
      document.body.classList.remove('camera-mode');
      console.log('[JitsiBridge] Camera preview disabled, showing canvas');
    }

    console.log('[JitsiBridge] Set to canvas mode for glasses');
    console.log('[JitsiBridge] ========== setVideoSource SUCCESS (canvas) ==========');
    return true;
  }
}

// Get current video source mode
function getVideoSourceMode() {
  return {
    mode: videoSourceMode,
    hasCamera: cameraStream !== null,
    hasCameraTrack: cameraStream?.getVideoTracks().length > 0
  };
}

// Expose functions to Flutter
// Create video track from canvas captureStream or camera getUserMedia
async function startVideoTrack() {
  console.log('[JitsiBridge] ========== startVideoTrack START ==========');
  console.log('[JitsiBridge] videoTrackStarted:', videoTrackStarted);
  console.log('[JitsiBridge] conference:', !!conference);
  console.log('[JitsiBridge] videoSourceMode:', videoSourceMode);
  console.log('[JitsiBridge] cameraStream:', !!cameraStream);

  if (videoTrackStarted) {
    console.log('[JitsiBridge] Video track already started - returning');
    return;
  }
  if (!conference) {
    console.log('[JitsiBridge] Cannot start video track - no conference');
    return;
  }

  console.log('[JitsiBridge] Starting video track, mode:', videoSourceMode);

  try {
    let videoTrackInfo;

    if (videoSourceMode === 'camera' && cameraStream) {
      // Camera mode: use getUserMedia stream directly
      // This is the efficient path - no canvas, no frame processing!
      console.log('[JitsiBridge] Using camera stream directly (getUserMedia)');
      console.log('[JitsiBridge] Camera stream tracks:', cameraStream.getTracks().length);
      const videoTrack = cameraStream.getVideoTracks()[0];
      console.log('[JitsiBridge] Camera video track:', videoTrack?.label, 'readyState:', videoTrack?.readyState);

      // Get resolution from track settings for logging
      const settings = videoTrack ? videoTrack.getSettings() : {};
      const width = settings.width || 1280;
      const height = settings.height || 720;
      console.log('[JitsiBridge] Camera resolution:', width, 'x', height);
      console.log('[JitsiBridge] Camera track settings:', JSON.stringify(settings));

      // Must include constraints with height/width - JitsiLocalTrack constructor requires them
      // See: https://github.com/jitsi/lib-jitsi-meet/blob/master/modules/RTC/JitsiLocalTrack.ts
      videoTrackInfo = [{
        stream: cameraStream,
        track: videoTrack,
        sourceType: 'camera',
        mediaType: 'video',
        videoType: 'camera',
        constraints: {
          height: { ideal: height },
          width: { ideal: width }
        }
      }];
    } else {
      // Canvas mode: use captureStream for glasses frames
      console.log('[JitsiBridge] Using canvas captureStream for glasses');
      console.log('[JitsiBridge] Canvas dimensions:', canvas.width, 'x', canvas.height);
      canvasStream = canvas.captureStream(24); // 24 fps max from glasses

      // Get actual canvas dimensions for constraints
      const canvasWidth = canvas.width || 504;
      const canvasHeight = canvas.height || 896;

      videoTrackInfo = [{
        stream: canvasStream,
        track: canvasStream.getVideoTracks()[0],
        sourceType: 'canvas',
        mediaType: 'video',
        videoType: 'camera',  // Must be 'camera' - 'desktop' not supported in WebView
        // Include constraints to help WebRTC target the correct resolution
        // No min values - let SDK adjust as needed for bandwidth
        constraints: {
          width: { ideal: canvasWidth },
          height: { ideal: canvasHeight },
          frameRate: { ideal: 24 }
        }
      }];
      console.log('[JitsiBridge] Canvas track constraints:', canvasWidth, 'x', canvasHeight, '@ 24fps');
    }

    console.log('[JitsiBridge] Creating Jitsi local track from stream...');
    const videoTracks = JitsiMeetJS.createLocalTracksFromMediaStreams(videoTrackInfo);
    localVideoTrack = videoTracks[0];
    console.log('[JitsiBridge] Local video track created:', !!localVideoTrack);
    if (localVideoTrack) {
      console.log('[JitsiBridge] Track type:', localVideoTrack.getType());
      console.log('[JitsiBridge] Track videoType:', localVideoTrack.videoType);
      console.log('[JitsiBridge] Track ID:', localVideoTrack.getId());
    }

    // Add to conference - log state before and after
    console.log('[JitsiBridge] Adding track to conference...');
    console.log('[JitsiBridge] Before addTrack - jvbJingleSession:', !!conference.jvbJingleSession);
    console.log('[JitsiBridge] Before addTrack - p2pJingleSession:', !!conference.p2pJingleSession);
    await conference.addTrack(localVideoTrack);
    console.log('[JitsiBridge] After addTrack - jvbJingleSession:', !!conference.jvbJingleSession);
    console.log('[JitsiBridge] After addTrack - p2pJingleSession:', !!conference.p2pJingleSession);

    videoTrackStarted = true;
    console.log('[JitsiBridge] Video track started and added to conference (mode:', videoSourceMode, ')');
    console.log('[JitsiBridge] ========== startVideoTrack SUCCESS ==========');
    updateStatus('Video streaming started (' + videoSourceMode + ')');
    notifyFlutter('videoTrackStarted', { mode: videoSourceMode });
  } catch (videoError) {
    console.error('[JitsiBridge] Video track creation failed:', videoError);
    console.error('[JitsiBridge] Error stack:', videoError.stack);
    console.log('[JitsiBridge] ========== startVideoTrack FAILED ==========');
    notifyFlutter('error', { message: 'Video track failed: ' + videoError.message });
  }
}

async function stopVideoTrack() {
  if (!videoTrackStarted) {
    console.log('[JitsiBridge] Video track already stopped');
    return;
  }

  console.log('[JitsiBridge] Stopping video track');

  try {
    if (localVideoTrack) {
      if (conference) {
        await conference.removeTrack(localVideoTrack);
      }
      localVideoTrack.dispose();
      localVideoTrack = null;
    }
    if (canvasStream) {
      canvasStream.getTracks().forEach(track => track.stop());
      canvasStream = null;
    }
    // Note: don't stop cameraStream here - it's managed by setVideoSource

    videoTrackStarted = false;
    console.log('[JitsiBridge] Video track stopped');
    updateStatus('Video streaming paused');
    notifyFlutter('videoTrackStopped', {});
  } catch (e) {
    console.error('[JitsiBridge] Error stopping video track:', e);
  }
}

// Debug function to test captureStream CPU impact
let captureStreamPaused = false;
function toggleCaptureStream() {
  captureStreamPaused = !captureStreamPaused;
  if (captureStreamPaused && canvasStream) {
    // Stop the tracks to see if CPU drops
    canvasStream.getTracks().forEach(track => track.stop());
    console.log('[JitsiBridge] captureStream STOPPED - check if CPU drops');
  } else if (!captureStreamPaused) {
    // Recreate captureStream
    canvasStream = canvas.captureStream(24);
    console.log('[JitsiBridge] captureStream RESUMED');
  }
  return captureStreamPaused ? 'stopped' : 'running';
}

// Comprehensive diagnostic dump - call this when things fail
function diagnosePeerConnection() {
  console.log('[JitsiBridge] ============ PEER CONNECTION DIAGNOSIS ============');
  console.log('[JitsiBridge] isJoined:', isJoined);
  console.log('[JitsiBridge] videoTrackStarted:', videoTrackStarted);
  console.log('[JitsiBridge] videoSourceMode:', videoSourceMode);
  console.log('[JitsiBridge] cameraStream:', !!cameraStream);
  console.log('[JitsiBridge] localVideoTrack:', !!localVideoTrack);
  console.log('[JitsiBridge] localAudioTrack:', !!localAudioTrack);
  console.log('[JitsiBridge] conference:', !!conference);

  if (conference) {
    console.log('[JitsiBridge] jvbJingleSession:', !!conference.jvbJingleSession);
    console.log('[JitsiBridge] p2pJingleSession:', !!conference.p2pJingleSession);
    console.log('[JitsiBridge] room:', conference.room?.roomname || 'unknown');

    // Check local tracks in conference
    const localTracks = conference.getLocalTracks();
    console.log('[JitsiBridge] Conference local tracks:', localTracks.length);
    localTracks.forEach((track, i) => {
      console.log('[JitsiBridge]   Track ' + i + ':', track.getType(), 'videoType:', track.videoType);
    });

    // Check peer connections
    if (conference.jvbJingleSession?.peerconnection?.peerconnection) {
      const pc = conference.jvbJingleSession.peerconnection.peerconnection;
      console.log('[JitsiBridge] JVB PeerConnection state:', pc.connectionState);
      console.log('[JitsiBridge] JVB ICE state:', pc.iceConnectionState);
      console.log('[JitsiBridge] JVB signaling state:', pc.signalingState);

      // Check senders
      const senders = pc.getSenders();
      console.log('[JitsiBridge] JVB senders:', senders.length);
      senders.forEach((sender, i) => {
        console.log('[JitsiBridge]   Sender ' + i + ':', sender.track?.kind || 'no track', 'enabled:', sender.track?.enabled);
      });
    } else {
      console.log('[JitsiBridge] No JVB peer connection available');
    }

    if (conference.p2pJingleSession?.peerconnection?.peerconnection) {
      const pc = conference.p2pJingleSession.peerconnection.peerconnection;
      console.log('[JitsiBridge] P2P PeerConnection state:', pc.connectionState);
      console.log('[JitsiBridge] P2P ICE state:', pc.iceConnectionState);
    }
  }
  console.log('[JitsiBridge] =====================================================');
}

// Debug function to check what tracks exist and their states
function debugTracks() {
  console.log('[JitsiBridge] === TRACK DEBUG ===');
  console.log('[JitsiBridge] canvasStream exists:', !!canvasStream);
  if (canvasStream) {
    const tracks = canvasStream.getTracks();
    console.log('[JitsiBridge] canvasStream tracks:', tracks.length);
    tracks.forEach((t, i) => {
      console.log('[JitsiBridge]   Track ' + i + ':', t.kind, 'enabled:', t.enabled, 'readyState:', t.readyState);
      const settings = t.getSettings();
      console.log('[JitsiBridge]   Settings:', JSON.stringify(settings));
    });
  }
  console.log('[JitsiBridge] localVideoTrack exists:', !!localVideoTrack);
  console.log('[JitsiBridge] localAudioTrack exists:', !!localAudioTrack);
  console.log('[JitsiBridge] ====================');
}

window.initJitsi = initJitsi;
window.joinRoom = joinRoom;
window.leaveRoom = leaveRoom;
window.setResolution = setResolution;
window.setAudioMuted = setAudioMuted;
window.setVideoMuted = setVideoMuted;
window.toggleAudio = toggleAudio;
window.toggleVideo = toggleVideo;
window.getState = getState;
window.getStats = getStats;
window.setupE2EE = setupE2EE;
window.disableE2EE = disableE2EE;
window.isE2EE = isE2EE;
window.logCodecInfo = logCodecInfo;
window.toggleCaptureStream = toggleCaptureStream;
window.debugTracks = debugTracks;
window.logProfileStats = logProfileStats;
window.startVideoTrack = startVideoTrack;
window.stopVideoTrack = stopVideoTrack;
window.setVideoSource = setVideoSource;
window.getVideoSourceMode = getVideoSourceMode;
window.diagnosePeerConnection = diagnosePeerConnection;

// Auto-initialize when script loads
if (typeof JitsiMeetJS !== 'undefined') {
  initJitsi();
} else {
  updateStatus('Waiting for lib-jitsi-meet...');
  // Retry after lib-jitsi-meet loads
  window.addEventListener('load', () => {
    if (typeof JitsiMeetJS !== 'undefined') {
      initJitsi();
    } else {
      updateStatus('Error: lib-jitsi-meet not loaded');
      notifyFlutter('error', { message: 'lib-jitsi-meet not loaded' });
    }
  });
}
