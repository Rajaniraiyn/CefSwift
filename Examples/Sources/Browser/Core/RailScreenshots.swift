import AppKit
import CefChromium
import CefSwiftUI

/// `-railScreenshots <directory>`: puts a window's tabs through a few
/// states and saves a PNG of the whole window in each — the tab rail, the
/// toolbar and the page — then quits.
///
/// Each picture is the window as the window server composites it, with
/// Chromium's page, from `CGWindowListCreateImage` of the app's own
/// window, which needs no screen-recording permission. (Drawing the app's
/// views into a bitmap would leave the page out, and with it anything
/// covering the page by mistake.)
@MainActor
enum RailScreenshots {
    static func capture(_ window: CefChromeWindow, controller: BrowserController, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func page(_ title: String) -> URL {
            // URL(string:) escapes the spaces and brackets itself.
            URL(string: "data:text/html,<title>\(title)</title><h1>\(title)</h1>")!
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(900)) }
        func shoot(_ name: String) async {
            await settle()
            guard let nsWindow = window.window, let image = windowImage(nsWindow) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name).png"))
            print("cefswift-rail-screenshot \(name)")
        }

        NSApp.appearance = NSAppearance(named: .aqua)
        window.window?.setContentSize(NSSize(width: 1180, height: 720))
        for title in ["Swift.org", "Apple Developer", "The Swift Programming Language", "WWDC Videos", "Human Interface Guidelines"] {
            _ = await controller.openTabNow(url: page(title), inBackground: true)
        }
        await shoot("1-several-tabs")
        try? await window.tabs.dropFirst(2).first?.select()
        await shoot("1b-switched-tab")

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
        await shoot("4b-find-bar")
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
        window.window?.setContentSize(NSSize(width: 900, height: 600))
        await shoot("8-resized")
        window.window?.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(2))
        await shoot("9-full-screen")
        window.window?.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(2))
        NSApp.terminate(nil)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage`, which the macOS 15 SDK and later keep
    /// from Swift, looked up at run time, for a window of this process.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }
}
