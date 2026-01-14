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
let framesWhileProcessing = 0;
let totalDecodeTimeMs = 0;
let lastDecodeTimeMs = 0;
let isProcessingFrame = false;
let lastFrameArrivalTime = 0;
let frameArrivalIntervals = [];
let pendingFrameData = null;

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

function connectWebSocket() {
  if (frameSocket && frameSocket.readyState === WebSocket.OPEN) {
    return; // Already connected
  }

  console.log('[JitsiBridge] Connecting to WebSocket...');
  updateStatus('Connecting to frame server...');

  try {
    // Use 127.0.0.1 explicitly - localhost may not resolve correctly in WebView
    frameSocket = new WebSocket('ws://127.0.0.1:8765');
    frameSocket.binaryType = 'blob';

    frameSocket.onopen = () => {
      console.log('[JitsiBridge] WebSocket connected');
      updateStatus('Frame server connected');
      wsConnected = true;
      notifyFlutter('wsConnected', {});
    };

    frameSocket.onmessage = (event) => {
      // Receive binary blob directly - no base64 decoding needed!
      handleBinaryFrame(event.data);
    };

    frameSocket.onclose = () => {
      console.log('[JitsiBridge] WebSocket disconnected');
      wsConnected = false;
      notifyFlutter('wsDisconnected', {});
      // Retry connection after delay
      if (!wsReconnectTimer) {
        wsReconnectTimer = setTimeout(() => {
          wsReconnectTimer = null;
          connectWebSocket();
        }, 2000);
      }
    };

    frameSocket.onerror = (error) => {
      console.error('[JitsiBridge] WebSocket error:', error);
      console.error('[JitsiBridge] WebSocket readyState:', frameSocket.readyState);
      console.error('[JitsiBridge] WebSocket url:', frameSocket.url);
      wsConnected = false;
    };
  } catch (e) {
    console.error('[JitsiBridge] WebSocket connection failed:', e);
    console.error('[JitsiBridge] Exception:', e.message, e.stack);
    wsConnected = false;
  }
}

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

    // Debug logging - calculate avg arrival interval
    const avgInterval = frameArrivalIntervals.length > 0
      ? Math.round(frameArrivalIntervals.reduce((a, b) => a + b, 0) / frameArrivalIntervals.length)
      : 0;
    console.log('[JitsiBridge] Stats: received=' + frameCount + ' drawn=' + framesDrawn + ' dropped=' + framesDroppedJs + ' whileProcessing=' + framesWhileProcessing + ' avgArrivalMs=' + avgInterval);
  }

  // If already processing, save as pending (drop previous pending)
  if (isProcessingFrame) {
    framesWhileProcessing++;
    if (pendingFrameData) {
      framesDroppedJs++;
    }
    pendingFrameData = blob;
    return;
  }

  processI420Frame(blob);
}

