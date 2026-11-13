import Foundation
import ObjectiveC

/// Overrides Objective-C methods of Chromium's AppKit classes, which the
/// framework does not export but the Objective-C runtime can see.
///
/// Hooks are installed a feature at a time, all or nothing: every class,
/// selector and type encoding a feature needs is probed first, and the
/// feature's overrides go in only when all of them are present. A CEF
/// update that renames or removes one leaves the whole feature uninstalled,
/// so it falls back to Chromium's own behavior instead of running half
/// hooked. SelfTest checks ``features`` so such an update fails CI instead
/// of degrading quietly.
@MainActor
enum CefObjCHook {
    /// A method a feature calls or overrides: the instance method
    /// `selector` of the class named `className`, whose type encoding,
    /// compared without offsets (`v32@0:8@16q24` matches `v@:@q`), is
    /// `types`.
    struct Method {
        let className: String
        let selector: Selector
        let types: String

        init(_ className: String, _ selector: Selector, types: String) {
            self.className = className
            self.selector = selector
            self.types = types
        }

        var key: String { "\(className) -\(NSStringFromSelector(selector))" }
    }

    /// One override: the method, the block that replaces it, and where to
    /// hand the implementation it calls through to.
    struct Override {
        let method: Method
        let block: Any
        let original: (IMP) -> Void
    }

    /// Each feature's name and the methods it lacks; an empty list means
    /// the feature is installed.
    private(set) static var features: [(name: String, missing: [String])] = []

    /// Whether the feature called `name` was installed.
    static func isInstalled(_ name: String) -> Bool {
        features.first { $0.name == name }?.missing.isEmpty ?? false
    }

    /// Installs the feature called `name` once: `overrides` go in only when
    /// they and every method in `requires` exist with the expected types.
    /// Returns whether the feature is installed.
    @discardableResult
    static func installFeature(_ name: String, requires: [Method] = [], overrides: [Override]) -> Bool {
        if let installed = features.first(where: { $0.name == name }) { return installed.missing.isEmpty }
        let missing = (requires + overrides.map(\.method)).filter { resolve($0) == nil }.map(\.key)
        features.append((name, missing))
        guard missing.isEmpty else {
            CefLog.error("CefSwift: \(missing.joined(separator: ", ")) unavailable in this CEF build; \(name) is disabled")
            return false
        }
        for override in overrides {
            guard let (cls, method) = resolve(override.method) else { continue }
            let replacement = imp_implementationWithBlock(override.block)
            let original = method_getImplementation(method)
            if class_addMethod(cls, override.method.selector, replacement, method_getTypeEncoding(method)) {
                // The class inherited the method: the override is its own
                // now, and `original` is the superclass's implementation, so
                // other classes are unaffected.
                override.original(original)
            } else {
                override.original(method_setImplementation(method, replacement))
            }
        }
        return true
    }

    /// The class and method for `method`, when both exist and the method's
    /// type encoding matches.
    private static func resolve(_ method: Method) -> (AnyClass, ObjectiveC.Method)? {
        guard let cls = NSClassFromString(method.className),
              let found = class_getInstanceMethod(cls, method.selector),
              let encoding = method_getTypeEncoding(found),
              stripOffsets(String(cString: encoding)) == method.types
        else { return nil }
        return (cls, found)
    }

    /// `v32@0:8@16q24` → `v@:@q`.
    static func stripOffsets(_ encoding: String) -> String {
        String(encoding.filter { !$0.isNumber })
    }
}
