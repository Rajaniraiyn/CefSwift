import AppKit
import CefKit
import CefSwiftUI
import Observation

/// CI smoke test (see .github/workflows/ci.yml).
///
/// When launched as `Browser --cef-smoke-test`, the app loads a tiny `data:` page and
/// exits as soon as the page actually renders:
///   exit 0 — first load completed (the page's <title> arrived)
///   exit 1 — load finished but the expected title never showed up
///   exit 2 — 45 s watchdog (CEF never initialized / never painted)
@MainActor
enum SmokeTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--cef-smoke-test")
    }

    /// data: URLs avoid network flake; chrome runtime style accepts top-level data: loads
    /// initiated by the embedder. The title is the success signal.
    private static let smokeURL = URL(string: "data:text/html,<title>cefswift-smoke-ok</title><h1>ok</h1>")!
    private static let expectedTitle = "cefswift-smoke-ok"

    static func runIfRequested(store: TabStore) {
        guard isRequested else { return }

        let model = store.newTab(url: smokeURL).model

        // Watchdog: something hung (framework load, helper spawn, first paint…).
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("[smoke] watchdog fired after 45s\n".utf8))
            exit(2)
        }

        observe(model)
    }

    /// Re-arming observation of the model's `title` / `isLoading` (@Observable).
    private static func observe(_ model: CefWebViewModel) {
        withObservationTracking {
            _ = model.title
            _ = model.isLoading
        } onChange: {
            Task { @MainActor in
                check(model)
                observe(model) // withObservationTracking fires once; re-arm.
            }
        }
        check(model)
    }

    private static var sawLoadStart = false

    private static func check(_ model: CefWebViewModel) {
        if model.title == expectedTitle {
            print("[smoke] load completed, title matched — OK")
            exit(0)
        }
        if model.isLoading {
            sawLoadStart = true
        } else if sawLoadStart {
            // Load finished without our title: give late title updates a moment, then fail.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if model.title == expectedTitle { exit(0) }
                FileHandle.standardError.write(
                    Data("[smoke] load finished but title was '\(model.title)'\n".utf8))
                exit(1)
            }
        }
    }
}
