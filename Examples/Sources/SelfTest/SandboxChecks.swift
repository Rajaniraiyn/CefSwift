import AppKit
import CefKit
import CefSwiftUI
import Darwin

/// `sandbox_check(pid, NULL, 0)`: 1 when the process runs in a sandbox.
@_silgen_name("sandbox_check")
private func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

/// Chromium's sandbox (`CefRuntime.Configuration.isSandboxEnabled`): whether the
/// helper processes run sealed. `SELFTEST_SANDBOX=1` or `0` runs SelfTest
/// with it on or off; otherwise the configuration's default applies.
extension SelfTest {
    static var sandboxOverride: Bool? {
        switch ProcessInfo.processInfo.environment["SELFTEST_SANDBOX"] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    static func sandboxChecks() async {
        let expected = CefRuntime.shared.configuration?.isSandboxEnabled == true
        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html")!)
        let view = hostWindowed(browser)
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await loaded(browser, title: "tab") else {
            check("sandbox: page loads", false, detail: browser.title)
            return
        }
        // The Alerts helper posts system notifications for Chromium and, as
        // in Chrome, is never sandboxed; it runs once anything has used
        // notifications.
        let helpers = childProcesses().filter { !$0.name.hasSuffix("(Alerts)") }
        let unexpected = helpers.filter { (sandbox_check($0.pid, nil, 0) == 1) != expected }
        check("sandbox: every helper process runs \(expected ? "sandboxed" : "unsandboxed")",
              !helpers.isEmpty && unexpected.isEmpty,
              detail: "\(helpers.count) helpers; " + unexpected.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))
        check("sandbox: the app process itself is not sandboxed", sandbox_check(getpid(), nil, 0) != 1)
    }

    /// The app's helper processes, by name.
    static func childProcesses() -> [(pid: pid_t, name: String)] {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }.map { pid in
            var name = [UInt8](repeating: 0, count: 256)
            let length = proc_name(pid, &name, UInt32(name.count))
            return (pid, String(decoding: name.prefix(Int(max(length, 0))), as: UTF8.self))
        }.filter { $0.name.contains("Helper") }
    }
}
