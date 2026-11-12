// The page-facing script of the system-decoder media shim: an ISO BMFF
// demuxer, a FLAC-in-MP4 writer and the MediaSource and media-element
// hooks. It evaluates to a function that `MediaShim` calls with the
// decoder, before the document's own scripts run.
enum MediaShimScript {
    static let source = ##"""
(function (native) {
'use strict';
// Minimal ISO BMFF demuxer: progressive (stbl) and fragmented (moof/trun).
// Samples: {track, dts, pts, dur, key, data:Uint8Array} with times in seconds.
const MP4 = (() => {
  const str = (d, o) => String.fromCharCode(d[o], d[o + 1], d[o + 2], d[o + 3]);
  function* boxes(d, start, end) {
    let o = start;
    while (o + 8 <= end) {
      const v = new DataView(d.buffer, d.byteOffset + o);
      let size = v.getUint32(0), hdr = 8;
      const type = str(d, o + 4);
      if (size === 1) { size = Number(v.getBigUint64(8)); hdr = 16; } else if (size === 0) size = end - o;
      if (size < hdr || o + size > end) { yield { type, start: o, body: o + hdr, end: end, truncated: true }; return; }
      yield { type, start: o, body: o + hdr, end: o + size };
      o += size;
    }
  }
  const child = (d, box, type) => { for (const b of boxes(d, box.body, box.end)) if (b.type === type) return b; };
  const path = (d, box, ...types) => { for (const t of types) { box = box && child(d, box, t); } return box; };
  const dv = (d, o) => new DataView(d.buffer, d.byteOffset + o);

  function parseTrak(d, trak) {
    const t = {};
    const tkhd = child(d, trak, 'tkhd'); const tv = dv(d, tkhd.body);
    t.id = tv.getUint8(0) === 1 ? tv.getUint32(20) : tv.getUint32(12);
    const mdia = child(d, trak, 'mdia');
    const mdhd = child(d, mdia, 'mdhd'); const mv = dv(d, mdhd.body);
    if (mv.getUint8(0) === 1) { t.timescale = mv.getUint32(20); t.duration = Number(mv.getBigUint64(24)); } else { t.timescale = mv.getUint32(12); t.duration = mv.getUint32(16); }
    t.handler = str(d, child(d, mdia, 'hdlr').body + 8);
    const stbl = path(d, mdia, 'minf', 'stbl');
    const stsd = child(d, stbl, 'stsd');
    const entry = boxes(d, stsd.body + 8, stsd.end).next().value;
    t.format = entry.type;
    if (t.handler === 'vide') {
      const ev = dv(d, entry.body);
      t.width = ev.getUint16(24); t.height = ev.getUint16(26);
      for (const b of boxes(d, entry.body + 78, entry.end)) {
        if (b.type === 'avcC') { t.avcC = d.slice(b.body, b.end); }
        if (b.type === 'hvcC') { t.hvcC = d.slice(b.body, b.end); }
      }
      if (t.avcC) {
        const c = t.avcC; t.codec = 'avc1.' + [c[1], c[2], c[3]].map(x => x.toString(16).padStart(2, '0')).join('');
        t.nalLength = (c[4] & 3) + 1;
        t.sps = []; t.pps = [];
        let o = 6; for (let n = c[5] & 31; n > 0; n--) { const l = (c[o] << 8) | c[o + 1]; t.sps.push(c.slice(o + 2, o + 2 + l)); o += 2 + l; }
        for (let n = c[o++]; n > 0; n--) { const l = (c[o] << 8) | c[o + 1]; t.pps.push(c.slice(o + 2, o + 2 + l)); o += 2 + l; }
      }
    } else if (t.handler === 'soun') {
      const ev = dv(d, entry.body);
      t.channels = ev.getUint16(16); t.sampleRate = ev.getUint32(24) >>> 16;
      for (const b of boxes(d, entry.body + 28, entry.end)) {
        if (b.type === 'esds') t.esds = d.slice(b.body, b.end);
      }
      if (t.esds) { t.asc = ascFromEsds(t.esds); if (t.asc) { t.codec = 'mp4a.40.' + (t.asc[0] >> 3); } }
    }
    // Edit list: first non-empty edit's media time shifts presentation.
    t.editShift = 0;
    const elst = path(d, trak, 'edts', 'elst');
    if (elst) {
      const ev = dv(d, elst.body); const ver = ev.getUint8(0); const n = ev.getUint32(4);
      for (let i = 0, o = 8; i < n; i++) {
        const mt = ver ? Number(ev.getBigInt64(o + 8)) : ev.getInt32(o + 4);
        o += ver ? 20 : 12;
        if (mt >= 0) { t.editShift = mt; break; }
      }
    }
    t.stbl = stbl;
    return t;
  }

  function ascFromEsds(e) {
    // Walk descriptors: ES_Descriptor(3) > DecoderConfig(4) > DecSpecificInfo(5).
    let o = 4;
    const len = () => { let l = 0, b; do { b = e[o++]; l = (l << 7) | (b & 0x7f); } while (b & 0x80); return l; };
    while (o < e.length) {
      const tag = e[o++]; const l = len();
      if (tag === 3) { const flags = e[o + 2]; o += 3; if (flags & 0x80) o += 2; if (flags & 0x40) o += 1 + e[o]; if (flags & 0x20) o += 2; continue; }
      if (tag === 4) { o += 13; continue; }
      if (tag === 5) return e.slice(o, o + l);
      o += l;
    }
  }

  function progressiveSamples(d, t) {
    const s = t.stbl, get = (ty) => child(d, s, ty);
    const out = [];
    const stsz = dv(d, get('stsz').body); const fixed = stsz.getUint32(4), count = stsz.getUint32(8);
    const sizes = i => fixed || stsz.getUint32(12 + 4 * i);
    let co = get('stco'), offsets;
    if (co) { const v = dv(d, co.body); offsets = Array.from({ length: v.getUint32(4) }, (_, i) => v.getUint32(8 + 4 * i)); }
    else { co = get('co64'); const v = dv(d, co.body); offsets = Array.from({ length: v.getUint32(4) }, (_, i) => Number(v.getBigUint64(8 + 8 * i))); }
    const stsc = dv(d, get('stsc').body); const nsc = stsc.getUint32(4);
    const stts = dv(d, get('stts').body); const nts = stts.getUint32(4);
    const ctts = get('ctts') && dv(d, get('ctts').body);
    const stss = get('stss') && dv(d, get('stss').body);
    const keys = stss ? new Set(Array.from({ length: stss.getUint32(4) }, (_, i) => stss.getUint32(8 + 4 * i) - 1)) : null;
    // Expand chunk -> samples.
    let sample = 0;
    for (let e = 0; e < nsc; e++) {
      const first = stsc.getUint32(8 + 12 * e) - 1, per = stsc.getUint32(12 + 12 * e);
      const next = e + 1 < nsc ? stsc.getUint32(8 + 12 * (e + 1)) - 1 : offsets.length;
      for (let c = first; c < next; c++) {
        let off = offsets[c];
        for (let k = 0; k < per && sample < count; k++, sample++) { const sz = sizes(sample); out.push({ off, size: sz }); off += sz; }
      }
    }
    let dts = 0, i = 0;
    for (let e = 0; e < nts; e++) { const n = stts.getUint32(8 + 8 * e), delta = stts.getUint32(12 + 8 * e); for (let k = 0; k < n && i < out.length; k++, i++) { out[i].dts = dts; out[i].dur = delta; dts += delta; } }
    if (ctts) { const ver = ctts.getUint8(0); let i = 0; for (let e = 0, ne = ctts.getUint32(4); e < ne; e++) { const n = ctts.getUint32(8 + 8 * e); const off = ver ? ctts.getInt32(12 + 8 * e) : ctts.getUint32(12 + 8 * e); for (let k = 0; k < n && i < out.length; k++, i++) out[i].cto = off; } }
    return out.map((x, i) => ({ track: t.id, dts: (x.dts - t.editShift) / t.timescale, pts: (x.dts + (x.cto || 0) - t.editShift) / t.timescale, dur: x.dur / t.timescale, key: keys ? keys.has(i) : true, off: x.off, size: x.size }));
  }

  function parseInit(d) {
    const moov = [...boxes(d, 0, d.length)].find(b => b.type === 'moov');
    if (!moov || moov.truncated) return null;
    const tracks = [];
    for (const b of boxes(d, moov.body, moov.end)) if (b.type === 'trak') tracks.push(parseTrak(d, b));
    const trex = {};
    const mvex = child(d, moov, 'mvex');
    if (mvex) for (const b of boxes(d, mvex.body, mvex.end)) if (b.type === 'trex') { const v = dv(d, b.body); trex[v.getUint32(4)] = { dur: v.getUint32(12), size: v.getUint32(16), flags: v.getUint32(20) }; }
    const mvhd = child(d, moov, 'mvhd'); const mv = dv(d, mvhd.body);
    const mts = mv.getUint8(0) === 1 ? mv.getUint32(20) : mv.getUint32(12);
    const mdur = mv.getUint8(0) === 1 ? Number(mv.getBigUint64(24)) : mv.getUint32(16);
    // iTunes gapless metadata: without an edit list, its encoder delay
    // (in the audio track's own sample rate) is the priming to skip.
    const tag = [0x69, 0x54, 0x75, 0x6e, 0x53, 0x4d, 0x50, 0x42]; // iTunSMPB
    search: for (let o = moov.body; o + 8 < moov.end; o++) {
      for (let k = 0; k < 8; k++) if (d[o + k] !== tag[k]) continue search;
      // The value is a `data` atom: size, 'data', type, locale, then text.
      let at = o + 8; while (at + 4 < moov.end && !(d[at] === 0x64 && d[at + 1] === 0x61 && d[at + 2] === 0x74 && d[at + 3] === 0x61)) at++;
      const text = String.fromCharCode(...d.subarray(at + 12, Math.min(at + 160, moov.end))).replace(/[^ 0-9A-Fa-f]/g, ' ');
      const fields = text.trim().split(/\s+/);
      const delay = parseInt(fields[1], 16);
      if (delay > 0 && delay < 1 << 16) for (const t of tracks) if (t.handler === 'soun' && !t.editShift) t.editShift = delay;
      break;
    }
    return { tracks, trex, fragmented: !!mvex, duration: mdur / mts, moovEnd: moov.end };
  }

  // Parses moof+mdat pairs from `d`; returns {samples, consumed}.
  function parseFragments(d, init, state) {
    const samples = []; let consumed = 0;
    const all = [...boxes(d, 0, d.length)];
    for (let i = 0; i < all.length; i++) {
      const b = all[i];
      if (b.truncated) break;
      if (b.type !== 'moof') { if (b.type !== 'mdat' || !state.pending) { consumed = b.end; continue; } }
      if (b.type === 'moof') {
        const mdat = all[i + 1];
        if (!mdat || mdat.truncated) break;
        for (const traf of boxes(d, b.body, b.end)) {
          if (traf.type !== 'traf') continue;
          const tfhd = child(d, traf, 'tfhd'); const hv = dv(d, tfhd.body); const fl = hv.getUint32(0) & 0xffffff;
          const id = hv.getUint32(4); let o = 8;
          const tr = init.tracks.find(t => t.id === id); const tx = init.trex[id] || {};
          let base = b.start, ddur = tx.dur, dsize = tx.size, dflags = tx.flags;
          if (fl & 1) { base = Number(hv.getBigUint64(o)); o += 8; }
          if (fl & 2) o += 4;
          if (fl & 8) { ddur = hv.getUint32(o); o += 4; }
          if (fl & 0x10) { dsize = hv.getUint32(o); o += 4; }
          if (fl & 0x20) { dflags = hv.getUint32(o); o += 4; }
          if (fl & 0x20000) base = b.start;
          const tfdt = child(d, traf, 'tfdt');
          let dts = state.next[id] || 0;
          if (tfdt) { const v = dv(d, tfdt.body); dts = v.getUint8(0) ? Number(v.getBigUint64(4)) : v.getUint32(4); }
          for (const trun of boxes(d, traf.body, traf.end)) {
            if (trun.type !== 'trun') continue;
            const v = dv(d, trun.body); const ver = v.getUint8(0); const tf = v.getUint32(0) & 0xffffff; const n = v.getUint32(4);
            let p = 8, dataOff = base; if (tf & 1) { dataOff = base + v.getInt32(p); p += 4; }
            let firstFlags = null; if (tf & 4) { firstFlags = v.getUint32(p); p += 4; }
            let off = dataOff;
            for (let k = 0; k < n; k++) {
              let dur = ddur, size = dsize, flags = k === 0 && firstFlags !== null ? firstFlags : dflags, cto = 0;
              if (tf & 0x100) { dur = v.getUint32(p); p += 4; }
              if (tf & 0x200) { size = v.getUint32(p); p += 4; }
              if (tf & 0x400) { flags = v.getUint32(p); p += 4; }
              if (tf & 0x800) { cto = ver ? v.getInt32(p) : v.getUint32(p); p += 4; }
              const key = tr.handler !== 'vide' || !(flags & 0x10000);
              samples.push({ track: id, dts: (dts - tr.editShift) / tr.timescale, pts: (dts + cto - tr.editShift) / tr.timescale, dur: dur / tr.timescale, key, data: d.subarray(off, off + size) });
              off += size; dts += dur;
            }
          }
          state.next[id] = dts;
        }
        consumed = mdat.end; i++;
      }
    }
    return { samples, consumed };
  }

  // AVCC access unit -> Annex B, with SPS/PPS before key frames.
  function annexB(t, au, key) {
    const parts = []; let total = 0;
    const push = (nal) => { parts.push(nal); total += 4 + nal.length; };
    if (key) { t.sps.forEach(push); t.pps.forEach(push); }
    const L = t.nalLength;
    for (let o = 0; o + L <= au.length;) {
      let n = 0; for (let k = 0; k < L; k++) n = n * 256 + au[o + k];
      o += L; push(au.subarray(o, o + n)); o += n;
    }
    const out = new Uint8Array(total); let o = 0;
    for (const p of parts) { out[o + 3] = 1; out.set(p, o + 4); o += 4 + p.length; }
    return out;
  }
  return { parseInit, progressiveSamples, parseFragments, annexB, boxes };
})();
// FLAC (verbatim subframes, 16-bit) in fragmented MP4, for a native
// `audio/mp4; codecs="flac"` SourceBuffer. Lossless: the PCM goes through
// unchanged.
const FlacMP4 = (() => {
  const crc8Table = new Uint8Array(256), crc16Table = new Uint16Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i; for (let k = 0; k < 8; k++) c = (c & 0x80) ? ((c << 1) ^ 0x07) & 0xff : (c << 1) & 0xff; crc8Table[i] = c;
    let d = i << 8; for (let k = 0; k < 8; k++) d = (d & 0x8000) ? ((d << 1) ^ 0x8005) & 0xffff : (d << 1) & 0xffff; crc16Table[i] = d;
  }
  const crc8 = (b, s, e) => { let c = 0; for (let i = s; i < e; i++) c = crc8Table[c ^ b[i]]; return c; };
  const crc16 = (b, s, e) => { let c = 0; for (let i = s; i < e; i++) c = ((c << 8) ^ crc16Table[(c >> 8) ^ b[i]]) & 0xffff; return c; };

  // ISO BMFF box helpers.
  const u32 = (n) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
  const u16 = (n) => [(n >>> 8) & 255, n & 255];
  const u64 = (n) => { const hi = Math.floor(n / 4294967296), lo = n >>> 0; return [...u32(hi), ...u32(lo)]; };
  const fourcc = (s) => [...s].map((c) => c.charCodeAt(0));
  const concat = (parts) => { let n = 0; for (const p of parts) n += p.length; const out = new Uint8Array(n); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; };
  const box = (type, ...parts) => { const body = concat(parts.map((p) => p instanceof Uint8Array ? p : Uint8Array.from(p))); return concat([Uint8Array.from([...u32(body.length + 8), ...fourcc(type)]), body]); };
  const full = (type, version, flags, ...parts) => box(type, [version, (flags >> 16) & 255, (flags >> 8) & 255, flags & 255], ...parts);
  const matrix = [...u32(0x10000), ...u32(0), ...u32(0), ...u32(0), ...u32(0x10000), ...u32(0), ...u32(0), ...u32(0), ...u32(0x40000000)];

  function init(rate, channels) {
    const si = new Uint8Array(34);
    si[0] = 0; si[1] = 16; si[2] = 0x10; si[3] = 0x00;          // min 16, max 4096 samples per block
    // 20-bit rate, 3-bit channels-1, 5-bit bits-1, 36-bit total (0).
    si[10] = (rate >> 12) & 255; si[11] = (rate >> 4) & 255;
    si[12] = ((rate & 15) << 4) | ((channels - 1) << 1) | (15 >> 4);
    si[13] = (15 & 15) << 4;
    const dfLa = full('dfLa', 0, 0, [0x80, 0, 0, 34], si);
    const entry = box('fLaC', [0, 0, 0, 0, 0, 0, ...u16(1), 0, 0, 0, 0, 0, 0, 0, 0, ...u16(channels), ...u16(16), 0, 0, 0, 0, ...u32(rate > 65535 ? 0 : rate * 65536)], dfLa);
    const stbl = box('stbl', full('stsd', 0, 0, u32(1), entry), full('stts', 0, 0, u32(0)), full('stsc', 0, 0, u32(0)), full('stsz', 0, 0, u32(0), u32(0)), full('stco', 0, 0, u32(0)));
    const minf = box('minf', full('smhd', 0, 0, [0, 0, 0, 0]), box('dinf', full('dref', 0, 0, u32(1), full('url ', 0, 1))), stbl);
    const mdia = box('mdia', full('mdhd', 0, 0, u32(0), u32(0), u32(rate), u32(0), [0x55, 0xc4, 0, 0]),
      full('hdlr', 0, 0, u32(0), fourcc('soun'), u32(0), u32(0), u32(0), fourcc('SoundHandler'), [0]), minf);
    const tkhd = full('tkhd', 0, 3, u32(0), u32(0), u32(1), u32(0), u32(0), u32(0), u32(0), u16(0), u16(0), u16(0x100), u16(0), matrix, u32(0), u32(0));
    const mvhd = full('mvhd', 0, 0, u32(0), u32(0), u32(1000), u32(0), u32(0x10000), u16(0x100), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], matrix, new Array(24).fill(0), u32(2));
    const mvex = box('mvex', full('trex', 0, 0, u32(1), u32(1), u32(0), u32(0), u32(0)));
    return concat([box('ftyp', fourcc('iso6'), u32(0), fourcc('iso6'), fourcc('mp41')), box('moov', mvhd, box('trak', tkhd, mdia), mvex)]);
  }

  // FLAC's UTF-8-like coding of a frame's first sample number (36 bits).
  function codedNumber(n) {
    let bits = 0; for (let v = n; v > 0; v = Math.floor(v / 2)) bits++;
    if (bits <= 7) return [n];
    const continuation = bits <= 11 ? 1 : bits <= 16 ? 2 : bits <= 21 ? 3 : bits <= 26 ? 4 : bits <= 31 ? 5 : 6;
    const out = [];
    for (let i = 0; i < continuation; i++) { out.unshift(0x80 | (n % 64)); n = Math.floor(n / 64); }
    const lead = (0xff << (7 - continuation)) & 0xff;
    return [lead | n, ...out];
  }

  // One FLAC frame of `count` frames of interleaved Int16 PCM starting at
  // frame `first`, numbered by its first sample `sampleNumber`.
  function frame(pcm, channels, first, count, sampleNumber) {
    const head = [0xff, 0xf9, 0x70, ((channels - 1) << 4) | 0x08];
    // Sample number, UTF-8 style (up to 36 bits).
    head.push(...codedNumber(sampleNumber));
    head.push(((count - 1) >> 8) & 255, (count - 1) & 255);
    const size = head.length + 1 + channels * (1 + 2 * count) + 2;
    const out = new Uint8Array(size);
    out.set(head); out[head.length] = crc8(out, 0, head.length);
    let o = head.length + 1;
    for (let c = 0; c < channels; c++) {
      out[o++] = 0x02; // verbatim subframe, no wasted bits
      for (let i = 0; i < count; i++) { const v = pcm[(first + i) * channels + c]; out[o++] = (v >> 8) & 255; out[o++] = v & 255; }
    }
    const crc = crc16(out, 0, o); out[o++] = crc >> 8; out[o++] = crc & 255;
    return out;
  }

  let sequence = 0;
  // A media segment: one MP4 sample per block, starting at `startSample`
  // (in samples at `rate`).
  function segment(pcm, channels, blocks, startSample) {
    const frames = []; let first = 0, number = startSample;
    for (const count of blocks) { if (count > 0) { frames.push({ data: frame(pcm, channels, first, count, Math.max(0, number)), count }); } first += count; number += count; }
    const trunEntries = []; for (const f of frames) trunEntries.push(...u32(f.count), ...u32(f.data.length));
    const build = (offset) => box('moof', full('mfhd', 0, 0, u32(++sequence)),
      box('traf', full('tfhd', 0, 0x020000, u32(1)), full('tfdt', 1, 0, u64(Math.max(0, startSample))),
        full('trun', 0, 0x000301, u32(frames.length), u32(offset), trunEntries)));
    const moof = build(build(0).length + 8);
    const mdat = box('mdat', concat(frames.map((f) => f.data)));
    return concat([moof, mdat]);
  }
  return { init, segment };
})();
// The page-facing half of the system-decoder media shim (audio). Runs in a
// document's main world before its scripts, as the body of a function that
// receives `native`, CefSwift's decoder: nothing is left in the page's
// globals. AAC is decoded by the system in the browser process and played as
// lossless FLAC through the page's own, native MediaSource.
const nativeIsTypeSupported = MediaSource.isTypeSupported;
const nativeAddSourceBuffer = MediaSource.prototype.addSourceBuffer;
const nativeRemoveSourceBuffer = MediaSource.prototype.removeSourceBuffer;
const nativeEndOfStream = MediaSource.prototype.endOfStream;
const nativeCanPlayType = HTMLMediaElement.prototype.canPlayType;
const srcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
const currentSrcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'currentSrc');
const FLAC = 'audio/mp4; codecs="flac"';

