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

// E2EE config (stored from joinRoom call)
let e2eeConfig = { enabled: false, passphrase: '' };

// Canvas setup
const canvas = document.getElementById('videoCanvas');
const ctx = canvas.getContext('2d');
let canvasStream = null;

// Stats tracking
let frameCount = 0;
let lastFrameTime = Date.now();
let lastStatsTime = Date.now();
let lastStatsFrameCount = 0;
let currentFps = 0;
let totalBytesReceived = 0;
let lastBytesReceived = 0;
let currentBitrate = 0; // kbps

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
    JitsiMeetJS.init({
      disableAudioLevels: true,
      disableSimulcast: false
    });
    JitsiMeetJS.setLogLevel(JitsiMeetJS.logLevels.WARN);
    updateStatus('lib-jitsi-meet initialized');
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
    try {
      canvasStream = canvas.captureStream(24); // 24 fps
      const videoTrackInfo = [{
        stream: canvasStream,
        sourceType: 'canvas',
        mediaType: 'video',
        videoType: 'camera'
      }];
      const videoTracks = JitsiMeetJS.createLocalTracksFromMediaStreams(videoTrackInfo);
      localVideoTrack = videoTracks[0];
      updateStatus('Video track created from canvas');
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

// Draw frame to canvas (called from Flutter via JS bridge)
function drawFrame(base64Data) {
  if (!base64Data) return;

  // Track bytes for bitrate calculation
  const byteLength = base64Data.length * 0.75; // Approximate decoded size
  totalBytesReceived += byteLength;
  frameCount++;

  // Calculate FPS and bitrate every second
  const now = Date.now();
  const elapsed = now - lastStatsTime;
  if (elapsed >= 1000) {
    const framesDelta = frameCount - lastStatsFrameCount;
    currentFps = Math.round(framesDelta * 1000 / elapsed);

    const bytesDelta = totalBytesReceived - lastBytesReceived;
    currentBitrate = Math.round(bytesDelta * 8 / elapsed); // kbps

    lastStatsTime = now;
    lastStatsFrameCount = frameCount;
    lastBytesReceived = totalBytesReceived;
  }

  const img = new Image();
  img.onload = () => {
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    lastFrameTime = Date.now();
  };
  img.onerror = () => {
    console.warn('[JitsiBridge] Failed to decode frame');
  };
  img.src = 'data:image/jpeg;base64,' + base64Data;
}

// Get current stats
function getStats() {
  return {
    resolution: canvas.width + 'x' + canvas.height,
    width: canvas.width,
    height: canvas.height,
    fps: currentFps,
    bitrate: currentBitrate,
    totalFrames: frameCount,
    totalBytes: totalBytesReceived,
    isJoined: isJoined,
    hasAudioTrack: localAudioTrack !== null,
    hasVideoTrack: localVideoTrack !== null,
    isE2EEEnabled: isE2EEEnabled
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
function setVideoMuted(muted) {
  isVideoMuted = muted;
  if (localVideoTrack) {
    if (muted) {
      localVideoTrack.mute();
    } else {
      localVideoTrack.unmute();
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
window.drawFrame = drawFrame;
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
