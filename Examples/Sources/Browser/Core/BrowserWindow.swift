import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// One of the browser's windows: a window Chromium draws, with Chrome's
/// tab strip and toolbar covered by the browser's own — the tab rail and a
/// toolbar of the features' items, bound to the active tab — and the
/// features' views over the page.
@MainActor
@Observable
final class BrowserWindow {
    let chrome: CefChromeWindow

    /// The browser of the active tab.
    var activeBrowser: CefBrowser? { chrome.activeTab?.browser }

    init(chrome: CefChromeWindow, controller: BrowserController) {
        self.chrome = chrome
        chrome.showsChromeUI = false
        chrome.setTopBar { WindowTopBar(window: chrome).environment(controller) }
        chrome.setSidebar { TabSidebar(window: chrome).environment(controller) }
        chrome.setPageOverlay { PageOverlay(window: chrome).environment(controller) }
        chrome.window?.contentMinSize = NSSize(width: 560, height: 320)
    }
}

/// Over Chrome's tab strip and toolbar: the rail on a row of its own beside
/// the window buttons (unless tabs are at the side), and the toolbar.
struct WindowTopBar: View {
    let window: CefChromeWindow
    @Environment(BrowserController.self) private var controller

    /// The window buttons' width, which the first row leaves free.
    static let windowButtonsWidth: CGFloat = 76
    static let toolbarHeight: CGFloat = 44

    var body: some View {
        // Chromium decides how tall the area is (its tab strip and toolbar):
        // the toolbar takes its bottom, the tabs the rest.
        let height = max(window.topBarHeight, Self.toolbarHeight)
        VStack(spacing: 0) {
            if !controller.tabsAtTheSide {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.windowButtonsWidth)
                    TabRail(window: window, axis: .horizontal)
                        .padding(.trailing, 8)
                }
                .padding(.top, 5)
                .frame(height: height - Self.toolbarHeight)
                Toolbar(window: window).frame(height: Self.toolbarHeight)
            } else {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.windowButtonsWidth)
                    Toolbar(window: window)
                }
                .frame(height: height)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { WindowDragArea() }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Over Chrome's vertical tab strip, with tabs at the side: the rail.
struct TabSidebar: View {
    let window: CefChromeWindow

    var body: some View {
        TabRail(window: window, axis: .vertical)
            .background(.bar)
            .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
    }
}

/// Empty parts of the top bar move the window, and a double click zooms
/// it, as in any title bar.
private struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
    }
}

/// The toolbar, bound to the window's active tab: back and forward, the
/// features' items and the address field.
struct Toolbar: View {
    let window: CefChromeWindow
    @Environment(BrowserController.self) private var controller

    var body: some View {
        HStack(spacing: 6) {
            if let browser = window.activeTab?.browser {
                NavigationButtons(browser: browser)
                Spacer(minLength: 8)
                controller.toolbarItems(.principal, for: browser)
                    .frame(maxWidth: 640)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    controller.toolbarItems(.trailing, for: browser)
                    if controller.tabsAtTheSide { NewTabButton(window: window) }
                }
                .buttonStyle(ToolbarIconButtonStyle())
            } else {
                Spacer()
            }
        }
        .id(window.activeTab?.browser.map(ObjectIdentifier.init))
        .padding(.horizontal, 8)
    }
}

/// The features' views over the active tab's page.
private struct PageOverlay: View {
    let window: CefChromeWindow
    @Environment(BrowserController.self) private var controller

    var body: some View {
        ZStack {
            if let browser = window.activeTab?.browser {
                controller.pageOverlay(for: browser).id(ObjectIdentifier(browser))
            }
        }
    }
}
