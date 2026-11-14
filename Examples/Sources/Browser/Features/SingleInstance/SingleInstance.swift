import CefSwiftUI

/// A single instance: launching the app again while it runs
/// (`CefRuntime.onRelaunch`) opens a new tab, or a tab for each URL or file
/// path passed on the command line (`Browser https://swift.org`).
struct SingleInstance: BrowserFeature {
    func start(_ controller: BrowserController) {
        CefRuntime.shared.onRelaunch = { [weak controller] arguments, directory in
            guard let controller else { return }
            let urls = arguments.compactMap { TypedAddress.url(fromArgument: $0, relativeTo: directory) }
            if urls.isEmpty { controller.openTab() } else { urls.forEach { controller.openTab(url: $0) } }
        }
    }
}
