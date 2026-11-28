import CCef
import CefBase
import CoreGraphics

extension CefWindow {
    /// Where DevTools for the window's page opens. Experimental and for
    /// tests: see ``CefWindow/devToolsPlacement``.
    @_spi(Testing) public enum DevToolsPlacement: Sendable, Equatable {
        /// A window of its own, which Chromium opens and draws.
        case automatic
        /// Inside this window, along `edge` of the page: `size` points tall
        /// at the bottom, or wide at the trailing edge.
        case docked(Edge, size: CGFloat)

        /// The edge of the page a docked DevTools sits at.
        public enum Edge: Sendable, Equatable {
            case bottom
            case trailing
        }
    }

    /// Puts DevTools, which Chromium has just created for the page, in
    /// this window beside the page, when ``devToolsPlacement`` docks it.
    /// Returns whether it did; otherwise Chromium gives DevTools a window
    /// of its own.
    ///
    /// DevTools fills a panel of its own whose delegate gives the panel its
    /// docked size: a browser view's own preferred size is what it shows,
    /// the whole window. At the bottom, the panel joins the window's
    /// column, below the page. At the trailing edge, the page moves into a
    /// row panel and the DevTools panel goes after it.
    ///
    /// TODO(upstream): docked DevTools cannot close. Reported to nobody
    /// yet; the draft report is in PR #51. CEF 158.0.6+g23f1736
    /// (Chromium 158.0.8127.89), official macOS arm64 minimal build,
    /// macOS 27.2:
    /// 1. A CefWindow with a Chrome-style page; `devToolsPlacement =
    ///    .docked(.bottom, size: 300)`; `page.showDevTools()`. DevTools opens
    ///    and draws beside the page (this works).
    /// 2. `page.closeDevTools()` (`close_dev_tools`). Chromium closes the
    ///    Views window the DevTools browser is in, the page's own: the
    ///    window delegate's `can_close` is asked; no `do_close` comes for
    ///    the DevTools browser.
    ///    - Close allowed: `EXC_BAD_ACCESS` in an `NSNotificationCenter`
    ///      observer under `-[NSWindow _finishClosingWindow]` /
    ///      `-[NSWindow _close]`, from `cef_do_message_loop_work`.
    ///    - Close refused (`can_close` returns 0): the window's next
    ///      `cef_panel_t::layout` after the DevTools browser is destroyed
    ///      stops at a Chromium check (`EXC_BREAKPOINT`), whether the
    ///      DevTools view was removed from the window, hidden
    ///      (`set_visible(0)`) or left in place.
    /// 3. Hiding the open DevTools panel instead, or removing the DevTools
    ///    view while its browser is open, hits the same `EXC_BREAKPOINT` at
    ///    the window's next layout.
    /// Turn this on for apps once a CEF update lets step 2 or 3 pass
    /// (SelfTest's `devToolsDocking` group).
    func dockDevTools(_ view: CefRef<cef_browser_view_t>) -> Bool {
        guard !isClosed, dockedDevTools == nil, case .docked(let edge, let size) = devToolsPlacement,
              let window = cefWindow?.pointer,
              let container = CefRef(adopting: cef_panel_create(DockPanelDelegate(edge: edge, size: size).makeDelegate()))
        else { return false }
        container.pointer.pointee.set_to_fill_layout(container.pointer).map { cefRelease($0) }
        add(view.pointer, to: container.pointer)
        dockedDevTools = view
        devToolsContainer = container
        dockedPlacement = devToolsPlacement
        window.withMemoryRebound(to: cef_panel_t.self, capacity: 1) { panel in
            switch edge {
            case .bottom:
                add(container.pointer, to: panel)
            case .trailing:
                guard let row = CefRef(adopting: cef_panel_create(nil)), let page = browserView else { return }
                devToolsRow = row
                // The page's view leaves the window for the row; CefKit
                // keeps its own reference, so it is not destroyed.
                page.pointer.withMemoryRebound(to: cef_view_t.self, capacity: 1) {
                    // remove_child_view consumes a reference to the view.
                    cefAddRef($0)
                    panel.pointee.remove_child_view(panel, $0)
                }
                add(page.pointer, to: row.pointer)
                add(container.pointer, to: row.pointer)
                add(row.pointer, to: panel)
            }
        }
        applyLayout()
        CefPage.refreshDevToolsStates()
        return true
    }

