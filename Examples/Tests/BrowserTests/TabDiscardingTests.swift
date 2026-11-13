import CefSwiftUI
import Testing

@testable import Browser

@MainActor @Suite struct TabDiscardingTests {
    typealias Tab = TabDiscarding.Tab<Int>

    let now = ContinuousClock.now

    func tab(_ id: Int, _ lifecycle: CefBrowser.Lifecycle, since seconds: Int, isLive: Bool = true) -> Tab {
        Tab(id: id, isLive: isLive, lifecycle: lifecycle, lifecycleChangedAt: now - .seconds(seconds))
    }

    @Test func checkIntervalFollowsTheDuration() {
        #expect(TabDiscarding.Policy.disabled.checkInterval == nil)
        #expect(TabDiscarding.Policy(discardsUnderMemoryPressure: true).checkInterval == nil)
        #expect(TabDiscarding.Policy(hiddenDuration: .seconds(2)).checkInterval == .milliseconds(500))
        #expect(TabDiscarding.Policy(hiddenDuration: .milliseconds(100)).checkInterval == .milliseconds(250))
        #expect(TabDiscarding.Policy(hiddenDuration: .seconds(3600)).checkInterval == .seconds(30))
    }

    @Test func onlyTabsHiddenLongEnoughAreDiscarded() {
        let tabs = [
            tab(1, .hidden, since: 120), tab(2, .hidden, since: 30), tab(3, .active, since: 600),
            tab(4, .passive, since: 600), tab(5, .discarded, since: 600), tab(6, .hidden, since: 600, isLive: false),
        ]
        #expect(TabDiscarding.tabsToDiscard(tabs, hiddenFor: .seconds(60), now: now) == [1])
    }

    @Test func longestHiddenGoesFirst() {
        let tabs = [tab(1, .hidden, since: 100), tab(2, .hidden, since: 300), tab(3, .hidden, since: 200)]
        #expect(TabDiscarding.tabsToDiscard(tabs, hiddenFor: .seconds(60), now: now) == [2, 3, 1])
    }

    @Test func memoryPressureTakesEveryHiddenTab() {
        let tabs = [tab(1, .hidden, since: 0), tab(2, .active, since: 0)]
        #expect(TabDiscarding.tabsToDiscard(tabs, hiddenFor: .zero, now: now) == [1])
    }

    /// A tab `discard()` refused waits another full spell.
    @Test func aRefusedTabWaitsAnotherSpell() {
        let tabs = [tab(1, .hidden, since: 600)]
        let tried = [1: now - .seconds(30)]
        #expect(TabDiscarding.tabsToDiscard(tabs, hiddenFor: .seconds(60), now: now, lastAttempts: tried).isEmpty)
        let triedLongAgo = [1: now - .seconds(90)]
        #expect(TabDiscarding.tabsToDiscard(tabs, hiddenFor: .seconds(60), now: now, lastAttempts: triedLongAgo) == [1])
    }

    /// A new hidden spell starts afresh, whatever happened in an earlier one.
    @Test func anAttemptInAnEarlierSpellDoesNotCount() {
        let tabs = [tab(1, .hidden, since: 120)]
        let tried = [1: now - .seconds(500)]
        #expect(TabDiscarding.tabsToDiscard(tabs, hiddenFor: .seconds(60), now: now, lastAttempts: tried) == [1])
    }
}
