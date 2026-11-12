import CCef
import Foundation

/// Runs Chromium's message loop from the main run loop.
///
/// Chromium asks for work through `on_schedule_message_pump_work`. A single
/// one-shot timer serves those requests: it fires at the earliest requested
/// time, never more than 1/30 s away, and is re-armed after every slice of
/// work, so work is never starved. This follows cefclient's
/// `MainMessageLoopExternalPump`.
@MainActor
final class CefMessagePump {
    private static let maximumDelay: TimeInterval = 1.0 / 30

    private var timer: Timer?
    private var isRunning = false
    /// Whether Chromium is running work right now: code called from here is
    /// inside a CEF callback.
    private(set) var isPerformingWork = false
    private var wasReentered = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        schedule(after: Self.maximumDelay)
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// Handles `on_schedule_message_pump_work`, which CEF calls from any thread.
    nonisolated func scheduleWork(delayMilliseconds: Int64) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.workRequested(delayMilliseconds: delayMilliseconds)
            }
        }
    }

    private func workRequested(delayMilliseconds: Int64) {
        guard isRunning else { return }
        if delayMilliseconds <= 0 {
            timer?.invalidate()
            timer = nil
            performWork()
        } else {
            schedule(after: min(TimeInterval(delayMilliseconds) / 1000, Self.maximumDelay))
        }
    }

    /// Arms the timer to fire after `delay`, unless it is already due sooner.
    private func schedule(after delay: TimeInterval) {
        let fireDate = Date(timeIntervalSinceNow: delay)
        if let timer {
            guard fireDate < timer.fireDate else { return }
            timer.invalidate()
        }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.performWork()
            }
        }
        // Common modes keep the pump running during window drags and menu
        // tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func performWork() {
        guard isRunning else { return }
        // Work can trigger a nested run loop that fires the timer again.
        // Chromium does not support re-entering its loop, so note the
        // request and run it once the outer call returns.
        guard !isPerformingWork else {
            wasReentered = true
            return
        }
        isPerformingWork = true
        wasReentered = false
        cef_do_message_loop_work()
        isPerformingWork = false

        guard isRunning else { return }
        if wasReentered {
            schedule(after: 0)
        } else if timer == nil {
            schedule(after: Self.maximumDelay)
        }
    }
}
