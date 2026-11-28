// Media Source Extensions. `addSourceBuffer` for a system audio type
// returns a genuine SourceBuffer of type FLAC: `sourceBuffers`, `instanceof`
// and the buffer's events, ranges and tracks are Chromium's own. Only
// what the page appends to such a buffer changes on the way: it is
// demuxed here, decoded by the media service, and appended as FLAC in a
// single native append, so the page sees one updatestart, update and
// updateend per append, as natively. While a decode is pending, the
// buffer reports itself updating and refuses what an updating buffer
// refuses.
const systemBuffers = new WeakMap(); // native SourceBuffer -> state
const buffersOf = new WeakMap(); // MediaSource -> Set of native SourceBuffers in system mode

const busy = (operation) => new DOMException(
  `Failed to execute '${operation}' on 'SourceBuffer': This SourceBuffer is still processing an 'appendBuffer' or 'remove' operation.`,
  'InvalidStateError');

function systemState(source, type) {
  return { source, type, pending: false, generation: 0, bytes: new Uint8Array(0), init: null, track: null, stream: null, fragments: { next: {} } };
}

// Demuxes what has arrived, decodes the complete fragments, and resolves
// to the FLAC to append (possibly empty).
async function demuxAndDecode(state) {
  const top = [...MP4.boxes(state.bytes, 0, state.bytes.length)];
  // An initialization segment (moov) configures the decoder.
  const moov = top.find((b) => b.type === 'moov' && !b.truncated);
  if (moov) {
    const init = MP4.parseInit(state.bytes.subarray(moov.start, moov.end));
    const track = init && init.tracks.find((t) => t.handler === 'soun' && t.decoder);
    if (!track) throw new Error('no audio track the system decodes');
    const same = state.track && state.track.format === track.format
      && String(state.track.decoder.configuration) === String(track.decoder.configuration);
    if (!same) {
      if (state.stream) state.stream.release();
      state.stream = new SystemAudioStream(track.decoder);
    }
    state.track = track; state.init = init; state.fragments = { next: {} };
    state.bytes = state.bytes.slice(moov.end);
  }
  if (!state.init) {
    if (state.bytes.length > 4 << 20) throw new Error('no initialization segment');
    return new Uint8Array(0);
  }
  const { samples, consumed } = MP4.parseFragments(state.bytes, state.init, state.fragments);
  const packets = samples.filter((s) => s.track === state.track.id).map((s) => ({ pts: s.pts, dur: s.dur, data: s.data }));
  const out = packets.length ? await state.stream.decode(packets) : new Uint8Array(0);
  state.bytes = state.bytes.slice(consumed);
  return out;
}

replaceMethod(SourceBuffer.prototype, 'appendBuffer', function appendBuffer(data) {
  const state = systemBuffers.get(this);
  if (!state) return apply(original.appendBuffer, this, [data]);
  if (state.pending) throw busy('appendBuffer');
  // What Chromium refuses at once, it refuses here too, with its words:
  // an updating or removed buffer, a closed source, a value that is not
  // a buffer.
  if (apply(original.updating, this, [])) return apply(original.appendBuffer, this, [data]);
  const source = state.source;
  if (source && (source.readyState === 'closed' || !Array.prototype.includes.call(source.sourceBuffers, this))) {
    throw new DOMException("Failed to execute 'appendBuffer' on 'SourceBuffer': This SourceBuffer has been removed from the parent media source.", 'InvalidStateError');
  }
  if (!(data instanceof ArrayBuffer) && !ArrayBuffer.isView(data)) return apply(original.appendBuffer, this, [data]);
  const bytes = ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : new Uint8Array(data);  const joined = new Uint8Array(state.bytes.length + bytes.length);
  joined.set(state.bytes); joined.set(bytes, state.bytes.length);
  state.bytes = joined;
  state.pending = true;
  const generation = state.generation;
  demuxAndDecode(state).then((flac) => {
    if (generation !== state.generation) return;
    state.pending = false;
    apply(original.appendBuffer, this, [flac]);
  }, () => {
    if (generation !== state.generation) return;
    state.pending = false; state.bytes = new Uint8Array(0);
    // An empty moov, which Chromium cannot parse: the append fails as a
    // corrupt one does natively, with `error`, `updateend` and a decode error.
    apply(original.appendBuffer, this, [Uint8Array.of(0, 0, 0, 8, 0x6d, 0x6f, 0x6f, 0x76)]);
  });
});

