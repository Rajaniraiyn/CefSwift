import Foundation

extension Bundle {
    /// CefKit's resources: the strings of its built-in sheets.
    static let cefKit = Bundle.cefSwiftResources("CefSwift_CefKit", module: .module)

    /// The resource bundle SwiftPM builds for a CefSwift target, called
    /// `name`.
    ///
    /// In an app it is in `Contents/Resources`, where `cef bundle` and
    /// Xcode put it, or in the resources of the framework that links the
    /// target. The `Bundle.module` of SwiftPM's native build system (Swift
    /// 6.1's default) looks in the app's root directory instead, where code
    /// signing allows no files, so CefSwift looks itself and uses `module`,
    /// SwiftPM's, only outside an app: in `swift test` and `swift run`,
    /// which find it in the build directory. An app that lacks the bundle
    /// shows the English keys, from `Bundle.main`, rather than stopping in
    /// SwiftPM's `fatalError`.
    package static func cefSwiftResources(_ name: String, module: @autoclosure () -> Bundle) -> Bundle {
        let candidates = [Bundle.main.resourceURL, Bundle(for: CefResourceBundleToken.self).resourceURL, Bundle.main.bundleURL]
        for directory in candidates {
            if let bundle = directory.flatMap({ Bundle(url: $0.appendingPathComponent(name + ".bundle")) }) {
                return bundle
            }
        }
        return Bundle.main.bundleURL.pathExtension == "app" ? .main : module()
    }
}

extension CefRuntime {
    /// CefKit's resource bundle, for tests.
    @_spi(Testing) public nonisolated static var resourceBundle: Bundle { .cefKit }
}

/// Finds the binary CefKit is linked into, for ``Bundle/cefSwiftResources(_:module:)``.
private final class CefResourceBundleToken {}
