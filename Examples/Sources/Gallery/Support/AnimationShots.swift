import AppKit
import CefKit

/// `Gallery -animationShots <directory>`: opens the Animation demo, plays
/// each of its scenes forward and back, and saves pictures of the window
/// while it does (at rest, during each spring and a second after it), a
/// sheet of them per scene, and the windowed page's layers at rest; then
/// quits. Pictures come from ``WindowCapture``, which needs no permission.
///
/// Like `-smoke`, it keeps Chromium's data in a temporary directory, so it
/// runs beside a Gallery already open.
@MainActor
enum AnimationShots {
    static let directory: URL? = UserDefaults.standard.string(forKey: "animationShots")
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    static var isEnabled: Bool { directory != nil }

    static let cacheDirectory: URL? = isEnabled
        ? FileManager.default.temporaryDirectory.appending(path: "cefswift-gallery-shots-\(getpid())")
        : nil

    static func prepare() {
        guard let directory else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if let cacheDirectory { try? FileManager.default.removeItem(at: cacheDirectory) }
                exit(0)
            }
        }
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 10 * 60)
            print("animationShots: watchdog, still running after 10 minutes")
            exit(124)
        }
    }

    /// One scene's pictures, gathered into a sheet when it ends.
    @MainActor final class Strip {
        let name: String
        private(set) var shots: [(String, CGImage)] = []
        private let window: NSWindow

        init(name: String, window: NSWindow) {
            self.name = name
            self.window = window
        }

        func shoot(_ label: String) {
            guard let directory, let image = WindowCapture.image(of: window) else {
                print("animationShots: no picture of the window for \(name) \(label)")
                return
            }
            shots.append((label, image))
            WindowCapture.writePNG(image, to: directory.appending(path: "\(name)-\(String(format: "%02d", shots.count))-\(label).png"))
        }

        func note(_ label: String, _ text: String) {
            guard let directory else { return }
            try? text.write(to: directory.appending(path: "\(name)-\(label).txt"), atomically: true, encoding: .utf8)
        }

        func save(_ data: Data, as label: String) {
            guard let directory else { return }
            try? data.write(to: directory.appending(path: "\(name)-\(label).png"))
        }

        func finish(columns: Int = 5) {
            guard let directory, let sheet = WindowCapture.sheet(shots, columns: columns, width: 472) else { return }
            WindowCapture.writePNG(sheet, to: directory.appending(path: "sheet-\(name).png"))
        }
    }
}
