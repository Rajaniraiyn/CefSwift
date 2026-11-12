import Foundation

/// How Chromium trades memory for speed and resilience: how many helper
/// processes it keeps running for the app.
///
/// Set it with ``CefConfiguration/memoryPolicy``. ``CefConfiguration/embedded``
/// uses ``reduced``; ``CefConfiguration/browser`` and the default
/// configuration use ``standard``. The guide lists measured savings.
public enum CefMemoryPolicy: Sendable, Equatable {
    /// Chromium's own behavior. Besides the renderer of each page, Chromium
    /// keeps a spare renderer process running, so that a page from a new
    /// site, or a new browser, does not wait for one to start.
    case standard

    /// Renderer processes start only when a page needs one. Saves the
    /// spare renderer, one process and about 13 MB. A page from a site
    /// that has no renderer yet, and each new browser, waits for its
    /// renderer to start, about 40 ms on an M3. Suits apps that show their
    /// own content.
    case reduced

    /// As ``reduced``, and Chromium's network service runs inside the app's
    /// process instead of a helper process of its own. Saves another
    /// process and about 6 MB. A crash in the network service then ends
    /// the app, where Chromium would otherwise restart the service, and the
    /// code that parses network data shares the app's memory. Suits apps
    /// that load only their own or trusted content.
    case minimal

    /// The features this policy turns on and off.
    var features: (enabled: Set<String>, disabled: Set<String>) {
        switch self {
        case .standard:
            return ([], [])
        case .reduced:
            return ([], ["SpareRendererForSitePerProcess"])
        case .minimal:
            return (["NetworkServiceInProcess2"], ["SpareRendererForSitePerProcess"])
        }
    }
}

extension CefConfiguration {
    /// The features to pass to Chromium: ``enabledFeatures`` and
    /// ``disabledFeatures`` with the memory policy's. A feature the app
    /// names itself wins over the policy's choice.
    var chromiumFeatures: (enabled: Set<String>, disabled: Set<String>) {
        let policy = memoryPolicy.features
        return (
            enabledFeatures.union(policy.enabled.subtracting(disabledFeatures)),
            disabledFeatures.union(policy.disabled.subtracting(enabledFeatures))
        )
    }
}
