# Bundling

Chromium does not run from a bare executable. It needs an app bundle with
its framework and five helper apps, laid out as it expects. The `cef`
command plugin builds that bundle, signs it, and checks what a signed
bundle can do.

## The `cef` command

Run it from the root of the package that defines your app:

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyApp
```

The two `--allow-…` options pre-approve the plugin's permissions: it writes
`.cef/` and the bundle into the package directory and downloads CEF from
`cef-builds.spotifycdn.com`. Every subcommand needs them.

| Subcommand | Does |
|---|---|
| `download` | Downloads the pinned CEF distribution into `.cef/`, verifies its size and SHA-1, extracts it and converts the framework to the versioned layout. Does nothing if it is already prepared. |
| `bundle` | Builds the product, compiles the helper, then assembles and signs `<Name>.app`. Downloads CEF first if needed. |
| `doctor <App.app>` | Inspects a built bundle and reports, per feature, whether it works and what is missing. See [cef doctor](#cef-doctor). |
| `package <App.app>` | Wraps the app in a zip (`ditto`) or a disk image (`hdiutil`). |
| `notarize <App.app>` | Packages the app, submits it with `xcrun notarytool submit --wait`, and staples the ticket. |
| `info` | Prints the pinned CEF and Chromium versions and the state of the `.cef/` cache. |
| `clean` | Removes `.cef/`. |

`doctor`, `package` and `notarize` take the app's path, or `--product
<Name>` for `dist/<Name>.app`. `swift package cef help` prints the usage.

Options of `bundle`:

| Option | Default | Effect |
|---|---|---|
| `--product <Name>` | Required | The executable product to bundle. |
| `--configuration debug\|release` | `release` | Build configuration. |
| `--output <dir>` | `dist` | Output directory, relative to the package. |
| `--config <file>` | `cefapp.json` beside the target's sources | The settings file. See [Per-product settings](#per-product-settings). |
| `--bundle-id <id>` | `bundleIdentifier`, else `com.cefswift.<name>` | The app's bundle identifier. |
| `--name <Name>` | The product name | The app, executable and display name. |
| `--version <version>` | `version`, else `1.0` | `CFBundleShortVersionString`, the version users see. |
| `--build <number>` | `build`, else `1` | `CFBundleVersion`, the build number. |
| `--sign <identity\|->` | `signingIdentity`, else detected | Code-signing identity: a name, part of one, or a SHA-1 hash; `-` signs ad hoc. See [Code signing](#code-signing). |
| `--team-id <ID>` | `teamIdentifier`, else the certificate's | The team identifier for `$(TeamIdentifierPrefix)`. |
| `--keychain <file>` | `signingKeychain`, else the search list | A keychain to find the identity in. |
| `--capability <name>` | Adds to `capabilities` | A [feature](#features) to enable; repeatable. |
| `--info-plist <file>` | None | A property list merged into the app's Info.plist, after `infoPlist`; repeatable. |
| `--entitlements <file>` | `entitlements` | The app's entitlements file. |
| `--provisioning-profile <file>` | `provisioningProfile` | Embedded as `Contents/embedded.provisionprofile`. |
| `--[no-]hardened-runtime` | `hardenedRuntime`, else on for Apple team identities | Signs executables with `--options runtime`. |
| `--[no-]timestamp` | `timestamp`, else on for Developer ID and App Store identities | A secure timestamp from Apple's server. |
| `--package zip\|dmg` | None | Packages the result, as `cef package` does. |
| `--notarize` | Off | Packages and notarizes the result; needs `--keychain-profile <name>` or `notarization.keychainProfile`. |
| `--flavor minimal\|standard` | `minimal` | Which CEF distribution to download. See [Flavors](#flavors). |
| `--platform macosarm64\|macosx64` | The build machine's | Which architecture's CEF to bundle. |
| `--manifest <path>` | `CEF_VERSION.json` | A different CEF manifest. |

`download` takes `--platform`, `--flavor` and `--manifest` as well, and
`info` takes `--manifest`.

The plugin finds `CEF_VERSION.json` in the invoking package or in any of its
dependencies, so an app that depends on CefSwift uses the CEF version that
CefSwift pins. To bundle a different CEF version, pass `--manifest` with a
`CEF_VERSION.json` pinned to it. That CEF build must still provide the
`CEF_API_VERSION` the vendored headers pin, with the same API hash, or the
app fails to start with `CefError.apiHashMismatch` or `CefError.loadFailed`.

The cache lives in the invoking package's `.cef/`. Add `.cef/` and `dist/`
to `.gitignore`.

## Per-product settings

A `cefapp.json` beside the product's sources sets what the command-line
options override. It may contain comments and trailing commas (JSON5).
Paths in it are relative to its directory. An unknown key is an error, so
a misspelled key does not go unnoticed.

```json
{
  "bundleIdentifier": "com.example.browser",
  "displayName": "Example Browser",
  "version": "2.1",
  "build": "214",
  "minimumSystemVersion": "15.0",

  "capabilities": ["camera", "microphone", "passkeys", "defaultBrowser"],
  "usageDescriptions": {
    "camera": "Websites you allow can use the camera.",
    "microphone": "Websites you allow can use the microphone.",
    "bluetooth": "Your phone can sign you in with a passkey."
  },
  "infoPlist": { "LSApplicationCategoryType": "public.app-category.productivity" },
  "entitlements": "Browser.entitlements",
  "helperEntitlements": { "renderer": "Renderer.entitlements" },

  "signingIdentity": "Developer ID Application: Example Corp (A1B2C3D4E5)",
  "provisioningProfile": "Browser_Developer_ID.provisionprofile",
  "notarization": { "keychainProfile": "notary", "format": "dmg" }
}
```

| Key | Default | Meaning |
|---|---|---|
| `bundleIdentifier`, `displayName`, `version`, `build` | `com.cefswift.<name>`, the product name, `1.0`, `1` | As the options of the same names. |
| `minimumSystemVersion` | The product's deployment target, else `14.0` | `LSMinimumSystemVersion`. |
| `signingIdentity`, `teamIdentifier`, `signingKeychain` | Detected | As `--sign`, `--team-id`, `--keychain`. |
| `hardenedRuntime`, `timestamp` | By identity | As `--[no-]hardened-runtime`, `--[no-]timestamp`. |
| `capabilities` | None | [Features](#features) to enable. |
| `usageDescriptions` | None | The sentence macOS shows when it asks the user, by capability name. |
| `infoPlist` | None | Keys merged into the app's Info.plist. |
| `entitlements` | None | The app's entitlements file. |
| `helperEntitlements` | None | Entitlements files merged over a helper's built-in ones, by helper: `helper`, `alerts`, `gpu`, `plugin`, `renderer`. A key set to `false` removes a built-in one. |
| `provisioningProfile` | None | The profile to embed. |
| `notarization.keychainProfile`, `notarization.format` | None, `zip` | Defaults of `cef notarize` and `bundle --notarize`. |

If you keep `cefapp.json` and entitlements files in the target's directory,
exclude them in `Package.swift` (`exclude: ["cefapp.json",
"MyApp.entitlements"]`), as the examples do, so SwiftPM does not warn about
unhandled files. The Browser example's
[`cefapp.json`](../Examples/Sources/Browser/cefapp.json) uses most keys, and
its `Browser-Distribution.entitlements` is a template for a team-signed
build.

## Bundle anatomy

```
MyApp.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo
    ├── embedded.provisionprofile              # when provisioningProfile is set
    ├── MacOS/
    │   └── MyApp                          # your product
    └── Frameworks/
        ├── libcefswift_helper_startup.dylib   # seals the helpers' sandbox
        ├── Chromium Embedded Framework.framework/
        │   ├── Versions/
        │   │   ├── A/
        │   │   │   ├── Chromium Embedded Framework   # the library itself
        │   │   │   ├── Resources/                    # .pak files, locales, icudtl.dat
        │   │   │   └── Libraries/                    # SwiftShader, Vulkan, libcef_sandbox.dylib
        │   │   └── Current -> A
        │   ├── Chromium Embedded Framework -> Versions/Current/Chromium Embedded Framework
        │   ├── Libraries -> Versions/Current/Libraries
        │   └── Resources -> Versions/Current/Resources
        ├── MyApp Helper.app
        ├── MyApp Helper (Alerts).app
        ├── MyApp Helper (GPU).app
        ├── MyApp Helper (Plugin).app
        └── MyApp Helper (Renderer).app
