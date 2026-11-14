import Foundation

/// Decisions a profile makes for every page in it.
///
/// A page's own ``CefBrowserDelegate`` answers first, where it implements
/// the question; the protocol's default implementations hand the question
/// to the page's profile, so an app that sets a profile's delegate decides
/// for every page of the profile — those it creates, and those Chromium
/// creates itself: native popups, tabs and windows opened from Chrome's
/// UI, extension pages. Every method has a default.
///
/// ```swift
/// final class ProfilePolicy: CefProfileDelegate {
///     func profile(_ profile: CefProfile, decidePermissionFor request: CefPermissionRequest,
///                  in page: CefBrowser) async -> CefPermissionDecision {
///         request.origin.host() == "meet.example.com" ? .allow : .deny
///     }
/// }
///
/// let policy = ProfilePolicy()
/// CefProfile.default.delegate = policy
/// ```
@MainActor
public protocol CefProfileDelegate: AnyObject {
    /// Resolve a permission request of one of the profile's pages that its
    /// delegate did not decide, and that the profile's
    /// ``CefProfile/siteSettings`` do not answer already. The default
    /// denies.
    ///
    /// Return ``CefPermissionDecision/alwaysAllow`` or
    /// ``CefPermissionDecision/alwaysDeny`` to store the answer in the
    /// profile's site settings, so the origin is not asked again.
    func profile(_ profile: CefProfile, decidePermissionFor request: CefPermissionRequest, in page: CefBrowser) async
        -> CefPermissionDecision

    /// Decide whether and where to save a download of one of the
    /// profile's pages (``CefDownload/browser``). The default,
    /// ``CefDownloadDecision/default(for:)``, follows the profile's
    /// ``CefProfile/downloadPolicy``: the Downloads folder unless the app
    /// set another.
    func profile(_ profile: CefProfile, decideDestinationFor download: CefDownload) async -> CefDownloadDecision
}

extension CefProfileDelegate {
    public func profile(
        _ profile: CefProfile, decidePermissionFor request: CefPermissionRequest, in page: CefBrowser
    ) async -> CefPermissionDecision {
        .deny
    }

    public func profile(_ profile: CefProfile, decideDestinationFor download: CefDownload) async -> CefDownloadDecision {
        .default(for: download)
    }
}

/// Stands in when a profile has no delegate.
@MainActor
final class CefDefaultProfileDelegate: CefProfileDelegate {
    static let shared = CefDefaultProfileDelegate()
}

extension CefProfile {
    /// The delegate that answers, the default when none is set.
    var effectiveDelegate: CefProfileDelegate { delegate ?? CefDefaultProfileDelegate.shared }
}
