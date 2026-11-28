# ``CefPasskeys``

Answer a page's WebAuthn requests with passkeys the app keeps.

## Overview

Chromium's own passkey authenticator needs a keychain access group no
provisioning profile can authorize, so a CEF app cannot use it. A
``CefPasskeyController`` attached to a page answers the page's
`navigator.credentials` calls itself, with passkeys in a
``CefPasskeyStore`` the app chooses, after the user confirms in the
passkey sheet (``CefPasskeyPresenter``) or the app's own interface
(``CefPasskeyDelegate``).

```swift
import CefPasskeys

var configuration = CefPage.Configuration()
configuration.attachments = [CefPasskeyController(policy: .app(CefKeychainPasskeyStore()))]
let page = CefPage(url: URL(string: "https://webauthn.io")!, configuration: configuration)
```

These are software keys with "none" attestation, not iCloud Keychain
passkeys.

## Topics

### Answering requests

- ``CefPasskeyController``
- ``CefPasskeyDelegate``
- ``CefPasskeyRequest``
- ``CefPasskeyDecision``
- ``CefPasskeyPresenter``

### Storing passkeys

- ``CefPasskeyStore``
- ``CefKeychainPasskeyStore``
- ``CefInMemoryPasskeyStore``
- ``CefPasskey``
- ``CefPasskeyStoreError``

### Verifying the user

- ``CefUserVerifier``
- ``CefUserVerification``
