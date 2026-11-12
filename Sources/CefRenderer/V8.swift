import CCef
import CefBase

// Typed wrappers over CEF's V8 C API. Every call happens on the renderer's
// main thread, inside a V8 context: in a render process handler callback,
// in a V8 function or interceptor callback, or between
// `V8Context.enter()` and `exit()`.

/// A JavaScript value, holding one reference to its `cef_v8_value_t`.
@MainActor
final class V8Value {
    private let reference: CefRef<cef_v8_value_t>
    var raw: UnsafeMutablePointer<cef_v8_value_t> { reference.pointer }

    /// Takes over the caller's reference.
    init(adopting raw: UnsafeMutablePointer<cef_v8_value_t>) {
        reference = CefRef(adopting: raw)
    }

    /// Takes over the caller's reference, if there is a value.
    convenience init?(adopting raw: UnsafeMutablePointer<cef_v8_value_t>?) {
        guard let raw else { return nil }
        self.init(adopting: raw)
    }

    /// The value with a reference added for CEF, which consumes it.
    func retained() -> UnsafeMutablePointer<cef_v8_value_t> {
        cefAddRef(raw)
        return raw
    }

    // MARK: Creating values

    static var undefined: V8Value { V8Value(adopting: cef_v8_value_create_undefined()!) }
    static var null: V8Value { V8Value(adopting: cef_v8_value_create_null()!) }
    static func bool(_ value: Bool) -> V8Value { V8Value(adopting: cef_v8_value_create_bool(value ? 1 : 0)!) }
    static func int(_ value: Int32) -> V8Value { V8Value(adopting: cef_v8_value_create_int(value)!) }
    static func double(_ value: Double) -> V8Value { V8Value(adopting: cef_v8_value_create_double(value)!) }
    static func string(_ value: String) -> V8Value {
        V8Value(adopting: CefStringUtil.withCefString(value) { cef_v8_value_create_string($0) }!)
    }
    static func array(count: Int) -> V8Value { V8Value(adopting: cef_v8_value_create_array(Int32(count))!) }
    static func object() -> V8Value { V8Value(adopting: cef_v8_value_create_object(nil, nil)!) }
    static func promise() -> V8Value? { V8Value(adopting: cef_v8_value_create_promise()) }

    /// A function that runs `body` when called. `body` receives `this` and
    /// the arguments and returns the result or an exception message.
    static func function(_ name: String, _ body: @escaping V8Function.Body) -> V8Value? {
        let handler = V8Function(body: body).makeHandler()
        return V8Value(adopting: CefStringUtil.withCefString(name) { cef_v8_value_create_function($0, handler) })
    }

    /// An object whose named properties `getter` provides; a name it
    /// returns `nil` for is looked up as usual, on the object and its
    /// prototype chain.
    static func object(intercepting getter: @escaping V8Interceptor.Getter) -> V8Value? {
        let interceptor = V8Interceptor(getter: getter).makeInterceptor()
        return V8Value(adopting: cef_v8_value_create_object(nil, interceptor))
    }

    // MARK: Reading values

    var isUndefined: Bool { raw.pointee.is_undefined(raw) != 0 }
    var isNull: Bool { raw.pointee.is_null(raw) != 0 }
    var isBool: Bool { raw.pointee.is_bool(raw) != 0 }
    var isInt: Bool { raw.pointee.is_int(raw) != 0 }
    var isUInt: Bool { raw.pointee.is_uint(raw) != 0 }
    var isDouble: Bool { raw.pointee.is_double(raw) != 0 }
    var isDate: Bool { raw.pointee.is_date(raw) != 0 }
    var isString: Bool { raw.pointee.is_string(raw) != 0 }
    var isObject: Bool { raw.pointee.is_object(raw) != 0 }
    var isArray: Bool { raw.pointee.is_array(raw) != 0 }
    var isArrayBuffer: Bool { raw.pointee.is_array_buffer(raw) != 0 }
    var isFunction: Bool { raw.pointee.is_function(raw) != 0 }
    var isPromise: Bool { raw.pointee.is_promise(raw) != 0 }

    var boolValue: Bool { raw.pointee.get_bool_value(raw) != 0 }
    var intValue: Int32 { raw.pointee.get_int_value(raw) }
    var uintValue: UInt32 { raw.pointee.get_uint_value(raw) }
    var doubleValue: Double { raw.pointee.get_double_value(raw) }
    var stringValue: String { CefStringUtil.takingUserFree(raw.pointee.get_string_value(raw)) ?? "" }
    /// A Date's time in milliseconds since 1970.
    var dateMilliseconds: Double { Self.milliseconds(of: raw.pointee.get_date_value(raw)) }

    /// A `cef_basetime_t` in milliseconds since 1970.
    nonisolated static func milliseconds(of basetime: cef_basetime_t) -> Double {
        var time = cef_time_t()
        var milliseconds = 0.0
        if cef_time_from_basetime(basetime, &time) != 0 {
            _ = cef_time_to_doublet(&time, &milliseconds)
            milliseconds *= 1000
        }
        return milliseconds
    }

