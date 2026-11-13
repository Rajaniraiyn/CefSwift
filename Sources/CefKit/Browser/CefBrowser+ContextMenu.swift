import AppKit
import CCef
import CefBase
import Foundation

extension CefBrowser.Configuration {
    /// Shapes a browser's context menu: change Chromium's menu, add your
    /// items, or turn the menu off.
    ///
    /// ```swift
    /// browserConfiguration.contextMenu.customize { menu, target in
    ///     menu.remove(.viewSource, .print)
    ///     if !target.selectedText.isEmpty {
    ///         menu.appendSection([
    ///             CefContextMenu.Item("Search Notes") { _, target in search(target.selectedText) },
    ///         ])
    ///     }
    /// }
    /// ```
    ///
    /// Customizations run in the order they were added, each on the menu
    /// the previous ones left, so independent parts of an app can each add
    /// one. To show the menu another way, implement
    /// ``CefBrowserDelegate/browser(_:runContextMenu:for:)``.
    @MainActor
    public struct ContextMenu {
        /// Changes the menu before it shows: one of ``customize(_:)``'s.
        public typealias Customization = @MainActor (inout CefContextMenu, CefContextMenuTarget) -> Void

        /// `false` shows no context menu.
        public var isEnabled = true
        /// Adds Inspect, which opens DevTools on the clicked element, to
        /// menus that lack it: Chrome-style browsers have Chromium's own,
        /// Alloy-style ones (views) none.
        public var showsInspectElement = false
        /// The customizations, in the order they run.
        public private(set) var customizations: [Customization] = []

        public init() {}

        /// Adds a customization, run after those added before it.
        public mutating func customize(_ customization: @escaping Customization) {
            customizations.append(customization)
        }

        /// Chromium's own title for Inspect, in the language of the rest of
        /// the menu (``CefRuntime/locale``); CefKit's when Chromium has none.
        static var inspectTitle: String {
            CefRuntime.shared.localizedString(CefRuntime.StringID(rawValue: IDS_CONTENT_CONTEXT_INSPECTELEMENT))
                ?? String(localized: "Inspect", bundle: .cefKit,
                          comment: "Context menu item that opens the developer tools on the element under the pointer. Shown only when Chromium has no string of its own for it.")
        }

        /// The menu to show for Chromium's `menu`: CefKit's adjustments,
        /// then the customizations, tidied.
        func menu(
            from menu: CefContextMenu, for target: CefContextMenuTarget, isChromeStyle: Bool, pageView: NSView? = nil
        ) -> CefContextMenu {
            var menu = CefContextMenu.adjusted(menu, for: target, isChromeStyle: isChromeStyle, pageView: pageView)
            if showsInspectElement, !menu.contains(.inspectElement) {
                menu.appendSection([CefContextMenu.Item(command: .inspectElement, title: Self.inspectTitle) { browser, target in
                    browser.showDevTools(inspecting: target.location)
                }])
            }
            for customization in customizations {
                customization(&menu, target)
            }
            return menu.normalized
        }
    }
}

extension CefBrowser {
    /// Sees the menu Chromium built for each click, before CefKit and the
    /// app change it.
    @_spi(Testing) public static var chromiumContextMenuObserver: (@MainActor (CefBrowser, CefContextMenu, CefContextMenuTarget) -> Void)?

    /// Shows the menu for a click: Chromium's `menu` as the configuration
    /// shapes it, through the delegate, then runs the chosen item. Chromium
    /// waits on `callback` until then.
    func runContextMenu(
        _ chromiumMenu: CefContextMenu, for target: CefContextMenuTarget,
        callback: CefRef<cef_run_context_menu_callback_t>
    ) {
        func cancel() { callback.pointer.pointee.cancel(callback.pointer) }
        CefBrowser.chromiumContextMenuObserver?(self, chromiumMenu, target)
        let contextMenu = configuration.contextMenu
        guard contextMenu.isEnabled else { return cancel() }
        let pageView = isOffscreen ? hostView : (nativeView ?? hostView)
        let menu = contextMenu.menu(from: chromiumMenu, for: target, isChromeStyle: isChromeStyle, pageView: pageView)
        guard !menu.items.isEmpty else { return cancel() }
        decide(.page) { await $0.browser(self, runContextMenu: menu, for: target) } then: { [weak self] chosen in
            if let action = chosen?.action {
                cancel()
                guard let self else { return }
                Task { await action(self, target) }
            } else if let chromiumID = chosen?.chromiumID {
                callback.pointer.pointee.cont(callback.pointer, Int32(chromiumID), cef_event_flags_t(rawValue: 0))
            } else {
                cancel()
            }
        }
    }
}

// MARK: - Handler

extension CefBrowserClient {
    func makeContextMenuHandler() -> UnsafeMutablePointer<cef_context_menu_handler_t> {
        let h = cefAllocate(cef_context_menu_handler_t.self, owner: self)
        // Chromium's menu is read as it is about to show, after
        // on_before_context_menu (left to Chromium), and shown by CefKit
        // in every hosting mode, so that offscreen and windowed browsers,
        // Alloy and Chrome style, show the same menu the same way.
        h.pointee.run_context_menu = { s, browser, frame, params, model, callback in
            cefRelease(frame)
            defer {
                cefRelease(params)
                cefRelease(model)
            }
            guard let params, let model, let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            let target = CefContextMenuTarget(raw: params)
            nonisolated(unsafe) let borrowedModel = model
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                let menu = CefContextMenu(model: borrowedModel, isChromeStyle: b.isChromeStyle)
                b.runContextMenu(menu, for: target, callback: callback)
                return 1
            }
        }
        return h
    }
}
