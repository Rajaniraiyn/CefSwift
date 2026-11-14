import os
import CCef
import Foundation
import CefBase

// MARK: - What a profile decides for its pages

/// A profile holds the defaults for every page in it, those the app
/// creates and those Chromium creates itself (native popups, tabs and
/// windows from Chrome's UI, extension pages): its request filter, scheme
/// handlers, user scripts, bridges and attachments here, its
/// ``CefProfile/delegate`` for permissions and downloads, and its
/// ``CefProfile/configuration``. A page adds to them or overrides them
/// where its ``CefBrowser/Configuration`` or delegate says; see the guide's
/// "What is configured where".
extension CefProfile {
    // MARK: Request filter

    /// Inspects — and may block, redirect or amend — every network request
    /// the profile's pages make, and those of their service and shared
    /// workers, which have no ``CefResourceRequest/frame``. Pages Chromium
    /// creates itself are covered too. A page with a filter of its own
    /// (``CefBrowser/Configuration/requestFilter``) uses that one instead,
    /// for its own requests; its workers' still go through this one.
    ///
    /// The app's own requests (``data(for:configuration:)``,
    /// ``bytes(for:configuration:)``, ``download(for:to:configuration:)``)
    /// are not filtered: CEF does not hand them to a profile's handlers.
    ///
    /// Takes effect for requests that start after it is set. `nil`, the
    /// default, lets every request through without CefKit looking at it.
    ///
    /// ```swift
    /// CefProfile.default.requestFilter = CefRequestFilter(
    ///     hosts: ["ads.example"], resourceTypes: [.script, .image]
    /// ) { _ in .block }
    /// ```
    public var requestFilter: CefRequestFilter? {
        get { requestPolicy.filter?.source }
        set { requestPolicy.filter = newValue.map(CefCompiledRequestFilter.init) }
    }

    // MARK: Scheme handlers

    /// Registers `handler` as the content source for `scheme` (optionally
    /// only for `domain`, for standard schemes) in this profile alone.
    /// It takes the place of a handler registered for the same scheme and
    /// domain with ``CefRuntime/registerSchemeHandler(scheme:domain:handler:)``,
    /// which serves every profile; registering again replaces it. For a
    /// custom scheme, declare it in ``CefRuntime/Configuration/customSchemes``.
    ///
    /// Call it after ``CefRuntime/initialize(configuration:)``; it applies
    /// to requests that start afterwards.
    public func registerSchemeHandler(scheme: String, domain: String? = nil, handler: some CefSchemeHandler) {
        let registered = CefRuntime.RegisteredSchemeHandler(
            scheme: scheme, domain: domain, factory: SchemeHandlerFactory(handler: handler))
        schemeHandlers.removeAll { $0.scheme == scheme && $0.domain == domain }
        schemeHandlers.append(registered)
        register(registered)
    }

    /// Removes the handler ``registerSchemeHandler(scheme:domain:handler:)``
    /// registered for `scheme` and `domain` in this profile. The runtime's
    /// handler for them, if any, serves the profile again.
    public func removeSchemeHandler(scheme: String, domain: String? = nil) {
        guard schemeHandlers.contains(where: { $0.scheme == scheme && $0.domain == domain }) else { return }
        schemeHandlers.removeAll { $0.scheme == scheme && $0.domain == domain }
        if let runtime = CefRuntime.shared.schemeHandlers.first(where: { $0.scheme == scheme && $0.domain == domain }) {
            register(runtime)
        } else {
            registerFactory(nil, scheme: scheme, domain: domain)
        }
    }

    // MARK: Page defaults

    /// Scripts injected into every document of every page of the profile,
    /// before the page's own scripts and those of the page's
    /// configuration (``CefBrowser/Configuration/userScripts``). Pages
    /// Chromium creates itself get them too.
    ///
    /// A change reaches every renderer of the profile's pages as it is
    /// made and applies to documents that start loading afterwards; a
    /// document already loaded keeps what a removed script did, until it
    /// is reloaded.
    public var userScripts: [CefUserScript] {
        get { pageUserScripts }
        set {
            pageUserScripts = newValue
            for page in pages { page.pageScripting.configurationDidChange() }
        }
    }

