import AppKit
@_spi(Testing) import CefKit
import os
import UserNotifications

/// Nothing CefSwift starts may ask macOS for a permission the app or a
/// page did not ask for: no notification authorization, no TCC prompt, at
/// launch or while pages load. Chromium asks for notification
/// authorization as soon as it sets up system notifications, which it does
/// for every profile at start-up, from the app and from its Alerts helper;
/// `CefRuntime.Configuration.Services.systemNotifications` keeps them off
/// unless the app turns them on.
///
/// Watched three ways: Chromium's use of `UNUserNotificationCenter` and
/// `NSUserNotificationCenter` in this process (where an authorization
/// request is answered "denied" without asking macOS, so that a regression
/// cannot prompt either), the Alerts helper starting at all, and, after a
/// launch, what the unified log says `usernoted` and `tccd` saw from the
/// app's bundles. With system notifications on, the first two catch
/// Chromium's `NSUserNotificationCenter.defaultUserNotificationCenter` and
/// the helper at every launch; the log shows both bundles connecting to
/// `usernoted`.
extension SelfTest {
    static func systemPromptChecks() async {
        await launchPromptChecks(label: "system prompts")
        for preset in ["embedded", "chrome"] {
            let started = Date()
            await runProbe("launchPrompts", label: "system prompts, .\(preset) preset",
                           environment: [presetEnvironmentKey: preset], timeout: .seconds(60))
            unifiedLogChecks(label: "system prompts, .\(preset) preset", since: started)
        }
    }

    static let presetEnvironmentKey = "CEFSWIFT_SELFTEST_PRESET"

    /// The probe's configuration: a preset with what the checks rely on.
    static func configureLaunchPromptsProbe(_ configuration: inout CefRuntime.Configuration) {
        guard ProcessInfo.processInfo.environment[presetEnvironmentKey] == "chrome" else { return }
        var chrome = CefRuntime.Configuration.chrome
        chrome.rootCacheDirectory = configuration.rootCacheDirectory
        chrome.customSchemes = configuration.customSchemes
        chrome.productName = configuration.productName
        chrome.isSandboxEnabled = configuration.isSandboxEnabled
        chrome.isOffscreenRenderingEnabled = configuration.isOffscreenRenderingEnabled
        chrome.preferences = configuration.preferences
        configuration = chrome
    }

    static func launchPromptsProbeChecks() async {
        await launchPromptChecks(label: "launch")
    }

    /// Opens a page in a Chrome-style window, as an app does at launch,
    /// and checks that nothing asked macOS for notification authorization;
    /// then that a page's own notifications still show.
    static func launchPromptChecks(label: String) async {
        let browser = CefBrowser(url: URL(string: "https://cefswift.test/prompts.html")!)
        let window = CefWindow(browser: browser)
        window.show()
        defer { window.close() }
        guard await loaded(browser, title: "prompts") else {
            check("\(label): page loads", false, detail: browser.title)
            return
        }
        // Chromium sets up notifications for a profile shortly after it
        // loads; give it time to.
        try? await Task.sleep(for: .seconds(3))
        let use = SystemPromptWatch.shared.snapshot
        check("\(label): Chromium never touches the user notification center",
              use.notificationCenterCalls.isEmpty && use.authorizationRequests == 0, detail: "\(use)")
        check("\(label): the Alerts helper never starts", use.alertsHelperLaunches == 0,
              detail: "\(use.alertsHelperLaunches) launches")
        guard use.isClean else {
            // The notification would go to macOS, which may show it.
            check("\(label): a page's notification still shows", false, detail: "not tried: it would reach macOS")
            return
        }

        // A page's notification, which it asked for and the app allowed:
        // Chromium shows it itself, in the app.
        let origin = URL(string: "https://cefswift.test")!
        CefProfile.default.siteSettings.set(.allow, for: .notifications, origin: origin)
        defer { CefProfile.default.siteSettings.set(.default, for: .notifications, origin: origin) }
        await expect("\(label): a page's notification still shows") {
            let result = try await browser.evaluateJavaScript("""
                new Promise(resolve => {
                  const n = new Notification('CefSwift', { body: 'SelfTest' });
                  n.onshow = () => { n.close(); resolve('shown ' + Notification.permission); };
                  n.onerror = () => resolve('error ' + Notification.permission);
                  setTimeout(() => resolve('no event ' + Notification.permission), 5000);
                })
                """).stringValue ?? ""
            return (result == "shown granted", result)
        }
        let after = SystemPromptWatch.shared.snapshot
        check("\(label): … without the user notification center either",
              after.isClean, detail: "\(after)")
    }

