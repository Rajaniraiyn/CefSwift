import CefPasskeys
import CefSwiftUI
import SwiftUI

/// With CefPasskeys, a `CefPasskeyController` answers a page's WebAuthn
/// calls from a store of the app's own instead of Chromium's dialog. Its
/// delegate decides each request while the page waits; this one asks in
/// the app's own interface. The store is in memory, so nothing touches the
/// keychain, and the demo never asks macOS to verify the user: a real app
/// verifies the user before it answers, as `CefPasskeyPresenter` does.
struct PasskeysDemo: Demo {
    let title = "Passkeys"
    let summary = "A page registers a passkey and signs in with it; the app answers from an in-memory store, after asking in its own interface."
    let symbol = "person.badge.key"
    let category = DemoCategory.passkeys

    func makeView() -> some View { PasskeysView() }
}

private struct PasskeysView: View {
    @State private var model = PasskeyModel()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if let request = model.pending {
                    HStack {
                        Text(request.kind == .registration
                             ? "Save a passkey for \(request.host)?"
                             : "Sign in to \(request.host) as \(request.passkeys.first?.userName ?? "–")?")
                        Spacer()
                        Button("Cancel") { model.answer(.deny) }
                        Button("Continue") {
                            model.answer(request.kind == .registration ? .createPasskey
                                         : request.passkeys.first.map { .signIn(with: $0) } ?? .deny)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(10)
                    .background(.tint.opacity(0.15))
                }
                CefWebView(model.browser)
            }
            .frame(minWidth: 380)
            List(model.saved) { passkey in
                VStack(alignment: .leading) {
                    Text(passkey.userName)
                    Text("\(passkey.relyingPartyID) · used \(passkey.signCount) times").font(.caption).foregroundStyle(.secondary)
                }
            }
            .overlay { if model.saved.isEmpty { Text("No passkeys").foregroundStyle(.secondary) } }
            .frame(minWidth: 200, maxWidth: 280)
        }
        .readyWhenLoaded(model.browser)
        .onDisappear {
            model.answer(.deny)
            model.browser.close(force: true)
        }
    }
}

@MainActor
@Observable
private final class PasskeyModel: CefPasskeyDelegate {
    private(set) var pending: CefPasskeyRequest?
    private(set) var saved: [CefPasskey] = []
    @ObservationIgnored private var reply: CheckedContinuation<CefPasskeyDecision, Never>?
    @ObservationIgnored private let store = CefInMemoryPasskeyStore()
    @ObservationIgnored private lazy var controller = CefPasskeyController(policy: .app(store), delegate: self)
    @ObservationIgnored lazy var browser: CefBrowser = {
        var configuration = CefBrowser.Configuration()
        configuration.attachments = [controller]
        // WebAuthn needs a secure origin with a domain: http://localhost.
        return CefBrowser(url: Self.page.localURL, configuration: configuration)
    }()

    func browser(_ browser: CefBrowser, decidePasskeyFor request: CefPasskeyRequest) async -> CefPasskeyDecision {
        // Conditional requests, made without a click, wait.
        guard request.hasUserGesture else { return .ignore }
        answer(.deny)
        pending = request
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { reply = $0 }
        } onCancel: {
            Task { @MainActor in self.answer(.deny) }
        }
        // The store saves after the page has its answer.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            saved = (try? await store.passkeys()) ?? saved
        }
        return decision
    }

    func answer(_ decision: CefPasskeyDecision) {
        reply?.resume(returning: decision)
        reply = nil
        pending = nil
    }

    static let page = SamplePage("passkeys.html", title: "Passkeys", body: """
        <h1>Passkeys</h1>
        <p><button onclick="register()">Create a Passkey</button> <button onclick="signIn()">Sign In</button></p>
        <p id=result class=card>Create a passkey for ada@example.com, then sign in with it.</p>
        <script>
          const challenge = () => crypto.getRandomValues(new Uint8Array(32));
          const show = text => result.textContent = text;
          async function register() {
            try {
              await navigator.credentials.create({ publicKey: {
                challenge: challenge(), rp: { name: 'Gallery' },
                user: { id: new Uint8Array([1, 2, 3, 4]), name: 'ada@example.com', displayName: 'Ada' },
                pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
                authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
              } });
              show('✓ Passkey created.');
            } catch (error) { show('✕ ' + error.name); }
          }
          async function signIn() {
            try {
              const credential = await navigator.credentials.get({ publicKey: { challenge: challenge(), userVerification: 'required' } });
              show('✓ Signed in as user ' + new Uint8Array(credential.response.userHandle).join('.'));
            } catch (error) { show('✕ ' + error.name); }
          }
        </script>
        """)
}