// Process I420 frame with WebGL
async function processI420Frame(blob) {
  isProcessingFrame = true;
  const decodeStart = Date.now();

  try {
    // Read blob as ArrayBuffer - track timing
    const blobReadStart = performance.now();
    const buffer = await blob.arrayBuffer();
    const blobReadTime = performance.now() - blobReadStart;
    profileStats.blobRead.total += blobReadTime;
    profileStats.blobRead.count++;

    // Parse header: width (4 bytes), height (4 bytes), then I420 data
    if (buffer.byteLength < 8) {
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

    // Calculate expected I420 size
    const ySize = width * height;
    const uvSize = (width / 2) * (height / 2);
    const expectedSize = 8 + ySize + uvSize * 2;

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
    const yData = new Uint8Array(buffer, 8, ySize);
    const uData = new Uint8Array(buffer, 8 + ySize, uvSize);
    const vData = new Uint8Array(buffer, 8 + ySize + uvSize, uvSize);

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

  isProcessingFrame = false;

  // Process pending frame if any
  if (pendingFrameData) {
    const nextData = pendingFrameData;
    pendingFrameData = null;
    processI420Frame(nextData);
  }
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
async function joinRoom(server, room, displayName, enableE2EE = false, e2eePassphrase = '') {
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
      // NOTE: AV1 uses software (libaom) in WebView even on Pixel 9a
      // H264 has the best hardware encoder support via MediaCodec on Android
      videoQuality: {
        // Desktop codec preference - H264 first for HW encoding, then VP9, AV1
        codecPreferenceOrder: ['H264', 'VP9', 'AV1', 'VP8'],
        // Mobile codec preference - H264 first for reliable HW encoding (MediaCodec)
        mobileCodecPreferenceOrder: ['H264', 'VP9', 'AV1', 'VP8'],
        // Screenshare codec - use H264 for hardware encoding
        screenshareCodec: 'H264',
        mobileScreenshareCodec: 'H264',
        // Enable adaptive mode to handle CPU overuse
        enableAdaptiveMode: true,
        // AV1 config with KSVC for efficiency
        av1: {
          maxBitratesVideo: {
            low: 100000,
            standard: 300000,
            high: 1000000,
            fullHd: 2000000,
            ultraHd: 4000000,
            ssHigh: 2500000
          },
          scalabilityModeEnabled: true,
          useSimulcast: false,
          useKSVC: true
        },
        // H264 fallback config
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
        },
        // VP9 config (good hardware support)
        vp9: {
          maxBitratesVideo: {
            low: 100000,
            standard: 300000,
            high: 1200000,
            fullHd: 2500000,
            ultraHd: 5000000,
            ssHigh: 2500000
          },
          scalabilityModeEnabled: true,
          useSimulcast: false,
          useKSVC: true
        },
        // VP8 config (often software-only, avoid if possible)
        vp8: {
          maxBitratesVideo: {
            low: 200000,
            standard: 500000,
            high: 1500000,
            fullHd: 3000000,
            ultraHd: 6000000,
            ssHigh: 2500000
          },
          scalabilityModeEnabled: false
        }
      }
    });

    // Create audio track from microphone
    try {
      const audioTracks = await JitsiMeetJS.createLocalTracks({
        devices: ['audio'],
        micDeviceId: 'default'
      });
      localAudioTrack = audioTracks[0];
      updateStatus('Audio track created');
    } catch (audioError) {
      console.warn('[JitsiBridge] Audio track creation failed:', audioError);
      // Continue without audio if it fails
    }

    // Create video track immediately on join
    await startVideoTrack();
    console.log('[JitsiBridge] Video track created on join');

    // Conference event listeners
    conference.on(JitsiMeetJS.events.conference.CONFERENCE_JOINED, async () => {
      isJoined = true;
      updateStatus('Joined room: ' + room);

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
      } catch (e) {
        console.log('[JitsiBridge] Could not log track info:', e);
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

      notifyFlutter('joined', { room: room, e2ee: e2eeConfig.enabled });
    });

    conference.on(JitsiMeetJS.events.conference.CONFERENCE_LEFT, () => {
      isJoined = false;
      updateStatus('Left room');
      notifyFlutter('left', {});
    });

    conference.on(JitsiMeetJS.events.conference.CONFERENCE_FAILED, (error) => {
      updateStatus('Conference failed: ' + error);
      notifyFlutter('conferenceFailed', { error: String(error) });
    });

    conference.on(JitsiMeetJS.events.conference.USER_JOINED, (id, user) => {
      remoteParticipantCount++;
      console.log('[JitsiBridge] Peer joined, count:', remoteParticipantCount);
      notifyFlutter('participantJoined', {
        id: id,
        displayName: user.getDisplayName() || 'Guest'
      });
    });

    conference.on(JitsiMeetJS.events.conference.USER_LEFT, (id) => {
      remoteParticipantCount = Math.max(0, remoteParticipantCount - 1);
      console.log('[JitsiBridge] Peer left, count:', remoteParticipantCount);
      notifyFlutter('participantLeft', { id: id });
    });

    conference.on(JitsiMeetJS.events.conference.TRACK_ADDED, (track) => {
      if (track.isLocal()) return;
      notifyFlutter('remoteTrackAdded', {
        participantId: track.getParticipantId(),
        type: track.getType()
      });
    });

    conference.on(JitsiMeetJS.events.conference.TRACK_REMOVED, (track) => {
      if (track.isLocal()) return;
      notifyFlutter('remoteTrackRemoved', {
        participantId: track.getParticipantId(),
        type: track.getType()
      });
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
    conference.join();

  } catch (e) {
    updateStatus('Conference error: ' + e.message);
    notifyFlutter('error', { message: e.message });
  }
}

// Get current stats
function getStats() {
  const avgDecodeMs = framesDrawn > 0 ? Math.round(totalDecodeTimeMs / framesDrawn) : 0;
  const jsDropRate = frameCount > 0 ? Math.round(framesDroppedJs * 100 / frameCount) : 0;
  const avgArrivalMs = frameArrivalIntervals.length > 0
    ? Math.round(frameArrivalIntervals.reduce((a, b) => a + b, 0) / frameArrivalIntervals.length)
    : 0;
  return {
    resolution: canvas.width + 'x' + canvas.height,
    width: canvas.width,
    height: canvas.height,
    fps: currentFps,
    bitrate: currentBitrate,
    totalFrames: frameCount,
    framesDrawn: framesDrawn,
    framesDroppedJs: framesDroppedJs,
    framesWhileProcessing: framesWhileProcessing,
    jsDropRate: jsDropRate,
    lastDecodeMs: lastDecodeTimeMs,
    avgDecodeMs: avgDecodeMs,
    avgArrivalMs: avgArrivalMs,
    totalBytes: totalBytesReceived,
    isJoined: isJoined,
    hasAudioTrack: localAudioTrack !== null,
    hasVideoTrack: localVideoTrack !== null,
    isE2EEEnabled: isE2EEEnabled,
    wsConnected: wsConnected
  };
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
function setVideoMuted(muted) {
  isVideoMuted = muted;
  if (localVideoTrack) {
    try {
      if (muted) {
        localVideoTrack.mute();
      } else {
        localVideoTrack.unmute();
      }
    } catch (e) {
      console.warn('[JitsiBridge] Video mute/unmute error (ignored):', e);
    }
    notifyFlutter('videoMutedChanged', { muted: muted });
  }
}

function toggleVideo() {
  setVideoMuted(!isVideoMuted);
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
function leaveRoom() {
  updateStatus('Leaving room...');

  try {
    if (localAudioTrack) {
      localAudioTrack.dispose();
      localAudioTrack = null;
    }
    if (localVideoTrack) {
      localVideoTrack.dispose();
      localVideoTrack = null;
    }
    if (conference) {
      conference.leave();
      conference = null;
    }
    if (connection) {
      connection.disconnect();
      connection = null;
    }

    isJoined = false;
    isE2EEEnabled = false;
    canvasStream = null;
    e2eeConfig = { enabled: false, passphrase: '' };
    remoteParticipantCount = 0;
    videoTrackStarted = false;
    updateStatus('Left room');
    notifyFlutter('left', {});
  } catch (e) {
    console.error('[JitsiBridge] Leave error:', e);
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
    console.log('[JitsiBridge] jvbJingleSession:', !!conference.jvbJingleSession);
    console.log('[JitsiBridge] p2pJingleSession:', !!conference.p2pJingleSession);

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

// Expose functions to Flutter
// Create video track from canvas captureStream
async function startVideoTrack() {
  if (videoTrackStarted) {
    console.log('[JitsiBridge] Video track already started');
    return;
  }
  if (!conference) {
    console.log('[JitsiBridge] Cannot start video track - no conference');
    return;
  }

  console.log('[JitsiBridge] Starting video track (peer joined, starting captureStream)');

  try {
    // NOW we create captureStream - only when needed!
    canvasStream = canvas.captureStream(24); // 24 fps max from glasses
    const videoTrackInfo = [{
      stream: canvasStream,
      sourceType: 'canvas',
      mediaType: 'video',
      videoType: 'desktop'  // 'desktop' type = screen share, won't trigger camera acquisition
    }];
    const videoTracks = JitsiMeetJS.createLocalTracksFromMediaStreams(videoTrackInfo);
    localVideoTrack = videoTracks[0];

    // Add to conference
    await conference.addTrack(localVideoTrack);

    videoTrackStarted = true;
    console.log('[JitsiBridge] Video track started and added to conference');
    updateStatus('Video streaming started (peer present)');
    notifyFlutter('videoTrackStarted', {});
  } catch (videoError) {
    console.error('[JitsiBridge] Video track creation failed:', videoError);
    notifyFlutter('error', { message: 'Video track failed: ' + videoError.message });
  }
}

async function stopVideoTrack() {
  if (!videoTrackStarted) {
    console.log('[JitsiBridge] Video track already stopped');
    return;
  }

  console.log('[JitsiBridge] Stopping video track (no peers remaining)');

  try {
    if (localVideoTrack) {
      await conference.removeTrack(localVideoTrack);
      localVideoTrack.dispose();
      localVideoTrack = null;
    }
    if (canvasStream) {
      canvasStream.getTracks().forEach(track => track.stop());
      canvasStream = null;
    }

    videoTrackStarted = false;
    console.log('[JitsiBridge] Video track stopped - CPU savings when alone');
    updateStatus('Video streaming paused (no peers)');
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
