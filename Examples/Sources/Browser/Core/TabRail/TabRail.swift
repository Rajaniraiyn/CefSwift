import AppKit
import CefChromium
import CefSwiftUI
import SwiftUI

/// The browser's tabs: a view of one window's tabs in Chromium's tab strip
/// (`CefChromeWindow.tabs`), across the top or down the side.
///
/// It keeps no list of its own. Each gesture is a command to Chromium —
/// select, close, pin, group, move — and the rail redraws when Chromium
/// reports the change, so what it shows is always Chromium's tab strip,
/// including changes extensions and Chrome's own commands make.
struct TabRail: View {
    enum Axis { case horizontal, vertical }

    let window: CefChromeWindow
    var axis: Axis = .horizontal

    @Environment(BrowserController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var extents: [Int: ClosedRange<CGFloat>] = [:]
    @State private var dropTarget: TabRailLogic.DropTarget?

    var body: some View {
        let items = Self.items(of: window, isCollapsed: controller.isCollapsed)
        let hidden = TabRailLogic.hiddenItems(in: items)
        Group {
            switch axis {
            case .horizontal: horizontal(items: items, hidden: hidden)
            case .vertical: vertical(items: items, hidden: hidden)
            }
        }
        .coordinateSpace(.named(RailSpace.name))
        .onPreferenceChange(ItemExtentKey.self) { extents = $0 }
        .onDrop(of: [CefTab.Transfer.contentType], delegate: RailDropDelegate(
            window: window, axis: axis, items: items, extents: { extents }, isRightToLeft: layoutDirection == .rightToLeft,
            target: $dropTarget, controller: controller))
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: window.tabs.map(\.id))
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: window.groups.map(controller.isCollapsed))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    // MARK: Layouts

    private func horizontal(items: [TabRailLogic.Item], hidden: Set<Int>) -> some View {
        GeometryReader { proxy in
            let headerWidths = items.map { headerWidth(for: $0) }
            let available = max(0, proxy.size.width - 36)
            let widths = TabRailLogic.widths(for: items, headerWidths: headerWidths, hiddenItems: hidden, available: available)
            let row = HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    if !hidden.contains(offset) {
                        itemView(item, offset: offset, axis: .horizontal)
                            .frame(width: widths.widths[offset])
                            .id(offset)
                            .overlay(alignment: .leading) { dropMarker(before: item) }
                    }
                }
            }
            .frame(height: proxy.size.height)
            HStack(spacing: 4) {
                // Tabs shrink to fit; once at their narrowest, they scroll.
                if widths.isScrolling {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal, showsIndicators: false) { row }
                            .frame(width: available)
                            // The tabs past the edges fade out.
                            .mask(LinearGradient(
                                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                        .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                                startPoint: .leading, endPoint: .trailing))
                            .onAppear { scrollToActive(reader, items: items) }
                            .onChange(of: window.activeTab?.id) { scrollToActive(reader, items: items) }
                    }
                } else {
                    row
                }
                NewTabButton(window: window)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    /// Keeps the active tab in view in a rail that scrolls.
    private func scrollToActive(_ reader: ScrollViewProxy, items: [TabRailLogic.Item]) {
        guard let active = window.activeTab, let offset = items.firstIndex(where: { $0.kind != .groupHeader(isCollapsed: true) && $0.kind != .groupHeader(isCollapsed: false) && $0.index == active.index })
        else { return }
        withAnimation(reduceMotion ? nil : .snappy) { reader.scrollTo(offset) }
    }

    private func vertical(items: [TabRailLogic.Item], hidden: Set<Int>) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                let pinned = window.tabs.filter(\.isPinned)
                if !pinned.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], spacing: 4) {
                        ForEach(pinned) { tab in
                            TabItemView(tab: tab, style: .pinnedTile).railExtent(index: tab.index, axis: .vertical)
                        }
                    }
                    .padding(.bottom, 6)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    if !hidden.contains(offset), item.kind != .pinnedTab {
                        itemView(item, offset: offset, axis: .vertical)
                            .overlay(alignment: .top) { dropMarker(before: item) }
                    }
                }
                NewTabButton(window: window, showsTitle: true)
            }
            .padding(8)
        }
    }

    @ViewBuilder private func itemView(_ item: TabRailLogic.Item, offset: Int, axis: Axis) -> some View {
        switch item.kind {
        case .pinnedTab, .tab:
            if item.index < window.tabs.count {
                let tab = window.tabs[item.index]
                TabItemView(tab: tab, style: item.kind == .pinnedTab ? .pinned : (axis == .vertical ? .row : .tab))
                    .railExtent(index: offset, axis: axis)
            }
        case .groupHeader:
            if let group = window.groups.first(where: { $0.id.rawValue == item.group }) {
                GroupHeaderView(group: group, axis: axis).railExtent(index: offset, axis: axis)
            }
        }
    }

    @ViewBuilder private func dropMarker(before item: TabRailLogic.Item) -> some View {
        if let dropTarget, dropTarget.insertionIndex == item.index, item.kind != .groupHeader(isCollapsed: false) || dropTarget.group == nil {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: axis == .horizontal ? 2 : nil, height: axis == .horizontal ? nil : 2)
                .padding(axis == .horizontal ? .vertical : .horizontal, 6)
                .offset(x: axis == .horizontal ? -2 : 0, y: axis == .horizontal ? 0 : -1)
                .transition(.opacity)
        }
    }

    private func headerWidth(for item: TabRailLogic.Item) -> CGFloat {
        guard case .groupHeader = item.kind, let group = window.groups.first(where: { $0.id.rawValue == item.group }) else { return 0 }
        return GroupHeaderView.width(for: group.title)
    }

    /// The window's tabs and group headers, in strip order.
    static func items(of window: CefChromeWindow, isCollapsed: (CefTabGroup) -> Bool) -> [TabRailLogic.Item] {
        var items: [TabRailLogic.Item] = []
        var lastGroup: Int?
        for tab in window.tabs {
            let group = tab.group?.id.rawValue
            if let group, group != lastGroup, let model = tab.group {
                items.append(.init(kind: .groupHeader(isCollapsed: isCollapsed(model)), index: tab.index, group: group,
                                   count: model.tabs.count))
            }
            lastGroup = group
            items.append(.init(kind: tab.isPinned ? .pinnedTab : .tab, index: tab.index, group: group))
        }
        return items
    }
}

