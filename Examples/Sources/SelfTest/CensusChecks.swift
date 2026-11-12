@_spi(Testing) import CefKit
import Foundation

/// The live-object census (`CefDiagnostics.census()`) after each group:
/// what CefKit still holds once the group's browsers have closed.
extension SelfTest {
    /// Waits up to five seconds for the census to come back to `baseline`
    /// once the group's browsers are gone, then prints what stayed.
    static func reportCensus(after group: String, baseline: [String: Int]) async {
        _ = await waitUntil(timeout: .seconds(10)) { CefRuntime.shared.browsers.isEmpty }
        var extra: [String: Int] = [:]
        _ = await waitUntil(timeout: .seconds(5)) {
            extra = censusDifference(from: baseline)
            return extra.isEmpty
        }
        let line = extra.isEmpty ? "baseline" : extra.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value > 0 ? "+" : "")\($0.value)" }.joined(separator: ", ")
        print("CENSUS after \(group): \(line)")
    }

    /// What may stay until shutdown: the global request context, which
    /// `CefRuntime` holds for the process, and the scheme handler factories
    /// registered with CEF, which it keeps until `cef_shutdown()`.
    static let processLifetimeCensus = ["CefRef<_cef_request_context_t>", "implemented SchemeHandlerFactory"]

    /// Before quitting: everything else CefKit held is gone.
    static func censusChecks(baseline: [String: Int]) async {
        var extra: [String: Int] = [:]
        _ = await waitUntil(timeout: .seconds(10)) {
            extra = censusDifference(from: baseline).filter { !processLifetimeCensus.contains($0.key) }
            return extra.isEmpty
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
