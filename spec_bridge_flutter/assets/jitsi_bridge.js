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

// Initialize WebGL for I420 YUV rendering
function initWebGL() {
  gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
  if (!gl) {
    console.warn('[JitsiBridge] WebGL not supported, falling back to 2D canvas');
    ctx = canvas.getContext('2d');
    return false;
  }
  console.log('[JitsiBridge] WebGL initialized');

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
  return true;
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
    // Read blob as ArrayBuffer
    const buffer = await blob.arrayBuffer();
    const data = new Uint8Array(buffer);

    // Parse header: width (4 bytes), height (4 bytes), then I420 data
    if (data.length < 8) {
      console.warn('[JitsiBridge] Frame too small:', data.length);
      isProcessingFrame = false;
      return;
    }

    const view = new DataView(buffer);
    const width = view.getUint32(0, true);  // little-endian
    const height = view.getUint32(4, true);

    // Calculate expected I420 size
    const ySize = width * height;
    const uvSize = (width / 2) * (height / 2);
    const expectedSize = 8 + ySize + uvSize * 2;

    if (data.length < expectedSize) {
      console.warn('[JitsiBridge] Frame data incomplete: got ' + data.length + ', expected ' + expectedSize);
      isProcessingFrame = false;
      return;
    }

    // Extract Y, U, V planes
    const yData = new Uint8Array(buffer, 8, ySize);
    const uData = new Uint8Array(buffer, 8 + ySize, uvSize);
    const vData = new Uint8Array(buffer, 8 + ySize + uvSize, uvSize);

    // Render using WebGL
    if (gl) {
      renderI420Frame(yData, uData, vData, width, height);
    } else {
      // Fallback: would need to convert to RGB manually (not implemented)
      console.warn('[JitsiBridge] WebGL not available, cannot render I420');
    }

    // Track timing
    lastDecodeTimeMs = Date.now() - decodeStart;
    totalDecodeTimeMs += lastDecodeTimeMs;
    framesDrawn++;
    lastFrameTime = Date.now();

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
    // Initialize conference with E2EE support
    conference = connection.initJitsiConference(room.toLowerCase(), {
      openBridgeChannel: true,
      p2p: {
        enabled: true
      },
      e2ee: {
        enabled: e2eeConfig.enabled
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

    // Create video track from canvas
    // Using 'desktop' type prevents Jitsi from trying to re-acquire a real camera on unmute
    try {
      canvasStream = canvas.captureStream(30); // 30 fps to match glasses
      const videoTrackInfo = [{
        stream: canvasStream,
        sourceType: 'canvas',
        mediaType: 'video',
        videoType: 'desktop'  // 'desktop' type = screen share, won't trigger camera acquisition
      }];
      const videoTracks = JitsiMeetJS.createLocalTracksFromMediaStreams(videoTrackInfo);
      localVideoTrack = videoTracks[0];
      updateStatus('Video track created from canvas (as desktop share)');
    } catch (videoError) {
      console.error('[JitsiBridge] Video track creation failed:', videoError);
      notifyFlutter('error', { message: 'Video track failed: ' + videoError.message });
    }

    // Conference event listeners
    conference.on(JitsiMeetJS.events.conference.CONFERENCE_JOINED, async () => {
      isJoined = true;
      updateStatus('Joined room: ' + room);

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
      notifyFlutter('participantJoined', {
        id: id,
        displayName: user.getDisplayName() || 'Guest'
      });
    });

    conference.on(JitsiMeetJS.events.conference.USER_LEFT, (id) => {
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

    // Add tracks to conference
    if (localAudioTrack) {
      await conference.addTrack(localAudioTrack);
    }
    if (localVideoTrack) {
      await conference.addTrack(localVideoTrack);
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

// Expose functions to Flutter
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
