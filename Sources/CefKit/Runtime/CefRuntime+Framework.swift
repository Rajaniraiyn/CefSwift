import AppKit
import CCef
import Foundation
import Observation
import CefBase

extension CefRuntime {
    // MARK: Framework resolution

    nonisolated static let frameworkBinaryName = "Chromium Embedded Framework"
    nonisolated static let frameworkBundleName = "Chromium Embedded Framework.framework"

    /// Resolves the framework binary for the browser process:
    /// explicit override → app bundle Frameworks dir → CEF_FRAMEWORK_PATH.
    nonisolated static func resolveFrameworkBinary(override: URL?) throws(CefError) -> URL {
        var searched: [String] = []

        if let override {
            let candidate = binaryURL(for: override)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("frameworkDirectory override: \(candidate.path)")
        }

        if let frameworks = Bundle.main.privateFrameworksURL {
            let candidate = frameworks
                .appendingPathComponent(frameworkBundleName)
                .appendingPathComponent(frameworkBinaryName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("app bundle: \(candidate.path)")
        }

        if let env = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"], !env.isEmpty {
            let candidate = binaryURL(for: URL(fileURLWithPath: env))
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("CEF_FRAMEWORK_PATH: \(candidate.path)")
        } else {
            searched.append("CEF_FRAMEWORK_PATH: (not set)")
        }

        throw CefError.frameworkNotFound("Searched: \(searched.joined(separator: "; ")).")
    }

    /// Accepts either a `.framework` directory or a direct binary path.
    nonisolated private static func binaryURL(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return url.appendingPathComponent(frameworkBinaryName)
        }
        return url
    }

    /// Configures the API version (first CEF call in every process) and
    /// verifies the platform API hash against the vendored headers.
    nonisolated static func verifyAPIHash() throws(CefError) {
        let version = ccef_pinned_api_version()
        guard let hash = cef_api_hash(version, 0) else {
            throw CefError.loadFailed("cef_api_hash returned NULL for API version \(version).")
        }
        let actual = String(cString: hash)
        let expected = String(cString: ccef_pinned_api_hash())
        guard actual == expected else {
            throw CefError.apiHashMismatch(expected: expected, actual: actual)
        }
    }
}
