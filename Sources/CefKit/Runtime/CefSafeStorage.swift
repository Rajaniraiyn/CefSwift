import Foundation

/// How Chromium encrypts cookies (and other secrets) at rest — i.e. whether
/// it creates the **"Chromium Safe Storage"** item in the user's keychain.
///
/// On first use of the real keychain, macOS shows the system dialog
/// *"<YourApp> wants to use your confidential information stored in
/// 'Chromium Safe Storage' in your keychain"*. Clicking **Always Allow**
/// records the app's *code-signature identity* in the keychain item's access
/// control list, so a properly signed app never asks again. Ad-hoc-signed
/// builds (the default for local dev builds, `codesign --sign -`) have no
/// stable signing identity — every rebuild produces a different signature —
/// so the grant cannot stick and the dialog reappears after each rebuild.
///
/// The dialog itself is owned by the macOS security daemon (it is the legacy
/// keychain ACL prompt); it cannot be replaced, restyled, or upgraded to
/// Touch ID by the embedding app. Chrome shows the exact same dialog.
public enum CefSafeStoragePolicy: Sendable {
    /// Pick the right behavior for the build at hand (the default):
    /// **DEBUG** builds (local dev, `swift build`) use a mock encryption key
    /// and never touch the keychain — no prompt, ever; **release** builds use
    /// the user's keychain like Chrome does — one prompt, and "Always Allow"
    /// sticks across rebuilds because the signing identity is stable.
    case automatic

    /// Always use the user's keychain (Chrome-like). Cookies are encrypted
    /// with a per-user key stored as "Chromium Safe Storage"; expect the
    /// one-time ACL prompt on first run. With an ad-hoc-signed dev build the
    /// prompt returns after every rebuild — prefer ``automatic`` for
    /// development.
    case keychain

    /// Never touch the keychain: cookies are encrypted with a fixed mock key
    /// (Chromium's `--use-mock-keychain`). No prompt, but the at-rest
    /// encryption is decorative — right for demos, kiosks, and CI; wrong for
    /// browsing profiles you care about.
    case mockKeychain
}

extension CefSafeStoragePolicy {
    /// Resolves ``automatic`` to `.mockKeychain` for DEBUG builds and
    /// `.keychain` for release builds. Returns other values unchanged.
    func resolved() -> CefSafeStoragePolicy {
        switch self {
        case .keychain, .mockKeychain:
            return self
        case .automatic:
            #if DEBUG
            return .mockKeychain
            #else
            return .keychain
            #endif
        }
    }
}
