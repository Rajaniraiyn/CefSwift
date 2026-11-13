import CCef
import CefBase
import Foundation

/// Typed access to Chromium's preferences — the settings behind
/// `chrome://settings` — for one profile or for the whole app.
///
/// ```swift
/// let preferences = profile.preferences
/// try preferences.set(false, for: .savesPasswords)
/// let size = preferences[.defaultFontSize]            // Int?
/// for await languages in preferences.observe(.acceptLanguages) { … }
/// ```
///
/// Keys name preferences with their Swift type; ``Key`` lists the common
/// ones, and `Key("dotted.name")` makes others. ``value(named:)`` and
/// ``setValue(_:named:)`` read and write raw JSON values by name.
@MainActor
public struct CefPreferences {
    enum Source {
        case profile(CefProfile)
        case application
    }

    let source: Source

    // MARK: Keys

    /// A preference's dotted name with the Swift type of its value.
    public struct Key<Value: Sendable>: Sendable {
        /// The preference's dotted name, such as `"browser.show_home_button"`.
        public let name: String
        let decode: @Sendable (CefJSON) -> Value?
        let encode: @Sendable (Value) -> CefJSON

        /// A key that converts its value with `decode` and `encode`.
        public init(_ name: String, decode: @escaping @Sendable (CefJSON) -> Value?, encode: @escaping @Sendable (Value) -> CefJSON) {
            self.name = name
            self.decode = decode
            self.encode = encode
        }
    }

    // MARK: Reading and writing

    /// The preference's value; `nil` when no such preference exists or its
    /// value is not of the key's type.
    public subscript<Value>(key: Key<Value>) -> Value? {
        value(named: key.name).flatMap(key.decode)
    }

    /// The raw value of the preference called `name`; `nil` when no such
    /// preference exists.
    public func value(named name: String) -> CefJSON? {
        withManager { manager in
            CefStringUtil.withCefString(name) { cefName -> CefJSON? in
                // The header says get_preference returns NULL for an unknown
                // name, but CEF 156 returns a value (SelfTest checks this).
                guard manager.pointee.has_preference(manager, cefName) != 0 else { return nil }
                // A NULL value is absent too, not JSON null.
                guard let value = manager.pointee.get_preference(manager, cefName) else { return nil }
                defer { cefRelease(value) }
                return CefJSON(cefValue: value)
            }
        } ?? nil
    }

    /// Changes a preference. `nil` restores its default.
    ///
    /// Throws when the preference is unknown, cannot be changed (see
    /// ``canSet(_:)``), or Chromium refuses the value.
    public func set<Value>(_ value: Value?, for key: Key<Value>) throws(CefError) {
        try setValue(value.map(key.encode), named: key.name)
    }

    /// Changes the preference called `name` to a raw value; `nil` restores
    /// its default.
    public func setValue(_ value: CefJSON?, named name: String) throws(CefError) {
        let failure: String? = withManager { manager in
            CefStringUtil.withCefString(name) { cefName -> String? in
                guard manager.pointee.has_preference(manager, cefName) != 0 else { return "no such preference" }
                var error = cef_string_t()
                defer { cef_string_utf16_clear(&error) }
                guard manager.pointee.set_preference(manager, cefName, value?.makeCefValue(), &error) == 0 else { return nil }
                let message = CefStringUtil.string(from: error)
                return message.isEmpty ? "Chromium refused the value" : message
            }
        } ?? "Chromium is not running"
        if let failure {
            throw CefError.operationFailed("Cannot set preference '\(name)': \(failure)")
        }
    }

    /// Sets each preference that exists, logging what Chromium refuses:
    /// the configured preferences, as Chromium starts or a profile is
    /// first used.
    func apply(_ preferences: [String: CefJSON]) {
        for (name, value) in preferences where contains(named: name) {
            do {
                try setValue(value, named: name)
            } catch {
                CefLog.error("\(error)")
            }
        }
    }

    /// Restores a preference's default value.
    public func reset<Value>(_ key: Key<Value>) throws(CefError) {
        try setValue(nil, named: key.name)
    }

    /// Every preference, as one JSON object: only those something set, or
    /// with `includingDefaults`, all of them.
    public func allValues(includingDefaults: Bool = true) -> CefJSON {
        withManager { manager in
            let dictionary = manager.pointee.get_all_preferences(manager, includingDefaults ? 1 : 0)
            defer { cefRelease(dictionary) }
            return CefJSON.object(CefJSON.members(of: dictionary))
        } ?? .object([:])
    }

    /// Whether the preference exists.
    public func contains<Value>(_ key: Key<Value>) -> Bool { contains(named: key.name) }

    func contains(named name: String) -> Bool {
        withManager { manager in
            CefStringUtil.withCefString(name) { manager.pointee.has_preference(manager, $0) != 0 }
        } ?? false
    }