    func isSame(_ other: V8Value) -> Bool { raw.pointee.is_same(raw, other.retained()) != 0 }

    subscript(key: String) -> V8Value? {
        V8Value(adopting: CefStringUtil.withCefString(key) { raw.pointee.get_value_bykey(raw, $0) })
    }

    subscript(index: Int) -> V8Value? {
        V8Value(adopting: raw.pointee.get_value_byindex(raw, Int32(index)))
    }

    var arrayLength: Int { Int(raw.pointee.get_array_length(raw)) }

    /// The object's own enumerable string keys.
    var keys: [String] {
        guard let list = cef_string_list_alloc() else { return [] }
        defer { cef_string_list_free(list) }
        guard raw.pointee.get_keys(raw, list) != 0 else { return [] }
        return cefStrings(from: list)
    }

    // MARK: Changing values

    /// Defines `key` on the object. Hidden properties are read-only, not
    /// enumerable and cannot be deleted, as `Object.defineProperty` with
    /// only a value makes them.
    @discardableResult
    func set(_ key: String, _ value: V8Value, hidden: Bool = false) -> Bool {
        let attributes = hidden
            ? cef_v8_propertyattribute_t(
                V8_PROPERTY_ATTRIBUTE_READONLY.rawValue | V8_PROPERTY_ATTRIBUTE_DONTENUM.rawValue
                    | V8_PROPERTY_ATTRIBUTE_DONTDELETE.rawValue)
            : V8_PROPERTY_ATTRIBUTE_NONE
        return CefStringUtil.withCefString(key) {
            raw.pointee.set_value_bykey(raw, $0, value.retained(), attributes) != 0
        }
    }

    @discardableResult
    func set(_ index: Int, _ value: V8Value) -> Bool {
        raw.pointee.set_value_byindex(raw, Int32(index), value.retained()) != 0
    }

    /// Calls the function with `this` and `arguments`; a thrown exception
    /// is returned as `.failure` with its message.
    @discardableResult
    func call(this: V8Value? = nil, _ arguments: [V8Value] = []) -> Result<V8Value, V8Exception> {
        let argumentPointers: [UnsafeMutablePointer<cef_v8_value_t>?] = arguments.map { $0.retained() }
        let result = argumentPointers.withUnsafeBufferPointer { buffer in
            raw.pointee.execute_function(raw, this?.retained(), buffer.count, buffer.baseAddress)
        }
        if let result { return .success(V8Value(adopting: result)) }
        let exception = V8Exception(adopting: raw.pointee.get_exception(raw))
        _ = raw.pointee.clear_exception(raw)
        return .failure(exception ?? V8Exception(message: "the function could not be called"))
    }

    /// Settles a promise created with ``promise()``. Inside its context.
    func resolve(_ value: V8Value) { _ = raw.pointee.resolve_promise(raw, value.retained()) }
    func reject(_ message: String) { _ = CefStringUtil.withCefString(message) { raw.pointee.reject_promise(raw, $0) } }
}

/// An exception thrown by JavaScript.
struct V8Exception: Error {
    var message: String
    var line = 0
    var column = 0

    init(message: String, line: Int = 0, column: Int = 0) {
        self.message = message
        self.line = line
        self.column = column
    }

    @MainActor
    init?(adopting raw: UnsafeMutablePointer<cef_v8_exception_t>?) {
        guard let raw else { return nil }
        defer { cefRelease(raw) }
        message = CefStringUtil.takingUserFree(raw.pointee.get_message(raw)) ?? "JavaScript exception"
        line = Int(raw.pointee.get_line_number(raw))
        column = Int(raw.pointee.get_start_column(raw))
    }
}

/// A V8 context: one JavaScript world of one document.
@MainActor
final class V8Context {
    private let reference: CefRef<cef_v8_context_t>
    var raw: UnsafeMutablePointer<cef_v8_context_t> { reference.pointer }

    /// Takes over the caller's reference.
    init(adopting raw: UnsafeMutablePointer<cef_v8_context_t>) {
        reference = CefRef(adopting: raw)
    }

    /// The context with a reference added for CEF, which consumes every
    /// object passed to it.
    func retained() -> UnsafeMutablePointer<cef_v8_context_t> {
        cefAddRef(raw)
        return raw
    }

    var isValid: Bool { raw.pointee.is_valid(raw) != 0 }
    var global: V8Value? { V8Value(adopting: raw.pointee.get_global(raw)) }

    func isSame(_ other: V8Context) -> Bool { raw.pointee.is_same(raw, other.retained()) != 0 }

    /// Runs `body` inside the context, which values created or settled
    /// outside a V8 callback need.
    func entered<R>(_ body: () -> R) -> R {
        _ = raw.pointee.enter(raw)
        defer { _ = raw.pointee.exit(raw) }
        return body()
    }

