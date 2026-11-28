// CefProtectedMedia's page script, for the FairPlay origins only, in the
// top frame, before the page's own scripts. `name` is the CefFairPlay
// bridge's global, `keySystems` the key systems to offer.
//
// It offers FairPlay Streaming through EME, catches the HLS playlist the
// player gives a media element and the certificate it gives its
// MediaKeys, and hands both to the app, whose FairPlay service plays the
// stream with AVFoundation. The key requests (SPC) the service makes come
// back as the session's `message` events; the licenses (CKC) the page's
// license server returns go back through `update`. The element then
// mirrors the service's player: its time, duration, paused and ended
// state and their events. Keys and decrypted media never reach the page.
(function (name, keySystems) {
'use strict';
const apply = Reflect.apply, getOwn = Object.getOwnPropertyDescriptor, defineOwn = Object.defineProperty;
const original = {
  requestMediaKeySystemAccess: navigator.requestMediaKeySystemAccess,
  setMediaKeys: HTMLMediaElement.prototype.setMediaKeys,
  play: HTMLMediaElement.prototype.play,
  pause: HTMLMediaElement.prototype.pause,
  load: HTMLMediaElement.prototype.load,
};
const accessors = {};
for (const name of ['src', 'currentSrc', 'currentTime', 'duration', 'paused', 'ended', 'readyState', 'seeking',
  'networkState', 'error', 'mediaKeys', 'volume', 'muted', 'playbackRate', 'buffered']) {
  accessors[name] = getOwn(HTMLMediaElement.prototype, name);
}
// The bridge's global appears right after this script, as the document's
// context is set up, so it is taken on first use: when the page first
// asks for a key system, before anything else here needs it.
let bridge = null, ready = null;
// Whether the app offers FairPlay to this page; asked once, and pushed
// again when the app's setting changes.
let enabled = false;
function connect() {
  if (ready) return ready;
  bridge = window[name];
  if (!bridge) return (ready = Promise.resolve());
  bridge.on('config', (config) => { enabled = !!config.enabled; });
  bridge.on('keyRequest', keyRequested);
  bridge.on('state', stateReported);
  return (ready = bridge.hello({}).then((config) => { enabled = !!config.enabled; }, () => { enabled = false; }));
}

// EME: MediaKeySystemAccess, MediaKeys and MediaKeySession for FairPlay.
const keysOf = new WeakMap(); // fake MediaKeys -> {certificate}
const sessions = new Set(); // live fake sessions
class FairPlaySession extends EventTarget {
  constructor(keys) {
    super(); this.keys = keys; this.sessionId = ''; this.expiration = NaN; this.keyStatuses = new Map();
    this.onmessage = null; this.onkeystatuseschange = null; this.keyURI = null;
    let settle; this.closed = new Promise((r) => { settle = r; }); this.settleClosed = settle;
    sessions.add(this);
  }
  generateRequest(initDataType, initData) {
    // FairPlay's init data is the key's skd:// URI.
    const text = new TextDecoder(initData.byteLength && new Uint8Array(initData.buffer || initData)[1] === 0 ? 'utf-16le' : 'utf-8')
      .decode(initData).replace(/\0/g, '');
    this.keyURI = (/skd:\/\/[^\s"]*/.exec(text) || [text])[0];
    this.sessionId = 'fps-' + Math.random().toString(36).slice(2);
    const pending = pendingRequests.get(this.keyURI);
    if (pending) { pendingRequests.delete(this.keyURI); this.deliver(pending); }
    return Promise.resolve();
  }
  deliver(request) {
    const event = new MessageEvent('message', { data: null });
    defineOwn(event, 'message', { value: request.buffer });
    defineOwn(event, 'messageType', { value: 'license-request' });
    if (typeof this.onmessage === 'function') this.onmessage(event);
    this.dispatchEvent(event);
  }
  update(response) {
    const bytes = new Uint8Array(response.buffer ? response.buffer.slice(response.byteOffset, response.byteOffset + response.byteLength) : response);
    let binary = ''; for (const b of bytes) binary += String.fromCharCode(b);
    bridge.license({ keyURI: this.keyURI, license: btoa(binary) });
    this.keyStatuses = new Map([[new Uint8Array(16).buffer, 'usable']]);
    this.dispatchEvent(new Event('keystatuseschange'));
    return Promise.resolve();
  }
  close() { sessions.delete(this); this.settleClosed(); return Promise.resolve(); }
  remove() { return Promise.resolve(); }
  load() { return Promise.resolve(false); }
}
class FairPlayKeys {
  createSession() { return new FairPlaySession(this); }
  setServerCertificate(certificate) {
    const bytes = new Uint8Array(certificate.buffer ? certificate.buffer.slice(certificate.byteOffset, certificate.byteOffset + certificate.byteLength) : certificate);
    keysOf.get(this).certificate = bytes;
    return Promise.resolve(true);
  }
  getStatusForPolicy() { return Promise.resolve('usable'); }
}
class FairPlayAccess {
  constructor(keySystem, configuration) { this.keySystem = keySystem; this.configuration = configuration; }
  getConfiguration() { return this.configuration; }
  createMediaKeys() { const keys = new FairPlayKeys(); keysOf.set(keys, { certificate: null }); return Promise.resolve(keys); }
}
const replace = (target, name, value) => defineOwn(target, name, { ...getOwn(target, name), value });
replace(Navigator.prototype, 'requestMediaKeySystemAccess', { requestMediaKeySystemAccess(keySystem, configurations) {
  if (!keySystems.includes(keySystem)) return apply(original.requestMediaKeySystemAccess, this, [keySystem, configurations]);
  const navigatorObject = this;
  return connect().then(() => {
    if (!enabled) return apply(original.requestMediaKeySystemAccess, navigatorObject, [keySystem, configurations]);
    const configuration = (configurations && configurations[0]) || {};
    return new FairPlayAccess(keySystem, { ...configuration, initDataTypes: ['skd'] });
  });
} }.requestMediaKeySystemAccess);

// Elements the service plays, and their mirrored state.
const players = new WeakMap(); // element -> {id, state, keys, src}
const elementOf = new Map(); // session id -> its element, while it plays
const pendingRequests = new Map(); // key URI -> SPC waiting for generateRequest
let nextId = 0;

replace(HTMLMediaElement.prototype, 'setMediaKeys', { setMediaKeys(keys) {
  if (keys && keysOf.has(keys)) { players.set(this, { ...(players.get(this) || {}), keys, pendingKeys: true }); return Promise.resolve(); }
  return apply(original.setMediaKeys, this, [keys]);
} }.setMediaKeys);

const isPlaylist = (url) => /^data:application\/(vnd\.apple\.mpegurl|x-mpegurl)/i.test(url) || /\.m3u8(\?|#|$)/i.test(url);
function mirrored(element) { const p = players.get(element); return p && p.id ? p : null; }

defineOwn(HTMLMediaElement.prototype, 'src', { ...accessors.src,
  get: { get src() { const p = players.get(this); return p && p.src !== undefined ? p.src : apply(accessors.src.get, this, []); } }.__lookupGetter__('src'),
  set: { set src(value) {
    const p = players.get(this), url = String(value);
    if (enabled && p && p.keys && isPlaylist(url)) { start(this, p, url); return; }
    if (p && p.id) stop(this, p);
    apply(accessors.src.set, this, [value]);
  } }.__lookupSetter__('src') });

async function playlistText(url) {
  if (url.startsWith('data:')) {
    const comma = url.indexOf(','), meta = url.slice(5, comma), body = url.slice(comma + 1);
    return /;base64/i.test(meta) ? atob(body) : decodeURIComponent(body);
  }
  return (await fetch(url, { credentials: 'include' })).text();
}

async function start(element, player, url) {
  if (player.id) stop(element, player);
  const id = 'fp' + (++nextId) + '-' + Date.now().toString(36);
  Object.assign(player, { id, src: url, error: null, state: { currentTime: 0, duration: NaN, paused: true, ended: false, ready: false } });
  players.set(element, player);
  elementOf.set(id, element);
  fire(element, 'loadstart');
  try {
    const keysState = keysOf.get(player.keys);
    const text = await playlistText(url);
    const certificate = keysState.certificate;
    if (!certificate) throw new Error('no certificate');
    let binary = ''; for (const b of certificate) binary += String.fromCharCode(b);
    await bridge.open({ session: id, playlist: text, certificate: btoa(binary) });
  } catch (error) {
    fail(element, player, String(error && error.message || error));
  }
}
function stop(element, player) {
  if (player.id) { bridge.close({ session: player.id }).catch(() => {}); elementOf.delete(player.id); }
  player.id = null; player.src = undefined;
}
function fail(element, player, message) {
  player.error = { code: 3, message: 'FairPlay: ' + message, MEDIA_ERR_DECODE: 3 };
  player.state.paused = true;
  fire(element, 'error');
}
const fire = (element, type) => element.dispatchEvent(new Event(type));

// The service's reports and key requests.
function keyRequested({ session, keyURI, request }) {
  const bytes = Uint8Array.from(atob(request), (c) => c.charCodeAt(0));
  const target = [...sessions].find((s) => s.keyURI === keyURI);
  if (target) { target.deliver(bytes); return; }
  pendingRequests.set(keyURI, bytes);
  const element = findElement(session);
  if (!element) return;
  // The player asks for the key when the element reports it encrypted.
  const initData = new TextEncoder().encode(keyURI);
  const event = new MediaEncryptedEvent('encrypted', { initDataType: 'skd', initData: initData.buffer });
  element.dispatchEvent(event);
}
function findElement(session) { return elementOf.get(session); }
function stateReported({ session, state }) {
  const element = findElement(session); if (!element) return;
  const player = players.get(element), before = player.state;
  player.state = { ...state, duration: state.duration < 0 ? NaN : state.duration };
  if (state.error) { fail(element, player, state.error); return; }
  if (!before.ready && state.ready) { fire(element, 'durationchange'); fire(element, 'loadedmetadata'); fire(element, 'loadeddata'); fire(element, 'canplay'); fire(element, 'canplaythrough'); }
  if (before.duration !== player.state.duration && before.ready) fire(element, 'durationchange');
  if (before.paused && !state.paused) { fire(element, 'play'); if (!state.waiting) fire(element, 'playing'); }
  if (!before.paused && state.paused && !state.ended) fire(element, 'pause');
  if (before.waiting && !state.waiting && !state.paused) fire(element, 'playing');
  if (!before.waiting && state.waiting) fire(element, 'waiting');
  if (state.seeked) { player.seeking = false; fire(element, 'seeked'); }
  if (before.currentTime !== state.currentTime) fire(element, 'timeupdate');
  if (!before.ended && state.ended) { fire(element, 'pause'); fire(element, 'ended'); }
}

// The element's state, from the service, for mirrored elements.
const mirror = (name, read) => defineOwn(HTMLMediaElement.prototype, name, { ...accessors[name],
  get: { get [name]() { const p = mirrored(this); return p ? read(p, this) : apply(accessors[name].get, this, []); } }.__lookupGetter__(name) });
mirror('currentSrc', (p) => p.src);
mirror('duration', (p) => p.state.duration);
mirror('paused', (p) => p.state.paused);
mirror('ended', (p) => !!p.state.ended);
mirror('readyState', (p) => (p.state.ready ? 4 : 0));
mirror('networkState', () => 2);
mirror('seeking', (p) => !!p.seeking);
mirror('error', (p) => p.error || null);
mirror('mediaKeys', (p) => p.keys);
defineOwn(HTMLMediaElement.prototype, 'currentTime', { ...accessors.currentTime,
  get: { get currentTime() { const p = mirrored(this); return p ? p.state.currentTime : apply(accessors.currentTime.get, this, []); } }.__lookupGetter__('currentTime'),
  set: { set currentTime(value) {
    const p = mirrored(this); if (!p) return apply(accessors.currentTime.set, this, [value]);
    p.seeking = true; p.state.currentTime = +value; fire(this, 'seeking');
    bridge.control({ session: p.id, command: 'seek', value: +value });
  } }.__lookupSetter__('currentTime') });
for (const [name, command] of [['volume', 'volume'], ['muted', 'muted'], ['playbackRate', 'rate']]) {
  defineOwn(HTMLMediaElement.prototype, name, { ...accessors[name],
    set: { set [name](value) {
      apply(accessors[name].set, this, [value]);
      const p = mirrored(this); if (p) bridge.control({ session: p.id, command, value: +value });
    } }.__lookupSetter__(name) });
}
replace(HTMLMediaElement.prototype, 'play', { play() {
  const p = mirrored(this); if (!p) return apply(original.play, this, []);
  bridge.control({ session: p.id, command: 'volume', value: apply(accessors.volume.get, this, []) });
  bridge.control({ session: p.id, command: 'muted', value: apply(accessors.muted.get, this, []) ? 1 : 0 });
  bridge.control({ session: p.id, command: 'play', value: 0 });
  return Promise.resolve();
} }.play);
replace(HTMLMediaElement.prototype, 'pause', { pause() {
  const p = mirrored(this); if (!p) return apply(original.pause, this, []);
  bridge.control({ session: p.id, command: 'pause', value: 0 });
} }.pause);
addEventListener('pagehide', () => {
  for (const element of [...elementOf.values()]) { const p = mirrored(element); if (p) stop(element, p); }
});
})
