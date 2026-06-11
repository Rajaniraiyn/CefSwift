import Foundation
import Security

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
    /// when the running app is **ad-hoc signed or unsigned** (a local dev
    /// build), use a mock encryption key and never touch the keychain — no
    /// prompt, ever; when the app carries a **real signing identity**
    /// (Apple Development / Developer ID / App Store), use the user's
    /// keychain like Chrome does — one prompt, and "Always Allow" sticks
    /// across rebuilds because the signing identity is stable.
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
    /// Resolves ``automatic`` against the running process's code signature.
    /// Returns either `.keychain` or `.mockKeychain`.
    func resolved() -> CefSafeStoragePolicy {
        switch self {
        case .keychain, .mockKeychain:
            return self
        case .automatic:
            return CefCodeSigning.processIsAdHocSigned ? .mockKeychain : .keychain
        }
    }
}

/// Code-signature inspection used by ``CefSafeStoragePolicy/automatic``.
enum CefCodeSigning {
    /// Whether the current process's main executable is ad-hoc signed or
    /// unsigned (no certificate chain). Computed once and cached.
    ///
    /// Detection failure is treated as *properly signed* (`false`): the safe
    /// failure mode for user data is the real keychain, not a mock key.
    static let processIsAdHocSigned: Bool = {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard let adHoc = isAdHocSigned(executableAt: executable) else {
            let message = "CefKit: could not inspect the code signature of \(executable.path); "
                + "assuming a properly signed build (safeStorage .automatic -> keychain).\n"
            FileHandle.standardError.write(Data(message.utf8))
            return false
        }
        return adHoc
    }()

    /// Inspects the static code signature of the executable at `url`.
    /// Returns `true` when ad-hoc signed or unsigned (empty/absent certificate
    /// chain), `false` when signed with a real certificate, and `nil` when the
    /// signature could not be inspected.
    static func isAdHocSigned(executableAt url: URL) -> Bool? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else { return nil }

        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: SecCSFlags.RawValue(kSecCSSigningInformation)),
            &information
        )
        // errSecCSUnsigned means "definitively not signed" — that's an answer,
        // not a detection failure.
        if status == errSecCSUnsigned { return true }
        guard status == errSecSuccess,
              let info = information as? [String: Any]
        else { return nil }

        // Unsigned code yields no identifier at all; ad-hoc-signed code has an
        // identifier but an empty/absent certificate chain.
        guard info[kSecCodeInfoIdentifier as String] != nil else { return true }
        let certificates = info[kSecCodeInfoCertificates as String] as? [AnyObject]
        return (certificates ?? []).isEmpty
    }
}
