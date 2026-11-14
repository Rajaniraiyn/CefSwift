/// Code that sets up every browser created with a configuration: once
/// Chromium has created the browser, again when it is restored after a
/// discard, and lets go when it closes.
///
/// Add attachments to ``CefBrowser/Configuration/attachments``, or to
/// ``CefProfile/attachments`` for every page of a profile. One
/// attachment object serves every browser made with that configuration,
/// popups included, since a popup gets its opener's configuration; keep
/// what belongs to one browser keyed by the browser, and drop it in
/// ``browserDidClose(_:)``.
///
/// ```swift
/// final class ConsoleRecorder: CefBrowserAttachment {
///     private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
///
///     func browserDidCreate(_ browser: CefBrowser) async {
///         let messages = browser.devTools.events("Runtime.consoleAPICalled")
///         try? await browser.devTools.send("Runtime.enable")
///         tasks[ObjectIdentifier(browser)] = Task {
///             for await message in messages { print(message["type"].stringValue ?? "") }
///         }
///     }
///
///     func browserDidClose(_ browser: CefBrowser) {
///         tasks.removeValue(forKey: ObjectIdentifier(browser))?.cancel()
///     }
/// }
///
/// var configuration = CefBrowser.Configuration()
/// configuration.attachments = [ConsoleRecorder()]
/// ```
///
/// For each creation of a browser, every attachment is told once, in
/// order: ``browserDidCreate(_:)``, then ``browserDidRestore(_:)`` each
/// time it is created anew after a discard, then ``browserDidClose(_:)``
/// once it closes. A browser that closes before Chromium created it, or
/// while an earlier attachment set it up, is closed for every attachment,
/// including those not told of its creation.
///
/// ``CefBrowser/ready()`` waits for attachments only when the browser is
/// held for them: when one of its attachments
/// ``preparesBeforeFirstDocument``, every attachment is told of the
/// creation before the first page, and the browser is ready once all have
/// returned; after a discard, it is ready once every
/// ``browserDidRestore(_:)`` has returned. Meanwhile DevTools calls and
/// JavaScript made from those methods, and from tasks they start, go
/// through. Otherwise the browser is ready as Chromium creates it, and
/// attachments are told of the creation as it becomes ready, without
/// holding anything: a caller of `ready()` may see an attachment still
/// setting up.
@MainActor
public protocol CefBrowserAttachment: AnyObject {
    /// Whether no page may run in the browser before
    /// ``browserDidCreate(_:)`` returns. The default is `false`.
    ///
    /// When any of a browser's attachments needs this, the browser starts
    /// blank and loads its first page only once every attachment has been
    /// told of its creation. A native popup cannot be held that way:
    /// Chromium creates it and runs its first document at once. So a
    /// page's popups, new tabs and windows that the delegate lets Chromium
    /// open (``CefWindowOpenDecision/allowNativePopup``) open instead in a
    /// browser CefKit creates with the opener's configuration. That popup
    /// arrives as a native one does (``CefBrowserDelegate/browser(_:didOpen:)``,
    /// then the opener's window's ``CefWindow/onPopup``), but the
    /// page cannot script it: `window.open` returns `null`, the popup has
    /// no `window.opener`, and a popup without a URL is refused. Browsers
    /// Chromium opens without a page asking, such as a tab from Chrome's
    /// own UI, have the default configuration, so only their profile's
    /// attachments (``CefProfile/attachments``) set them up.
    var preparesBeforeFirstDocument: Bool { get }

    /// Chromium has created the browser. When any of the browser's
    /// attachments ``preparesBeforeFirstDocument``, its first page waits
    /// until every attachment's call has returned; otherwise the page may
    /// already be loading.
    ///
    /// The browser can close while this runs; ``browserDidClose(_:)`` is
    /// then called before it returns. Attachments later in the list are
    /// not told of a browser that has closed.
    func browserDidCreate(_ browser: CefBrowser) async

    /// The browser was created anew after a discard. Its page loads again
    /// once this returns. DevTools domains enabled through
    /// ``CefBrowser/devTools`` are enabled again by then, and its event
    /// streams go on, but whatever the old Chromium browser held, such as
    /// scripts added with `Page.addScriptToEvaluateOnNewDocument`, went
    /// with it. The default does nothing.
    func browserDidRestore(_ browser: CefBrowser) async

    /// The browser has closed, before its DevTools session ends. Not
    /// called for a discard, which keeps the browser.
    func browserDidClose(_ browser: CefBrowser)
}

extension CefBrowserAttachment {
    public var preparesBeforeFirstDocument: Bool { false }
    public func browserDidCreate(_ browser: CefBrowser) async {}
    public func browserDidRestore(_ browser: CefBrowser) async {}
    public func browserDidClose(_ browser: CefBrowser) {}
}
