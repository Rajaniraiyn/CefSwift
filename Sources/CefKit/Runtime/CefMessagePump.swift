import CCef
import Foundation

/// Drives CEF's message loop from the main run loop (external message pump).
///
/// CEF requests work via `on_schedule_message_pump_work(delay_ms)`; we honor
/// those requests with one-shot timers clamped to 33 ms, and additionally run
/// a steady ~30 fps fallback timer while the runtime is alive so work is
/// never starved (the official cefclient pattern, simplified per its own
/// recommendation). All work happens on the main thread, with a re-entrancy
/// guard around `cef_do_message_loop_work()`.
@MainActor
final class CefMessagePump {
    /// Maximum delay between work slices (33 ms ≈ 30 Hz).
    private static let maxDelay: TimeInterval = 0.033

    private var fallbackTimer: Timer?
    private var scheduledTimer: Timer?
    private var isPerformingWork = false
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let timer = Timer(timeInterval: Self.maxDelay, repeats: true) { _ in
            // Timer fires on the main run loop; CEF's UI thread is the main
            // thread with an external pump.
            MainActor.assumeIsolated {
                CefRuntime.shared.messagePump?.performWork()
            }
        }
        // .common so the pump keeps running during window drags/menus.
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    func stop() {
        isRunning = false
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        scheduledTimer?.invalidate()
        scheduledTimer = nil
    }

    /// Entry point for `on_schedule_message_pump_work`. May be called from
    /// any thread.
    nonisolated func scheduleWork(delayMilliseconds: Int64) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.scheduleOnMain(delayMilliseconds: delayMilliseconds)
            }
        }
    }

    private func scheduleOnMain(delayMilliseconds: Int64) {
        guard isRunning else { return }
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        if delayMilliseconds <= 0 {
            performWork()
            return
        }
        let delay = min(TimeInterval(delayMilliseconds) / 1000.0, Self.maxDelay)
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                CefRuntime.shared.messagePump?.performWork()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduledTimer = timer
    }

    func performWork() {
        guard isRunning, !isPerformingWork else { return }
        isPerformingWork = true
        cef_do_message_loop_work()
        isPerformingWork = false
    }
}
