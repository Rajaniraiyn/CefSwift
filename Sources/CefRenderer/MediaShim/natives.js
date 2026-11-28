// The page's own media functions, taken before any of its scripts run,
// and the means to replace them with functions that look like the
// originals: CefSwift's `native.function` makes a native function that
// calls ours, so `Function.prototype.toString` prints `[native code]`,
// and what ours throws reaches the page as thrown.
const apply = Reflect.apply;
const getOwn = Object.getOwnPropertyDescriptor;
const defineOwn = Object.defineProperty;
const original = {
  isTypeSupported: MediaSource.isTypeSupported,
  addSourceBuffer: MediaSource.prototype.addSourceBuffer,
  endOfStream: MediaSource.prototype.endOfStream,
  appendBuffer: SourceBuffer.prototype.appendBuffer,
  remove: SourceBuffer.prototype.remove,
  abort: SourceBuffer.prototype.abort,
  changeType: SourceBuffer.prototype.changeType,
  updating: getOwn(SourceBuffer.prototype, 'updating').get,
  canPlayType: HTMLMediaElement.prototype.canPlayType,
  play: HTMLMediaElement.prototype.play,
  src: getOwn(HTMLMediaElement.prototype, 'src'),
  currentSrc: getOwn(HTMLMediaElement.prototype, 'currentSrc'),
  decodingInfo: typeof MediaCapabilities === 'function' ? MediaCapabilities.prototype.decodingInfo : undefined,
  fetch: fetch,
  createObjectURL: URL.createObjectURL,
  revokeObjectURL: URL.revokeObjectURL,
  setTimeout: setTimeout,
};

// A native function named `name` with the original's `length`.
function nativeLike(name, length, implementation) {
  const made = native.function(name, implementation);
  if (typeof made !== 'function') return implementation;
  defineOwn(made, 'length', { value: length, configurable: true });
  return made;
}
function replaceMethod(target, name, implementation) {
  const descriptor = getOwn(target, name);
  defineOwn(target, name, { ...descriptor, value: nativeLike(name, descriptor.value.length, implementation) });
}
function replaceAccessor(target, name, getter, setter) {
  const descriptor = getOwn(target, name);
  const replacement = { ...descriptor };
  if (getter) replacement.get = nativeLike('get ' + name, 0, getter);
  if (setter) replacement.set = nativeLike('set ' + name, 1, setter);
  defineOwn(target, name, replacement);
}