// MIME types whose codecs are all AAC: what the shim takes over.
function parseType(type) {
  const match = /^\s*([^;\s]+)\s*(?:;(.*))?$/.exec(String(type));
  if (!match) return null;
  const mime = match[1].toLowerCase();
  const codecs = /codecs\s*=\s*"?([^";]*)"?/i.exec(match[2] || '');
  return { mime, codecs: codecs ? codecs[1].split(',').map((c) => c.trim()).filter(Boolean) : [] };
}
const isAAC = (codec) => /^mp4a\.(40\.(2|5|29)|67)$/i.test(codec);
function isAACType(type, requireCodecs) {
  const parsed = parseType(type);
  if (!parsed) return false;
  if (!['audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/mp4a-latm', 'video/mp4'].includes(parsed.mime)) return false;
  if (parsed.codecs.length === 0) return !requireCodecs && parsed.mime !== 'video/mp4';
  return parsed.codecs.every(isAAC);
}
const define = (target, name, value) => {
  const original = Object.getOwnPropertyDescriptor(target, name);
  Object.defineProperty(target, name, { ...original, value });
};

define(MediaSource, 'isTypeSupported', { isTypeSupported(type) {
  return isAACType(type, true) || nativeIsTypeSupported.call(this, type);
} }.isTypeSupported);
define(HTMLMediaElement.prototype, 'canPlayType', { canPlayType(type) {
  const answer = nativeCanPlayType.call(this, type);
  if (answer === '' && isAACType(type, false)) return parseType(type).codecs.length ? 'probably' : 'maybe';
  return answer;
} }.canPlayType);

