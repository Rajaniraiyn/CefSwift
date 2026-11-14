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
            // URL(string:) escapes the spaces and brackets itself.
            URL(string: "data:text/html,<title>\(title)</title><h1>\(title)</h1>")!
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(900)) }
        func shoot(_ name: String, extra: CGFloat = 0) async {
            await settle()
            guard let cover = window.topBar?.superview else { return }
            cover.layoutSubtreeIfNeeded()
            let bounds = cover.bounds
            let height = controller.tabsAtTheSide ? bounds.height : window.topBarHeight + extra
            let rect = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, max(height, 1)))
            guard let bitmap = cover.bitmapImageRepForCachingDisplay(in: rect) else { return }
            cover.cacheDisplay(in: rect, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            print("cefswift-rail-screenshot \(name)")
        }

        NSApp.appearance = NSAppearance(named: .aqua)
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
            try? await window.tabs.first { $0.group === reading }?.select()
            if let videos { controller.toggleCollapsed(videos) }
            await shoot("3-groups-one-collapsed")
        }

        for index in 1...16 {
            _ = await controller.openTabNow(url: page("Article \(index)"), inBackground: true)
        }
        await shoot("4-overflow")

        // The find bar along the top of the page, in place of Chromium's.
        window.activeTab?.browser?.execute(.find)
        await settle()
        window.activeTab?.browser?.findSession.text = "Article"
        await shoot("4b-find-bar", extra: window.pageBar?.fittingSize.height ?? 0)
        window.activeTab?.browser?.findSession.end()

        NSApp.appearance = NSAppearance(named: .darkAqua)
        await shoot("5-dark")
        NSApp.appearance = NSAppearance(named: .aqua)

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
