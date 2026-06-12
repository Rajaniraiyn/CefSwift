import AppKit
import CefKit
import CefSwiftUI
import Observation

/// CI smoke test (see .github/workflows/ci.yml).
///
/// When launched as `Browser --cef-smoke-test`, opens the chrome window on a
/// tiny `data:` page and exits as soon as the page renders:
///   exit 0 — first load completed (the page's <title> arrived)
///   exit 1 — load finished but the expected title never showed up
///   exit 2 — 45 s watchdog (CEF never initialized / never painted)
@MainActor
enum SmokeTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--cef-smoke-test")
    }

    private static let smokeURL = URL(string: "data:text/html,<title>cefswift-smoke-ok</title><h1>ok</h1>")!
    private static let expectedTitle = "cefswift-smoke-ok"
    private static var shell: BrowserShell?

    static func run(shell: BrowserShell) {
        self.shell = shell
        shell.openWindow(initialURL: smokeURL)

        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("[smoke] watchdog fired after 45s\n".utf8))
            exit(2)
        }
        observe(shell)
    }

    /// Re-arming observation of the shell's mirrored title/loading state.
    private static func observe(_ shell: BrowserShell) {
        withObservationTracking {
            _ = shell.selectedTab?.title
            _ = shell.isLoading
        } onChange: {
            Task { @MainActor in
                check(shell)
                observe(shell)
            }
        }
        check(shell)
    }

    private static var sawLoadStart = false

    private static func check(_ shell: BrowserShell) {
        if shell.selectedTab?.title == expectedTitle {
            print("[smoke] load completed, title matched — OK")
            exit(0)
        }
        if shell.isLoading {
            sawLoadStart = true
        } else if sawLoadStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if shell.selectedTab?.title == expectedTitle { exit(0) }
                FileHandle.standardError.write(
                    Data("[smoke] load finished but title was '\(shell.selectedTab?.title ?? "")'\n".utf8))
                exit(1)
            }
        }
    }
}
