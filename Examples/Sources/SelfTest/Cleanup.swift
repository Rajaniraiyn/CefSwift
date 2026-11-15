import Darwin
import Foundation

/// Removes the cache, profile and scratch directories SelfTest makes in
/// `$TMPDIR`. Each is named after the process that made it
/// (`cefswift-selftest-<pid>`, `cefswift-selftest-downloads-<pid>`, …).
///
/// - At exit, a run removes its own. Every normal exit comes after
///   `cef_shutdown()` returned (SelfTest quits through `terminate:`), so
///   nothing writes there any more.
/// - An isolated run's parent removes each child's once the child exited,
///   so a killed or crashed group leaves nothing behind.
/// - At start, a run removes those of processes that no longer exist,
///   left by runs that were killed before they could.
enum SelfTestCleanup {
    private static let prefixes = ["cefswift-selftest-", "cefswift-bench-", "cefswift-threads-"]

    static func install() {
        removeLeftovers()
        atexit {
            SelfTestCleanup.remove(ownedBy: getpid())
        }
    }

    /// The process a scratch entry belongs to: the number at the end of its
    /// name, before any extension.
    static func owner(of name: String) -> pid_t? {
        guard prefixes.contains(where: name.hasPrefix) else { return nil }
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        guard let digits = stem.split(separator: "-").last, let pid = pid_t(digits) else { return nil }
        return pid
    }

    /// Removes the entries of process `pid`.
    static func remove(ownedBy pid: pid_t) {
        let directory = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where owner(of: name) == pid {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Removes the entries of processes that have exited.
    static func removeLeftovers() {
        let directory = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard let pid = owner(of: name), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
