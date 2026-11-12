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
                arguments.append(.string(""))
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

    package func string(_ index: Int) -> String {
        guard index < arguments.count, case .string(let value) = arguments[index] else { return "" }
        return value
    }

    package func int(_ index: Int) -> Int {
        guard index < arguments.count else { return 0 }
        switch arguments[index] {
        case .int(let value): return Int(value)
        case .double(let value): return Int(value)
        default: return 0
        }
    }

    package func bool(_ index: Int) -> Bool {
        guard index < arguments.count, case .bool(let value) = arguments[index] else { return false }
        return value
    }
}

/// The page-scripting protocol between `CefBrowser`/`CefBridge` in the
/// browser process and `PageScripting` in the helper's renderer.
package enum CefPageScriptingMessage {
    /// The key in a browser's `extra_info` holding its configuration (JSON
    /// text): bridges and user scripts, so that a renderer process has
    /// them before the browser's first document starts.
    package static let configurationKey = "cefswift.page"

    // Browser process → renderer.

    /// `[configuration JSON]`: replaces the browser's configuration.
    package static let configure = "cefswift.page.configure"
    /// `[request, source]`: runs a script in the frame's main world.
    package static let evaluate = "cefswift.page.evaluate"
    /// `[bridge, context, call, succeeded, value JSON or error message]`.
    package static let reply = "cefswift.page.reply"
    /// `[bridge, event, payload JSON]`: to the frame's listeners.
    package static let emit = "cefswift.page.emit"

    // Renderer → browser process.

    /// `[generation]`: a renderer process saw the browser's first document
    /// and holds that configuration generation.
    package static let sync = "cefswift.page.sync"
    /// `[bridge, context, call, method, arguments JSON, origin]`.
    package static let call = "cefswift.page.call"
    /// `[request, succeeded, value JSON or error message, line, column]`.
    package static let evaluated = "cefswift.page.evaluated"
}
