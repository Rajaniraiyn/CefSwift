import Foundation

extension CefRuntime {
    /// How Chromium trades memory for speed and resilience: how many helper
    /// processes it keeps running for the app.
    ///
    /// Set it with ``CefRuntime/Configuration/processPolicy``. ``CefRuntime/Configuration/embedded``
    /// uses ``onDemand``; ``CefRuntime/Configuration/chrome`` and the default
    /// configuration use ``automatic``. The guide lists measured savings.
    public enum ProcessPolicy: Sendable, Equatable {
        /// Chromium's own behavior. Besides the renderer of each page, Chromium
        /// keeps a spare renderer process running, so that a page from a new
        /// site, or a new browser, does not wait for one to start.
        case automatic

        /// Renderer processes start only when a page needs one. Saves the
        /// spare renderer, one process and about 13 MB. A page from a site
        /// that has no renderer yet, and each new browser, waits for its
        /// renderer to start, about 40 ms on an M3. Suits apps that show their
        /// own content.
        case onDemand

        /// As ``onDemand``, and Chromium's network service runs inside the app's
        /// process instead of a helper process of its own. Saves another
        /// process and about 6 MB. A crash in the network service then ends
        /// the app, where Chromium would otherwise restart the service, and the
        /// code that parses network data shares the app's memory. Suits apps
        /// that load only their own or trusted content.
        case minimal

        /// The features this policy turns on and off.
        var features: (enabled: Set<String>, disabled: Set<String>) {
            switch self {
            case .automatic:
                return ([], [])
            case .onDemand:
                return ([], ["SpareRendererForSitePerProcess"])
            case .minimal:
                return (["NetworkServiceInProcess2"], ["SpareRendererForSitePerProcess"])
            }
        }
    }
}

extension CefRuntime.Configuration {
    /// Chromium's feature for notifications through macOS's notification
    /// center; see ``Services/systemNotifications``.
    static let systemNotificationsFeature = "SystemNotifications"

    /// The features to pass to Chromium: ``enabledFeatures`` and
    /// ``disabledFeatures`` with the memory policy's and the services'. A
    /// feature the app names itself wins over their choice.
    var chromiumFeatures: (enabled: Set<String>, disabled: Set<String>) {
        var policy = processPolicy.features
        if services.systemNotifications == .disabled {
            policy.disabled.insert(Self.systemNotificationsFeature)
        }
        return (
            enabledFeatures.union(policy.enabled.subtracting(disabledFeatures)),
            disabledFeatures.union(policy.disabled.subtracting(enabledFeatures))
        )
    }
}
