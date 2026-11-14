import CoreGraphics

/// The tab rail's arithmetic, kept apart from CEF and SwiftUI so it can be
/// tested on its own (`Tests/BrowserTests/TabRailTests.swift`): how wide
/// tabs are and when the rail scrolls, where a dropped tab lands, and which
/// tab a keyboard command selects.
enum TabRailLogic {
    /// One thing in the rail, in strip order.
    struct Item: Equatable {
        enum Kind: Equatable {
            case pinnedTab
            case tab
            /// A group's header; its tabs follow it unless collapsed.
            case groupHeader(isCollapsed: Bool)
        }

        var kind: Kind
        /// For a tab, its index in Chromium's strip; for a header, its
        /// group's first tab's.
        var index: Int
        /// The group it belongs to (for a header, its own).
        var group: Int?
        /// For a header: how many tabs the group has.
        var count = 0
    }

    // MARK: Widths

    struct Metrics: Equatable {
        var pinnedWidth: CGFloat = 34
        var minimumTabWidth: CGFloat = 76
        var maximumTabWidth: CGFloat = 224
        var spacing: CGFloat = 2
    }

    /// How wide each item is along a horizontal rail, and whether the rail
    /// has to scroll: tabs share the room left by pinned tabs and group
    /// headers, up to their widest; once they are at their narrowest the
    /// rail scrolls.
    struct Widths: Equatable {
        var widths: [CGFloat]
        var isScrolling: Bool
        var contentWidth: CGFloat
    }

    static func widths(
        for items: [Item], headerWidths: [CGFloat], hiddenItems: Set<Int> = [], available: CGFloat, metrics: Metrics = .init()
    ) -> Widths {
        var fixed: CGFloat = 0
        var flexible = 0
        var visible = 0
        for (offset, item) in items.enumerated() where !hiddenItems.contains(offset) {
            visible += 1
            switch item.kind {
            case .pinnedTab: fixed += metrics.pinnedWidth
            case .groupHeader: fixed += offset < headerWidths.count ? headerWidths[offset] : 0
            case .tab: flexible += 1
            }
        }
        let spacing = CGFloat(max(0, visible - 1)) * metrics.spacing
        let share = flexible == 0 ? 0 : (available - fixed - spacing) / CGFloat(flexible)
        let tabWidth = min(metrics.maximumTabWidth, max(metrics.minimumTabWidth, share.rounded(.down)))
        let widths = items.enumerated().map { offset, item -> CGFloat in
            if hiddenItems.contains(offset) { return 0 }
            switch item.kind {
            case .pinnedTab: return metrics.pinnedWidth
            case .groupHeader: return offset < headerWidths.count ? headerWidths[offset] : 0
            case .tab: return tabWidth
            }
        }
        let content = fixed + spacing + CGFloat(flexible) * tabWidth
        return Widths(widths: widths, isScrolling: content > available + 0.5, contentWidth: content)
    }

    /// The items a collapsed group hides: its tabs, not its header.
    static func hiddenItems(in items: [Item]) -> Set<Int> {
        var collapsed = Set<Int>()
        for item in items {
            if case .groupHeader(true) = item.kind, let group = item.group { collapsed.insert(group) }
        }
        var hidden = Set<Int>()
        for (offset, item) in items.enumerated() where item.kind == .tab {
            if let group = item.group, collapsed.contains(group) { hidden.insert(offset) }
        }
        return hidden
    }

    // MARK: Dropping

    /// Where a dropped tab goes.
    struct DropTarget: Equatable {
        /// The index in Chromium's strip, before the dragged tab is taken
        /// out (``finalIndex(movingFrom:)`` gives `chrome.tabs.move`'s).
        var insertionIndex: Int
        /// The group the tab joins; `nil` to be out of any group.
        var group: Int?
        /// Whether the tab lands among the pinned tabs.
        var isPinned: Bool

        /// The index `chrome.tabs.move` takes for a tab now at `source` in
        /// the same window: the tab leaves its place first.
        func finalIndex(movingFrom source: Int?) -> Int {
            guard let source, source < insertionIndex else { return insertionIndex }
            return insertionIndex - 1
        }
    }

    /// The drop target for a point `position` points along the rail, from
    /// its leading edge, given each item's extent along it (`extents[i]` is
    /// item `i`'s leading and trailing offset; hidden items have none).
    static func dropTarget(at position: CGFloat, items: [Item], extents: [ClosedRange<CGFloat>?]) -> DropTarget {
        let shown = items.indices.filter { $0 < extents.count && extents[$0] != nil }
        let tabCount = items.reduce(0) { count, item in
            item.kind == .groupHeader(isCollapsed: true) || item.kind == .groupHeader(isCollapsed: false)
                ? max(count, item.index + item.count) : max(count, item.index + 1)
        }
        let pinnedCount = items.filter { $0.kind == .pinnedTab }.count
        for offset in shown {
            guard let extent = extents[offset], position < extent.upperBound else { continue }
            let item = items[offset]
            let isLeadingHalf = position < (extent.lowerBound + extent.upperBound) / 2
            switch item.kind {
            case .pinnedTab:
                return DropTarget(insertionIndex: isLeadingHalf ? item.index : item.index + 1, group: nil, isPinned: true)
            case .groupHeader(let isCollapsed):
                // Before the header: before the group. After its middle:
                // into the group, at its start (past it when collapsed).
                if isLeadingHalf || isCollapsed {
                    return DropTarget(
                        insertionIndex: isLeadingHalf ? item.index : item.index + item.count, group: nil,
                        isPinned: false)
                }
                return DropTarget(insertionIndex: item.index, group: item.group, isPinned: false)
            case .tab:
                let index = isLeadingHalf ? item.index : item.index + 1
                // Between two tabs of a group, or after its last tab's
                // middle: in the group.
                return DropTarget(insertionIndex: max(index, pinnedCount), group: item.group, isPinned: false)
            }
        }
        return DropTarget(insertionIndex: tabCount, group: nil, isPinned: false)
    }

    // MARK: Keyboard

    /// Commands that pick another tab.
    enum Selection: Equatable {
        /// ⌘1 to ⌘8: that tab. ⌘9: the last, as in Safari and Chrome.
        case number(Int)
        /// ⌃Tab, ⌘⌥→, ⌘⇧]: the next, wrapping round.
        case next
        /// ⌃⇧Tab, ⌘⌥←, ⌘⇧[: the previous, wrapping round.
        case previous
    }

    /// The index `selection` picks among `count` tabs with `active` shown;
    /// `nil` when it picks none.
    static func index(for selection: Selection, active: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch selection {
        case .number(let number):
            guard (1...9).contains(number) else { return nil }
            return number == 9 ? count - 1 : (number <= count ? number - 1 : nil)
        case .next:
            return ((active ?? -1) + 1) % count
        case .previous:
            return ((active ?? 0) - 1 + count) % count
        }
    }

    /// Which tabs "Close Other Tabs" and "Close Tabs to the Right" close,
    /// by index, among `count`; pinned tabs are kept, as in Chrome.
    static func indicesToClose(others index: Int, count: Int, pinned: Set<Int>) -> [Int] {
        (0..<count).filter { $0 != index && !pinned.contains($0) }
    }

    static func indicesToClose(after index: Int, count: Int, pinned: Set<Int>) -> [Int] {
        guard index + 1 < count else { return [] }
        return (index + 1..<count).filter { !pinned.contains($0) }
    }
}
