/// The JavaScript side of ``CefServiceHosts``, installed once per host
/// document by the first call: the registry of modules and functions, the
/// calls in flight with their `AbortController`s, progress and events with
/// back-pressure, and the encoder that writes results in the wire format.
///
/// A call's script is one line, `__cefswiftServices.invoke(handle, args,
/// call)`: each function is compiled once per document, the first time it
/// is called there (`define`), and invoked by its handle afterwards.
///
/// A result travels as one `ArrayBuffer` holding its wire encoding
/// (``CefWireReader``'s format), written here by JIT-compiled code instead
/// of value by value through the V8 C API, which costs about a
/// microsecond per value. The browser process checks the bytes' structure
/// as it does any renderer payload, and decodes the caller's type straight
/// from them.
enum CefServiceHostRuntime {
    /// Marks the error an invocation of a function the document does not
    /// have throws; the engine then defines it again.
    static let undefinedFunctionMarker = "cefswift: undefined function"

    /// Defines `encode(value)`, which returns an `ArrayBuffer` holding
    /// `value` in the wire format: tags 0 null, 1 false, 2 true, 3 Int32,
    /// 4 Float64, 5 string, 6 array, 7 object, 8 bytes; little-endian; a
    /// container's byte length counts what follows its 9-byte head. Values
    /// are written as `JSON.stringify` sees them (`toJSON`, own enumerable
    /// keys, `undefined` and functions left out of objects and `null` in
    /// arrays, `null` for a value inside itself or nested deeper than 64),
    /// except that an `ArrayBuffer` or typed array is bytes. Needs only
    /// `TextEncoder`, so unit tests run it in JavaScriptCore.
    static let encoder = #"""
        const utf8 = new TextEncoder();
        let bytes = new Uint8Array(1 << 14), view = new DataView(bytes.buffer), n = 0;
        const reserve = k => {
          if (n + k <= bytes.length) return;
          let size = bytes.length * 2;
          while (size < n + k) size *= 2;
          const next = new Uint8Array(size);
          next.set(bytes.subarray(0, n));
          bytes = next;
          view = new DataView(bytes.buffer);
        };
        const run = (s, at) => utf8.encodeInto(s, bytes.subarray(at)).written;
        const string = s => {
          reserve(5 + s.length * 3);
          bytes[n] = 5;
          const length = run(s, n + 5);
          view.setUint32(n + 1, length, true);
          n += 5 + length;
        };
        const open = [];
        const omitted = v => v === undefined || typeof v === 'function' || typeof v === 'symbol';
        const write = (v, depth) => {
          switch (typeof v) {
            case 'boolean': reserve(1); bytes[n++] = v ? 2 : 1; return;
            case 'number':
              if ((v | 0) === v) { reserve(5); bytes[n] = 3; view.setInt32(n + 1, v, true); n += 5; }
              else if (Number.isFinite(v)) { reserve(9); bytes[n] = 4; view.setFloat64(n + 1, v, true); n += 9; }
              else { reserve(1); bytes[n++] = 0; }
              return;
            case 'string': string(v); return;
            case 'object': break;
            default: reserve(1); bytes[n++] = 0; return;
          }
          // A value inside itself is null, as past the depth limit.
          if (v === null || depth >= 64 || open.includes(v)) { reserve(1); bytes[n++] = 0; return; }
          if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) {
            const data = v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
            reserve(5 + data.length);
            bytes[n] = 8;
            view.setUint32(n + 1, data.length, true);
            bytes.set(data, n + 5);
            n += 5 + data.length;
            return;
          }
          if (typeof v.toJSON === 'function') { write(v.toJSON(), depth); return; }
          const start = n;
          let count = 0;
          reserve(9);
          n += 9;
          open.push(v);
          if (Array.isArray(v)) {
            bytes[start] = 6;
            for (let i = 0; i < v.length; i++) { const e = v[i]; write(omitted(e) ? null : e, depth + 1); count++; }
          } else {
            bytes[start] = 7;
            for (const key of Object.keys(v)) {
              const e = v[key];
              if (omitted(e)) continue;
              reserve(4 + key.length * 3);
              const length = run(key, n + 4);
              view.setUint32(n, length, true);
              n += 4 + length;
              write(e, depth + 1);
              count++;
            }
          }
          open.pop();
          view.setUint32(start + 1, n - start - 9, true);
          view.setUint32(start + 5, count, true);
        };
        const encode = value => {
          n = 0;
          open.length = 0;
          write(value, 0);
          const encoded = bytes.slice(0, n).buffer;
          // A large result's scratch space is not kept.
          if (bytes.length > (1 << 20)) { bytes = new Uint8Array(1 << 14); view = new DataView(bytes.buffer); }
          return encoded;
        };
        """#

    /// Defines `window.__cefswiftServices` unless the document has it.
    static func bootstrap(eventBridge: String) -> String {
        """
        window.__cefswiftServices ??= (() => {
          const bridge = () => window.\(eventBridge);

          \(encoder)
          // Sends values one at a time, each once the browser process has
          // taken the one before; a value that arrives meanwhile replaces
          // the one waiting. Bounded memory, newest wins.
          const latest = send => {
            let waiting, hasWaiting = false, sending = false;
            const next = () => {
              if (!hasWaiting) { sending = false; return; }
              const value = waiting;
              waiting = undefined;
              hasWaiting = false;
              sending = true;
              Promise.resolve(send(value)).then(next, next);
            };
            return value => {
              waiting = value;
              hasWaiting = true;
              if (!sending) next();
            };
          };

          const modules = {}, functions = [], calls = new Map(), emitters = {};
          const stats = { calls: 0, ms: 0, aborts: 0 };
          const emitFor = name => (event, payload) => {
            const key = name + '/' + event;
            (emitters[key] ??= latest(p => bridge()?.event({ module: name, name: event, payload: p ?? null })))(payload);
          };
          return {
            stats, calls,
            define(handle, name, setup, fn) { functions[handle] = { name, setup, fn }; },
            async invoke(handle, args, call) {
              const f = functions[handle];
              if (!f) throw new Error('\(undefinedFunctionMarker) ' + handle);
              const controller = new AbortController();
              calls.set(call, controller);
              const started = performance.now();
              try {
                const service = await (modules[f.name] ??= Promise.resolve().then(() => f.setup(emitFor(f.name))).catch(error => {
                  delete modules[f.name];
                  throw error;
                }));
                controller.signal.throwIfAborted();
                const signal = controller.signal;
                let finished = false;
                let send = null;
                const progress = value => {
                  if (finished || signal.aborted) return;
                  send ??= latest(data => finished || signal.aborted ? null : bridge()?.progress({ call, data }));
                  send(encode(value));
                };
                const value = await f.fn(service, args, { signal, progress });
                finished = true;  // no progress after the result
                return encode(value);
              } finally {
                calls.delete(call);
                stats.calls += 1;
                stats.ms += performance.now() - started;
              }
            },
            cancel(call) {
              const controller = calls.get(call);
              if (!controller) return;
              stats.aborts += 1;
              controller.abort();
            },
          };
        })()
        """
    }
}
