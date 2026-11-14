import CefChromium
import CefSwiftUI
import SwiftUI

/// Find in page: Edit › Find (⌘F) shows Chromium's find bar.
///
/// A `CefWindow` can replace it with the app's own bar
/// (`CefWindow.setFindBar`, driven by `CefFindSession`, as the Gallery's
/// Find in Page demo does); CefChromium does not yet follow Chromium's
/// surfaces in a `CefChromeWindow`, so the browser's windows show
/// Chromium's own.
struct FindBar: BrowserFeature {
    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { controller.current?.execute(.find) }.keyboardShortcut("f")
        }
    }
}