// Decoding: one native AAC decoder per stream.
let nextStream = 0;
class AACStream {
  constructor(cookie) { this.id = ++nextStream; this.cookie = cookie; this.sentCookie = false; this.expected = null; }
  // `packets`: [{pts, data}] in decode order. Resolves to runs of PCM:
  // [{start (sample), pcm Int16Array, blocks [frames], rate, channels}].
  async decode(packets) {
    if (!packets.length) return [];
    const reset = this.expected === null || Math.abs(packets[0].pts - this.expected) > 0.002;
    let size = 0; for (const p of packets) size += p.data.length;
    const joined = new Uint8Array(size); let o = 0;
    for (const p of packets) { joined.set(p.data, o); o += p.data.length; }
    const result = await native.decode(this.id, reset, this.sentCookie ? null : this.cookie.buffer.slice(this.cookie.byteOffset, this.cookie.byteOffset + this.cookie.byteLength),
      joined.buffer, packets.map((p) => p.data.length));
    this.sentCookie = true;
    const { rate, channels } = result; const frames = result.frames;
    const pcm = new Int16Array(result.pcm);
    const last = packets[packets.length - 1];
    this.expected = last.pts + last.dur;
    // After a reset the first packet has no predecessor to overlap with:
    // its output is replaced by silence, which keeps the timeline exact.
    if (reset) pcm.fill(0, 0, frames[0] * channels);
    // Runs of packets that follow each other in time; a gap in their
    // timestamps starts a new run. Within a run the decoder's output is
    // contiguous from the run's first timestamp: the decoder may emit less
    // for a packet (HE-AAC drops its SBR delay after it starts) without the
    // timeline moving.
    const runs = []; let at = 0;
    for (let i = 0; i < packets.length; i++) {
      const previous = packets[i - 1];
      if (!previous || Math.abs(packets[i].pts - (previous.pts + previous.dur)) > 0.002) runs.push({ start: Math.round(packets[i].pts * rate), length: 0, first: at, blocks: [] });
      const run = runs[runs.length - 1];
      run.blocks.push(frames[i]); run.length += frames[i]; at += frames[i];
    }
    return runs.map((run) => {
      let { start, first, blocks } = run;
      // Priming before time zero (the edit list's) is not played.
      let skip = Math.max(0, -start);
      while (skip > 0 && blocks.length) { const take = Math.min(skip, blocks[0]); blocks[0] -= take; first += take; start += take; skip -= take; if (!blocks[0]) blocks.shift(); }
      const length = blocks.reduce((a, b) => a + b, 0);
      return { start, blocks, rate, channels, pcm: pcm.subarray(first * channels, (first + length) * channels) };
    }).filter((run) => run.blocks.length);
  }
  release() { native.release(this.id); }
}

