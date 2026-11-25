import AppKit
import CCef
import Foundation
import Observation
import CefBase

/// Process-wide CEF lifecycle: loading the framework, `cef_initialize`, the
/// message pump, the set of live pages, and shutdown.
///
/// SwiftUI apps get all of this from `CefSwiftApp`. In an AppKit app, call
/// ``initialize(configuration:)`` first thing in `main`, before anything
/// touches `NSApp`.
@MainActor
@Observable
public final class CefRuntime {
    public static let shared = CefRuntime()

    /// Where the runtime is in its one life per process.
    public enum State: Sendable, Equatable {
        /// ``initialize(configuration:)`` has not been called, or failed
        /// before Chromium started.
        case notStarted
        /// ``initialize(configuration:)`` is running.
        case starting
        /// Chromium is running; pages can be created.
        case running
        /// The app is quitting and Chromium is shutting down.
        case stopping
        /// Chromium has shut down. It cannot start again in this process.
        case stopped

        /// Throws unless the runtime can start from this state.
        func checkCanStart() throws(CefError) {
            switch self {
            case .notStarted: return
            case .starting, .running: throw CefError.alreadyInitialized
            case .stopping, .stopped: throw CefError.shutDown
            }
        }
    }

    /// Where the runtime is in its life: ``State/running`` from a successful
    /// ``initialize(configuration:)`` until the app quits.
    public private(set) var state = State.notStarted

    /// Whether Chromium is running (``state`` is ``State/running``).
    public var isRunning: Bool { state == .running }

    /// The configuration CEF was initialized with.
    public private(set) var configuration: CefRuntime.Configuration?

    /// The locale of Chromium's own interface, such as `"fr"`, `"pt-BR"` or
    /// `"en-US"`: ``CefRuntime/Configuration/localization`` resolved to a locale the
    /// bundle has strings for. `nil` until Chromium runs.
    public private(set) var locale: String?

    /// Every live page in the process, in creation order — including
    /// popups and tabs opened through Chrome's own UI.
    public private(set) var pages: [CefPage] = []

    /// Called for each page Chromium creates on its own initiative: a
    /// native popup, a DevTools window, a tab or window opened through
    /// Chrome's UI. Assign a delegate here to manage those pages.
    ///
    /// A page ``onChromeTab`` decides about reaches this closure only
    /// when the answer is ``CefChromeTabDecision/showInChromeWindow``.
    @ObservationIgnored public var onPageCreated: ((CefPage) -> Void)?

    /// Called when the app is launched again while it is running — from
    /// the command line, or by another app — with the new launch's
    /// arguments (without the program path) and its working directory.
    ///
    /// Only one instance can use a cache directory, so the second launch
    /// hands its arguments over to this one and exits. Open a window, or
    /// the URLs among the arguments:
    ///
    /// ```swift
    /// CefRuntime.shared.onRelaunch = { arguments, _ in
    ///     let urls = arguments.compactMap(URL.init(string:)).filter { $0.scheme != nil }
    ///     urls.isEmpty ? openTab(nil) : urls.forEach(openTab)
    /// }
    /// ```
    ///
    /// When `nil`, the running app is brought to the front.
    @ObservationIgnored public var onRelaunch: ((_ arguments: [String], _ workingDirectory: URL?) -> Void)?

    func handleRelaunch(arguments: [String], workingDirectory: URL?) {
        // Not from inside Chromium's callback, which may open windows.
        DispatchQueue.main.async {
            NSApp.activate()
            self.onRelaunch?(arguments, workingDirectory)
        }
    }

    @ObservationIgnored var messagePump: CefMessagePump?
    @ObservationIgnored private var appContext: CefAppContext?
    @ObservationIgnored private var settings: MappedCefSettings?
    @ObservationIgnored private var pagesByIdentifier: [Int32: CefPage] = [:]
    @ObservationIgnored private var isTerminationRequested = false
    @ObservationIgnored private var hasRequestedWidevine = false
    /// The Widevine fetch in progress; ``installWidevine()`` callers share it.
    @ObservationIgnored var widevineInstallation: Task<CefRuntime.WidevineState, Never>?

    private init() {}

