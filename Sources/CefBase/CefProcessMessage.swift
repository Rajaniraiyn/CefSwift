import CCef

/// A message between the browser process and a renderer: a name and a
/// list of plain arguments, as `cef_process_message_t` carries them.
///
/// The browser process sends one to a frame with
/// `cef_frame_t.send_process_message(PID_RENDERER, …)`, where the helper's
/// render process handler receives it; a renderer sends one to the
/// browser process, where `cef_client_t.on_process_message_received`
/// receives it. Both sides name messages `cefswift.<extension>.<message>`.
package struct CefProcessMessage: Sendable, Equatable {
    package enum Argument: Sendable, Equatable {
        case string(String)
        case int(Int32)
        case bool(Bool)
        case double(Double)
        /// An argument of a type CefSwift does not send (null, binary, a
        /// dictionary or a list); sent as null.
        case unsupported
    }

    package var name: String
    package var arguments: [Argument]

    package init(_ name: String, _ arguments: [Argument] = []) {
        self.name = name
        self.arguments = arguments
    }

    /// Reads a borrowed message.
    package init(reading message: UnsafeMutablePointer<cef_process_message_t>) {
        name = CefStringUtil.takingUserFree(message.pointee.get_name(message)) ?? ""
        arguments = []
        guard let list = message.pointee.get_argument_list(message) else { return }
        defer { cefRelease(list) }
        for index in 0..<list.pointee.get_size(list) {
            switch list.pointee.get_type(list, index) {
            case VTYPE_STRING:
                arguments.append(.string(CefStringUtil.takingUserFree(list.pointee.get_string(list, index)) ?? ""))
            case VTYPE_INT:
                arguments.append(.int(list.pointee.get_int(list, index)))
            case VTYPE_BOOL:
                arguments.append(.bool(list.pointee.get_bool(list, index) != 0))
            case VTYPE_DOUBLE:
                arguments.append(.double(list.pointee.get_double(list, index)))
            default:
                arguments.append(.unsupported)
            }
        }
    }

    /// A new `cef_process_message_t` with one reference, which
    /// `send_process_message` consumes.
    package func make() -> UnsafeMutablePointer<cef_process_message_t>? {
        guard let message = CefStringUtil.withCefString(name, { cef_process_message_create($0) }) else { return nil }
        if let list = message.pointee.get_argument_list(message) {
            defer { cefRelease(list) }
            for (index, argument) in arguments.enumerated() {
                switch argument {
                case .string(let value): _ = CefStringUtil.withCefString(value) { list.pointee.set_string(list, index, $0) }
                case .int(let value): _ = list.pointee.set_int(list, index, value)
                case .bool(let value): _ = list.pointee.set_bool(list, index, value ? 1 : 0)
                case .double(let value): _ = list.pointee.set_double(list, index, value)
                case .unsupported: _ = list.pointee.set_null(list, index)
                }
            }
        }
        return message
    }

    /// Sends the message from `frame` to `process`. Returns whether CEF
    /// took it.
    @discardableResult
    package func send(from frame: UnsafeMutablePointer<cef_frame_t>, to process: cef_process_id_t) -> Bool {
        guard frame.pointee.is_valid(frame) != 0, let message = make() else { return false }
        frame.pointee.send_process_message(frame, process, message)
        return true
    }

    // The accessors are total: a message from another process may hold
    // anything, so a missing argument or one of another type is `nil`, and
    // so is a `.double` that is not exactly an integer (NaN, an infinity,
    // a fraction or a value out of `Int`'s range).

    /// The string at `index`, or `nil`.
    package func string(_ index: Int) -> String? {
        guard arguments.indices.contains(index), case .string(let value) = arguments[index] else { return nil }
        return value
    }

    /// The integer at `index`: an `.int`, or a `.double` that is exactly
    /// an integer. `nil` otherwise.
    package func int(_ index: Int) -> Int? {
        guard arguments.indices.contains(index) else { return nil }
        switch arguments[index] {
        case .int(let value): return Int(value)
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    /// The Boolean at `index`, or `nil`.
    package func bool(_ index: Int) -> Bool? {
        guard arguments.indices.contains(index), case .bool(let value) = arguments[index] else { return nil }
        return value
    }
}

/// The page-scripting protocol between `CefBrowser`/`CefBridge` in the
/// browser process and `PageScripting` in the helper's renderer.
///
/// `configure` and `sync` are ``CefProcessMessage``s, sent once per
/// configuration change or renderer process. The others carry a wire
/// payload (``CefWireBuffer``, ``CefWirePayload``): a ``CefWireHeader``,
/// then values, as listed for each message.
package enum CefPageScriptingMessage {
    /// The key in a browser's `extra_info` holding its configuration (JSON
    /// text): bridges and user scripts, so that a renderer process has
    /// them before the browser's first document starts.
    package static let configurationKey = "cefswift.page"
    /// The start of every page-scripting message's name.
    package static let prefix: StaticString = "cefswift.page."

    // Browser process → renderer.

    /// `[configuration JSON]`: replaces the browser's configuration.
    package static let configure = CefStaticString("cefswift.page.configure")
    /// Header `target`: the request. Values: the script's source.
    package static let evaluate = CefStaticString("cefswift.page.evaluate")
    /// Header `target`: the document, `call`, `succeeded`. Values: the
    /// bridge's name, then the result, or the error message.
    package static let reply = CefStaticString("cefswift.page.reply")
    /// Values: the bridge's name, the event, the payload. To the frame's
    /// listeners.
    package static let emit = CefStaticString("cefswift.page.emit")

    // Renderer → browser process.

    /// `[generation]`: a renderer process saw the browser's first document
    /// and holds that configuration generation.
    package static let sync = CefStaticString("cefswift.page.sync")
    /// Header `target`: the document, `call`. Values: the bridge's name,
    /// the method, the document's origin, the argument.
    package static let call = CefStaticString("cefswift.page.call")
    /// Header `target`: the request, `succeeded`, `line`, `column`. Values:
    /// the result, or the error message.
    package static let evaluated = CefStaticString("cefswift.page.evaluated")

    /// The messages.
    package enum Kind: CaseIterable, Sendable {
        case configure, evaluate, reply, emit, sync, call, evaluated

        package var name: CefStaticString {
            switch self {
            case .configure: CefPageScriptingMessage.configure
            case .evaluate: CefPageScriptingMessage.evaluate
            case .reply: CefPageScriptingMessage.reply
            case .emit: CefPageScriptingMessage.emit
            case .sync: CefPageScriptingMessage.sync
            case .call: CefPageScriptingMessage.call
            case .evaluated: CefPageScriptingMessage.evaluated
            }
        }

        /// Whether the message carries a wire payload.
        package var isWire: Bool { self != .configure && self != .sync }

        /// The message named `name`, compared without making a Swift string.
        package init?(name: UnsafePointer<cef_string_t>?) {
            guard CefStringUtil.hasPrefix(name, CefPageScriptingMessage.prefix),
                  let kind = Self.allCases.first(where: { $0.name.matches(name) })
            else { return nil }
            self = kind
        }
    }
}

extension CefProcessMessage {
    /// A message named by a static string.
    package init(_ name: CefStaticString, _ arguments: [Argument] = []) {
        self.init(name.text, arguments)
    }
}
