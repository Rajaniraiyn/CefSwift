import CCef
import CefBase

extension CefRuntime {
    /// Reads an application-wide Chromium preference — one Chromium keeps
    /// for the whole app rather than per profile, such as
    /// `"browser.confirm_to_quit"`. `nil` when no such preference exists.
    public func preference(_ name: String) -> CefJSON? {
        withGlobalPreferences { manager in
            CefStringUtil.withCefString(name) { cefName -> CefJSON? in
                guard manager.pointee.has_preference(manager, cefName) != 0 else { return nil }
                let value = manager.pointee.get_preference(manager, cefName)
                defer { cefRelease(value) }
                return CefJSON(cefValue: value)
            }
        } ?? nil
    }

    /// Changes an application-wide Chromium preference. Pass `nil` to restore
    /// its default. Throws if the preference is unknown or `value` has the
    /// wrong type. Per-profile settings are changed with
    /// ``CefProfile/setPreference(_:to:)``.
    public func setPreference(_ name: String, to value: CefJSON?) throws(CefError) {
        let failure: String? = withGlobalPreferences { manager in
            CefStringUtil.withCefString(name) { cefName -> String? in
                guard manager.pointee.has_preference(manager, cefName) != 0 else { return "no such preference" }
                var error = cef_string_t()
                defer { cef_string_utf16_clear(&error) }
                guard manager.pointee.set_preference(manager, cefName, value?.makeCefValue(), &error) == 0 else { return nil }
                return CefStringUtil.string(from: error)
            }
        } ?? "Chromium is not running"
        if let failure {
            throw CefError.operationFailed("Cannot set preference '\(name)': \(failure)")
        }
    }

    /// Applies the configured preferences Chromium keeps application-wide;
    /// profiles apply the rest as each is first used.
    func applyApplicationWidePreferences(_ preferences: [String: CefJSON]) {
        for (name, value) in preferences where preference(name) != nil {
            do {
                try setPreference(name, to: value)
            } catch {
                CefLog.error("\(error)")
            }
        }
    }

    private func withGlobalPreferences<R>(_ body: (UnsafeMutablePointer<cef_preference_manager_t>) -> R) -> R? {
        guard isInitialized, let manager = cef_preference_manager_get_global() else { return nil }
        defer { cefRelease(manager) }
        return body(manager)
    }
}