/// The rail's coordinate space, which drops are measured in.
enum RailSpace {
    static let name = "TabRail"
}

/// Each item's extent along the rail, by its offset among the rail's items.
struct ItemExtentKey: PreferenceKey {
    static let defaultValue: [Int: ClosedRange<CGFloat>] = [:]
    static func reduce(value: inout [Int: ClosedRange<CGFloat>], nextValue: () -> [Int: ClosedRange<CGFloat>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this item's extent along the rail.
    func railExtent(index: Int, axis: TabRail.Axis) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(RailSpace.name))
                Color.clear.preference(
                    key: ItemExtentKey.self,
                    value: [index: axis == .horizontal ? frame.minX...max(frame.minX, frame.maxX) : frame.minY...max(frame.minY, frame.maxY)])
            }
        }
    }
}

/// Lands tabs dropped on the rail: from this window, another window or
/// another profile's window.
private struct RailDropDelegate: DropDelegate {
    let window: CefChromeWindow
    let axis: TabRail.Axis
    let items: [TabRailLogic.Item]
    let extents: () -> [Int: ClosedRange<CGFloat>]
    let isRightToLeft: Bool
    @Binding var target: TabRailLogic.DropTarget?
    let controller: BrowserController

    private func resolve(_ info: DropInfo) -> TabRailLogic.DropTarget {
        let known = extents()
        let list = items.indices.map { known[$0] }
        var position = axis == .horizontal ? info.location.x : info.location.y
        if isRightToLeft, axis == .horizontal, let last = list.compactMap({ $0 }).map(\.upperBound).max() {
            position = last - position
        }
        return TabRailLogic.dropTarget(at: position, items: items, extents: list)
    }

    func dropEntered(info: DropInfo) { target = resolve(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = resolve(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        let landing = resolve(info)
        target = nil
        let providers = info.itemProviders(for: [CefTab.Transfer.contentType])
        let dragged = controller.draggedTab
        controller.draggedTab = nil
        guard let provider = providers.first else { return false }
        let window = window
        let controller = controller
        if let dragged {
            Task { await controller.land(dragged, at: landing, in: window) }
            return true
        }
        _ = provider.loadTransferable(type: CefTab.Transfer.self) { result in
            guard let transfer = try? result.get() else { return }
            Task { @MainActor in await controller.land(transfer, at: landing, in: window) }
        }
        return true
    }
}

/// The New Tab button at the end of the rail.
struct NewTabButton: View {
    let window: CefChromeWindow
    var showsTitle = false
    @Environment(BrowserController.self) private var controller

    var body: some View {
        Button {
            controller.openTab(in: window)
        } label: {
            if showsTitle {
                Label("New Tab", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
            } else {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
        }
        .buttonStyle(RailButtonStyle())
        .help("New Tab (⌘T)")
        .accessibilityLabel("New Tab")
    }
}

/// A plain button that shows a soft highlight on hover and press.
struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minHeight: 28)
                .background(.primary.opacity(configuration.isPressed ? 0.12 : isHovered ? 0.07 : 0), in: .rect(cornerRadius: 7))
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}