// MSE: a SourceBuffer for AAC whose data goes, decoded, into a native FLAC one.
const shims = new WeakMap();      // wrapper -> state
const realOf = new WeakMap();     // wrapper -> native SourceBuffer
const sourceShims = new WeakMap(); // MediaSource -> Set of wrappers
const queueTask = (f) => setTimeout(f, 0);

class AACSourceBuffer extends EventTarget {}
Object.setPrototypeOf(AACSourceBuffer.prototype, SourceBuffer.prototype);
const handlerNames = ['onupdatestart', 'onupdate', 'onupdateend', 'onerror', 'onabort'];
for (const name of handlerNames) {
  Object.defineProperty(AACSourceBuffer.prototype, name, {
    configurable: true,
    get() { return shims.get(this).handlers[name] || null; },
    set(f) { const s = shims.get(this); if (s.handlers[name]) this.removeEventListener(name.slice(2), s.handlers[name]); s.handlers[name] = typeof f === 'function' ? f : null; if (s.handlers[name]) this.addEventListener(name.slice(2), s.handlers[name]); },
  });
}
const forwarded = ['buffered', 'timestampOffset', 'mode', 'appendWindowStart', 'appendWindowEnd', 'audioTracks', 'videoTracks', 'textTracks'];
for (const name of forwarded) {
  const descriptor = Object.getOwnPropertyDescriptor(SourceBuffer.prototype, name);
  if (!descriptor) continue;
  Object.defineProperty(AACSourceBuffer.prototype, name, {
    configurable: true,
    get() { return descriptor.get.call(realOf.get(this)); },
    set: descriptor.set && function (value) {
      if (shims.get(this).updating && name !== 'appendWindowEnd') throw new DOMException("Failed to set the '" + name + "' property on 'SourceBuffer': This SourceBuffer is still processing an 'appendBuffer' or 'remove' operation.", 'InvalidStateError');
      descriptor.set.call(realOf.get(this), value);
    },
  });
}
Object.defineProperty(AACSourceBuffer.prototype, 'updating', { configurable: true, get() { return shims.get(this).updating; } });