    /// Initializes CEF in the page (main) process. Call once, on the main
    /// thread, before creating pages and before anything else creates
    /// `NSApp` — CEF needs the application object to be a `CefApplication`,
    /// which this installs.
    ///
    /// Call it before the app starts work on other threads, too: loading the
    /// framework makes Chromium's allocator the default malloc zone, and
    /// memory another thread frees while the zones are swapped traps.
    ///
    /// Throws ``CefError/alreadyInitialized`` when Chromium is running, and
    /// ``CefError/shutDown`` once it has shut down: Chromium starts once per
    /// process.
    public func initialize(configuration: CefRuntime.Configuration = .init()) throws(CefError) {
        try state.checkCanStart()
        state = .starting
        do {
            try start(configuration: configuration)
        } catch {
            // Chromium cannot start a second time once `cef_initialize` ran.
            state = error.isBeforeChromiumStarted ? .notStarted : .stopped
            throw error
        }
        state = .running
        lifecycleCoordinator.start()
        // Profiles apply the rest as each is first used.
        preferences.apply(configuration.effectivePreferences)
        logCapabilities()
    }

    private func start(configuration: CefRuntime.Configuration) throws(CefError) {
        CefApplication.install()

        let frameworkBinary = try Self.resolveFrameworkBinary(override: configuration.frameworkDirectory)
        guard ccef_load_framework(frameworkBinary.path) != 0 else {
            throw CefError.loadFailed(String(cString: ccef_loader_error()))
        }
        try Self.verifyAPIHash()

        let pump = CefMessagePump()
        // Pages created through Chrome's own UI have no CefPage asking
        // for them; this client adopts them as they appear.
        let defaultClient = CefBrowserClient(page: nil, chromeToolbar: configuration.chromeToolbar)
        let context = CefAppContext(
            configuration: configuration, pump: pump, defaultClient: defaultClient.makeClient())
        let frameworkDirectory = frameworkBinary.deletingLastPathComponent()
        // Chromium loads whatever pack it is told to, and cannot start
        // without one: ask only for a pack the framework has.
        let packs = ChromiumLocales.packs(inResources: frameworkDirectory.appendingPathComponent("Resources"))
        let locale = configuration.localization.resolve(packs: packs)?.locale
        let mapped = MappedCefSettings(
            configuration: configuration, frameworkDirectory: frameworkDirectory, locale: locale)

        // Kept for the life of the process, as the real argv is.
        let arguments = CefCommandLine.chromiumArguments(from: CommandLine.arguments)
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        argv.initialize(from: arguments.map { strdup($0) } + [nil], count: arguments.count + 1)
        var mainArgs = cef_main_args_t(argc: Int32(arguments.count), argv: argv)
        guard cef_initialize(&mainArgs, &mapped.raw, context.makeApp(), nil) != 0 else {
            let exitCode = cef_get_exit_code()
            if exitCode == CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED.rawValue {
                throw CefError.anotherInstanceRunning
            }
            throw CefError.initializationFailed(exitCode: exitCode)
        }

        appContext = context
        settings = mapped
        CefBridge.localSchemes = Set(["file"] + configuration.customSchemes
            .filter { $0.options.contains(.local) }.map { $0.name.lowercased() })
        self.locale = locale ?? "en-US"
        self.configuration = configuration
        messagePump = pump
        pump.start()
    }

    /// Logs one line naming what the app's signature leaves out, such as
    /// the keychain for safe storage; at info level when nothing is.
    private func logCapabilities() {
        let capabilities = CefAppCapabilities.current
        let limitations = capabilities.limitationsSummary()
        if let limitations {
            CefLog.notice(limitations)
        }
        CefLog.info("CefSwift: Chromium's sandbox is \(configuration?.isSandboxEnabled == true ? "on" : "off"); " +
                    "locale \(locale ?? "en-US")")
        if limitations == nil {
            CefLog.info("CefSwift: signed \(capabilities.signature.rawValue), team " +
                        "\(capabilities.teamIdentifier ?? "none")")
        }
    }

    /// Opens a window drawn entirely by Chrome — tab strip, omnibox, menus,
    /// extension toolbar — showing `url`. The fastest route to a complete
    /// page; trim or rebrand it with ``CefRuntime/Configuration/chromeToolbar`` and
    /// ``CefRuntime/Configuration/productName``.
    ///
    /// Tabs and windows the user opens from there are reported through
    /// ``onPageCreated`` and listed in ``pages``. The returned
    /// page holds `delegate` weakly, like ``CefPage/delegate``; keep
    /// your own reference to it.
    @discardableResult
    public func openChromeWindow(
        url: URL, frame: CGRect? = nil, configuration: CefPage.Configuration = .init(), delegate: CefPageDelegate? = nil
    ) -> CefPage {
        let page = CefPage(url: url, configuration: configuration, delegate: delegate)
        page.createInChromeUIWindow(frame: frame)
        return page
    }

