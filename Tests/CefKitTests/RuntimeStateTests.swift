import Testing

@testable import CefKit

/// The runtime starts once per process.
struct RuntimeStateTests {
    @Test func startsOnlyFromNotStarted() {
        #expect(throws: Never.self) { try CefRuntime.State.notStarted.checkCanStart() }
        for state in [CefRuntime.State.starting, .running] {
            #expect(throws: CefError.self) { try state.checkCanStart() }
        }
        for state in [CefRuntime.State.stopping, .stopped] {
            do {
                try state.checkCanStart()
                Issue.record("\(state) must not start again")
            } catch {
                if case .shutDown = error { continue }
                Issue.record("\(state): \(error)")
            }
        }
    }

    @Test func onlyFailuresBeforeChromiumStartsAllowAnotherTry() {
        #expect(CefError.frameworkNotFound("").isBeforeChromiumStarted)
        #expect(CefError.apiHashMismatch(expected: "a", actual: "b").isBeforeChromiumStarted)
        #expect(!CefError.initializationFailed(exitCode: 1).isBeforeChromiumStarted)
        #expect(!CefError.anotherInstanceRunning.isBeforeChromiumStarted)
    }

    @MainActor @Test func theRuntimeHasNotStartedInUnitTests() {
        #expect(CefRuntime.shared.state == .notStarted)
        #expect(!CefRuntime.shared.isRunning)
    }
}