    /// A function for code that runs outside any V8 callback, such as a
    /// process message handler that entered the context itself. Inside the
    /// context.
    ///
    /// In CEF 156 a function from ``V8Value/function(_:_:)`` created there
    /// never reaches its Swift side when called: the call returns
    /// `undefined` and runs nothing. One created inside a V8 callback, such
    /// as an interceptor's getter, works. So this returns a small
    /// JavaScript function that looks the native function up through an
    /// interceptor on each call.
    func durableFunction(_ body: @escaping V8Function.Body) -> V8Value? {
        let target = V8Value.object { name in
            name == "call" ? V8Value.function("call", body) : nil
        }
        guard let target, case .success(let make) = run("(target) => function () { return target.call.apply(this, arguments); }")
        else { return nil }
        guard case .success(let function) = make.call(this: nil, [target]) else { return nil }
        return function
    }

    /// Compiles and runs `source` as a classic script.
    func run(_ source: String) -> Result<V8Value, V8Exception> {
        var source = source
        return source.withUTF8 { run(utf8: UnsafeRawBufferPointer($0)) }
    }

    /// Compiles and runs the UTF-8 `source` as a classic script, without
    /// making a Swift string of it.
    func run(utf8 source: UnsafeRawBufferPointer) -> Result<V8Value, V8Exception> {
        var result: UnsafeMutablePointer<cef_v8_value_t>?
        var exception: UnsafeMutablePointer<cef_v8_exception_t>?
        var noURL = cef_string_t()
        // `eval` is CEF's name for running a script in the context; it is
        // not JavaScript's eval and is not subject to the page's CSP.
        let ran = CefStringUtil.withCefString(utf8: source) { code in
            raw.pointee.eval(raw, code, &noURL, 1, &result, &exception)
        }
        if ran != 0, let value = V8Value(adopting: result) { return .success(value) }
        cefRelease(result)
        return .failure(V8Exception(adopting: exception) ?? V8Exception(message: "the script did not run"))
    }
}

/// The Swift side of a JavaScript function.
final class V8Function: Sendable {
    /// `this`, the arguments; the result, or an exception message.
    typealias Body = @MainActor @Sendable (V8Value?, [V8Value]) -> Result<V8Value?, V8Exception>

    private let body: Body

    init(body: @escaping Body) {
        self.body = body
    }

    /// The returned handler carries one reference, consumed by
    /// `cef_v8_value_create_function`.
    func makeHandler() -> UnsafeMutablePointer<cef_v8_handler_t> {
        let handler = cefAllocate(cef_v8_handler_t.self, owner: self)
        handler.pointee.execute = { s, _, object, count, arguments, result, exception in
            nonisolated(unsafe) let object = object
            nonisolated(unsafe) let arguments = arguments
            nonisolated(unsafe) let result = result
            nonisolated(unsafe) let exception = exception
            guard let owner = cefOwner(V8Function.self, s) else {
                cefRelease(object)
                for index in 0..<count { cefRelease(arguments?[index]) }
                return 0
            }
            return MainActor.assumeIsolated {
                let this = V8Value(adopting: object)
                let values = (0..<count).compactMap { V8Value(adopting: arguments?[$0]) }
                switch owner.body(this, values) {
                case .success(let value):
                    result?.pointee = value?.retained()
                case .failure(let error):
                    if let exception { CefStringUtil.set(error.message, into: &exception.pointee) }
                }
                return 1
            }
        }
        return handler
    }
}

/// The Swift side of an object's named-property interceptor.
final class V8Interceptor: Sendable {
    /// The property's name; its value, or `nil` to look it up as usual.
    typealias Getter = @MainActor @Sendable (String) -> V8Value?

    private let getter: Getter

    init(getter: @escaping Getter) {
        self.getter = getter
    }

    /// The returned interceptor carries one reference, consumed by
    /// `cef_v8_value_create_object`.
    func makeInterceptor() -> UnsafeMutablePointer<cef_v8_interceptor_t> {
        let interceptor = cefAllocate(cef_v8_interceptor_t.self, owner: self)
        interceptor.pointee.get_byname = { s, name, object, result, _ in
            cefRelease(object)
            let name = CefStringUtil.string(from: name)
            nonisolated(unsafe) let result = result
            guard let owner = cefOwner(V8Interceptor.self, s) else { return 0 }
            return MainActor.assumeIsolated {
                guard let value = owner.getter(name) else { return 0 }
                result?.pointee = value.retained()
                return 1
            }
        }
        interceptor.pointee.get_byindex = { _, _, object, _, _ in
            cefRelease(object)
            return 0
        }
        interceptor.pointee.set_byname = { _, _, object, value, _ in
            cefRelease(object)
            cefRelease(value)
            return 0
        }
        interceptor.pointee.set_byindex = { _, _, object, value, _ in
            cefRelease(object)
            cefRelease(value)
            return 0
        }
        return interceptor
    }
}
