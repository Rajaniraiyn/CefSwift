import os

/// CefSwift's own diagnostics, in the unified log under the `CefSwift`
/// subsystem (Chromium's log is configured by `CefConfiguration.logFile`).
enum CefLog {
    private static let logger = Logger(subsystem: "CefSwift", category: "runtime")

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
