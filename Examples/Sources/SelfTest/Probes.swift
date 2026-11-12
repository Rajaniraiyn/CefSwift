import AppKit
import CefKit

/// Checks that need Chromium started with another configuration run in a
/// second instance of this app, a probe: `CEFSWIFT_SELFTEST_PROBE=<name>`
/// selects the probe, which changes the configuration
/// (``configure(_:forProbe:)``), runs its checks and quits. The instance
/// that started it prints the probe's result lines and counts its failures.
extension SelfTest {
    static let probeEnvironmentKey = "CEFSWIFT_SELFTEST_PROBE"
    static let probeRootEnvironmentKey = "CEFSWIFT_SELFTEST_PROBE_ROOT"

    /// The probe this instance runs, if it is one.
    static var probe: String? { ProcessInfo.processInfo.environment[probeEnvironmentKey] }

    /// The checks of each probe.
    static let probes: [String: @MainActor () async -> Void] = [
        "chromiumSignIn": chromiumSignInProbeChecks,
        "localization": localizationProbeChecks,
        "policies": policiesProbeChecks,
    ]

    /// Changes the configuration for the probe `name`.
    static func configure(_ configuration: inout CefConfiguration, forProbe name: String) {
        switch name {
        case "chromiumSignIn":
            configuration.authenticationPrompt = .chromium
        case "localization":
            configureLocalizationProbe(&configuration)
        case "policies":
            configurePoliciesProbe(&configuration)
        default:
            break
        }
    }

    /// Starts this app as the probe `name`, with extra `arguments` and
    /// `environment`, and reports its result lines with `label` in front.
    /// Returns the probe's output lines.
    @discardableResult
    static func runProbe(
        _ name: String, label: String, arguments: [String] = [], environment extra: [String: String] = [:],
        timeout: Duration = .seconds(45)
    ) async -> [String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-selftest-probe-\(name)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[probeEnvironmentKey] = name
        environment[probeRootEnvironmentKey] = root.path
        environment["SELFTEST_ONLY"] = nil
        environment["SELFTEST_ISOLATED"] = nil
        environment.merge(extra) { $1 }
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        do {
            try child.run()
        } catch {
            check("\(label): probe starts", false, detail: "\(error)")
            return []
        }
        // Read while it runs, so a full pipe does not stall it.
        let reader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let finished = await waitUntil(timeout: timeout) { !child.isRunning }
        if !finished { child.terminate() }
        let lines = String(decoding: await reader.value, as: UTF8.self).split(separator: "\n").map(String.init)
        for line in lines where ["NOTE ", "PASS ", "FAIL ", "SKIP "].contains(where: line.hasPrefix) {
            if line.hasPrefix("FAIL ") { failures += 1 }
            print(labelled(line, label))
        }
        check("\(label): probe finishes", finished && child.terminationStatus == 0,
              detail: finished ? "status \(child.terminationStatus)" : "still running")
        return lines
    }

    /// `PASS name` as `PASS label: name`; `SKIP [category] name` as
    /// `SKIP [category] label: name`.
    private static func labelled(_ line: String, _ label: String) -> String {
        var head = String(line.prefix(5))
        var rest = line.dropFirst(5)
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            head += rest[...close] + " "
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        return head + label + ": " + rest
    }
}
