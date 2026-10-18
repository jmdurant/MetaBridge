const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');

function bridge() {
  const sockets = [], events = [], timers = new Map();
  let timerId = 0;
  class Socket {
    static OPEN = 1;
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; sockets.push(this); }
    close() { this.readyState = 3; }
    send(data) { this.sent.push(data); }
    open() { this.readyState = 1; this.onopen(); }
  }
  const element = { width: 504, height: 896, style: {}, classList: { add() {}, remove() {} } };
  const context = vm.createContext({
    console: { log() {}, warn() {}, error() {} },
    document: { getElementById: () => element, body: element },
    WebSocket: Socket, URL, Blob, TextEncoder, crypto: webcrypto, performance,
    setTimeout(fn) { const id = ++timerId; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); }, setInterval() { return 1; }, clearInterval() {},
    addEventListener() {},
    flutter_inappwebview: { callHandler(_, event, data) { events.push([event, JSON.parse(data)]); } }
  });
  context.window = context;
  vm.runInContext(fs.readFileSync('assets/jitsi_bridge.js', 'utf8'), context);
  return { context, sockets, events, timers, run: code => vm.runInContext(code, context) };
}

test('a late native close cannot reset a connected Flutter fallback', () => {
  const b = bridge();
  b.context.connectWebSocket();
  const native = b.sockets[0];
  native.onerror();
  const fallback = b.sockets[1];
  assert.match(fallback.url, /:8765$/);
  fallback.open();
  native.onclose();
  assert.equal(b.run('wsConnected'), true);
  assert.equal(b.run('frameSocket'), fallback);
  assert.equal(b.timers.size, 0);
});

test('failed fallback reconnects and receipt acknowledges frame delivery', () => {
  const b = bridge();
  b.context.connectWebSocket();
  b.sockets[0].onerror();
  b.sockets[1].onerror();
  assert.equal(b.timers.size, 1);
  const retry = [...b.timers.values()][0];
  retry();
  const socket = b.sockets[2];
  socket.open();
  // Keep one decode in flight to test delivery independent of browser rendering.
  b.run('isProcessingFrame = true');
  socket.onmessage({ data: new Blob([new Uint8Array([1, 2, 3])]) });
  assert.deepEqual(socket.sent, ['frameReceived']);
});

test('requested E2EE aborts before media creation when unsupported', async () => {
  const b = bridge();
  let tracksCreated = 0, joined = 0, left = 0;
  b.context.mockConference = {
    isE2EESupported: () => false,
    leave: async () => { left++; },
    join: () => { joined++; }
  };
  b.context.JitsiMeetJS = { createLocalTracks: () => { tracksCreated++; return []; } };
  b.run(`e2eeConfig = { enabled: true, passphrase: 'shared secret' };
    connection = { initJitsiConference: () => mockConference, disconnect() {} };`);
  await b.context.onConnectionEstablished('room', 'name', true);
  assert.equal(tracksCreated, 0);
  assert.equal(joined, 0);
  assert.equal(left, 1);
  assert.equal(b.run('isE2EEEnabled'), false);
  assert.ok(b.events.some(([event]) => event === 'e2eeError'));
});

test('E2EE uses a CryptoKey and checks the enabled state', async () => {
  const b = bridge();
  let keyInfo;
  b.context.mockConference = {
    isE2EESupported: () => true,
    setMediaEncryptionKey: info => { keyInfo = info; },
    toggleE2EE() {}, isE2EEEnabled: () => false
  };
  b.run('conference = mockConference');
  await assert.rejects(b.context.setupE2EE('shared secret'), /did not enable/);
  assert.equal(keyInfo.encryptionKey.algorithm.name, 'HKDF');
  assert.equal(b.run('isE2EEEnabled'), false);
  b.context.mockConference.isE2EEEnabled = () => true;
  assert.equal(await b.context.setupE2EE('shared secret'), true);
});

test('microphone preference reaches the connection callback', async () => {
  const b = bridge();
  const listeners = {};
  let observed;
  b.context.JitsiMeetJS = {
    events: { connection: { CONNECTION_ESTABLISHED: 'connected' } },
    JitsiConnection: class {
      addEventListener(event, handler) { listeners[event] = handler; }
      connect() {}
    }
  };
  b.context.recordConnection = (...args) => { observed = args; };
  b.run('onConnectionEstablished = recordConnection');
  await b.context.joinRoom('https://meet.example.org', 'room', 'name', false, '', false);
  listeners.connected();
  assert.deepEqual(observed, ['room', 'name', false]);
});

test('stale frames are rejected after the timestamp sign bit and rollover', async () => {
  for (const now of [0x90000000, 0x100000020]) {
    const b = bridge();
    b.context.testNow = now;
    b.run('Date.now = () => testNow');
    const data = new ArrayBuffer(18);
    const header = new DataView(data);
    header.setUint32(0, 2, true); header.setUint32(4, 2, true);
    header.setUint32(8, (now - 200) >>> 0, true);
    await b.context.processI420FrameInternal(new Blob([data]));
    assert.equal(b.run('framesDroppedStale'), 1);
  }
});
