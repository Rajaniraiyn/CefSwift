@_spi(Testing) import CefKit
import Foundation

/// The live-object census (`CefDiagnostics.census()`) after each group:
/// what CefKit still holds once the group's browsers have closed.
extension SelfTest {
    /// Prints what stayed after `group` compared with `baseline`.
    ///
    /// Leftovers of the kinds that are expected to stay a while (the
    /// process-lifetime objects, and the objects of service hosts while one
    /// is open) are reported at once. Anything else may still be on its way
    /// out (a browser finishing its close), so it waits up to five seconds
    /// for that first.
    static func reportCensus(after group: String, baseline: [String: Int]) async {
        _ = await waitUntil(timeout: .seconds(10)) { CefRuntime.shared.browsers.isEmpty }
        var extra: [String: Int] = [:]
        _ = await waitUntil(timeout: .seconds(5)) {
            extra = censusDifference(from: baseline)
            return extra.keys.allSatisfy(isExpectedBetweenGroups)
        }
        let line = extra.isEmpty ? "baseline" : extra.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value > 0 ? "+" : "")\($0.value)" }.joined(separator: ", ")
        let hosts = CefProfile.default.runningServiceHosts
        print("CENSUS after \(group): \(line)" + (hosts.isEmpty ? "" : " (service hosts open: \(hosts.joined(separator: ", ")))"))
    }

    /// What may stay until shutdown: the request contexts of the global
    /// profile and of named profiles, which `CefProfile` keeps for the
    /// process (with their `CefProfileContextHandler`s), the scheme handler
    /// factories registered with CEF, which it keeps until `cef_shutdown()`,
    /// and the one resource request handler navigations share.
    static let processLifetimeCensus: Set<String> = [
        "CefRef<_cef_request_context_t>", "implemented CefProfileContextHandler", "implemented SchemeHandlerFactory",
        "implemented NavigationHandlerOwner",
    ]

    /// What an open service host holds: a hidden Chrome-style browser in a
    /// CEF window. Hosts close 30 s after their last call, so they outlive
    /// the group that called them.
    static let serviceHostCensus: Set<String> = [
        "CefRef<_cef_browser_t>", "CefRef<_cef_browser_view_t>", "CefRef<_cef_window_t>",
        "implemented BrowserViewDelegate", "implemented WindowDelegate", "implemented CefBrowserClient",
    ]

    /// Whether a leftover of `kind` between groups needs no waiting for.
    static func isExpectedBetweenGroups(_ kind: String) -> Bool {
        processLifetimeCensus.contains(kind)
            || (serviceHostCensus.contains(kind) && !CefProfile.default.runningServiceHosts.isEmpty)
    }

    /// Before quitting: everything else CefKit held is gone, once the
    /// internal-page service hosts have closed.
    ///
    /// A group in a process of its own (`SELFTEST_ISOLATED`) has no time
    /// to wait within its deadline, so it only reports.
    static func censusChecks(baseline: [String: Int]) async {
        let isolatedChild = ProcessInfo.processInfo.environment["SELFTEST_ISOLATED_CHILD"] == "1"
        // Closed as idling closes them, without waiting the 30 s. Hosts of
        // named profiles closed with the profile's last browser.
        CefProfile.default.stopServiceHosts()
        var extra: [String: Int] = [:]
        _ = await waitUntil(timeout: .seconds(isolatedChild ? 3 : 15)) {
            extra = censusDifference(from: baseline).filter { !processLifetimeCensus.contains($0.key) }
            return extra.isEmpty
        }
        if isolatedChild {
            if !extra.isEmpty {
                print("NOTE census before quitting: " + extra.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
            return
        }
        check("census: nothing but process-lifetime objects is alive before quitting", extra.isEmpty,
              detail: extra.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    }

    static func censusDifference(from baseline: [String: Int]) -> [String: Int] {
        var difference: [String: Int] = [:]
        let now = CefDiagnostics.census()
        for key in Set(now.keys).union(baseline.keys) {
            let delta = (now[key] ?? 0) - (baseline[key] ?? 0)
            if delta != 0 { difference[key] = delta }
        }
        return difference
    }
}
