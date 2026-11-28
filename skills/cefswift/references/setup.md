# Setup, bundling and shipping

Details: `docs/bundling.md` in the CefSwift checkout, or
https://rajaniraiyn.dev/cefswift/ship/tracks.

## Package

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Rajaniraiyn/CefSwift", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "CefSwiftUI", package: "CefSwift"),
                // .product(name: "CefChromium", package: "CefSwift"),
                // .product(name: "CefPasskeys", package: "CefSwift"),
            ],
            exclude: ["cefapp.json"]
        ),
    ]
)
```

- macOS 14 is the minimum. SwiftUI APIs such as
  `.defaultLaunchBehavior(.suppressed)` need `.macOS(.v15)`.
- `exclude` keeps SwiftPM from warning about `cefapp.json` and
  entitlements files kept beside the sources.
- A Swift 6 toolchain. The Command Line Tools are enough for SwiftPM,
  plain `swift build` and `swift package cef bundle` included; Xcode 16 or
  later only for Xcode projects. Three tracks build the same bundle: a
  SwiftPM package, a hand-written SwiftUI app with plain SwiftPM, or an
  Xcode project. Prefer `@Environment` keys written out by hand over
  `@Entry` in app code, so the app builds with the Command Line Tools too.

## The cef command

All subcommands need both `--allow-…` options:

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyApp            # build, assemble, sign: dist/MyApp.app
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef doctor dist/MyApp.app             # check the bundle; non-zero on errors
```

Other subcommands: `download`, `package <App.app>` (zip or dmg),
`notarize <App.app>`, `info`, `clean`. `bundle` options:
`--configuration debug|release` (default release), `--output <dir>`,
`--bundle-id`, `--name`, `--version`, `--build`, `--sign <identity|->`,
`--capability <name>` (repeatable), `--entitlements`,
`--provisioning-profile`, `--package zip|dmg`, `--notarize
--keychain-profile <name>`.

## cefapp.json

Beside the executable target's sources. JSON5: comments and trailing commas
allowed. Unknown keys are errors.

```json
{
  "bundleIdentifier": "com.example.browser",
  "displayName": "Example Browser",
  "minimumSystemVersion": "15.0",
  "capabilities": ["camera", "microphone", "location", "defaultBrowser"],
  "usageDescriptions": {
    "camera": "Websites you allow can use the camera.",
    "microphone": "Websites you allow can use the microphone.",
    "location": "Websites you allow can see your approximate location."
  },
  "cef": { "localizations": "all" }
}
```

Capabilities: `camera`, `microphone`, `location`, `bluetooth`, `usb`,
`localNetwork`, `appleEvents`, `passkeys` (restricted entitlement, needs a
provisioning profile), `defaultBrowser`, `handoff`, `protectedMedia`
(Widevine under a team-signed hardened runtime). Each one except `passkeys`
needs a usage description where macOS shows one.

## Signing tracks

| Track | How | Runs on |
|---|---|---|
| Ad hoc | `cef bundle` with no identity in the keychain | The Mac that built it |
| Apple Development | Certificate in the login keychain; picked up automatically | That Mac and the profile's devices |
| Developer ID, notarized | `--sign "Developer ID Application: …" --notarize --keychain-profile notary` after `xcrun notarytool store-credentials notary` | Any Mac |

## Xcode track

1. New macOS App (SwiftUI). Add the package
   `https://github.com/Rajaniraiyn/CefSwift`, product `CefSwiftUI`.
2. Signing & Capabilities: remove App Sandbox.
3. Copy `Examples/Xcode/CefSwift.xcconfig` into the project and set it as
   the target's configuration file. For a local package, set
   `CEFSWIFT_PACKAGE_DIR` to its path.
4. Build Phases: add a Run Script phase at the end, untick "Based on
   dependency analysis", script `"$CEFSWIFT_PACKAGE_DIR/Scripts/xcode-embed.sh"`.
5. Set `ENABLE_USER_SCRIPT_SANDBOXING = NO` if the phase reports
   `Sandbox: … deny(1) file-read-data`.

## Common failures

| Symptom | Fix |
|---|---|
| `CefError.frameworkNotFound` at launch | You ran `swift run` or the bare executable. Run the bundle. |
| `bootstrap_check_in …MachPortRendezvousServer…: Permission denied (1100)` | App Sandbox is on. Remove it. |
| `SIGKILL (Code Signature Invalid)` | A restricted entitlement with no matching profile. `cef doctor`. |
| Camera or microphone fails without a prompt | Add the capability and its usage description. |
| `external macro implementation type 'SwiftUIMacros…' could not be found` | A CefSwift older than #35 (or your own code) uses a SwiftUI macro such as `@Entry`, whose plugin the Command Line Tools lack. Update CefSwift to a version that includes #35, or point `SDKROOT` at the 26.x SDK (`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift package …`), and write environment keys out by hand instead of `@Entry`. You do not need Xcode. |
| `CefChromeWindow.open` throws "Chromium did not open the window" on a cold first launch | CefChromium's hidden service host took longer than its timeout, seen on a Mac under heavy CPU load. Relaunch. |
| "MyApp is damaged" on another Mac | Notarize, or for a test `xattr -dr com.apple.quarantine MyApp.app`. |
