import Foundation
import Testing

@testable import CefKit

/// `CefLoadTracker`, driven by the events CEF reports for the main frame.
@MainActor
struct LoadTrackerTests {
    let a = URL(string: "https://a.test/")!
    let b = URL(string: "https://b.test/")!
    let direct = CefLoadTracker.Transition(isDirectLoad: true)
    let link = CefLoadTracker.Transition()

    /// Starts `navigation`'s wait in a task of its own.
    func waiting(_ navigation: CefNavigation, timeout: Duration? = nil) -> Task<CefLoadResult, any Error> {
        Task { @MainActor in try await navigation.waitUntilLoaded(timeout: timeout) }
    }

    /// Lets tasks started so far reach their first suspension.
    func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func finishesWithTheStatusOfItsDocument() async throws {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        let wait = waiting(navigation)
        await settle()
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.navigationWillStart(url: b, transition: link, isRedirect: true, isCancelled: false)
        tracker.mainFrameDidCommit(url: b, transition: direct)
        tracker.mainFrameDidFinish(url: b, httpStatus: 200)
        let result = try await wait.value
        #expect(result == CefLoadResult(url: b, httpStatus: 200))
        // Awaiting again returns the same outcome.
        #expect(try await navigation.waitUntilLoaded() == result)
    }

    @Test func anEarlierDocumentDoesNotFinishIt() async throws {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(b, shownURL: a)
        tracker.navigationWillStart(url: b, transition: direct, isRedirect: false, isCancelled: false)
        // The page shown before reports its load and its abort late.
        tracker.mainFrameDidFinish(url: a, httpStatus: 200)
        tracker.mainFrameDidFail(CefLoadError(code: -3, message: "aborted", url: a))
        #expect(navigation.outcome == nil)
        tracker.mainFrameDidCommit(url: b, transition: direct)
        tracker.mainFrameDidFinish(url: b, httpStatus: 404)
        #expect(try await navigation.waitUntilLoaded().httpStatus == 404)
    }

