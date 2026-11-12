import CCef
import Foundation
import CefBase

extension CefBrowserClient {
    /// Builds the `cef_accessibility_handler_t` that the render handler
    /// returns for offscreen browsers. Chromium calls it on the UI thread
    /// once the browser's accessibility state is enabled.
    ///
    /// A large page's first update holds tens of thousands of values. Each
    /// update is written as JSON by Chromium in one call, then parsed on a
    /// serial background queue and applied back on the main thread, in the
    /// order Chromium sent them, so the main thread stays responsive.
    func makeAccessibilityHandler() -> UnsafeMutablePointer<cef_accessibility_handler_t> {
        let handler = cefAllocate(cef_accessibility_handler_t.self, owner: self)

        handler.pointee.on_accessibility_tree_change = { s, value in
            // The value arrives with a reference for the receiver.
            defer { cefRelease(value) }
            CefBrowserClient.deliverAccessibility(s, value) { browser, json in browser.accessibilityTreeDidChange(json) }
        }

        handler.pointee.on_accessibility_location_change = { s, value in
            defer { cefRelease(value) }
            CefBrowserClient.deliverAccessibility(s, value) { browser, json in browser.accessibilityLocationsDidChange(json) }
        }

        return handler
    }

    /// Parses accessibility updates off the main thread, one at a time.
    private nonisolated static let accessibilityQueue = DispatchQueue(label: "CefSwift.accessibility", qos: .userInitiated)

    private nonisolated static func deliverAccessibility(
        _ handler: UnsafeMutablePointer<cef_accessibility_handler_t>?,
        _ value: UnsafeMutablePointer<cef_value_t>?,
        _ apply: @escaping @MainActor @Sendable (CefBrowser, CefJSON) -> Void
    ) {
        guard let client = cefOwner(CefBrowserClient.self, handler), let value else { return }
        // cef_write_json takes over a reference; the callback keeps its own.
        cefAddRef(value)
        guard let text = CefStringUtil.takingUserFree(cef_write_json(value, JSON_WRITER_DEFAULT)) else { return }
        accessibilityQueue.async {
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            let json = object.map(CefJSON.init(foundationObject:)) ?? .null
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let browser = client.primary else { return }
                    apply(browser, json)
                }
            }
        }
    }
}

extension CefJSON {
    /// Converts the output of `JSONSerialization`.
    init(foundationObject object: Any) {
        switch object {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]:
            self = .array(array.map(CefJSON.init(foundationObject:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(CefJSON.init(foundationObject:)))
        default:
            self = .null
        }
    }
}