```

### Helper apps

Chromium runs renderers, the GPU process, plugins and notification
("alerts") services as separate processes. On macOS each process type is an
app of its own, with its own bundle identifier and `Info.plist`. All five
contain the same binary, copied and renamed.

`cef bundle` compiles that binary with `xcrun clang` from
`Plugins/CefPlugin/Helper/` in the CefSwift package, against the framework
it bundles. The helper links `libcefswift_helper_startup.dylib` and then the
framework, so dyld loads both at launch, and it builds the product with a
weak link to the framework (`-weak_framework`). Libraries loaded at launch
keep the framework's 12 MB of fixed-up pointers as shared, clean memory in
every process; see [architecture](architecture.md#loading-the-framework-at-launch).
An app bundled another way, for example by an Xcode project, builds its
helper from the same two files with the same link order (see
`HelperBuilder.swift` in the plugin for the exact commands). Its app
executable runs without the link to the framework, since CefKit loads the
framework with `dlopen` if dyld has not, but that process then holds the
12 MB privately.

The names matter. Chromium derives helper paths from the main executable's
name, so each helper executable is named `<executable> Helper` or
`<executable> Helper (<Type>)` and sits in the main app's
`Contents/Frameworks/`. Bundle identifiers follow the same pattern:

| Helper | Bundle identifier |
|---|---|
| `MyApp Helper.app` | `<bundle ID>.helper` |
| `MyApp Helper (Alerts).app` | `<bundle ID>.helper.alerts` |
| `MyApp Helper (GPU).app` | `<bundle ID>.helper.gpu` |
| `MyApp Helper (Plugin).app` | `<bundle ID>.helper.plugin` |
| `MyApp Helper (Renderer).app` | `<bundle ID>.helper.renderer` |

### Versioned framework layout

CEF distributions ship the framework in a flat layout. Code signing and the
Xcode 26 toolchain expect the versioned layout: `Versions/A/` with
top-level symlinks. `cef download` converts the framework in place, so every
later step sees a well-formed framework.

## Info.plist

The main app's `Info.plist` includes:

| Key | Value | Why |
|---|---|---|
| `LSEnvironment` | `{ MallocNanoZone = "0" }` | Chromium's allocator does not work with the nano malloc zone; without it the app can crash inside CEF. |
| `NSPrincipalClass` | `NSApplication` | CefSwift creates its `CefApplication` subclass at launch, before anything else uses `NSApp`. |
| `LSMinimumSystemVersion` | `minimumSystemVersion`, else the product's deployment target | The package's minimum. |
| `NSHighResolutionCapable` | `true` | Retina rendering. |
| `NSSupportsAutomaticGraphicsSwitching` | `true` | Lets Macs with two GPUs use the integrated one. |

The keys of each capability, `infoPlist` and each `--info-plist` file are
merged over these, in that order: dictionaries key by key, arrays without
repeating an element, other values replaced. `CFBundleExecutable`,
`CFBundleIdentifier`, `CFBundlePackageType`, `CFBundleShortVersionString`,
`CFBundleVersion` and `LSMinimumSystemVersion` come from their own settings,
and setting them there is an error.

Each helper's `Info.plist` adds:

| Key | Value | Why |
|---|---|---|
| `LSUIElement` | `true` | Helpers never appear in the Dock or the app switcher. |
| `LSFileQuarantineEnabled` | `true` | Files that helper processes write are quarantined, as in other browsers. |
| Every `NS…UsageDescription` of the app | The app's | In case macOS attributes an access to the helper. |
| `NSUserNotificationAlertStyle` (Alerts helper) | `alert` | As in Chromium's `helper-alerts-Info.plist`. |

## Code signing

### Identity

The identity is, in order of precedence:

1. `--sign <identity>`, or `--sign -` for ad hoc.
2. `signingIdentity` in `cefapp.json`.
3. The first "Apple Development" identity in your keychain, else the first
   "Developer ID Application" identity.
4. Ad hoc, when there is none.

The plugin reads the team identifier from the certificate's
organizational unit (the parenthesized identifier in an Apple Development
certificate's name is the person's, not the team's). Finding the identity
and reading the certificate do not touch its private key; `codesign` does,
and macOS may ask once for access to it.

### Order and options

The plugin signs inside out, each item before what contains it, and never
with `--deep`:

1. Each Mach-O file in the framework's `Libraries/`. CEF ships them
   linker-signed ad hoc; re-signing them with the app's identity is what lets
   library validation load them.
2. The framework.
3. `libcefswift_helper_startup.dylib`.
4. Each helper app, with its entitlements.
5. The app, with its entitlements and the embedded profile.

Executables (the app and helpers) get `--options runtime` when the hardened
runtime is on; libraries and the framework take no options or entitlements,
since they run with those of the process that loads them. `--timestamp`
adds a secure timestamp (it needs a network connection); otherwise the
plugin passes `--timestamp=none`, so signing works offline.

| Identity | Hardened runtime | Timestamp | `get-task-allow` |
|---|---|---|---|
| Ad hoc | Off | Off | No |
| Apple Development | On | Off | Added, so the app can be debugged |
| Developer ID Application | On | On | Refused: notarization rejects it |

### Entitlements

Each part's entitlements are built from:

| Part | Built in | Added |
|---|---|---|
| App | None | Each capability's; the `entitlements` file's; with a profile, `com.apple.application-identifier` and `com.apple.developer.team-identifier` from it, as Xcode adds them |
| Renderer, GPU helpers | `com.apple.security.cs.allow-jit` | `helperEntitlements` |
| Base helper | None | `device.camera` and `device.audio-input` from those capabilities (Chromium can run its video capture and audio services there); `helperEntitlements` |
| Alerts, Plugin helpers | None | `helperEntitlements` |

The built-in ones follow CEF's
[code signing guide](https://chromiumembedded.github.io/cef/code_signing)
and Chromium's `chrome/app/helper-renderer-entitlements.plist` and
`helper-gpu-entitlements.plist`: V8 and the GPU process's shader compilers
generate code at run time, which the hardened runtime allows only with
`allow-jit`. None of the parts needs
`com.apple.security.cs.disable-library-validation`: the plugin signs every
library a process loads, the startup library and CEF's own included, with
the app's identity.

Strings in entitlements files may use `$(TeamIdentifierPrefix)` and
`$(AppIdentifierPrefix)` (`<team ID>.`), `$(TeamIdentifier)` and
`$(CFBundleIdentifier)`.

Restricted entitlements, which a provisioning profile has to authorize
(`keychain-access-groups`, `com.apple.application-identifier` and every
`com.apple.developer.…` key), need an Apple team signature and a profile.
macOS kills an app that claims one its profile does not authorize. So the
plugin:

- refuses to sign an `entitlements` file with a restricted entitlement
  when the bundle is signed ad hoc or has no profile, or when the profile
  does not authorize it, and says which;
- leaves out a capability's restricted entitlements in those cases, with a
  warning naming what is lost, so the same `cefapp.json` builds ad hoc and
  signed;
- refuses restricted entitlements for helpers, which have no profile of
  their own.

### Provisioning profile

`provisioningProfile` is decoded with `security cms -D -i` and checked
before anything is built. Errors stop the bundle:

- the profile is not for macOS, or has expired;
- its team is not the identity's;
- its App ID does not match `<team ID>.<bundle ID>` (wildcard App IDs
  match by prefix);
- it is a development profile with a Developer ID identity, or the other
  way round;
- it does not list the signing certificate;
- it does not authorize an entitlement the app claims.

Download profiles from Certificates, Identifiers & Profiles on the Apple
Developer website: a "Developer ID" profile for distribution, a "macOS App
Development" profile for development builds. Both need an App ID for the
bundle identifier with the capabilities enabled.

## Distribution

### Local builds (ad hoc)

- [ ] `swift package … cef bundle --product MyApp`. With no identity in the
  keychain, the bundle is signed ad hoc, without the hardened runtime.
- [ ] Runs on the Mac that built it. Gatekeeper refuses it on another Mac.
- [ ] `.automatic` safe storage uses a mock keychain; Chromium passkeys
  offer security keys and, with the `bluetooth` capability, phones.
- [ ] To test the hardened runtime and the entitlements locally, bundle with
  `--hardened-runtime`; unrestricted entitlements apply ad hoc.

### Development builds (Apple Development)

- [ ] An Apple Development certificate in the login keychain (Xcode,
  Settings > Accounts > Manage Certificates). `cef bundle` picks it up
  without `--sign`.
- [ ] For restricted entitlements, a macOS App Development profile that
  lists this Mac, set as `provisioningProfile`.
- [ ] The hardened runtime is on and `get-task-allow` lets a debugger
  attach. The app runs on the Mac that built it and on the devices the
  profile lists; Gatekeeper refuses it when downloaded.
- [ ] `.automatic` safe storage uses the login keychain: macOS asks once for
  "Chromium Safe Storage", and Always Allow lasts across rebuilds.

### Distribution builds (Developer ID, notarized)

- [ ] A Developer ID Application certificate (only the team's Account
  Holder can create one).
- [ ] A Developer ID provisioning profile when the app claims restricted
  entitlements (for iCloud Keychain passkeys).
- [ ] Store notary credentials once:
  `xcrun notarytool store-credentials notary` (an app-specific password, or
  an App Store Connect API key).
- [ ] Bundle, notarize and staple:

  ```sh
  swift package --allow-writing-to-package-directory --allow-network-connections all \
      cef bundle --product MyApp --sign "Developer ID Application: Example Corp (A1B2C3D4E5)" \
      --notarize --keychain-profile notary --package dmg
  ```

  This signs with the hardened runtime and a secure timestamp, wraps the app
  in a signed disk image, submits it with `xcrun notarytool submit --wait`,
  prints the notary log when Apple rejects it, and staples the ticket with
  `xcrun stapler staple`. A zip cannot hold a stapled ticket of its own, so
  with `zip` the plugin staples the app and zips it again.
- [ ] `swift package … cef doctor dist/MyApp.app` reports no errors, and
  `spctl --assess --type execute -vv dist/MyApp.app` prints
  `source=Notarized Developer ID`.

## Features

Each capability adds what its feature needs. Usage descriptions come from
`usageDescriptions`, by capability name, or from the same keys in
`infoPlist`; a capability without one is an error, except `passkeys`.

| Capability | Info.plist | Entitlements (hardened runtime) | Granted by | Notes |
|---|---|---|---|---|
| `camera` | `NSCameraUsageDescription` | `com.apple.security.device.camera` (app, base helper) | Any signature | `getUserMedia` video. |
| `microphone` | `NSMicrophoneUsageDescription` | `com.apple.security.device.audio-input` (app, base helper) | Any signature | `getUserMedia` audio, speech input. |
| `location` | `NSLocationUsageDescription` | `com.apple.security.personal-information.location` | Any signature | The Geolocation API, through Core Location. |
| `bluetooth` | `NSBluetoothAlwaysUsageDescription` | `com.apple.security.device.bluetooth` | Any signature | Web Bluetooth, and phones as passkeys. Chromium uses Bluetooth only when the responsible app's Info.plist has the key, so launch the app from Finder or `open`, not from a terminal that would be responsible for it. |
| `usb` | None | `com.apple.security.device.usb` | Any signature | WebUSB. WebHID and Web Serial need no entitlement outside the App Sandbox. |
| `localNetwork` | `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_googlecast._tcp`) | None | Any signature | Local network privacy (macOS 15 and later) applies to Cast discovery and to pages reaching local addresses. |
| `appleEvents` | `NSAppleEventsUsageDescription` | `com.apple.security.automation.apple-events` | Any signature | Sending Apple Events to other apps. |
| `passkeys` | `NSWebBrowserPublicKeyCredentialUsageDescription` (optional); includes `bluetooth` | `com.apple.developer.web-browser.public-key-credential` (restricted) | Apple, on request, to web browsers; in a provisioning profile | iCloud Keychain passkeys through AuthenticationServices. Request it from Apple with the [passkey entitlement request form](https://developer.apple.com/contact/request/macos-browsers-passkeys/); Apple then enables it for the App ID as a managed capability. |
| `defaultBrowser` | `CFBundleURLTypes` (`http`, `https`), `CFBundleDocumentTypes` (`public.html`, `public.xhtml`) | None | Any signature | The app can be chosen as the default browser, and can ask with `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`. `com.apple.developer.web-browser` is an iOS entitlement; macOS needs none. |
| `handoff` | `NSUserActivityTypes` (`NSUserActivityTypeBrowsingWeb`) | None | Any signature | Handoff of web pages. |

Under the hardened runtime, a missing resource entitlement makes the access
fail silently; without it, the entitlements are not enforced. The usage
description is needed either way: without it macOS ends the process that
asks.

Other features:

| Feature | Needs |
|---|---|
| Safe storage in the keychain ("Chromium Safe Storage") | A team signature: `.automatic` picks the keychain then. Ad hoc builds use `--use-mock-keychain`. See [Keychain access](guide.md#keychain-access). |
| Chromium's profile passkeys with Touch ID | Not available with CEF 156: Chromium checks for the keychain access group `.org.chromium.Chromium.webauthn`, compiled in from Chromium's branding with an empty team identifier, and a provisioning profile authorizes only groups that start with a team identifier. `CefPasskeyMode.app` with `CefKeychainPasskeyStore` verifies the user with Touch ID instead. |
| `CefKeychainPasskeyStore` | A team signature with a provisioning profile, which gives the app the `com.apple.application-identifier` entitlement the data protection keychain needs. Ad hoc builds get `errSecMissingEntitlement` (-34018). |
| Screen sharing (`getDisplayMedia`) | Nothing in the bundle; macOS asks the user for Screen Recording permission. |
| Notifications | Nothing in the bundle; macOS asks the user. The Alerts helper gets `NSUserNotificationAlertStyle`. |
| `NSAppTransportSecurity` | Nothing: Chromium does its own networking, which App Transport Security does not cover. |

### App Sandbox

CefSwift does not support the App Sandbox (`com.apple.security.app-sandbox`),
so it cannot ship in the Mac App Store. Chromium's own signing never uses it;
CEF documents only Developer ID distribution; and Chromium's processes talk
over Mach services and use interfaces the App Sandbox denies, which Electron,
the one Chromium-based framework with an App Store build, patches out of
Chromium for it. If the entitlements claim it, the plugin gives every helper
`com.apple.security.app-sandbox` and `com.apple.security.inherit`, as App
Sandbox child processes require, and warns. Chromium's own sandbox is
separate and supported: see [Sandbox](sandbox.md).

## cef doctor

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef doctor dist/MyApp.app [--json]
```

