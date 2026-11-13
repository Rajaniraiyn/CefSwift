import AppKit
import CefKit

/// `Gallery -smoke` (or `GALLERY_SMOKE=1`): opens every demo in turn, waits
/// for it to report ready, prints `PASS <demo>` or `FAIL <demo> — <reason>`,
/// then a `SUMMARY` line, and quits with the number of failures as its exit
/// status.
///
/// A demo also fails when its browsers and windows are still open after
/// it is closed. `GALLERY_SMOKE_ONLY=BridgeDemo,RequestsDemo` runs only
/// those. Chromium's data goes in a temporary directory, removed at exit,
/// and keychain access is mocked (see `GalleryApp`), so a run needs nobody
/// at the screen.
@MainActor
enum Smoke {
    static let isEnabled = CommandLine.arguments.contains("-smoke")
        || ProcessInfo.processInfo.environment["GALLERY_SMOKE"] == "1"

    /// A fresh data directory for each smoke run.
    static let cacheDirectory: URL? = isEnabled
        ? FileManager.default.temporaryDirectory.appending(path: "cefswift-gallery-smoke-\(getpid())")
        : nil

    static let timeout = Duration.seconds(45)
    private static var failures = 0

    static func prepare() {
        guard isEnabled else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        // Open the window whatever window state an earlier run left behind.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        // Exit with the failure count once Chromium has shut down.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
                exit(Int32(min(failures, 125)))
            }
        }
        // A last resort, should quitting itself hang.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 15 * 60)
            print("FAIL smoke — watchdog: still running after 15 minutes")
            exit(124)
        }
    }

    static func run(_ model: GalleryModel) async {
        let only = ProcessInfo.processInfo.environment["GALLERY_SMOKE_ONLY"]?
            .split(separator: ",").map(String.init)
        let demos = Demos.all.filter { only?.contains($0.id) ?? true }
        let clock = ContinuousClock()
        // Start from no demo, so that each one opens afresh.
        model.selection = nil
        _ = await waitUntil { CefRuntime.shared.browsers.isEmpty }
        for demo in demos {
            let start = clock.now
            model.selection = demo.id
            let result = await model.readiness.wait(timeout: timeout)
            // Close the demo, and check it leaves nothing open behind it.
            model.selection = nil
            let closed = await waitUntil { CefRuntime.shared.browsers.isEmpty && CefWindow.all.isEmpty }
            let seconds = (clock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
            switch result {
            case .failure(let failure):
                report(false, demo, failure.reason)
            case .success where !closed:
                report(false, demo, "left \(CefRuntime.shared.browsers.count) browsers and \(CefWindow.all.count) windows open")
            case .success:
                report(true, demo, seconds)
            }
        }
        print("SUMMARY \(demos.count - failures) passed, \(failures) failed")
        NSApp.terminate(nil)
    }

    private static func report(_ passed: Bool, _ demo: any Demo, _ detail: String) {
        if passed {
            print("PASS \(demo.id) (\(detail))")
        } else {
            failures += 1
            print("FAIL \(demo.id) — \(detail)")
        }
    }

    private static func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
