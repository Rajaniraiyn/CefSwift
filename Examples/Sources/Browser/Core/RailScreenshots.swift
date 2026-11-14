import AppKit
import CefChromium
import CefSwiftUI

/// `-railScreenshots <directory>`: puts a window's tabs through a few
/// states and saves a PNG of the browser's own views in each — the tab
/// rail and the toolbar over Chrome's — then quits.
///
/// Each picture is the app's views drawn into a bitmap
/// (`cacheDisplay(in:to:)`), from inside the process: no screen recording
/// is involved, so no permission is asked for. Chromium's page is not in
/// them.
@MainActor
enum RailScreenshots {
    static func capture(_ window: CefChromeWindow, controller: BrowserController, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func page(_ title: String) -> URL {
            URL(string: "data:text/html,<title>\(title.replacingOccurrences(of: " ", with: "%20"))</title><h1>\(title.replacingOccurrences(of: " ", with: "%20"))</h1>")!
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(900)) }
        func shoot(_ name: String) async {
            await settle()
            guard let cover = window.topBar?.superview else { return }
            cover.layoutSubtreeIfNeeded()
            let bounds = cover.bounds
            let height = controller.tabsAtTheSide ? bounds.height : window.topBarHeight
            let rect = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, max(height, 1)))
            guard let bitmap = cover.bitmapImageRepForCachingDisplay(in: rect) else { return }
            cover.cacheDisplay(in: rect, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            print("cefswift-rail-screenshot \(name)")
        }

        window.window?.setContentSize(NSSize(width: 1180, height: 720))
        for title in ["Swift.org", "Apple Developer", "The Swift Programming Language", "WWDC Videos", "Human Interface Guidelines"] {
            _ = await controller.openTabNow(url: page(title), inBackground: true)
        }
        await shoot("1-several-tabs")

        let tabs = window.tabs
        if tabs.count >= 6 {
            try? await window.strip.pin([tabs[0], tabs[1]])
            await shoot("2-pinned")
            let reading = try? await window.strip.group([tabs[2], tabs[3]])
            try? await reading?.setTitle("Reading")
            try? await reading?.setColor(.blue)
            let videos = try? await window.strip.group([tabs[4], tabs[5]])
            try? await videos?.setTitle("Videos")
            try? await videos?.setColor(.orange)
            try? await videos?.setCollapsed(true)
            try? await window.tabs.last?.select()
            await shoot("3-groups-one-collapsed")
        }

        for index in 1...16 {
            _ = await controller.openTabNow(url: page("Article \(index)"), inBackground: true)
        }
        await shoot("4-overflow")

        NSApp.appearance = NSAppearance(named: .darkAqua)
        await shoot("5-dark")
        NSApp.appearance = nil

        controller.tabsAtTheSide = true
        try? await Task.sleep(for: .seconds(1))
        await shoot("6-vertical")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await shoot("7-vertical-dark")
        NSApp.appearance = nil
        controller.tabsAtTheSide = false
        await settle()
        NSApp.terminate(nil)
    }
}