    @Test func failsWithTheLoadError() async {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.mainFrameDidFail(CefLoadError(code: -105, message: "ERR_NAME_NOT_RESOLVED", url: a))
        await #expect(throws: CefLoadError(code: -105, message: "ERR_NAME_NOT_RESOLVED", url: a)) {
            try await navigation.waitUntilLoaded()
        }
    }

    @Test func aNavigationThatNeverCommitsIsAborted() async {
        // A download, or a 204: loading stops without a document.
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.loadingDidChange(isLoading: false, currentURL: nil)
        await #expect { try await navigation.waitUntilLoaded() } throws: { ($0 as? CefLoadError)?.isCancellation == true }
    }

    @Test func theDelegatesCancellationIsAnAbort() async {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: true)
        await #expect { try await navigation.waitUntilLoaded() } throws: { ($0 as? CefLoadError)?.isCancellation == true }
    }

    @Test func anotherNavigationSupersedesIt() async {
        let tracker = CefLoadTracker()
        let first = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        // A link the page follows.
        tracker.navigationWillStart(url: b, transition: link, isRedirect: false, isCancelled: false)
        await #expect { try await first.waitUntilLoaded() } throws: { Self.isSuperseded($0) }

        // A second load before the first one started.
        let second = tracker.request(a, shownURL: nil)
        let third = tracker.request(b, shownURL: nil)
        await #expect { try await second.waitUntilLoaded() } throws: { Self.isSuperseded($0) }
        #expect(third.outcome == nil)
    }

    @Test func anAbortReportedBeforeTheNextNavigationIsASupersession() async {
        // Chromium aborts the navigation it replaces before it starts the
        // new one.
        let tracker = CefLoadTracker()
        let first = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        let second = tracker.request(b, shownURL: nil)
        tracker.mainFrameDidFail(CefLoadError(code: -3, message: "ERR_ABORTED", url: a))
        tracker.navigationWillStart(url: b, transition: direct, isRedirect: false, isCancelled: false)
        await #expect { try await first.waitUntilLoaded() } throws: { Self.isSuperseded($0) }
        #expect(second.outcome == nil)
    }

    @Test func aCloseHoldsTheAbortUntilTheBrowserCloses() async {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.browserWillClose()
        tracker.mainFrameDidFail(CefLoadError(code: -3, message: "ERR_ABORTED", url: a))
        tracker.loadingDidChange(isLoading: false, currentURL: nil)
        await settle()
        #expect(navigation.outcome == nil)
        tracker.browserDidClose()
        await #expect { try await navigation.waitUntilLoaded() } throws: { Self.isClosed($0) }
    }

    @Test func aCrashReportedAfterLoadingStoppedFailsTheLoad() async {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.mainFrameDidCommit(url: a, transition: direct)
        tracker.loadingDidChange(isLoading: false, currentURL: a)
        tracker.renderProcessDidTerminate(.killed)
        await #expect {
            try await navigation.waitUntilLoaded()
        } throws: {
            if case .renderProcessTerminated(.killed)? = $0 as? CefError { true } else { false }
        }
    }

    @Test func aPageNavigatingByItselfDoesNotClaimALoad() async throws {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(b, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: link, isRedirect: false, isCancelled: false)
        tracker.mainFrameDidCommit(url: a, transition: link)
        tracker.mainFrameDidFinish(url: a, httpStatus: 200)
        #expect(navigation.outcome == nil)
        tracker.navigationWillStart(url: b, transition: direct, isRedirect: false, isCancelled: false)
        tracker.mainFrameDidCommit(url: b, transition: direct)
        tracker.mainFrameDidFinish(url: b, httpStatus: 200)
        #expect(try await navigation.waitUntilLoaded().url == b)
    }

    @Test func aClientRedirectContinuesTheNavigation() async throws {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.mainFrameDidCommit(url: a, transition: direct)
        tracker.navigationWillStart(
            url: b, transition: CefLoadTracker.Transition(isClientRedirect: true), isRedirect: false, isCancelled: false)
        // The first document's load event, after the redirect started.
        tracker.mainFrameDidFinish(url: a, httpStatus: 200)
        #expect(navigation.outcome == nil)
        tracker.mainFrameDidCommit(url: b, transition: link)
        tracker.mainFrameDidFinish(url: b, httpStatus: 200)
        #expect(try await navigation.waitUntilLoaded().url == b)
    }

    @Test func aFragmentFinishesAsTheAddressChanges() async throws {
        let tracker = CefLoadTracker()
        let target = URL(string: "https://a.test/#part")!
        let navigation = tracker.request(target, shownURL: a)
        tracker.mainFrameAddressDidChange(URL(string: "https://a.test/#other"))
        #expect(navigation.outcome == nil)
        tracker.mainFrameAddressDidChange(target)
        let result = try await navigation.waitUntilLoaded()
        #expect(result.isSameDocument && result.httpStatus == nil)
        #expect(!CefLoadTracker.differOnlyInFragment(target, b))
        #expect(!CefLoadTracker.differOnlyInFragment(a, a))
    }

    @Test func aCrashFailsTheLoadingDocument() async {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.mainFrameDidCommit(url: a, transition: direct)
        tracker.renderProcessDidTerminate(.crashed)
        await #expect {
            try await navigation.waitUntilLoaded()
        } throws: {
            if case .renderProcessTerminated(.crashed)? = $0 as? CefError { true } else { false }
        }
    }

    @Test func closingFailsEveryWaiter() async {
        let tracker = CefLoadTracker()
        let started = tracker.request(a, shownURL: nil)
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        let asked = tracker.request(b, shownURL: nil)
        let waits = [waiting(started), waiting(asked)]
        let settled = Task { @MainActor in try await tracker.waitUntilSettled() }
        await settle()
        tracker.browserDidClose()
        for wait in waits {
            await #expect { try await wait.value } throws: { Self.isClosed($0) }
        }
        await #expect { try await settled.value } throws: { Self.isClosed($0) }
    }

    @Test func theTimeoutEndsOnlyTheWait() async throws {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        await #expect {
            try await navigation.waitUntilLoaded(timeout: .milliseconds(50))
        } throws: {
            if case .timedOut? = $0 as? CefError { true } else { false }
        }
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.mainFrameDidCommit(url: a, transition: direct)
        tracker.mainFrameDidFinish(url: a, httpStatus: 200)
        #expect(try await navigation.waitUntilLoaded().httpStatus == 200)
    }

    @Test func cancellingTheTaskEndsTheWait() async {
        let tracker = CefLoadTracker()
        let navigation = tracker.request(a, shownURL: nil)
        let wait = waiting(navigation)
        await settle()
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        #expect(navigation.outcome == nil)
    }

    @Test func settlingFollowsTheNavigationThatReplacedAnother() async throws {
        let tracker = CefLoadTracker()
        _ = tracker.request(a, shownURL: nil)
        let settled = Task { @MainActor in try await tracker.waitUntilSettled() }
        await settle()
        tracker.navigationWillStart(url: a, transition: direct, isRedirect: false, isCancelled: false)
        tracker.navigationWillStart(url: b, transition: link, isRedirect: false, isCancelled: false)
        tracker.mainFrameDidCommit(url: b, transition: link)
        tracker.mainFrameDidFinish(url: b, httpStatus: 200)
        #expect(try await settled.value.url == b)
        #expect(tracker.isIdle)
        #expect(try tracker.settledOutcome?.get().url == b)
    }

    static func isSuperseded(_ error: any Error) -> Bool {
        if case .navigationSuperseded? = error as? CefError { true } else { false }
    }

    static func isClosed(_ error: any Error) -> Bool {
        if case .browserClosed? = error as? CefError { true } else { false }
    }
}