It reads the bundle with `codesign`, `security`, `spctl`, `stapler` and
`xattr`, and prints:

- the signature (ad hoc, Apple Development, Developer ID), the team, the
  hardened runtime and the secure timestamp;
- each helper's signature and entitlements, and whether the framework and
  its libraries are signed like the app;
- the embedded profile and its checks;
- Gatekeeper's verdict, the stapled ticket and the quarantine attribute;
- per feature, whether it works and what is missing; the safe-storage
  policy `.automatic` picks; and the passkey authenticators Chromium can
  offer.

It exits non-zero when it finds an error, something that stops the app from
launching, from loading a part, or from passing notarization. `--json`
prints the same report as JSON, with `errors` and `warnings` counts.

The plugin runs in SwiftPM's sandbox, where `spctl` cannot assess apps; the
report says so and the Gatekeeper line is informational. Run `spctl
--assess --type execute -vv <App.app>` in Terminal for that verdict.

For an ad hoc bundle with the hardened runtime, the summary reads:

```
SelfTest.app (dev.rajaniraiyn.cefswift.selftest)
  signature:      ad hoc, hardened runtime
  safe storage:   mock keychain
  passkeys:       security keys (USB/NFC)
```

At run time, `CefRuntime.shared.capabilities` (`CefAppCapabilities`) answers
the same questions from the running app's signature, and CefSwift logs one
line at start-up naming what the signature leaves out. See
[the guide](guide.md#signing-and-capabilities).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The app dies at launch with `SIGKILL (Code Signature Invalid)`; the log shows `taskgated-helper … Unsatisfied entitlements` or `AMFI` | A restricted entitlement no embedded profile authorizes, or a profile that does not match the bundle | `cef doctor`; embed a matching profile, or drop the entitlement. `cef bundle` refuses these combinations. |
| `errSecMissingEntitlement` (-34018) from the keychain | The data protection keychain without `com.apple.application-identifier`, as in ad hoc builds | Sign with a team identity and a profile. |
| A helper fails with `Library not loaded … code signature … not valid for use in process` | A library signed differently from the process (other team, or ad hoc under a team signature) | Bundle again; `cef doctor` names the library. |
| Renderers crash at start under the hardened runtime | The renderer helper lacks `allow-jit` | Keep the built-in helper entitlements; `cef doctor` flags it. |
| "MyApp is damaged" or "cannot be opened" on another Mac | The download is quarantined and the app is not notarized | Notarize. For a test only: `xattr -dr com.apple.quarantine MyApp.app`. |
| Notarization `Invalid` | Missing hardened runtime or timestamp, `get-task-allow`, or an unsigned nested binary | `cef notarize` prints the notary log; `cef doctor` names the part. |
| Camera, microphone or location requests fail without a prompt | A missing usage description or, under the hardened runtime, entitlement | Add the capability. |
| Phones are not offered as passkeys | No `NSBluetoothAlwaysUsageDescription`, or the app was started from a terminal, which becomes the responsible process | Add `bluetooth`; launch with `open`. |

## Flavors

| Flavor | Contents | Download (arm64 / x86_64) |
|---|---|---|
| `minimal` | The Release framework | About 135 MB / 142 MB |
| `standard` | Release and Debug builds | About 312 MB / 361 MB |

Bundles always contain the Release framework. `standard` is useful only when
you need CEF's Debug build from `.cef/dist/`.