const fire = (target, type) => target.dispatchEvent(new Event(type));
function begin(wrapper, work) {
  const state = shims.get(wrapper);
  state.updating = true;
  const generation = state.generation;
  queueTask(async () => {
    if (state.generation !== generation) return;
    fire(wrapper, 'updatestart');
    let failed = false;
    try { await work(() => state.generation !== generation); } catch (e) { failed = true; }
    if (state.generation !== generation) return;
    state.updating = false;
    if (failed) { state.pending = new Uint8Array(0); fire(wrapper, 'error'); } else fire(wrapper, 'update');
    fire(wrapper, 'updateend');
    if (state.onIdle) { const f = state.onIdle; state.onIdle = null; f(); }
  });
}
function realOperation(real, start) {
  return new Promise((resolve, reject) => {
    const done = () => { real.removeEventListener('error', fail); resolve(); };
    const fail = () => { real.removeEventListener('updateend', done); reject(new Error('append failed')); };
    real.addEventListener('updateend', done, { once: true });
    real.addEventListener('error', fail, { once: true });
    try { start(); } catch (e) { real.removeEventListener('updateend', done); real.removeEventListener('error', fail); reject(e); }
  });
}
const busy = (name) => new DOMException(`Failed to execute '${name}' on 'SourceBuffer': This SourceBuffer is still processing an 'appendBuffer' or 'remove' operation.`, 'InvalidStateError');

