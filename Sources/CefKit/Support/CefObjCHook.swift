import Foundation
import ObjectiveC

/// Overrides Objective-C methods of Chromium's AppKit classes, which the
/// framework does not export but the Objective-C runtime can see.
///
/// Every hook is feature-detected: a class or selector that a CEF update
/// renames or removes leaves the hook uninstalled, and the feature that
/// depends on it falls back to Chromium's own behavior. SelfTest checks
/// ``missingHooks`` so such an update fails CI instead of degrading quietly.
@MainActor
enum CefObjCHook {
    /// Hooks that could not be installed, as `Class -selector` strings.
    private(set) static var missingHooks: [String] = []
    private static var installed: Set<String> = []

    /// Replaces the implementation of the instance method `selector` in the
    /// class named `className` with `block`, and returns the implementation
    /// to call through to. When the class inherits the method, the override
    /// is added to the class alone and the inherited implementation is
    /// returned, so other classes are unaffected.
    ///
    /// Returns `nil`, and records the hook as missing, when the class or the
    /// method does not exist or its type encoding is not `expectedTypes`
    /// (compared without offsets, so `v32@0:8@16q24` matches `v@:@q`).
    static func override(
        _ className: String, _ selector: Selector, expectedTypes: String, with block: Any
    ) -> IMP? {
        let key = "\(className) -\(NSStringFromSelector(selector))"
        guard !installed.contains(key) else { return nil }
        guard let cls = NSClassFromString(className),
              let method = class_getInstanceMethod(cls, selector),
              let encoding = method_getTypeEncoding(method),
              stripOffsets(String(cString: encoding)) == expectedTypes
        else {
            if !missingHooks.contains(key) { missingHooks.append(key) }
            CefLog.error("CefSwift: \(key) is unavailable in this CEF build; the feature that uses it is disabled")
            return nil
        }
        installed.insert(key)
        let replacement = imp_implementationWithBlock(block)
        let original = method_getImplementation(method)
        if class_addMethod(cls, selector, replacement, encoding) {
            // The class inherited the method: the override is its own now,
            // and `original` is the superclass's implementation.
            return original
        }
        return method_setImplementation(method, replacement)
    }

    /// Records whether a class and selector exist, for features that call
    /// a method rather than override it.
    @discardableResult
    static func require(_ className: String, _ selector: Selector) -> Bool {
        let key = "\(className) -\(NSStringFromSelector(selector))"
        guard let cls = NSClassFromString(className), class_getInstanceMethod(cls, selector) != nil else {
            if !missingHooks.contains(key) { missingHooks.append(key) }
            return false
        }
        return true
    }

    /// `v32@0:8@16q24` → `v@:@q`.
    private static func stripOffsets(_ encoding: String) -> String {
        String(encoding.filter { !$0.isNumber })
    }
}
