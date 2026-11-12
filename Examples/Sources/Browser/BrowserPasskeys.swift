import CefSwiftUI
import SwiftUI

/// The browser's own passkeys, used when Settings → Passkeys is set to
/// "This browser". They live in the keychain when the app is signed with a
/// team identity, and in memory otherwise (an ad hoc signed build has no
/// data protection keychain), so they last until the app quits.
@MainActor
@Observable
final class BrowserPasskeys: CefPasskeyStore {
    static let shared = BrowserPasskeys()

    /// Whether new tabs answer passkey requests from this store instead of
    /// Chromium's own dialog.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "passkeysByBrowser") }

    private(set) var all: [CefPasskey] = []
    /// Whether the passkeys survive a relaunch.
    private(set) var isPersistent = true

    private let keychain = CefKeychainPasskeyStore()
    private let memory = CefInMemoryPasskeyStore()
    /// Private tabs keep their passkeys to themselves, for the session.
    let privateStore = CefInMemoryPasskeyStore()

    private var store: CefPasskeyStore { isPersistent ? keychain : memory }

    func refresh() async {
        do {
            all = try await store.passkeys()
        } catch {
            isPersistent = false
            all = (try? await memory.passkeys()) ?? []
        }
        all.sort { $0.relyingPartyID < $1.relyingPartyID }
    }

    func passkeys() async throws -> [CefPasskey] {
        await refresh()
        return all
    }

    func save(_ passkey: CefPasskey) async throws {
        do {
            try await store.save(passkey)
        } catch {
            isPersistent = false
            try await memory.save(passkey)
        }
        await refresh()
    }

    func remove(_ passkey: CefPasskey) async throws {
        try await store.remove(passkey)
        await refresh()
    }
}

/// Settings → Passkeys: who answers sites, and the saved passkeys.
struct PasskeySettings: View {
    @AppStorage("passkeysByBrowser") private var byBrowser = false
    private let passkeys = BrowserPasskeys.shared

    var body: some View {
        Section {
            Picker("Passkeys", selection: $byBrowser) {
                Text("Chromium").tag(false)
                Text("This browser").tag(true)
            }
            if byBrowser {
                if passkeys.all.isEmpty {
                    Text("No saved passkeys").foregroundStyle(.secondary)
                }
                ForEach(passkeys.all) { passkey in
                    LabeledContent {
                        Button("Remove", role: .destructive) {
                            Task { try? await passkeys.remove(passkey) }
                        }
                    } label: {
                        Text(passkey.relyingPartyID)
                        Text(passkey.userName)
                    }
                }
            }
        } footer: {
            Text(byBrowser
                 ? "New tabs ask you before a site saves or uses a passkey."
                    + (passkeys.isPersistent ? "" : " This build keeps them only until the browser quits.")
                 : "Chromium's own dialog handles passkeys and security keys.")
        }
        .task { await passkeys.refresh() }
    }
}