replaceAccessor(SourceBuffer.prototype, 'updating', function () {
  const state = systemBuffers.get(this);
  return (state && state.pending) || apply(original.updating, this, []);
});

replaceMethod(SourceBuffer.prototype, 'remove', function remove(start, end) {
  const state = systemBuffers.get(this);
  if (state && state.pending) throw busy('remove');
  return apply(original.remove, this, [start, end]);
});

replaceMethod(SourceBuffer.prototype, 'abort', function abort() {
  const state = systemBuffers.get(this);
  if (state) {
    const wasPending = state.pending;
    state.generation++; state.pending = false;
    state.bytes = new Uint8Array(0); state.fragments = { next: {} };
    if (state.stream) state.stream.restart();
    if (wasPending) {
      // An append in progress ends with `abort` and `updateend`, as natively.
      this.dispatchEvent(new Event('abort'));
      this.dispatchEvent(new Event('updateend'));
    }
  }
  return apply(original.abort, this, []);
});

replaceMethod(SourceBuffer.prototype, 'changeType', function changeType(type) {
  const state = systemBuffers.get(this);
  if (state && state.pending) throw busy('changeType');
  if (isSystemAudioType(type, true)) {
    apply(original.changeType, this, [FLAC]);
    if (!state) systemBuffers.set(this, systemState(null, type));
    else { state.init = null; state.type = type; }
    return;
  }
  apply(original.changeType, this, [type]);
  if (state) { if (state.stream) state.stream.release(); systemBuffers.delete(this); }
});

// Setters an updating buffer refuses.
for (const name of ['timestampOffset', 'appendWindowStart', 'mode']) {
  const descriptor = getOwn(SourceBuffer.prototype, name);
  if (!descriptor || !descriptor.set) continue;
  const set = descriptor.set;
  replaceAccessor(SourceBuffer.prototype, name, null, function (value) {
    const state = systemBuffers.get(this);
    if (state && state.pending) {
      throw new DOMException(`Failed to set the '${name}' property on 'SourceBuffer': This SourceBuffer is still processing an 'appendBuffer' or 'remove' operation.`, 'InvalidStateError');
    }
    return apply(set, this, [value]);
  });
}

replaceMethod(MediaSource, 'isTypeSupported', function isTypeSupported(type) {
  return isSystemAudioType(type, true) || apply(original.isTypeSupported, this, [type]);
});

replaceMethod(MediaSource.prototype, 'addSourceBuffer', function addSourceBuffer(type) {
  if (!isSystemAudioType(type, true)) return apply(original.addSourceBuffer, this, [type]);
  const buffer = apply(original.addSourceBuffer, this, [FLAC]);
  systemBuffers.set(buffer, systemState(this, type));
  if (!buffersOf.has(this)) buffersOf.set(this, new Set());
  buffersOf.get(this).add(buffer);
  return buffer;
});

replaceMethod(MediaSource.prototype, 'endOfStream', function endOfStream(...args) {
  for (const buffer of buffersOf.get(this) || []) {
    const state = systemBuffers.get(buffer);
    if (state && state.pending) {
      throw new DOMException("Failed to execute 'endOfStream' on 'MediaSource': The 'updating' attribute is true on one or more of this MediaSource's SourceBuffers.", 'InvalidStateError');
    }
  }
  return apply(original.endOfStream, this, args);
});

replaceMethod(HTMLMediaElement.prototype, 'canPlayType', function canPlayType(type) {
  const answer = apply(original.canPlayType, this, [type]);
  if (answer === '' && isSystemAudioType(type, false)) return parseType(type).codecs.length ? 'probably' : 'maybe';
  return answer;
});

// Media Capabilities, which players such as Shaka and dash.js ask before
// MediaSource: a system audio configuration is as supported as the rest
// of the query is without it.
if (original.decodingInfo) {
  replaceMethod(MediaCapabilities.prototype, 'decodingInfo', function decodingInfo(configuration) {
    const audio = configuration && configuration.audio;
    if (!audio || !isSystemAudioType(audio.contentType, true) || configuration.keySystemConfiguration) {
      return apply(original.decodingInfo, this, [configuration]);
    }
    const rest = { ...configuration, audio: { ...audio, contentType: FLAC } };
    return apply(original.decodingInfo, this, [rest]).then((info) => ({ ...info, configuration }));
  });
}