    /// The docked DevTools browser has been destroyed: CefKit lets go of
    /// its view, without laying the window out again (see the
    /// `TODO(upstream)` at ``dockDevTools(_:)``).
    func dockedDevToolsDidClose() {
        guard dockedDevTools != nil else { return }
        dockedDevTools = nil
        devToolsContainer = nil
        dockedPlacement = nil
        CefPage.refreshDevToolsStates()
    }

    /// Lays out the docked DevTools panel, from ``applyLayout()``: it keeps
    /// its preferred size along the window's column, or along the row at
    /// the trailing edge, and the page takes the rest.
    func layOutDockedDevTools(in layout: UnsafeMutablePointer<cef_box_layout_t>) {
        guard let container = devToolsContainer else { return }
        var target = layout
        var rowLayout: UnsafeMutablePointer<cef_box_layout_t>?
        if let row = devToolsRow {
            var settings = cef_box_layout_settings_t()
            settings.size = MemoryLayout<cef_box_layout_settings_t>.stride
            settings.horizontal = 1
            settings.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH
            settings.main_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH
            settings.default_flex = 1
            rowLayout = row.pointer.pointee.set_to_box_layout(row.pointer, &settings)
            guard let rowLayout else { return }
            target = rowLayout
        }
        defer { cefRelease(rowLayout) }
        container.pointer.withMemoryRebound(to: cef_view_t.self, capacity: 1) {
            // set_flex_for_view consumes a reference to the view.
            cefAddRef($0)
            target.pointee.set_flex_for_view(target, $0, 0)
        }
    }

    /// The edge DevTools is docked at, while it is open in this window. For tests.
    @_spi(Testing) public var dockedDevToolsEdge: DevToolsPlacement.Edge? {
        guard dockedDevTools != nil, case .docked(let edge, _)? = dockedPlacement else { return nil }
        return edge
    }

    /// A view's bounds in the window, in points.
    private func boundsInWindow<View>(_ view: UnsafeMutablePointer<View>) -> CGRect {
        view.withMemoryRebound(to: cef_view_t.self, capacity: 1) { v in
            var origin = cef_point_t()
            _ = v.pointee.convert_point_to_window(v, &origin)
            let bounds = v.pointee.get_bounds(v)
            return CGRect(x: Int(origin.x), y: Int(origin.y), width: Int(bounds.width), height: Int(bounds.height))
        }
    }

    /// The docked DevTools view's bounds in the window, in points. For tests.
    @_spi(Testing) public var dockedDevToolsBounds: CGRect? { dockedDevTools.map { boundsInWindow($0.pointer) } }

    /// The page's view's bounds in the window, in points. For tests.
    @_spi(Testing) public var pageViewBounds: CGRect? { browserView.map { boundsInWindow($0.pointer) } }

    /// The address the docked DevTools view shows. For tests.
    @_spi(Testing) public var dockedDevToolsURL: String? {
        guard let view = dockedDevTools?.pointer, let browser = view.pointee.get_browser(view) else { return nil }
        defer { cefRelease(browser) }
        guard let frame = browser.pointee.get_main_frame(browser) else { return nil }
        defer { cefRelease(frame) }
        return CefStringUtil.takingUserFree(frame.pointee.get_url(frame))
    }

    private func add<View>(_ view: UnsafeMutablePointer<View>, to panel: UnsafeMutablePointer<cef_panel_t>) {
        view.withMemoryRebound(to: cef_view_t.self, capacity: 1) {
            // add_child_view consumes a reference to the view.
            cefAddRef($0)
            panel.pointee.add_child_view(panel, $0)
        }
    }
}

/// Owner of the `cef_panel_delegate_t` of the panel docked DevTools fills:
/// gives the panel its docked size along the layout's axis.
final class DockPanelDelegate: Sendable {
    let edge: CefWindow.DevToolsPlacement.Edge
    let size: CGFloat

    init(edge: CefWindow.DevToolsPlacement.Edge, size: CGFloat) {
        self.edge = edge
        self.size = size
    }

    func makeDelegate() -> UnsafeMutablePointer<cef_panel_delegate_t> {
        let d = cefAllocate(cef_panel_delegate_t.self, owner: self)
        d.pointee.base.get_preferred_size = { s, view in
            cefRelease(view)
            guard let owner = cefOwner(DockPanelDelegate.self, s) else { return cef_size_t() }
            // The layout stretches the other side; it is 1, not 0, because
            // CEF takes a size with a side of 0 as no answer and uses the
            // view's own, which for a browser view is the whole window.
            let size = max(1, Int32(saturating: owner.size))
            switch owner.edge {
            case .bottom: return cef_size_t(width: 1, height: size)
            case .trailing: return cef_size_t(width: size, height: 1)
            }
        }
        return d
    }
}
