// The types the shim takes over: MP4 audio whose codecs Chromium's own
// build lacks and the media service decodes. A type mixing such a codec
// with another, or naming video, stays Chromium's.
const FLAC = 'audio/mp4; codecs="flac"';
const systemCodec = /^(mp4a\.40\.(2|02|5|05|29|42)|mp4a\.67|alac|ac-3|ec-3)$/i;
const audioMimeTypes = ['audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/mp4a-latm'];

// `type` as {mime, codecs: [string]}, or null.
function parseType(type) {
  const match = /^\s*([^;\s]+)\s*(?:;(.*))?$/.exec(String(type));
  if (!match) return null;
  const mime = match[1].toLowerCase();
  const codecs = /codecs\s*=\s*"?([^";]*)"?/i.exec(match[2] || '');
  return { mime, codecs: codecs ? codecs[1].split(',').map((c) => c.trim()).filter(Boolean) : [] };
}

// Whether the shim plays `type`. MediaSource needs the codecs named;
// canPlayType answers "maybe" for a bare audio MIME type, as Chrome does.
function isSystemAudioType(type, requireCodecs) {
  const parsed = parseType(type);
  if (!parsed) return false;
  const isVideo = parsed.mime === 'video/mp4';
  if (!audioMimeTypes.includes(parsed.mime) && !isVideo) return false;
  if (parsed.codecs.length === 0) return !requireCodecs && !isVideo;
  return parsed.codecs.every((codec) => systemCodec.test(codec));
}
