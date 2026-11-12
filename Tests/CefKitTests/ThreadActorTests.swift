import CCef
import Foundation
import Testing
import os

@testable import CefKit

// The thread actors without Chromium: before start-up and after shutdown
// their jobs run on a private serial queue. Chromium's own threads are
// checked by SelfTest's `threads` group.

/// An actor on an executor of its own, so tests can move it through
/// phases without touching the shared ones.
private actor TestActor {
    let executor: CefThreadExecutor
    var log: [Int] = []

    init(executor: CefThreadExecutor) {
        self.executor = executor
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    func append(_ value: Int) {
        log.append(value)
    }

    func isOnExecutor() -> Bool { executor.isCurrent }
}

@CefIOActor private var ioCount = 0

/// Code that the compiler cannot see is on the IO actor.
private func incrementFromUnknownContext() {
    CefIOActor.assumeIsolated { ioCount += 1 }
}

@Suite struct ThreadActorTests {
    @Test func beforeStartUpJobsRunInOrderOnTheQueue() async {
        let actor = TestActor(executor: CefThreadExecutor(thread: TID_IO, label: "test-order"))
        await withTaskGroup(of: Void.self) { _ in
            for index in 0..<100 {
                await actor.append(index)
            }
        }
        #expect(await actor.log == Array(0..<100))
        #expect(await actor.isOnExecutor())
        #expect(!actor.executor.isCurrent)
    }

    @Test func assumeIsolatedWorksInsideAJob() async {
        await Task { @CefIOActor in incrementFromUnknownContext() }.value
        #expect(await ioCount >= 1)
    }

    @Test func jobsSentWhileStoppingRunAfterShutdown() async throws {
        let executor = CefThreadExecutor(thread: TID_IO, label: "test-stop")
        let actor = TestActor(executor: executor)
        await actor.append(0)
        executor.willStop()
        let held = Task { for index in 1...3 { await actor.append(index) } }
        try await Task.sleep(for: .milliseconds(100))
        // Held, not run, while Chromium shuts down.
        let ran = OSAllocatedUnfairLock(initialState: false)
        Task { await actor.append(-1); ran.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ran.withLock { $0 })
        executor.didStop()
        await held.value
        let log = await actor.log
        #expect(log.first == 0)
        #expect(log.filter { $0 > 0 } == [1, 2, 3])
    }
}

@Suite struct EnergySaverTests {
    @Test func constrainedInLowPowerModeOrUnderSeriousHeat() {
        #expect(CefEnergyConditions(isLowPowerModeEnabled: true, thermalState: .nominal).isConstrained)
        #expect(CefEnergyConditions(isLowPowerModeEnabled: false, thermalState: .serious).isConstrained)
        #expect(CefEnergyConditions(isLowPowerModeEnabled: false, thermalState: .critical).isConstrained)
        #expect(!CefEnergyConditions(isLowPowerModeEnabled: false, thermalState: .fair).isConstrained)
    }

    @Test func presets() {
        #expect(CefEnergySaver.automatic.reducedOffscreenFrameRate == 30)
        #expect(CefEnergySaver.off.reducedOffscreenFrameRate == nil)
        #expect(CefEnergySaver(reducedOffscreenFrameRate: 0).reducedOffscreenFrameRate == 1)
    }

    @Test func lifecycleVisibility() {
        #expect(CefBrowser.Lifecycle.active.isVisible && CefBrowser.Lifecycle.passive.isVisible)
        #expect(!CefBrowser.Lifecycle.hidden.isVisible && !CefBrowser.Lifecycle.discarded.isVisible)
    }
}

@Suite struct SchemeByteRangeTests {
    @Test func parsesSingleRanges() {
        #expect(SchemeByteRange(header: "bytes=0-99", totalLength: 1000) == .partial(0...99))
        #expect(SchemeByteRange(header: "bytes=900-", totalLength: 1000) == .partial(900...999))
        #expect(SchemeByteRange(header: "bytes=-100", totalLength: 1000) == .partial(900...999))
        #expect(SchemeByteRange(header: "bytes=-5000", totalLength: 1000) == .partial(0...999))
        #expect(SchemeByteRange(header: "bytes=500-5000", totalLength: 1000) == .partial(500...999))
    }

    @Test func unsatisfiableAndIgnoredRanges() {
        #expect(SchemeByteRange(header: "bytes=1000-", totalLength: 1000) == .unsatisfiable)
        #expect(SchemeByteRange(header: "bytes=-0", totalLength: 1000) == .unsatisfiable)
        #expect(SchemeByteRange(header: "bytes=0-1,5-6", totalLength: 1000) == .whole)
        #expect(SchemeByteRange(header: "items=0-1", totalLength: 1000) == .whole)
        #expect(SchemeByteRange(header: "bytes=9-3", totalLength: 1000) == .whole)
    }

    @Test func unknownLengthServesOnlyClosedRanges() {
        #expect(SchemeByteRange(header: "bytes=10-19", totalLength: nil) == .partial(10...19))
        #expect(SchemeByteRange(header: "bytes=10-", totalLength: nil) == .whole)
        #expect(SchemeByteRange(header: "bytes=-10", totalLength: nil) == .whole)
    }
}
