# Bundling

Chromium does not run from a bare executable. It needs an app bundle with
its framework and five helper apps, laid out as it expects. The `cef`
command plugin builds that bundle.

## The `cef` command

Run it from the root of the package that defines your app:

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product MyApp
```

The two `--allow-…` options pre-approve the plugin's permissions: it writes
`.cef/` and the bundle into the package directory and downloads CEF from
`cef-builds.spotifycdn.com`.

| Subcommand | Does |
|---|---|
| `download` | Downloads the pinned CEF distribution into `.cef/`, verifies its size and SHA-1, extracts it and converts the framework to the versioned layout. Does nothing if it is already prepared. |
| `bundle` | Builds the product, compiles the helper, then assembles and signs `<Name>.app`. Downloads CEF first if needed. |
| `info` | Prints the pinned CEF and Chromium versions and the state of the `.cef/` cache. |
| `clean` | Removes `.cef/`. |

Options of `bundle`:

| Option | Default | Effect |
|---|---|---|
| `--product <Name>` | Required | The executable product to bundle. |
| `--configuration debug\|release` | `release` | Build configuration. |
| `--output <dir>` | `dist` | Output directory, relative to the package. |
| `--bundle-id <id>` | `cefapp.json`, else `com.cefswift.<name>` | The app's bundle identifier. |
| `--name <Name>` | The product name | The app, executable and display name. |
| `--sign <identity\|->` | `cefapp.json`, else detected | Code-signing identity; `-` signs ad hoc. See [Code signing](#code-signing). |
| `--version <version>` | `cefapp.json`, else `1.0` | `CFBundleShortVersionString`, the version users see. |
| `--build <number>` | `cefapp.json`, else `1` | `CFBundleVersion`, the build number. |
| `--flavor minimal\|standard` | `minimal` | Which CEF distribution to download. See [Flavors](#flavors). |
| `--platform macosarm64\|macosx64` | The build machine's | Which architecture's CEF to bundle. |
| `--manifest <path>` | `CEF_VERSION.json` | A different CEF manifest. |

`download` takes `--platform`, `--flavor` and `--manifest` as well, and
`info` takes `--manifest`. `swift package cef help` prints the usage.

The plugin finds `CEF_VERSION.json` in the invoking package or in any of its
dependencies, so an app that depends on CefSwift uses the CEF version that
CefSwift pins. To bundle a different CEF version, pass `--manifest` with a
`CEF_VERSION.json` pinned to it. That CEF build must still provide the
`CEF_API_VERSION` the vendored headers pin, with the same API hash, or the
app fails to start with `CefError.apiHashMismatch` or `CefError.loadFailed`.

The cache lives in the invoking package's `.cef/`. Add `.cef/` and `dist/`
to `.gitignore`.

## Per-product settings

A `cefapp.json` beside the product's sources sets defaults that the
command-line options override:

```json
{
  "bundleIdentifier": "com.example.myapp",
  "displayName": "My App",
  "version": "2.1",
  "build": "214",
  "minimumSystemVersion": "15.0",
  "signingIdentity": "Developer ID Application: Example (TEAMID)"
}
```

Every key is optional. `version` and `build` default to `1.0` and `1`.
`minimumSystemVersion` defaults to the deployment target the product was
built for — the macOS version in the package's `platforms` — or `14.0`
when the executable does not record one. If you
keep `cefapp.json` in the target's directory, exclude it in `Package.swift`
(`exclude: ["cefapp.json"]`), as the examples do, so SwiftPM does not warn
about an unhandled file.

## Bundle anatomy

```
MyApp.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo
    ├── MacOS/
    │   └── MyApp                          # your product
    └── Frameworks/
        ├── libcefswift_helper_startup.dylib   # seals the helpers' sandbox
        ├── Chromium Embedded Framework.framework/
        │   ├── Versions/
        │   │   ├── A/
        │   │   │   ├── Chromium Embedded Framework   # the library itself
        │   │   │   ├── Resources/                    # .pak files, locales, icudtl.dat
        │   │   │   └── Libraries/                    # ANGLE, SwiftShader, libcef_sandbox.dylib
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

`CFBundleShortVersionString` and `CFBundleVersion` come from `--version`
and `--build`, or `version` and `build` in `cefapp.json`, and default to
`1.0` and `1`. The helpers carry the same values.

Each helper's `Info.plist` adds:

| Key | Value | Why |
|---|---|---|
| `LSUIElement` | `true` | Helpers never appear in the Dock or the app switcher. |
| `LSFileQuarantineEnabled` | `true` | Files that helper processes write are quarantined, as in other browsers. |

## Code signing

The plugin signs inside out, each nested item before its container: the
framework, the helper startup library, each helper app, then the app. The identity is, in order of
precedence:

1. `--sign <identity>`, or `--sign -` for ad hoc.
2. `signingIdentity` in `cefapp.json`.
3. The first "Apple Development" identity in your keychain, else the first
   "Developer ID Application" identity.
4. Ad hoc, when there is none.

An ad hoc signature is enough to run the app on the machine that built it.
It changes with every build, which affects keychain access: see
[Keychain access](guide.md#keychain-access).

The plugin signs without the hardened runtime and without a secure
timestamp, so its bundles are for development.

## Distributing

Gatekeeper refuses an ad hoc signed app that was downloaded, because the
download carries the `com.apple.quarantine` attribute. For testing on another
Mac, the recipient can remove it with
`xattr -dr com.apple.quarantine MyApp.app`.

To distribute, re-sign the bundle inside out with a Developer ID identity,
the hardened runtime (`codesign --options runtime --timestamp`) and the
entitlements Chromium needs, such as `com.apple.security.cs.allow-jit`; then
notarize with `xcrun notarytool submit` and staple the ticket with
`xcrun stapler staple`. The plugin does not do this. See CEF's
documentation for the entitlements each helper needs.

## Flavors

| Flavor | Contents | Download (arm64 / x86_64) |
|---|---|---|
| `minimal` | The Release framework | About 135 MB / 142 MB |
| `standard` | Release and Debug builds | About 312 MB / 361 MB |

Bundles always contain the Release framework. `standard` is useful only when
you need CEF's Debug build from `.cef/dist/`.