    // MARK: Custom scheme handlers

    /// Registers `handler` as the content source for `scheme` (optionally
    /// restricted to `domain` for standard schemes). Call after
    /// ``initialize(configuration:)``; for custom (non-built-in) schemes the
    /// scheme must also be declared in ``CefRuntime/Configuration/customSchemes``.
    /// Registering again for the same scheme/domain replaces the handler.
    ///
    /// The handler serves every profile, present and future: the default
    /// one, and the ``CefProfile/incognito()`` and
    /// ``CefProfile/persistent(id:displayName:)`` profiles, whose request
    /// contexts Chromium keeps separately. A profile's own handler for the
    /// same scheme and domain (``CefProfile/registerSchemeHandler(scheme:domain:handler:)``)
    /// takes its place in that profile.
    public func registerSchemeHandler(scheme: String, domain: String? = nil, handler: some CefSchemeHandler) {
        precondition(
            isRunning,
            "CefRuntime.registerSchemeHandler requires initialize() to have succeeded first."
        )
        let factory = SchemeHandlerFactory(handler: handler)
        // cef_register_scheme_handler_factory consumes our +1 factory ref.
        let factoryPointer = factory.makeFactory()
        let registered = CefStringUtil.withCefString(scheme) { cefScheme in
            if let domain {
                return CefStringUtil.withCefString(domain) { cefDomain in
                    cef_register_scheme_handler_factory(cefScheme, cefDomain, factoryPointer)
                }
            }
            return cef_register_scheme_handler_factory(cefScheme, nil, factoryPointer)
        }
        if registered == 0 {
            CefLog.error("cef_register_scheme_handler_factory failed for scheme '\(scheme)'")
        }
        schemeHandlers.removeAll { $0.scheme == scheme && $0.domain == domain }
        schemeHandlers.append(RegisteredSchemeHandler(scheme: scheme, domain: domain, factory: factory))
        CefProfile.registerSchemeHandler(schemeHandlers[schemeHandlers.count - 1])
        // The default profile's context shares the global context's
        // registrations, so its own handler goes back in place.
        if let own = CefProfile.default.schemeHandlers.first(where: { $0.scheme == scheme && $0.domain == domain }) {
            CefProfile.default.register(own)
        }
    }

    /// Removes the handler ``registerSchemeHandler(scheme:domain:handler:)``
    /// registered for `scheme` and `domain`, from every profile that has
    /// no handler of its own for them.
    public func removeSchemeHandler(scheme: String, domain: String? = nil) {
        guard isRunning, schemeHandlers.contains(where: { $0.scheme == scheme && $0.domain == domain }) else { return }
        schemeHandlers.removeAll { $0.scheme == scheme && $0.domain == domain }
        if !CefProfile.default.schemeHandlers.contains(where: { $0.scheme == scheme && $0.domain == domain }) {
            CefStringUtil.withCefString(scheme) { cefScheme in
                if let domain {
                    _ = CefStringUtil.withCefString(domain) { cef_register_scheme_handler_factory(cefScheme, $0, nil) }
                } else {
                    _ = cef_register_scheme_handler_factory(cefScheme, nil, nil)
                }
            }
        }
        CefProfile.unregisterSchemeHandler(scheme: scheme, domain: domain)
    }

    /// A scheme handler registered with ``registerSchemeHandler(scheme:domain:handler:)``.
    struct RegisteredSchemeHandler {
        var scheme: String
        var domain: String?
        var factory: SchemeHandlerFactory
    }

    /// Every registered scheme handler, for profiles that create their
    /// request context later.
    @ObservationIgnored private(set) var schemeHandlers: [RegisteredSchemeHandler] = []

