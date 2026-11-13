import CefSwiftUI
import SwiftUI

/// When a page asks for a permission its site settings leave to the user,
/// the delegate's `browser(_:decidePermissionFor:)` decides, and may take
/// its time: here it waits for the app's own prompt. `.alwaysAllow` and
/// `.alwaysDeny` also store the answer in `profile.siteSettings`, which the
/// app can read and change for each origin.
struct PermissionsDemo: Demo {
    let title = "Permissions and Site Settings"
    let summary = "A page's permission requests answered by a prompt of the app's own, and the site's settings, which those answers change."
    let symbol = "hand.raised"
    let category = DemoCategory.network

    func makeView() -> some View { PermissionsView() }
}

private struct PermissionsView: View {
    @State private var model = PermissionModel()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let request = model.pending {
                    HStack {
                        Text("\(request.origin) asks for \(request.kinds.sitePermissions.map(\.rawValue).joined(separator: ", ")).")
                        Spacer()
                        Button("Deny") { model.answer(.deny) }
                        Button("Always Allow") { model.answer(.alwaysAllow) }
                        Button("Allow Once") { model.answer(.allow) }.keyboardShortcut(.defaultAction)
                    }
                    .padding(10)
                    .background(.yellow.opacity(0.2))
                }
                CefWebView(model.browser)
            }
            .frame(minWidth: 380)
            SiteSettingsList(origin: PermissionModel.page.localURL)
                .frame(minWidth: 240, maxWidth: 320)
        }
        .readyWhenLoaded(model.browser)
        .onDisappear {
            model.answer(.dismiss)
            model.browser.close(force: true)
        }
    }
}

@MainActor
@Observable
private final class PermissionModel: CefBrowserDelegate {
    private(set) var pending: CefPermissionRequest?
    @ObservationIgnored private var reply: CheckedContinuation<CefPermissionDecision, Never>?
    @ObservationIgnored lazy var browser = CefBrowser(url: Self.page.localURL, delegate: self)

    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        answer(.dismiss)  // one question at a time
        pending = request
        // The request is cancelled when the page navigates away or closes.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { reply = $0 }
        } onCancel: {
            Task { @MainActor in self.answer(.dismiss) }
        }
    }

    func answer(_ decision: CefPermissionDecision) {
        reply?.resume(returning: decision)
        reply = nil
        pending = nil
    }

    // Permissions macOS itself does not ask about, so no system prompt follows.
    static let page = SamplePage("permissions.html", title: "Permissions", body: """
        <h1>Permissions</h1>
        <p><button onclick="ask(() => getScreenDetails().then(s => s.screens.length + ' screens'))">Window Management</button>
           <button onclick="ask(() => navigator.requestMIDIAccess({ sysex: true }).then(() => 'MIDI granted'))">MIDI</button>
           <button onclick="ask(() => Promise.resolve(open('about:blank') ? 'opened a popup' : 'popup blocked'))">Open a Popup</button></p>
        <p id=result class=card>Each button asks for a permission.</p>
        <script>
          function ask(request) {
            request().then(text => result.textContent = '✓ ' + text, error => result.textContent = '✕ ' + error.message);
          }
        </script>
        """)
}

/// The settings that apply to one origin, editable; they follow changes
/// made anywhere, the prompt's answers included.
private struct SiteSettingsList: View {
    let origin: URL
    @State private var revision = 0
    private let permissions: [(CefSitePermission, String)] = [
        (.windowManagement, "Window Management"), (.midiSystemExclusive, "MIDI"),
        (.popups, "Pop-ups"), (.javaScript, "JavaScript"), (.images, "Images"),
    ]
    private var settings: CefSiteSettings { CefProfile.default.siteSettings }

    var body: some View {
        Form {
            Section(origin.host() ?? "") {
                ForEach(permissions, id: \.0) { permission, name in
                    Picker(name, selection: binding(for: permission)) {
                        ForEach(permission.supportedSettings, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
            }
            Button("Reset Site") { settings.reset(origin: origin) }
        }
        .formStyle(.grouped)
        .id(revision)
        .task {
            for await _ in settings.changes { revision += 1 }
        }
    }

    private func binding(for permission: CefSitePermission) -> Binding<CefSitePermission.Setting> {
        Binding {
            settings.setting(for: permission, origin: origin)
        } set: {
            settings.set($0, for: permission, origin: origin)
        }
    }
}
