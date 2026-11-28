// One stream of compressed audio decoded by the media service. The
// service keeps the decoder and the timeline; this side sends packets
// with their times and gets back FLAC in fragmented MP4, ready to append
// to a native `audio/mp4; codecs="flac"` SourceBuffer in one call.
let nextStream = 0;
class SystemAudioStream {
  // `decoder`: {codec, configuration: Uint8Array, rate, channels}.
  constructor(decoder) { this.id = ++nextStream; this.decoder = decoder; this.discontinuity = true; }

  // `packets`: [{pts, dur, data: Uint8Array}] in decode order, times in
  // seconds. Resolves to the bytes to append; empty when there is nothing.
  async decode(packets) {
    if (!packets.length) return new Uint8Array(0);
    let size = 0; for (const p of packets) size += p.data.length;
    const joined = new Uint8Array(size);
    const sizes = new Uint32Array(packets.length), timing = new Float64Array(packets.length * 2);
    let o = 0;
    packets.forEach((p, i) => { joined.set(p.data, o); o += p.data.length; sizes[i] = p.data.length; timing[2 * i] = p.pts; timing[2 * i + 1] = p.dur; });
    const { codec, configuration, rate, channels } = this.decoder;
    const discontinuity = this.discontinuity; this.discontinuity = false;
    const config = configuration.byteOffset === 0 && configuration.byteLength === configuration.buffer.byteLength
      ? configuration.buffer : configuration.slice().buffer;
    const segments = await native.decode(this.id, discontinuity, codec, rate, channels, config, joined.buffer, sizes.buffer, timing.buffer);
    if (segments.length === 1) return new Uint8Array(segments[0]);
    let total = 0; for (const s of segments) total += s.byteLength;
    const out = new Uint8Array(total); let at = 0;
    for (const s of segments) { out.set(new Uint8Array(s), at); at += s.byteLength; }
    return out;
  }

  // The next packets do not continue the last ones (a seek, an abort).
  restart() { this.discontinuity = true; }
  release() { native.release(this.id); }
}