    /// Shuts Chromium down, at the end of a quit that
    /// ``handleTerminationRequest()`` started once every page and window
    /// has gone. Never from inside a Chromium callback, and never with a
    /// CEF window left, which crashes `cef_shutdown()`.
    ///
    /// Tears down in order: the shutdown participants (such as service
    /// hosts and media router registrations), observers and timers, profile
    /// request contexts, the message pump, then Chromium itself, with jobs
    /// for the thread actors waiting it out.
    ///
    /// The framework stays loaded (the loader has no unload), and CEF
    /// cannot start again in the same process: the state ends at
    /// ``State/stopped`` and a later ``initialize(configuration:)`` throws.
    func shutDownChromium() {
        guard state == .running || state == .stopping else { return }
        guard hasNoPages, CefWindow.liveCount == 0, messagePump?.isPerformingWork != true else {
            CefLog.error("CefSwift: shutdown deferred: \(pages.count + servicePages.count) browsers, "
                         + "\(CefWindow.liveCount) windows still open")
            return
        }
        state = .stopping
        closePagesAwaitingProfiles()
        requestsInFlightAtShutdown = URLRequestRegistry.shared.count
        let participants = shutdownParticipants.compactMap(\.participant)
        shutdownParticipants = []
        participants.forEach { $0.runtimeWillShutDown() }
        lifecycleCoordinator.stop()
        widevineInstallation?.cancel()
        CefProfile.releaseRequestContexts()
        messagePump?.stop()
        messagePump = nil
        CefThreadExecutor.all.forEach { $0.willStop() }
        // Chromium 158 queues an AppKit occlusion check when its last window
        // closes. AppKit may fire it in its termination run loop after CEF
        // has destroyed the content client it consults.
        let checkerType = NSClassFromString("WebContentsOcclusionCheckerMac") as? NSObject.Type
        let sharedInstance = NSSelectorFromString("sharedInstance")
        let checker: AnyObject? = checkerType.flatMap { type in
            guard class_getClassMethod(type, sharedInstance) != nil else { return nil }
            return type.perform(sharedInstance)?.takeUnretainedValue()
        }
        cef_shutdown()
        if let checker {
            NSObject.cancelPreviousPerformRequests(
                withTarget: checker, selector: NSSelectorFromString("performOcclusionStateUpdates"), object: nil)
        }
        CefThreadExecutor.all.forEach { $0.didStop() }
        appContext = nil
        settings = nil
        state = .stopped
    }

    /// Adds `participant`, held weakly, to the objects that release what
    /// they hold of Chromium when it shuts down; see
    /// ``CefShutdownParticipant``. Adding one twice adds it once.
    func addShutdownParticipant(_ participant: any CefShutdownParticipant) {
        shutdownParticipants.removeAll { $0.participant == nil }
        guard !shutdownParticipants.contains(where: { $0.participant === participant }) else { return }
        shutdownParticipants.append(WeakShutdownParticipant(participant: participant))
    }

    private struct WeakShutdownParticipant {
        weak var participant: (any CefShutdownParticipant)?
    }

    @ObservationIgnored private var shutdownParticipants: [WeakShutdownParticipant] = []

    /// Called once as the app starts to quit, before the runtime closes
    /// the pages: a module built on CefKit closes what it keeps its own
    /// way first. Chromium is still fully running.
    package func whenQuitStarts(_ observer: @escaping @MainActor () -> Void) {
        terminationObservers.append(observer)
    }

    @ObservationIgnored private var terminationObservers: [@MainActor () -> Void] = []

    // MARK: Page registry / termination

    func register(_ page: CefPage) {
        lifecycleCoordinator.setNeedsUpdate()
        // A DevTools window's page comes and goes like any other.
        defer { CefPage.refreshDevToolsStates() }
        pagesByIdentifier[page.identifier] = page
        // Internal-page service pages stay out of the public list. A
        // page restored after a discard is listed already.
        if servicePageIDs.contains(page.id) {
            servicePages.append(page)
        } else if !pages.contains(where: { $0 === page }) {
            pages.append(page)
        }
        // Chromium's update service starts fetching once a page exists;
        // ask for Widevine then rather than at its first scheduled run, a
        // minute after launch.
        if !hasRequestedWidevine, let configuration, configuration.services.protectedMedia != .disabled {
            hasRequestedWidevine = true
            if !widevine.isInstalled { Task { _ = try? await installWidevine() } }
        }
    }

    /// A page discarded by closing its Chromium page: Chromium's
    /// identifier goes, the page stays in ``pages``.
    func forgetIdentifier(of page: CefPage) {
        if pagesByIdentifier[page.identifier] === page {
            pagesByIdentifier[page.identifier] = nil
        }
        continueTerminationIfReady()
    }

    func unregister(_ page: CefPage) {
        defer { CefPage.refreshDevToolsStates() }
        pagesByIdentifier[page.identifier] = nil
        page.lifecycle = .hidden
        if pages.contains(where: { $0 === page }) {
            pages.removeAll { $0 === page }
            let profile = page.configuration.profile ?? .default
            if !pages.contains(where: { ($0.configuration.profile ?? .default) === profile }) {
                profile.lastPageDidClose()
            }
        }
        servicePages.removeAll { $0 === page }
        servicePageIDs.remove(page.id)
        continueTerminationIfReady()
    }