Object.assign(AACSourceBuffer.prototype, {
  appendBuffer(data) {
    const state = shims.get(this);
    if (state.updating) throw busy('appendBuffer');
    if (!state.source || state.source.readyState === 'closed' || state.removed) throw new DOMException("Failed to execute 'appendBuffer' on 'SourceBuffer': This SourceBuffer has been removed from the parent media source.", 'InvalidStateError');
    const bytes = ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : new Uint8Array(data);
    const joined = new Uint8Array(state.pending.length + bytes.length);
    joined.set(state.pending); joined.set(bytes, state.pending.length);
    state.pending = joined;
    begin(this, async (stale) => {
      const real = realOf.get(this);
      // An initialization segment (moov) configures the decoder.
      const top = [...MP4.boxes(state.pending, 0, state.pending.length)];
      const moov = top.find((b) => b.type === 'moov' && !b.truncated);
      if (moov) {
        const init = MP4.parseInit(state.pending.subarray(moov.start, moov.end));
        const track = init && init.tracks.find((t) => t.handler === 'soun' && t.esds);
        if (!track) throw new Error('no AAC track');
        const cookie = track.esds.subarray(4);
        if (!state.track || String(state.track.esds) !== String(track.esds)) {
          if (state.stream) state.stream.release();
          state.stream = new AACStream(cookie); state.format = null;
        }
        state.track = track; state.init = init; state.fragments = { next: {} };
        state.pending = state.pending.slice(moov.end);
      }
      if (!state.init) { if (state.pending.length > 4 << 20) throw new Error('no initialization segment'); return; }
      const { samples, consumed } = MP4.parseFragments(state.pending, state.init, state.fragments);
      const packets = samples.filter((s) => s.track === state.track.id).map((s) => ({ pts: s.pts, dur: s.dur, data: s.data.slice() }));
      state.pending = state.pending.slice(consumed);
      if (!packets.length) return;
      const runs = await state.stream.decode(packets);
      if (stale()) return;
      for (const run of runs) {
        const format = run.rate + '/' + run.channels;
        if (state.format !== format) { await realOperation(real, () => real.appendBuffer(FlacMP4.init(run.rate, run.channels))); state.format = format; }
        if (stale()) return;
        await realOperation(real, () => real.appendBuffer(FlacMP4.segment(run.pcm, run.channels, run.blocks, run.start)));
        if (stale()) return;
      }
    });
  },
  remove(start, end) {
    const state = shims.get(this);
    if (state.updating) throw busy('remove');
    const real = realOf.get(this);
    begin(this, () => realOperation(real, () => real.remove(start, end)));
  },
  abort() {
    const state = shims.get(this);
    const real = realOf.get(this);
    const wasUpdating = state.updating;
    state.generation++; state.updating = false;
    state.pending = new Uint8Array(0); state.fragments = { next: {} };
    if (state.stream) state.stream.expected = null;
    if (real.updating) real.abort();
    if (wasUpdating) { fire(this, 'abort'); fire(this, 'updateend'); }
  },
  changeType(type) {
    if (!isAACType(type, true)) throw new DOMException("Failed to execute 'changeType' on 'SourceBuffer': Changing to the type provided ('" + type + "') is not supported.", 'NotSupportedError');
  },
});
for (const name of ['appendBuffer', 'remove', 'abort', 'changeType']) {
  Object.defineProperty(AACSourceBuffer.prototype, name, { ...Object.getOwnPropertyDescriptor(AACSourceBuffer.prototype, name), enumerable: false });
}

