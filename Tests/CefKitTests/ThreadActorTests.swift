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

/// Counts jobs and catches two of them running at once.
private final class SerialProbe: Sendable {
    private struct State {
        var running = 0
        var overlaps = 0
        var completed = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func run() {
        state.withLock { state in
            state.running += 1
            if state.running > 1 { state.overlaps += 1 }
        }
        // Long enough for a concurrent job to show up.
        for _ in 0..<200 { _ = state.withLock { $0.running } }
        state.withLock { state in
            state.running -= 1
            state.completed += 1
        }
    }

    var overlaps: Int { state.withLock { $0.overlaps } }
    var completed: Int { state.withLock { $0.completed } }
}

private actor ProbeActor {
    let executor: CefThreadExecutor
    let probe: SerialProbe

    init(executor: CefThreadExecutor, probe: SerialProbe) {
        self.executor = executor
        self.probe = probe
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    func work() { probe.run() }
}

@Suite struct ThreadExecutorTransitionTests {
    /// Stands in for Chromium's thread: a serial queue that runs posted
    /// jobs, and rejects every seventh one synchronously, inside the post,
    /// as Chromium does when it cannot take a task. `shutDown` waits for
    /// the thread to finish its jobs, as `cef_shutdown()` does.
    private static func fakeChromium() -> (send: CefThreadExecutor.Sender, shutDown: @Sendable () -> Void) {
        let thread = DispatchQueue(label: "test-chromium")
        let count = OSAllocatedUnfairLock(initialState: 0)
        let send: CefThreadExecutor.Sender = { job in
            let n = count.withLock { n in
                n += 1
                return n
            }
            if n % 7 == 0 { return }  // Released here: dropped unrun.
            thread.async { job.run() }
        }
        return (send, { thread.sync {} })
    }

    @Test func enqueuesRacingStartAndShutdownRunSeriallyAndAllRun() async {
        for round in 0..<40 {
            let chromium = Self.fakeChromium()
            let executor = CefThreadExecutor(thread: TID_IO, label: "test-race-\(round)", send: chromium.send)
            let probe = SerialProbe()
            let actor = ProbeActor(executor: executor, probe: probe)
            let senders = 8, perSender = 60
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<senders {
                    group.addTask {
                        for _ in 0..<perSender { await actor.work() }
                    }
                }
                group.addTask {
                    await Task.yield()
                    executor.start()
                    await Task.yield()
                    executor.willStop()
                    await Task.yield()
                    chromium.shutDown()
                    executor.didStop()
                }
            }
            #expect(probe.overlaps == 0, "round \(round)")
            #expect(probe.completed == senders * perSender, "round \(round)")
        }
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

    @Test func extremeAndMalformedRanges() {
        // Lengths that overflow an Int are ignored, not trapped on.
        #expect(SchemeByteRange(header: "bytes=0-9223372036854775807", totalLength: nil) == .whole)
        #expect(SchemeByteRange(header: "bytes=1-9223372036854775807", totalLength: nil)
                == .partial(1...Int.max))
        #expect(SchemeByteRange(header: "bytes=0-9223372036854775807", totalLength: 10) == .partial(0...9))
        #expect(SchemeByteRange(header: "bytes=0-99999999999999999999", totalLength: 10) == .whole)
        #expect(SchemeByteRange(header: "bytes=-9223372036854775807", totalLength: 10) == .partial(0...9))
        #expect(SchemeByteRange(header: "bytes=9223372036854775806-", totalLength: Int.max) == .partial(Int.max - 1...Int.max - 1))
        #expect(SchemeByteRange(header: "bytes=0-", totalLength: Int.max) == .partial(0...(Int.max - 1)))
        // Only digits are positions.
        #expect(SchemeByteRange(header: "bytes=+1-5", totalLength: 10) == .whole)
        #expect(SchemeByteRange(header: "bytes=1-+5", totalLength: 10) == .whole)
        #expect(SchemeByteRange(header: "bytes=0x1-5", totalLength: 10) == .whole)
        #expect(SchemeByteRange(header: "bytes=1--5", totalLength: 10) == .whole)
        #expect(SchemeByteRange(header: "bytes=-", totalLength: 10) == .whole)
        #expect(SchemeByteRange(header: "bytes=", totalLength: 10) == .whole)
        #expect(SchemeByteRange(header: "bytes=١-٥", totalLength: 10) == .whole)
        #expect(SchemeByteRange(header: "bytes= 2 - 4 ", totalLength: 10) == .partial(2...4))
        #expect(SchemeByteRange(header: "bytes=0-0", totalLength: 0) == .unsatisfiable)
    }

    @Test func unknownLengthServesOnlyClosedRanges() {
        #expect(SchemeByteRange(header: "bytes=10-19", totalLength: nil) == .partial(10...19))
        #expect(SchemeByteRange(header: "bytes=10-", totalLength: nil) == .whole)
        #expect(SchemeByteRange(header: "bytes=-10", totalLength: nil) == .whole)
    }
}