    /// Bridges exposed to every page of the profile, as
    /// ``CefBrowser/Configuration/bridges`` are to one page. A page's own
    /// bridge of the same name takes the place of the profile's in that
    /// page. A change applies to documents that start loading afterwards.
    public var bridges: [CefBridge] {
        get { pageBridges }
        set {
            pageBridges = newValue
            for page in pages {
                for bridge in newValue { bridge.attach(to: page) }
                page.pageScripting.configurationDidChange()
            }
        }
    }

    /// Code that sets up every page of the profile, before the attachments
    /// of the page's own configuration (``CefBrowserAttachment``). Pages
    /// Chromium creates itself get them too. A page takes the profile's
    /// attachments as it is created; a change applies to pages created
    /// afterwards.
    public var attachments: [any CefBrowserAttachment] {
        get { pageAttachments }
        set { pageAttachments = newValue }
    }

    /// The profile's live pages, Chromium's own included, without CefKit's
    /// hidden ones.
    var pages: [CefBrowser] {
        CefRuntime.shared.browsers.filter { $0.profile === self && $0.state != .closed }
    }
}

// MARK: - The request filter on the IO thread

/// A profile's request filter, which its request context handlers read on
/// the IO thread.
final class CefProfileRequestPolicy: Sendable {
    private let state = OSAllocatedUnfairLock<CefCompiledRequestFilter?>(initialState: nil)

    var filter: CefCompiledRequestFilter? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Owner of a profile's `cef_request_context_handler_t`: it reports when
/// the context is ready and hands each request of the profile with no page
/// filter of its own, a worker's included, to the profile's filter.
///
/// Chromium also asks the app for a handler for each request context it
/// creates itself (`get_default_request_context_handler`), for windows it
/// opens from its own UI; such a handler learns its profile when the
/// context is ready.
final class CefProfileContextHandler: Sendable {
    private let policy: OSAllocatedUnfairLock<CefProfileRequestPolicy?>
    private let onInitialized: (@MainActor @Sendable (_ cachePath: String) -> Void)?

    init(policy: CefProfileRequestPolicy?, onInitialized: (@MainActor @Sendable (_ cachePath: String) -> Void)? = nil) {
        self.policy = OSAllocatedUnfairLock(initialState: policy)
        self.onInitialized = onInitialized
    }

    func makeHandler() -> UnsafeMutablePointer<cef_request_context_handler_t> {
        let handler = cefAllocate(cef_request_context_handler_t.self, owner: self)
        // UI thread.
        handler.pointee.on_request_context_initialized = { s, context in
            defer { cefRelease(context) }
            guard let context, let owner = cefOwner(CefProfileContextHandler.self, s) else { return }
            let path = CefStringUtil.takingUserFree(context.pointee.get_cache_path(context)) ?? ""
            nonisolated(unsafe) let raw = context
            MainActor.assumeIsolated {
                if owner.policy.withLock({ $0 == nil }), let profile = CefProfile.owning(raw) {
                    owner.policy.withLock { $0 = profile.requestPolicy }
                }
                owner.onInitialized?(path)
            }
        }
        // IO thread.
        handler.pointee.get_resource_request_handler = {
            s, browser, frame, request, isNavigation, _, initiator, _ in
            defer {
                cefRelease(browser)
                cefRelease(frame)
                cefRelease(request)
            }
            let filter = cefOwner(CefProfileContextHandler.self, s)?.policy.withLock { $0?.filter }
            return CefResourceRequestHandlers.handler(
                filter: filter, browser: browser, request: request, isNavigation: isNavigation != 0,
                initiator: initiator)
        }
        return handler
    }
}
