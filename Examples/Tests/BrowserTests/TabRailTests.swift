import CoreGraphics
import Testing

@testable import Browser

/// The tab rail's arithmetic: widths, overflow, drops and keyboard commands.
@Suite struct TabRailTests {
    typealias Item = TabRailLogic.Item

    /// Two pinned tabs, then a group of two (header first), then two tabs.
    let items: [Item] = [
        Item(kind: .pinnedTab, index: 0, group: nil),
        Item(kind: .pinnedTab, index: 1, group: nil),
        Item(kind: .groupHeader(isCollapsed: false), index: 2, group: 7, count: 2),
        Item(kind: .tab, index: 2, group: 7),
        Item(kind: .tab, index: 3, group: 7),
        Item(kind: .tab, index: 4, group: nil),
        Item(kind: .tab, index: 5, group: nil),
    ]

    @Test func tabsShareTheRoomUpToTheirWidest() {
        let widths = TabRailLogic.widths(for: items, headerWidths: [0, 0, 40, 0, 0, 0, 0], available: 2000)
        #expect(widths.widths == [34, 34, 40, 224, 224, 224, 224])
        #expect(!widths.isScrolling)
    }

    @Test func tabsShrinkThenTheRailScrolls() {
        let metrics = TabRailLogic.Metrics()
        let shrunk = TabRailLogic.widths(for: items, headerWidths: [0, 0, 40, 0, 0, 0, 0], available: 600)
        // 600 less 2 × 34 pinned, a 40 point header and 6 gaps of 2.
        #expect(shrunk.widths[3] == ((600 - 68 - 40 - 12) / 4).rounded(.down))
        #expect(!shrunk.isScrolling)
        let crowded = TabRailLogic.widths(for: items, headerWidths: [0, 0, 40, 0, 0, 0, 0], available: 300)
        #expect(crowded.widths[3] == metrics.minimumTabWidth)
        #expect(crowded.isScrolling)
    }

    @Test func aCollapsedGroupHidesItsTabsButNotItsHeader() {
        var collapsed = items
        collapsed[2].kind = .groupHeader(isCollapsed: true)
        let hidden = TabRailLogic.hiddenItems(in: collapsed)
        #expect(hidden == [3, 4])
        let widths = TabRailLogic.widths(for: collapsed, headerWidths: [0, 0, 40, 0, 0, 0, 0], hiddenItems: hidden, available: 2000)
        #expect(widths.widths[3] == 0 && widths.widths[2] == 40)
    }

    /// Each item 100 points wide, side by side.
    var extents: [ClosedRange<CGFloat>?] { items.indices.map { CGFloat($0) * 100...CGFloat($0) * 100 + 100 } }

    @Test func dropsLandBeforeOrAfterATabByItsHalves() {
        let before = TabRailLogic.dropTarget(at: 510, items: items, extents: extents)
        #expect(before == .init(insertionIndex: 4, group: nil, isPinned: false))
        let after = TabRailLogic.dropTarget(at: 590, items: items, extents: extents)
        #expect(after == .init(insertionIndex: 5, group: nil, isPinned: false))
    }

    @Test func dropsAmongPinnedTabsPin() {
        #expect(TabRailLogic.dropTarget(at: 160, items: items, extents: extents) == .init(insertionIndex: 2, group: nil, isPinned: true))
    }

    @Test func dropsJoinAGroupInsideItOrPastItsHeadersMiddle() {
        // Between the group's two tabs.
        #expect(TabRailLogic.dropTarget(at: 390, items: items, extents: extents).group == 7)
        // The header's trailing half: the group's start.
        #expect(TabRailLogic.dropTarget(at: 270, items: items, extents: extents) == .init(insertionIndex: 2, group: 7, isPinned: false))
        // The header's leading half: before the group, outside it.
        #expect(TabRailLogic.dropTarget(at: 210, items: items, extents: extents) == .init(insertionIndex: 2, group: nil, isPinned: false))
    }

    @Test func aCollapsedGroupIsSteppedOver() {
        var collapsed = items
        collapsed[2].kind = .groupHeader(isCollapsed: true)
        var shown = extents
        shown[3] = nil
        shown[4] = nil
        #expect(TabRailLogic.dropTarget(at: 270, items: collapsed, extents: shown) == .init(insertionIndex: 4, group: nil, isPinned: false))
    }

    @Test func dropsPastTheEndGoLast() {
        #expect(TabRailLogic.dropTarget(at: 5000, items: items, extents: extents).insertionIndex == 6)
    }

    @Test func aMoveWithinTheWindowAccountsForTheTabLeaving() {
        let target = TabRailLogic.DropTarget(insertionIndex: 5, group: nil, isPinned: false)
        #expect(target.finalIndex(movingFrom: 2) == 4)
        #expect(target.finalIndex(movingFrom: 5) == 5)
        #expect(target.finalIndex(movingFrom: nil) == 5)
    }

    @Test func numberedShortcutsPickThatTabAndNinePicksTheLast() {
        #expect(TabRailLogic.index(for: .number(1), active: 3, count: 5) == 0)
        #expect(TabRailLogic.index(for: .number(5), active: 0, count: 5) == 4)
        #expect(TabRailLogic.index(for: .number(7), active: 0, count: 5) == nil)
        #expect(TabRailLogic.index(for: .number(9), active: 0, count: 12) == 11)
    }

    @Test func nextAndPreviousWrapRound() {
        #expect(TabRailLogic.index(for: .next, active: 4, count: 5) == 0)
        #expect(TabRailLogic.index(for: .previous, active: 0, count: 5) == 4)
        #expect(TabRailLogic.index(for: .next, active: nil, count: 0) == nil)
    }

    @Test func closingOthersAndToTheRightKeepsPinnedTabs() {
        #expect(TabRailLogic.indicesToClose(others: 3, count: 6, pinned: [0, 1]) == [2, 4, 5])
        #expect(TabRailLogic.indicesToClose(after: 3, count: 6, pinned: [0, 1]) == [4, 5])
        #expect(TabRailLogic.indicesToClose(after: 5, count: 6, pinned: []) == [])
    }
}