    /// Resumes a quit that was waiting for pages and their windows to
    /// close. Chromium finishes destroying a window after its page has
    /// gone, and shutting down before that, or from inside one of its
    /// callbacks, crashes in `cef_shutdown()`; so `terminate:` is retried
    /// from the run loop once nothing is left.
    func continueTerminationIfReady() {
        guard isTerminationRequested, hasNoPages, CefWindow.liveCount == 0 else { return }
        DispatchQueue.main.async {
            self.replyToQuitEvent(cancelled: false)
            NSApp.terminate(nil)
        }
    }

    private var hasNoPages: Bool { pages.isEmpty && servicePages.isEmpty }

    /// Whether the profile requests in flight have been cancelled and have
    /// released their CEF references, the last step before shutdown.
    @ObservationIgnored private var requestsDrained = false
    @ObservationIgnored private var requestDrain: Task<Void, Never>?

    /// How many profile requests still held CEF references when shutdown
    /// began; zero once the drain has done its work. For tests.
    @ObservationIgnored @_spi(Testing) public private(set) var requestsInFlightAtShutdown: Int?

    /// Cancels the profile requests in flight on the IO thread, then quits
    /// again. Gives up waiting after a few seconds, so a stuck IO thread
    /// cannot stop the app from quitting; `shutDownChromium()` then cancels
    /// what is left without waiting, as before.
    private func drainRequests() {
        guard requestDrain == nil else { return }
        requestDrain = Task {
            // Whichever ends first: the drain, or the time limit.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = CefResumeOnce(continuation, fallback: ())
                Task {
                    await URLRequestRegistry.shared.drainForShutdown()
                    once.resume(returning: ())
                }
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    once.resume(returning: ())
                }
            }
            if URLRequestRegistry.shared.count > 0 {
                CefLog.error("CefSwift: \(URLRequestRegistry.shared.count) requests had not ended at shutdown")
            }
            requestsDrained = true
            requestDrain = nil
            NSApp.terminate(nil)
        }
    }

    /// A page asked to stay open while quitting: the quit is abandoned, so
    /// closing the last window later does not end the app.
    func cancelTermination() {
        isTerminationRequested = false
        replyToQuitEvent(cancelled: true)
    }

    /// The quit Apple Event (from logging out, restarting, shutting down,
    /// or another app) the app is answering by closing its pages.
    @ObservationIgnored private var suspendedQuitEvent: NSAppleEventManager.SuspensionID?

    /// Holds back the reply to a quit Apple Event until the pages have
    /// closed, as `NSApplication.TerminateReply.terminateLater` does. The
    /// sender, such as loginwindow, then waits for the answer instead of
    /// reading an early reply.
    private func suspendQuitEventIfNeeded() {
        let manager = NSAppleEventManager.shared()
        guard suspendedQuitEvent == nil, let event = manager.currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication)
        else { return }
        suspendedQuitEvent = manager.suspendCurrentAppleEvent()
    }

    /// Answers a held quit event: done, or cancelled by a page that asked
    /// to stay, which makes a logout or restart stop as it does when an
    /// app cancels it.
    private func replyToQuitEvent(cancelled: Bool) {
        guard let suspension = suspendedQuitEvent else { return }
        suspendedQuitEvent = nil
        let manager = NSAppleEventManager.shared()
        if cancelled {
            manager.replyAppleEvent(forSuspensionID: suspension)
                .setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: AEKeyword(keyErrorNumber))
        }
        manager.resume(withSuspensionID: suspension)
    }

    func page(withIdentifier identifier: Int32) -> CefPage? {
        pagesByIdentifier[identifier]
    }

    /// Called from `CefApplication.terminate(_:)`. Quitting closes every
    /// page first (so pages can run `beforeunload` and state is flushed),
    /// then terminates once the last one is gone.
    func handleTerminationRequest() -> Bool {
        guard isRunning else { return true }
        // Pages waiting for a profile Chromium is still loading are in
        // no list below, and their profile could load during the quit:
        // they close now, and their ready() throws pageClosed.
        closePagesAwaitingProfiles()
        if !isTerminationRequested {
            // Modules close what they keep their own way first: CefChromium
            // closes Chromium's windows as windows, which Chromium records.
            let observers = terminationObservers
            terminationObservers = []
            observers.forEach { $0() }
        }
        isTerminationRequested = true
        // Pages discarded by closing them have nothing left in Chromium.
        for page in pages where page.isDiscarded && page.raw == nil {
            page.handleClosed()
        }
        if hasNoPages {
            // Not from inside Chromium's message loop work, where a Chrome
            // command or a page may have asked to quit.
            guard CefWindow.liveCount == 0, messagePump?.isPerformingWork != true else {
                suspendQuitEventIfNeeded()
                CefWindow.all.forEach { $0.close() }
                continueTerminationIfReady()
                return false
            }
            // Requests in flight end on the IO thread first; quitting
            // carries on once they have.
            guard requestsDrained else {
                suspendQuitEventIfNeeded()
                drainRequests()
                return false
            }
            replyToQuitEvent(cancelled: false)
            shutDownChromium()
            return true
        }
        suspendQuitEventIfNeeded()
        for page in pages {
            page.close()
        }
        for page in servicePages {
            page.close(force: true)
        }
        return false
    }

    // MARK: Pages waiting for their profile

    private struct WeakPage {
        weak var page: CefPage?
    }

    /// Pages whose creation waits for their profile to load: Chromium
    /// has nothing of them yet, so they are not in ``pages``.
    @ObservationIgnored private var pagesAwaitingProfiles: [WeakPage] = []

    func pageAwaitsProfile(_ page: CefPage) {
        pagesAwaitingProfiles.removeAll { $0.page == nil }
        guard !pagesAwaitingProfiles.contains(where: { $0.page === page }) else { return }
        pagesAwaitingProfiles.append(WeakPage(page: page))
    }

    func pageStoppedAwaitingProfile(_ page: CefPage) {
        pagesAwaitingProfiles.removeAll { $0.page == nil || $0.page === page }
    }

    /// The number of pages waiting for their profile. For tests.
    @_spi(Testing) public var pagesAwaitingProfilesCount: Int {
        pagesAwaitingProfiles.filter { $0.page != nil }.count
    }

    private func closePagesAwaitingProfiles() {
        let waiting = pagesAwaitingProfiles.compactMap(\.page)
        pagesAwaitingProfiles = []
        // Each closes as a page not created yet does: `handleClosed()`.
        waiting.forEach { $0.close(force: true) }
    }

    // MARK: Service pages (internal-page data APIs)

    /// Live service pages: hidden, created by CefKit itself, and left out
    /// of ``pages``.
    @ObservationIgnored private var servicePages: [CefPage] = []

    /// The hidden pages of internal-page services that are open.
    @_spi(Testing) public var openServicePages: [CefPage] { servicePages }
    @ObservationIgnored private var servicePageIDs: Set<CefPage.ID> = []

    /// Marks `page` as a service page. Call before it is created.
    func registerServicePage(_ page: CefPage) {
        servicePageIDs.insert(page.id)
    }

    /// Whether `page` is one of CefKit's hidden service pages, which
    /// get none of their profile's page policy.
    func isServicePage(_ page: CefPage) -> Bool {
        servicePageIDs.contains(page.id)
    }

    /// Whether the app is quitting, so no new service pages should start.
    package var isTerminating: Bool { isTerminationRequested }

    // MARK: Energy policy

    /// When CefKit spends less energy on its own. `.automatic`, the
    /// default, lowers offscreen pages' frame rate to 30 while Low Power
    /// Mode is on or the Mac is under serious thermal pressure.
    ///
    /// ```swift
    /// CefRuntime.shared.energyPolicy = .disabled   // a game or video player
    /// ```
    public var energyPolicy: CefRuntime.EnergyPolicy {
        get { lifecycleCoordinator.energyPolicy }
        set { lifecycleCoordinator.energyPolicy = newValue }
    }

    /// Low Power Mode and the thermal state as the energy policy should see
    /// them, instead of the system's, until
    /// ``stopSimulatingEnergyConditions()``.
    @_spi(Testing) public func simulateEnergyConditions(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) {
        lifecycleCoordinator.simulatedConditions = CefEnergyConditions(
            isLowPowerModeEnabled: lowPowerMode, thermalState: thermalState)
    }

    @_spi(Testing) public func stopSimulatingEnergyConditions() {
        lifecycleCoordinator.simulatedConditions = nil
    }

    /// Follows windows, the app and the system, and publishes each
    /// page's ``CefPage/lifecycle``.
    @ObservationIgnored private(set) lazy var lifecycleCoordinator = CefLifecycleCoordinator()

    /// Discards Chrome-style pages through Chromium's own tab discarding.
    @ObservationIgnored private(set) lazy var tabDiscarder = CefTabDiscarder()
}
