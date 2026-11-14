import os

/// CefSwift's own diagnostics, in the unified log under the `CefSwift`
/// subsystem (Chromium's log is configured by `CefRuntime.Configuration.logFile`).
package enum CefLog {
    private static let logger = Logger(subsystem: "CefSwift", category: "runtime")

    package static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    package static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    package static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
