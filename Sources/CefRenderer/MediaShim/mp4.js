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
      // QuickTime's sound descriptions 1 and 2 are longer before their boxes.
      const version = ev.getUint16(8);
      const extensions = entry.body + 28 + (version === 1 ? 16 : version === 2 ? 36 : 0);
      for (const b of boxes(d, extensions, entry.end)) {
        if (b.type === 'esds') t.esds = d.slice(b.body, b.end);
        if (b.type === 'alac') t.alac = d.slice(b.start, b.end);
        if (b.type === 'dac3' || b.type === 'dec3') t.dolby = d.slice(b.body, b.end);
      }
      if (t.esds) { t.asc = ascFromEsds(t.esds); if (t.asc) { t.codec = 'mp4a.40.' + (t.asc[0] >> 3); } }
      t.decoder = audioDecoderConfig(t);
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

  // What the system decoder needs of an audio track: the sample entry's
  // type and the box that configures it. Undefined for a codec the media
  // service does not decode, and for encrypted tracks (`enca`).
  function audioDecoderConfig(t) {
    const config = (codec, configuration) => ({ codec, configuration, rate: t.sampleRate, channels: t.channels });
    switch (t.format) {
      case 'mp4a': return t.esds && config('mp4a', t.esds.subarray(4));
      case 'alac': return t.alac && config('alac', t.alac);
      case 'ac-3': case 'ec-3': return config(t.format, t.dolby || new Uint8Array(0));
    }
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