define(MediaSource.prototype, 'addSourceBuffer', { addSourceBuffer(type) {
  if (!isAACType(type, true)) return nativeAddSourceBuffer.call(this, type);
  const real = nativeAddSourceBuffer.call(this, FLAC);
  const wrapper = new AACSourceBuffer();
  Object.setPrototypeOf(wrapper, AACSourceBuffer.prototype);
  realOf.set(wrapper, real);
  shims.set(wrapper, { source: this, updating: false, generation: 0, pending: new Uint8Array(0), handlers: {}, stream: null, track: null, init: null, format: null, fragments: { next: {} } });
  if (!sourceShims.has(this)) sourceShims.set(this, new Set());
  sourceShims.get(this).add(wrapper);
  return wrapper;
} }.addSourceBuffer);
define(MediaSource.prototype, 'removeSourceBuffer', { removeSourceBuffer(buffer) {
  const real = realOf.get(buffer);
  if (!real) return nativeRemoveSourceBuffer.call(this, buffer);
  const state = shims.get(buffer);
  buffer.abort(); state.removed = true;
  if (state.stream) state.stream.release();
  sourceShims.get(this)?.delete(buffer);
  return nativeRemoveSourceBuffer.call(this, real);
} }.removeSourceBuffer);
define(MediaSource.prototype, 'endOfStream', { endOfStream(...args) {
  const pending = [...(sourceShims.get(this) || [])].filter((b) => shims.get(b).updating);
  if (!pending.length) return nativeEndOfStream.apply(this, args);
  // Waits for appends still being decoded, which the page considers done.
  let left = pending.length;
  for (const b of pending) shims.get(b).onIdle = () => { if (--left === 0 && this.readyState === 'open') nativeEndOfStream.apply(this, args); };
} }.endOfStream);