    /// Whether the preference can be changed. It cannot when an enterprise
    /// policy manages it or a command-line switch set it; Chromium's API
    /// does not say which. `false` for an unknown preference.
    public func canSet<Value>(_ key: Key<Value>) -> Bool { canSet(named: key.name) }

    /// Whether the preference called `name` can be changed.
    public func canSet(named name: String) -> Bool {
        withManager { manager in
            CefStringUtil.withCefString(name) { cefName in
                manager.pointee.has_preference(manager, cefName) != 0
                    && manager.pointee.can_set_preference(manager, cefName) != 0
            }
        } ?? false
    }

    /// Whether the preference has its default value: nothing set it.
    ///
    /// Chromium's API gives no way to read a default while another value
    /// is set; ``reset(_:)`` restores it.
    public func isDefault<Value>(_ key: Key<Value>) -> Bool { isDefault(named: key.name) }

    /// Whether the preference called `name` has its default value.
    public func isDefault(named name: String) -> Bool {
        guard contains(named: name) else { return false }
        let explicit: CefJSON? = withManager { manager in
            let dictionary = manager.pointee.get_all_preferences(manager, 0)
            defer { cefRelease(dictionary) }
            return CefJSON.object(CefJSON.members(of: dictionary))
        }
        return Self.lookUp(name, in: explicit ?? .null) == nil
    }

    /// The member at a dotted path in a nested object.
    nonisolated static func lookUp(_ name: String, in object: CefJSON) -> CefJSON? {
        var current = object
        for component in name.split(separator: ".") {
            guard let next = current.objectValue?[String(component)] else { return nil }
            current = next
        }
        return current
    }

    // MARK: Observing