    /// What the unified log recorded for this app's bundle, the app and
    /// its helpers, since `since`: no connection to `usernoted`, and no TCC
    /// request but silent preflights (`CGPreflightListenEventAccess`,
    /// which never prompts).
    static func unifiedLogChecks(label: String, since: Date) {
        let app = Bundle.main.bundlePath
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let start = formatter.string(from: since.addingTimeInterval(-1))
        guard let notifications = unifiedLog(start: start, predicate: #"process == "usernoted" AND eventMessage CONTAINS "Connection ""#),
              let tcc = unifiedLog(
                start: start, predicate: #"process == "tccd" AND (eventMessage CONTAINS "AUTHREQ_ATTRIBUTION" OR eventMessage CONTAINS "AUTHREQ_CTX")"#)
        else {
            skip("\(label): the unified log shows no notification or TCC request", because: "`log show` is not available", .environment)
            return
        }
        let connections = notifications.filter { $0.contains(app) }
        check("\(label): the unified log shows no connection to the user notification center",
              connections.isEmpty, detail: connections.prefix(2).joined(separator: " | "))
        // The requests the app's processes made themselves: tccd names the
        // requesting binary in the request's attribution, and its kind in
        // the request's context, by message id.
        func messageID(_ line: String) -> Substring? {
            guard let range = line.range(of: "msgID=") else { return nil }
            return line[range.upperBound...].prefix { $0 != "," }
        }
        let ours = Set(tcc.filter { line in
            guard let requesting = line.range(of: "requesting={") else { return false }
            return line[requesting.upperBound...].prefix { $0 != "}" }.contains(app)
        }.compactMap(messageID))
        let requests = tcc.filter { $0.contains("AUTHREQ_CTX") && messageID($0).map(ours.contains) == true }
        let prompting = requests.filter { !$0.contains("preflight=yes") }
        check("\(label): the unified log shows no TCC request but silent preflights", prompting.isEmpty,
              detail: prompting.prefix(2).joined(separator: " | "))
        if !requests.isEmpty {
            let services = Set(requests.compactMap { line in
                line.range(of: "service=").map { String(line[$0.upperBound...].prefix { $0 != "," }) }
            })
            print("NOTE \(label): TCC preflights: \(services.sorted().joined(separator: ", "))")
        }
    }

    private static func unifiedLog(start: String, predicate: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--start", start, "--style", "compact", "--predicate", predicate]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// Counts what this process asks of macOS's notification centers, and the
/// launches of the Alerts helper, from before Chromium starts. Getting a
/// center object is not counted: AppKit itself gets one as the app
/// finishes launching, which asks nothing. Authorization requests are
/// answered "not granted" here, without asking macOS.
final class SystemPromptWatch: Sendable {
    static let shared = SystemPromptWatch()

    struct Use: Sendable, CustomStringConvertible {
        /// Calls that reach `usernoted`, by selector.
        var notificationCenterCalls: [String] = []
        var authorizationRequests = 0
        var alertsHelperLaunches = 0
        var isClean: Bool { notificationCenterCalls.isEmpty && authorizationRequests == 0 && alertsHelperLaunches == 0 }
        var description: String {
            "center calls [\(notificationCenterCalls.joined(separator: ", "))], "
                + "\(authorizationRequests) authorization requests, \(alertsHelperLaunches) Alerts helper launches"
        }
    }

    private let use = OSAllocatedUnfairLock(initialState: Use())
    private let seenHelpers = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    var snapshot: Use { use.withLock { $0 } }

    /// Installs the counters and starts watching for the Alerts helper.
    func install() {
        let center: AnyClass = UNUserNotificationCenter.self
        // What Chromium's notification services do with a center, each a
        // method taking one object (a delegate, a set, a completion block).
        let calls: [(AnyClass?, String)] = [
            (center, "setDelegate:"),
            (center, "setNotificationCategories:"),
            (center, "getNotificationSettingsWithCompletionHandler:"),
            (center, "getDeliveredNotificationsWithCompletionHandler:"),
            (center, "getNotificationCategoriesWithCompletionHandler:"),
            // Deprecated, and what Chromium's older alert service uses.
            (NSClassFromString("NSUserNotificationCenter"), "setDelegate:"),
            (NSClassFromString("NSUserNotificationCenter"), "deliverNotification:"),
        ]
        for case (let type?, let name) in calls {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(type, selector) else { continue }
            typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
            let label = "\(NSStringFromClass(type)).\(name)"
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { object, argument in
                SystemPromptWatch.shared.use.withLock { $0.notificationCenterCalls.append(label) }
                original(object, selector, argument)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        // Getting a center, by Chromium; AppKit gets one itself as the app
        // finishes launching.
        let getters: [(AnyClass?, String)] = [
            (center, "currentNotificationCenter"),
            (NSClassFromString("NSUserNotificationCenter"), "defaultUserNotificationCenter"),
        ]
        for case (let type?, let name) in getters {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(type, selector) else { continue }
            typealias Getter = @convention(c) (AnyClass, Selector) -> AnyObject
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let label = "\(NSStringFromClass(type)).\(name)"
            let replacement: @convention(block) (AnyClass) -> AnyObject = { type in
                if Thread.callStackSymbols.contains(where: { $0.contains("Chromium Embedded Framework") }) {
                    SystemPromptWatch.shared.use.withLock { $0.notificationCenterCalls.append(label) }
                }
                return original(type, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let request = NSSelectorFromString("requestAuthorizationWithOptions:completionHandler:")
        if let method = class_getInstanceMethod(center, request) {
            let replacement: @convention(block) (AnyObject, UInt, @escaping (Bool, Error?) -> Void) -> Void = { _, _, completion in
                SystemPromptWatch.shared.use.withLock { $0.authorizationRequests += 1 }
                completion(false, nil)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        // The helper runs for a fraction of a second when it starts for
        // nothing; look often.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(15))
        timer.setEventHandler { SystemPromptWatch.shared.lookForAlertsHelper() }
        timer.resume()
        Self.timer.withLock { $0 = timer }
    }

    private static let timer = OSAllocatedUnfairLock<DispatchSourceTimer?>(uncheckedState: nil)

    private func lookForAlertsHelper() {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var name = [UInt8](repeating: 0, count: 256)
            let length = proc_name(pid, &name, UInt32(name.count))
            guard String(decoding: name.prefix(Int(max(length, 0))), as: UTF8.self).hasSuffix("(Alerts)") else { continue }
            let isNew = seenHelpers.withLock { $0.insert(pid).inserted }
            if isNew { use.withLock { $0.alertsHelperLaunches += 1 } }
        }
    }
}
