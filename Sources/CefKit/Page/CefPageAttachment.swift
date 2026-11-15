/// Code that sets up every page created with a configuration: once
/// Chromium has created the page, again when it is restored after a
/// discard, and lets go when it closes.
///
/// Add attachments to ``CefPage/Configuration/attachments``, or to
/// ``CefProfile/attachments`` for every page of a profile. One
/// attachment object serves every page made with that configuration,
/// popups included, since a popup gets its opener's configuration; keep
/// what belongs to one page keyed by the page, and drop it in
/// ``pageDidClose(_:)``.
///
/// ```swift
/// final class ConsoleRecorder: CefPageAttachment {
///     private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
///
///     func pageDidCreate(_ page: CefPage) async {
///         let messages = page.devTools.events("Runtime.consoleAPICalled")
///         try? await page.devTools.send("Runtime.enable")
///         tasks[ObjectIdentifier(page)] = Task {
///             for await message in messages { print(message["type"].stringValue ?? "") }
///         }
///     }
///
///     func pageDidClose(_ page: CefPage) {
///         tasks.removeValue(forKey: ObjectIdentifier(page))?.cancel()
///     }
/// }
///
/// var configuration = CefPage.Configuration()
/// configuration.attachments = [ConsoleRecorder()]
/// ```
///
/// For each creation of a page, every attachment is told once, in
/// order: ``pageDidCreate(_:)``, then ``pageDidRestore(_:)`` each
/// time it is created anew after a discard, then ``pageDidClose(_:)``
/// once it closes. A page that closes before Chromium created it, or
/// while an earlier attachment set it up, is closed for every attachment,
/// including those not told of its creation.
///
/// ``CefPage/ready()`` waits for attachments only when the page is
/// held for them: when one of its attachments
/// ``preparesBeforeFirstDocument``, every attachment is told of the
/// creation before the first page, and the page is ready once all have
/// returned; after a discard, it is ready once every
/// ``pageDidRestore(_:)`` has returned. Meanwhile DevTools calls and
/// JavaScript made from those methods, and from tasks they start, go
/// through. Otherwise the page is ready as Chromium creates it, and
/// attachments are told of the creation as it becomes ready, without
/// holding anything: a caller of `ready()` may see an attachment still
/// setting up.
@MainActor
public protocol CefPageAttachment: AnyObject {
    /// Whether no page may run in the page before
    /// ``pageDidCreate(_:)`` returns. The default is `false`.
    ///
    /// When any of a page's attachments needs this, the page starts
    /// blank and loads its first page only once every attachment has been
    /// told of its creation. A native popup cannot be held that way:
    /// Chromium creates it and runs its first document at once. So a
    /// page's popups, new tabs and windows that the delegate lets Chromium
    /// open (``CefWindowOpenDecision/allowNativePopup``) open instead in a
    /// page CefKit creates with the opener's configuration. That popup
    /// arrives as a native one does (``CefPageDelegate/page(_:didOpen:)``,
    /// then the opener's window's ``CefWindow/onPopup``), but the
    /// page cannot script it: `window.open` returns `null`, the popup has
    /// no `window.opener`, and a popup without a URL is refused. Browsers
    /// Chromium opens without a page asking, such as a tab from Chrome's
    /// own UI, have the default configuration, so only their profile's
    /// attachments (``CefProfile/attachments``) set them up.
    var preparesBeforeFirstDocument: Bool { get }

    /// Chromium has created the page. When any of the page's
    /// attachments ``preparesBeforeFirstDocument``, its first page waits
    /// until every attachment's call has returned; otherwise the page may
    /// already be loading.
    ///
    /// The page can close while this runs; ``pageDidClose(_:)`` is
    /// then called before it returns. Attachments later in the list are
    /// not told of a page that has closed.
    func pageDidCreate(_ page: CefPage) async

    /// The page was created anew after a discard. Its page loads again
    /// once this returns. DevTools domains enabled through
    /// ``CefPage/devTools`` are enabled again by then, and its event
    /// streams go on, but whatever the old Chromium page held, such as
    /// scripts added with `Page.addScriptToEvaluateOnNewDocument`, went
    /// with it. The default does nothing.
    func pageDidRestore(_ page: CefPage) async

    /// The page has closed, before its DevTools session ends. Not
    /// called for a discard, which keeps the page.
    func pageDidClose(_ page: CefPage)
}

extension CefPageAttachment {
    public var preparesBeforeFirstDocument: Bool { false }
    public func pageDidCreate(_ page: CefPage) async {}
    public func pageDidRestore(_ page: CefPage) async {}
    public func pageDidClose(_ page: CefPage) {}
}
