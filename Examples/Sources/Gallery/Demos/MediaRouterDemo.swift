import CefSwiftUI
import SwiftUI

/// `CefMediaRouter.shared` is Chromium's media router: the Cast and DIAL
/// devices on the network, as `sinks`, and the routes in use. It runs
/// under the `.chrome` preset; `.embedded` turns it off. Looking for
/// devices goes to the local network, so macOS may ask for permission the
/// first time, and with no devices around the list stays empty.
struct MediaRouterDemo: Demo {
    let title = "Media Router"
    let summary = "Cast and DIAL devices on the local network, as Chromium's media router finds them."
    let symbol = "tv.and.mediabox"
    let category = DemoCategory.runtime

    func makeView() -> some View { MediaRouterView() }
}

private struct MediaRouterView: View {
    private let router = CefMediaRouter.shared
    @Environment(\.demoReadiness) private var readiness

    var body: some View {
        List(router.sinks) { sink in
            Label(sink.name, systemImage: sink.kind == .cast ? "tv" : "hifispeaker")
        }
        .overlay {
            if !router.isAvailable {
                ContentUnavailableView("No Media Router", systemImage: "tv.slash",
                                       description: Text("The runtime configuration turns the MediaRouter feature off."))
            } else if router.sinks.isEmpty {
                ContentUnavailableView {
                    Label(router.isDiscovering ? "Searching…" : "Not Searching", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text(router.isDiscovering ? "No devices found yet." : "Search the local network for devices to cast to.")
                } actions: {
                    if !router.isDiscovering { Button("Search for Devices", action: router.startDiscovery) }
                }
            }
        }
        .toolbar {
            if router.isDiscovering { Button("Stop", systemImage: "stop.circle", action: router.stopDiscovery) }
        }
        .onAppear { router.isAvailable ? readiness?.ready() : readiness?.fail("the media router is not available") }
        .onDisappear(perform: router.stopDiscovery)
    }
}
