/// Code that sets up every browser created with a configuration: once
/// Chromium has created the browser, again when it is restored after a
/// discard, and lets go when it closes.
///
/// Add attachments to ``CefBrowser/Configuration/attachments``. One
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
/// While CefKit waits for ``browserDidCreate(_:)`` or
/// ``browserDidRestore(_:)``, the browser is not ready
/// (``CefBrowser/ready()``), yet DevTools calls and JavaScript made from
/// that method, and from tasks it starts, go through.
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
    /// then the opener's window's ``CefBrowserWindow/onPopup``), but the
    /// page cannot script it: `window.open` returns `null`, the popup has
    /// no `window.opener`, and a popup without a URL is refused. Browsers
    /// Chromium opens without a page asking, such as a tab from Chrome's
    /// own UI, have the default configuration and so no attachments.
    var preparesBeforeFirstDocument: Bool { get }

    /// Chromium has created the browser, and its first page has not
    /// started loading. With ``preparesBeforeFirstDocument``, the page
    /// waits until this returns.
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