// Progressive files: an <audio>/<video> whose AAC source the browser cannot
// play, and whose bytes the page could read itself (same origin, or CORS).
const takenOver = new WeakMap(); // element -> original URL
for (const [name, descriptor] of [['src', srcDescriptor], ['currentSrc', currentSrcDescriptor]]) {
  Object.defineProperty(HTMLMediaElement.prototype, name, { ...descriptor, get: { get [name]() {
    const original = takenOver.get(this);
    return original !== undefined ? original : descriptor.get.call(this);
  } }.__lookupGetter__(name) });
}
const audioExtension = /\.(m4a|m4b|mp4|aac)(\?|#|$)/i;
let redispatching = false;
addEventListener('error', (event) => {
  if (redispatching) return;
  const target = event.target;
  let element, url, type = '';
  if (target instanceof HTMLSourceElement && target.parentElement instanceof HTMLMediaElement) {
    element = target.parentElement; url = target.src; type = target.type;
  } else if (target instanceof HTMLMediaElement) {
    element = target; url = descriptor(target);
    if (!target.error || target.error.code !== MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED) return;
  } else return;
  if (takenOver.has(element) || !url || /^(blob|data|mediasource|mediastream):/i.test(url)) return;
  if (type ? !isAACType(type, false) : !audioExtension.test(url)) return;
  let parsed; try { parsed = new URL(url, document.baseURI); } catch (e) { return; }
  if (/^(blob|data|javascript|about|chrome|chrome-extension|chrome-untrusted|devtools):$/.test(parsed.protocol)) return;
  const sameOrigin = parsed.origin === location.origin;
  if (!sameOrigin && element.crossOrigin === null) return; // the page could not read these bytes
  event.stopImmediatePropagation();
  playFile(element, parsed.href, sameOrigin, target).catch(() => {
    takenOver.delete(element);
    redispatching = true; try { target.dispatchEvent(new Event('error')); } finally { redispatching = false; }
  });
}, true);
function descriptor(element) { return srcDescriptor.get.call(element) || currentSrcDescriptor.get.call(element); }

async function fetchRange(url, credentials, start, end) {
  const response = await fetch(url, { credentials, headers: { Range: `bytes=${start}-${end - 1}` }, cache: 'force-cache' });
  if (!response.ok) throw new Error('fetch failed');
  const bytes = new Uint8Array(await response.arrayBuffer());
  return response.status === 206 ? { bytes, partial: true } : { bytes, partial: false };
}

// ADTS (.aac): packets and the ES descriptor to configure the decoder with.
function parseADTS(bytes) {
  const packets = []; let o = 0, config = null, rate = 0;
  const rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
  while (o + 7 <= bytes.length && bytes[o] === 0xff && (bytes[o + 1] & 0xf6) === 0xf0) {
    const header = (bytes[o + 1] & 1) ? 7 : 9;
    const length = ((bytes[o + 3] & 3) << 11) | (bytes[o + 4] << 3) | (bytes[o + 5] >> 5);
    if (!config) {
      const object = (bytes[o + 2] >> 6) + 1, frequency = (bytes[o + 2] >> 2) & 15, channels = ((bytes[o + 2] & 1) << 2) | (bytes[o + 3] >> 6);
      rate = rates[frequency] || 48000;
      const asc = [(object << 3) | (frequency >> 1), ((frequency & 1) << 7) | (channels << 3)];
      config = Uint8Array.from([3, 25, 0, 0, 0, 4, 17, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 2, ...asc, 6, 1, 2]);
    }
    if (length < header || o + length > bytes.length) break;
    packets.push({ pts: packets.length * 1024 / rate, dur: 1024 / rate, data: bytes.slice(o + header, o + length) });
    o += length;
  }
  return config && packets.length ? { config, packets, duration: packets.length * 1024 / rate } : null;
}

async function playFile(element, url, sameOrigin, origin) {
  const credentials = sameOrigin ? 'same-origin' : element.crossOrigin === 'use-credentials' ? 'include' : 'omit';
  takenOver.set(element, url);
  // The head of the file says what it is; an MP4's moov may be at its end.
  let head = await fetchRange(url, credentials, 0, 1 << 20);
  let whole = head.partial ? null : head.bytes;
  let source; // {cookie, packets: [{pts, data | off,size}], duration, read(packet range)}
  const adts = parseADTS(head.bytes);
  if (adts) {
    if (head.partial && head.bytes.length === 1 << 20) whole = (await fetchRange(url, credentials, 0, 1 << 30)).bytes;
    const parsed = whole ? parseADTS(whole) : adts;
    source = { cookie: parsed.config, duration: parsed.duration, packets: parsed.packets };
  } else {
    let moov = null, offset = 0, data = head.bytes;
    for (const b of MP4.boxes(data, 0, data.length)) {
      if (b.type === 'moov') { moov = b; break; }
      if (b.truncated) { offset = b.start; break; }
    }
    if (!moov || moov.truncated) {
      // Walk the top-level boxes by their headers to find the moov.
      let position = 0;
      for (let guard = 0; guard < 64; guard++) {
        const header = (await fetchRange(url, credentials, position, position + 16)).bytes;
        if (header.length < 8) break;
        const view = new DataView(header.buffer); let size = view.getUint32(0);
        const type = String.fromCharCode(...header.subarray(4, 8));
        if (size === 1) size = Number(view.getBigUint64(8));
        if (type === 'moov') { data = (await fetchRange(url, credentials, position, position + size)).bytes; moov = { start: 0 }; offset = position; break; }
        if (size < 8) break;
        position += size;
      }
      if (!moov) throw new Error('no moov');
    }
    const init = MP4.parseInit(data.subarray(moov.start));
    const track = init && init.tracks.find((t) => t.handler === 'soun' && t.esds);
    if (!track || init.tracks.some((t) => t.handler === 'vide')) throw new Error('not an AAC-only file');
    const samples = MP4.progressiveSamples(data.subarray(moov.start), track);
    source = { cookie: track.esds.subarray(4), duration: init.duration || track.duration / track.timescale, packets: samples };
  }
  // A MediaSource of the element's own, fed ahead of the playhead.
  const media = new MediaSource();
  const objectURL = URL.createObjectURL(media);
  srcDescriptor.set.call(element, objectURL);
  await new Promise((resolve) => media.addEventListener('sourceopen', resolve, { once: true }));
  URL.revokeObjectURL(objectURL);
  media.duration = source.duration;
  const real = nativeAddSourceBuffer.call(media, FLAC);
  const stream = new AACStream(source.cookie);
  let format = null, next = 0, busy = false, generation = 0;
  const chunkSeconds = 10, aheadSeconds = 30, behindSeconds = 20;
  const indexAt = (time) => { let lo = 0, hi = source.packets.length - 1; while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (source.packets[mid].pts <= time) lo = mid; else hi = mid - 1; } return lo; };
  const bufferedEnd = () => { const t = element.currentTime, b = real.buffered; for (let i = 0; i < b.length; i++) if (b.start(i) <= t + 0.1 && b.end(i) >= t) return b.end(i); return t; };
  async function readPackets(first, last) {
    const slice = source.packets.slice(first, last);
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
      while (next < source.packets.length && bufferedEnd() - element.currentTime < aheadSeconds && mine === generation) {
        const endTime = source.packets[next].pts + chunkSeconds;
        let last = next; while (last < source.packets.length && source.packets[last].pts < endTime) last++;
        const packets = await readPackets(next, last);
        const runs = await stream.decode(packets);
        if (mine !== generation) break;
        for (const run of runs) {
          const runFormat = run.rate + '/' + run.channels;
          if (format !== runFormat) { await realOperation(real, () => real.appendBuffer(FlacMP4.init(run.rate, run.channels))); format = runFormat; }
          await realOperation(real, () => real.appendBuffer(FlacMP4.segment(run.pcm, run.channels, run.blocks, run.start)));
        }
        next = last;
        const behind = element.currentTime - behindSeconds;
        if (behind > 0 && real.buffered.length && real.buffered.start(0) < behind) await realOperation(real, () => real.remove(0, behind));
      }
      if (next >= source.packets.length && media.readyState === 'open' && !real.updating) nativeEndOfStream.call(media);
    } finally { busy = false; }
  }
  element.addEventListener('timeupdate', () => { pump().catch(() => {}); });
  element.addEventListener('seeking', () => {
    const t = element.currentTime, b = real.buffered;
    for (let i = 0; i < b.length; i++) if (b.start(i) <= t && t < b.end(i) - 0.5) return;
    generation++; next = indexAt(t); stream.expected = null;
    const restart = () => { busy = false; pump().catch(() => {}); };
    if (real.updating) real.addEventListener('updateend', restart, { once: true }); else restart();
  });
  await pump();
}
})
"""##
}
