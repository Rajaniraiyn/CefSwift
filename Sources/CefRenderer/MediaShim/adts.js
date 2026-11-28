// ADTS (.aac): the packets, and the ES descriptor an MP4 would carry to
// configure the decoder with.
function parseADTS(bytes) {
  const packets = []; let o = 0, config = null, rate = 0, channels = 0;
  const rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
  while (o + 7 <= bytes.length && bytes[o] === 0xff && (bytes[o + 1] & 0xf6) === 0xf0) {
    const header = (bytes[o + 1] & 1) ? 7 : 9;
    const length = ((bytes[o + 3] & 3) << 11) | (bytes[o + 4] << 3) | (bytes[o + 5] >> 5);
    if (!config) {
      const object = (bytes[o + 2] >> 6) + 1, frequency = (bytes[o + 2] >> 2) & 15;
      channels = ((bytes[o + 2] & 1) << 2) | (bytes[o + 3] >> 6);
      rate = rates[frequency] || 48000;
      const asc = [(object << 3) | (frequency >> 1), ((frequency & 1) << 7) | (channels << 3)];
      config = Uint8Array.from([3, 25, 0, 0, 0, 4, 17, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 2, ...asc, 6, 1, 2]);
    }
    if (length < header || o + length > bytes.length) break;
    packets.push({ pts: packets.length * 1024 / rate, dur: 1024 / rate, data: bytes.subarray(o + header, o + length) });
    o += length;
  }
  if (!config || !packets.length) return null;
  return { decoder: { codec: 'mp4a', configuration: config, rate, channels }, packets, duration: packets.length * 1024 / rate };
}