    /// The preference's value now and after each change, for as long as the
    /// stream is iterated. `nil` when the value is not of the key's type.
    public func observe<Value>(_ key: Key<Value>) -> AsyncStream<Value?> {
        let decode = key.decode
        let raw = observe(named: key.name)
        let (stream, continuation) = AsyncStream<Value?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task { @MainActor in
            for await value in raw { continuation.yield(value.flatMap(decode)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The raw value of the preference called `name` now and after each
    /// change, for as long as the stream is iterated.
    public func observe(named name: String) -> AsyncStream<CefJSON?> {
        let (stream, continuation) = AsyncStream<CefJSON?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(value(named: name))
        let preferences = self
        // Made only once there is a manager to take it: add consumes the
        // reference, and without Chromium nothing would release it.
        let registration: UnsafeMutablePointer<cef_registration_t>? = withManager { manager in
            guard let add = manager.pointee.add_preference_observer else { return nil }
            let observer = PreferenceObserver { changed in
                continuation.yield(preferences.value(named: changed))
            }.makeObserver()
            return CefStringUtil.withCefString(name) { add(manager, $0, observer) }
        } ?? nil
        guard let token = CefObserverRegistration(adopting: registration) else {
            continuation.finish()
            return stream
        }
        token.end(with: continuation)
        return stream
    }

    // MARK: Manager

    private func withManager<R>(_ body: (UnsafeMutablePointer<cef_preference_manager_t>) -> R) -> R? {
        switch source {
        case .profile(let profile):
            return profile.withPreferences(body)
        case .application:
            guard CefRuntime.shared.isRunning, let manager = cef_preference_manager_get_global() else { return nil }
            defer { cefRelease(manager) }
            return body(manager)
        }
    }
}

extension CefProfile {
    /// The profile's preferences, with typed keys and observation.
    public var preferences: CefPreferences { CefPreferences(source: .profile(self)) }
}

extension CefRuntime {
    /// The preferences Chromium keeps for the whole app rather than per
    /// profile, such as ``CefPreferences/Key/confirmsQuit``.
    public var preferences: CefPreferences { CefPreferences(source: .application) }
}

/// Owner of a `cef_preference_observer_t`. Called on the UI thread.
private final class PreferenceObserver: Sendable {
    let changed: @MainActor @Sendable (String) -> Void

    init(changed: @escaping @MainActor @Sendable (String) -> Void) {
        self.changed = changed
    }

    func makeObserver() -> UnsafeMutablePointer<cef_preference_observer_t> {
        let observer = cefAllocate(cef_preference_observer_t.self, owner: self)
        observer.pointee.on_preference_changed = { s, name in
            guard let owner = cefOwner(PreferenceObserver.self, s) else { return }
            let name = CefStringUtil.string(from: name)
            MainActor.assumeIsolated { owner.changed(name) }
        }
        return observer
    }
}

// MARK: - Value conversions

extension CefPreferences.Key where Value == Bool {
    /// A preference holding a Boolean.
    public init(_ name: String) {
        self.init(name, decode: { $0.boolValue }, encode: { .bool($0) })
    }
}

extension CefPreferences.Key where Value == Int {
    /// A preference holding an integer.
    public init(_ name: String) {
        self.init(name, decode: { $0.intValue }, encode: { .number(Double($0)) })
    }
}

extension CefPreferences.Key where Value == Double {
    /// A preference holding a number.
    public init(_ name: String) {
        self.init(name, decode: { $0.doubleValue }, encode: { .number($0) })
    }
}

extension CefPreferences.Key where Value == String {
    /// A preference holding a string.
    public init(_ name: String) {
        self.init(name, decode: { $0.stringValue }, encode: { .string($0) })
    }
}

extension CefPreferences.Key where Value == [String] {
    /// A preference holding a list of strings.
    public init(_ name: String) {
        self.init(name, decode: { $0.arrayValue?.compactMap(\.stringValue) }, encode: { .array($0.map(CefJSON.string)) })
    }

    /// A preference holding a comma-separated list in one string, as
    /// `intl.accept_languages` does.
    public static func commaSeparated(_ name: String) -> Self {
        Self(name, decode: { json in
            json.stringValue.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }, encode: { .string($0.joined(separator: ",")) })
    }
}

extension CefPreferences.Key where Value == URL {
    /// A preference holding a file path.
    public static func fileURL(_ name: String) -> Self {
        Self(name, decode: { json in
            json.stringValue.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        }, encode: { .string($0.path) })
    }
}

extension CefPreferences.Key where Value == CefJSON {
    /// A preference with its raw JSON value.
    public static func raw(_ name: String) -> Self {
        Self(name, decode: { $0 }, encode: { $0 })
    }
}

// MARK: - Common preferences

extension CefPreferences.Key where Value == Bool {
    /// Offering to save passwords (`credentials_enable_service`). Turning it
    /// off stops saving; saved passwords still fill.
    public static var savesPasswords: Self { Self("credentials_enable_service") }
    /// Filling addresses (`autofill.profile_enabled`).
    public static var fillsAddresses: Self { Self("autofill.profile_enabled") }
    /// Filling payment cards (`autofill.credit_card_enabled`).
    public static var fillsPaymentCards: Self { Self("autofill.credit_card_enabled") }
    /// Checking spelling while typing (`browser.enable_spellchecking`).
    public static var checksSpelling: Self { Self("browser.enable_spellchecking") }
    /// Showing the home button in Chrome's toolbar (`browser.show_home_button`).
    public static var showsHomeButton: Self { Self("browser.show_home_button") }
    /// Offering to translate pages (`translate.enabled`).
    public static var offersTranslation: Self { Self("translate.enabled") }
    /// Safe Browsing protection (`safebrowsing.enabled`).
    public static var usesSafeBrowsing: Self { Self("safebrowsing.enabled") }
    /// Search suggestions in the address bar (`search.suggest_enabled`).
    public static var showsSearchSuggestions: Self { Self("search.suggest_enabled") }
    /// Loading sites over HTTPS only, with a warning before HTTP
    /// (`https_only_mode_enabled`).
    public static var usesHTTPSOnlyMode: Self { Self("https_only_mode_enabled") }
    /// Sending a Do Not Track request (`enable_do_not_track`).
    public static var sendsDoNotTrack: Self { Self("enable_do_not_track") }
    /// Asking before quitting with ⌘Q (`browser.confirm_to_quit`). Application-wide.
    public static var confirmsQuit: Self { Self("browser.confirm_to_quit") }
}

extension CefPreferences.Key where Value == Int {
    /// The default font size, in pixels (`webkit.webprefs.default_font_size`).
    public static var defaultFontSize: Self { Self("webkit.webprefs.default_font_size") }
    /// The default fixed-width font size (`webkit.webprefs.default_fixed_font_size`).
    public static var defaultFixedFontSize: Self { Self("webkit.webprefs.default_fixed_font_size") }
    /// The smallest font size pages may use (`webkit.webprefs.minimum_font_size`).
    public static var minimumFontSize: Self { Self("webkit.webprefs.minimum_font_size") }
}

extension CefPreferences.Key where Value == String {
    /// The home page (`homepage`).
    public static var homePage: Self { Self("homepage") }
}

extension CefPreferences.Key where Value == [String] {
    /// The languages pages are asked for, in order (`intl.accept_languages`).
    public static var acceptLanguages: Self { .commaSeparated("intl.accept_languages") }
    /// The spelling dictionaries in use (`spellcheck.dictionaries`).
    public static var spellingLanguages: Self { Self("spellcheck.dictionaries") }
}

extension CefPreferences {
    /// Which cookies a profile blocks.
    public enum ThirdPartyCookies: Int, Sendable, CaseIterable {
        /// Third-party cookies are allowed.
        case allow = 0
        /// Blocked in incognito profiles only.
        case blockInIncognito = 1
        /// Blocked everywhere.
        case block = 2
    }
}

extension CefPreferences.Key where Value == CefPreferences.ThirdPartyCookies {
    /// Third-party cookie blocking (`profile.cookie_controls_mode`).
    public static var thirdPartyCookies: Self {
        Self("profile.cookie_controls_mode",
             decode: { $0.intValue.flatMap(CefPreferences.ThirdPartyCookies.init(rawValue:)) },
             encode: { .number(Double($0.rawValue)) })
    }
}
