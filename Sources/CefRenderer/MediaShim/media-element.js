// Progressive files: an <audio> or <video> whose audio-only MP4 or ADTS
// source Chromium cannot play, and whose bytes the page could read itself
// (same origin, or cross-origin with `crossorigin` and CORS). The shim
// catches the element's "not supported" error before the page sees it,
// fetches the file in ranges as the playhead needs it, and plays it from
// a MediaSource of its own. `src` and `currentSrc` keep the page's address.
const takenOver = new WeakMap(); // element -> the page's URL
const takeovers = new WeakMap(); // element -> promise of the takeover's first append
replaceAccessor(HTMLMediaElement.prototype, 'src', function () {
  const url = takenOver.get(this);
  return url !== undefined ? url : apply(original.src.get, this, []);
}, function (value) {
  takenOver.delete(this); takeovers.delete(this);
  listenForErrors(this);
  return apply(original.src.set, this, [value]);
});
replaceAccessor(HTMLMediaElement.prototype, 'currentSrc', function () {
  const url = takenOver.get(this);
  return url !== undefined ? url : apply(original.currentSrc.get, this, []);
});

const audioExtension = /\.(m4a|m4b|mp4|aac)(\?|#|$)/i;
let redispatching = false;
// Starts playing `element` from the shim's MediaSource when its source,
// from `target` (the element or one of its <source> children), is one the
// shim plays and the page could read. Returns the takeover's promise, or
// null.
function takeOver(element, target) {
  let url, type = '';
  if (target instanceof HTMLSourceElement) {
    url = target.src; type = target.type;
  } else {
    url = apply(original.src.get, element, []) || apply(original.currentSrc.get, element, []);
    if (!element.error || element.error.code !== MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED) return null;
  }
  if (takeovers.has(element)) return takeovers.get(element);
  if (!url || /^(blob|data|mediasource|mediastream):/i.test(url)) return null;
  if (type ? !isSystemAudioType(type, false) : !audioExtension.test(url)) return null;
  let parsed; try { parsed = new URL(url, document.baseURI); } catch (e) { return null; }
  if (!/^(https?|file):$/.test(parsed.protocol) && parsed.origin !== location.origin) return null;
  const sameOrigin = parsed.origin === location.origin;
  if (!sameOrigin && element.crossOrigin === null) return null; // the page could not read these bytes
  const takeover = playFile(element, parsed.href, sameOrigin);
  takeovers.set(element, takeover);
  takeover.catch(() => {
    takenOver.delete(element); takeovers.delete(element);
    redispatching = true; try { target.dispatchEvent(new Event('error')); } finally { redispatching = false; }
  });
  return takeover;
}
// The element's "not supported" error, caught before the page's own
// listeners: on the window for elements in the document, on the element
// for one that is not (`new Audio(url)`), once it has a source.
function caught(event) {
  if (redispatching) return;
  const target = event.target;
  const element = target instanceof HTMLSourceElement ? target.parentElement : target;
  if (!(element instanceof HTMLMediaElement)) return;
  if (takeOver(element, target)) event.stopImmediatePropagation();
}
addEventListener('error', caught, true);
const listening = new WeakSet();
function listenForErrors(element) {
  if (listening.has(element)) return;
  listening.add(element);
  element.addEventListener('error', (event) => { if (!element.isConnected) caught(event); }, true);
}

// `new Audio(url)` starts loading before any setter of the page's runs,
// and its element is in no document: the shim listens on it from the
// start.
if (typeof Audio === 'function') {
  const NativeAudio = Audio;
  const replacement = nativeLike('Audio', NativeAudio.length, function Audio(...args) {
    const element = Reflect.construct(NativeAudio, args);
    listenForErrors(element);
    return element;
  });
  replacement.prototype = NativeAudio.prototype;
  defineOwn(window, 'Audio', { ...getOwn(window, 'Audio'), value: replacement });
}

// A page that calls play() right after setting src gets the rejection of
// Chromium's failed load before the shim takes over; such a play() waits
// for the takeover and plays then, as it would with a source Chromium
// plays. An element out of the document whose error went unseen is taken
// over here.
replaceMethod(HTMLMediaElement.prototype, 'play', function play() {
  const element = this;
  listenForErrors(element);
  return apply(original.play, element, []).catch((error) => {
    if (!error || error.name !== 'NotSupportedError') throw error;
    const takeover = takeovers.get(element) || takeOver(element, element);
    if (!takeover) throw error;
    return takeover.then(() => apply(original.play, element, []), () => { throw error; });
  });
});

async function fetchRange(url, credentials, start, end) {
  const response = await original.fetch.call(window, url, { credentials, headers: { Range: `bytes=${start}-${end - 1}` }, cache: 'force-cache' });
  if (!response.ok) throw new Error('fetch failed');
  const bytes = new Uint8Array(await response.arrayBuffer());
  return { bytes, partial: response.status === 206 };
}

// The file's packets: {decoder, duration, packets: [{pts, dur, data | off, size}]}.
async function openFile(url, credentials) {
  // The head of the file says what it is; an MP4's moov may be at its end.
  const head = await fetchRange(url, credentials, 0, 1 << 20);
  let whole = head.partial ? null : head.bytes;
  const adts = parseADTS(head.bytes);
  if (adts) {
    if (head.partial && head.bytes.length === 1 << 20) whole = (await fetchRange(url, credentials, 0, 1 << 30)).bytes;
    return { whole, ...(whole ? parseADTS(whole) : adts) };
  }
  let moov = null, data = head.bytes;
  for (const b of MP4.boxes(data, 0, data.length)) {
    if (b.type === 'moov') { moov = b; break; }
    if (b.truncated) break;
  }
  if (!moov || moov.truncated) {
    // Walk the top-level boxes by their headers to find the moov.
    moov = null;
    let position = 0;
    for (let guard = 0; guard < 64; guard++) {
      const header = (await fetchRange(url, credentials, position, position + 16)).bytes;
      if (header.length < 8) break;
      const view = new DataView(header.buffer); let size = view.getUint32(0);
      const type = String.fromCharCode(...header.subarray(4, 8));
      if (size === 1) size = Number(view.getBigUint64(8));
      if (type === 'moov') { data = (await fetchRange(url, credentials, position, position + size)).bytes; moov = { start: 0 }; break; }
      if (size < 8) break;
      position += size;
    }
    if (!moov) throw new Error('no moov');
  }
  const init = MP4.parseInit(data.subarray(moov.start));
  const track = init && init.tracks.find((t) => t.handler === 'soun' && t.decoder);
  if (!track || init.tracks.some((t) => t.handler === 'vide')) throw new Error('not an audio-only file the system decodes');
  return { whole, decoder: track.decoder, duration: init.duration || track.duration / track.timescale, packets: MP4.progressiveSamples(data.subarray(moov.start), track) };
}

async function playFile(element, url, sameOrigin) {
  const credentials = sameOrigin ? 'same-origin' : element.crossOrigin === 'use-credentials' ? 'include' : 'omit';
  takenOver.set(element, url);
  const file = await openFile(url, credentials);
  let whole = file.whole;
  // A MediaSource of the element's own, fed ahead of the playhead.
  const media = new MediaSource();
  const objectURL = original.createObjectURL.call(URL, media);
  apply(original.src.set, element, [objectURL]);
  await new Promise((resolve) => media.addEventListener('sourceopen', resolve, { once: true }));
  original.revokeObjectURL.call(URL, objectURL);
  media.duration = file.duration;
  const real = apply(original.addSourceBuffer, media, [FLAC]);
  const stream = new SystemAudioStream(file.decoder);
  let next = 0, busy = false, generation = 0;
  const chunkSeconds = 10, aheadSeconds = 30, behindSeconds = 20;
  const packets = file.packets;
  const indexAt = (time) => { let lo = 0, hi = packets.length - 1; while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (packets[mid].pts <= time) lo = mid; else hi = mid - 1; } return lo; };
  const bufferedEnd = () => { const t = element.currentTime, b = real.buffered; for (let i = 0; i < b.length; i++) if (b.start(i) <= t + 0.1 && b.end(i) >= t) return b.end(i); return t; };
  const append = (bytes) => new Promise((resolve, reject) => {
    const done = () => { real.removeEventListener('error', fail); resolve(); };
    const fail = () => { real.removeEventListener('updateend', done); reject(new Error('append failed')); };
    real.addEventListener('updateend', done, { once: true });
    real.addEventListener('error', fail, { once: true });
    try { apply(original.appendBuffer, real, [bytes]); } catch (e) { real.removeEventListener('updateend', done); real.removeEventListener('error', fail); reject(e); }
  });
  const removeBefore = (time) => new Promise((resolve) => {
    real.addEventListener('updateend', resolve, { once: true });
    apply(original.remove, real, [0, time]);
  });
  async function readPackets(first, last) {
    const slice = packets.slice(first, last);
    if (slice[0].data) return slice;
    if (whole) return slice.map((p) => ({ pts: p.pts, dur: p.dur, data: whole.subarray(p.off, p.off + p.size) }));
    const start = slice[0].off, end = Math.max(...slice.map((p) => p.off + p.size));
    const { bytes, partial } = await fetchRange(url, credentials, start, end);
    if (!partial) { whole = bytes; return readPackets(first, last); }
    return slice.map((p) => ({ pts: p.pts, dur: p.dur, data: bytes.subarray(p.off - start, p.off - start + p.size) }));
  }
  async function pump() {
    if (busy || media.readyState === 'closed') return;
    busy = true;
    const mine = generation;
    try {
      while (next < packets.length && bufferedEnd() - element.currentTime < aheadSeconds && mine === generation) {
        const endTime = packets[next].pts + chunkSeconds;
        let last = next; while (last < packets.length && packets[last].pts < endTime) last++;
        const flac = await stream.decode(await readPackets(next, last));
        if (mine !== generation) break;
        if (flac.length) { await append(flac); buffered(); }
        next = last;
        const behind = element.currentTime - behindSeconds;
        if (behind > 0 && real.buffered.length && real.buffered.start(0) < behind) await removeBefore(behind);
      }
      if (next >= packets.length && media.readyState === 'open' && !apply(original.updating, real, [])) apply(original.endOfStream, media, []);
    } finally { busy = false; }
  }
  element.addEventListener('timeupdate', () => { pump().catch(() => {}); });
  element.addEventListener('seeking', () => {
    const t = element.currentTime, b = real.buffered;
    for (let i = 0; i < b.length; i++) if (b.start(i) <= t && t < b.end(i) - 0.5) return;
    generation++; next = indexAt(t); stream.restart();
    const restart = () => { busy = false; pump().catch(() => {}); };
    if (apply(original.updating, real, [])) real.addEventListener('updateend', restart, { once: true }); else restart();
  });
  // Resolves once the first audio is buffered; the pump goes on.
  let buffered;
  const first = new Promise((resolve) => { buffered = resolve; });
  await Promise.race([first, pump().then(buffered)]);
}
