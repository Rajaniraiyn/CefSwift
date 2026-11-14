# Bundling

Chromium does not run from a bare executable. It needs an app bundle with
its framework and five helper apps, laid out as it expects, each part
signed. CefSwift builds that bundle in either of two ways, and both run one
implementation, the package's `cefswift` tool (`Sources/CefBundling`):

| | SwiftPM | Xcode |
|---|---|---|
| Who builds the app | `swift package cef bundle`, the `cef` command plugin, with SwiftPM | Xcode, as for any app target |
| Who adds the framework and helpers | The plugin, through `cefswift bundle` | A Run Script phase, through `cefswift embed` ([Xcode](#xcode)) |
| Who signs the app | `cefswift`, last | Xcode, last; `cefswift` signs the parts inside first, with the build's identity |
| Settings | [`cefapp.json`](#per-product-settings) and options | Xcode's build settings, and `CEF_…` ones ([Settings](#settings)) |
| CEF download and cache | `.cef/` in the package | `.cef/` beside the project (`CEF_CACHE_DIR`) |
| Checks | `swift package cef doctor` | The phase runs `cef doctor`'s checks on every build, as Xcode errors and warnings |

What goes in the bundle, how it is signed and what each feature needs is
the same either way, and the rest of this page applies to both.

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
| `bundle` | Builds the product, compiles the helper, then assembles and signs `<Name>.app`. Downloads CEF first if needed. See [What `bundle` puts in the app](#what-bundle-puts-in-the-app). |
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
| `--product <Name>` | Required | The executable product to bundle, from the invoking package or a dependency. |
| `--configuration debug\|release` | `release` | Build configuration. |
| `--output <dir>` | `dist` | Output directory, relative to the package. |
| `--config <file>` | `cefapp.json` beside the sources of the product's executable target | The settings file. See [Per-product settings](#per-product-settings). |
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
| `--platform macosarm64\|macosx64` | The build machine's | Which architecture's CEF to bundle. It must be the architecture SwiftPM builds for, which is the one `swift package` runs as; anything else is an error. Run `arch -x86_64 swift package …` to bundle for Intel on Apple silicon. |
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

The plugin finds the product in the package graph, builds it, the helper
and the helper's startup library with SwiftPM, and runs `cefswift` for the
rest: it checks the settings before building, downloads CEF, then
assembles and signs the bundle.

## Xcode

An Xcode app target builds, embeds and signs the app as it always does. A
Run Script phase at the end of its build phases adds what Chromium needs,
before Xcode signs the app:

1. Add the package (File › Add Package Dependencies…, or Add Local… for a
   local copy) and its `CefSwiftUI` product (or `CefKit`) to the app
   target. Xcode builds CefSwift and copies its resource bundles
   (`CefSwift_CefKit.bundle`) into the app, where `Bundle.module` finds
   them.
2. Remove App Sandbox in Signing & Capabilities (see
   [App Sandbox](#app-sandbox)). Keep the hardened runtime.
3. Give the target CefSwift's settings: copy
   [`Examples/Xcode/CefSwift.xcconfig`](../Examples/Xcode/CefSwift.xcconfig)
   into the project and choose it as the target's configuration file
   (Project › Info › Configurations), or set them yourself:

   | Setting | Value | Why |
   |---|---|---|
   | `ENABLE_USER_SCRIPT_SANDBOXING` | `NO` | The phase runs SwiftPM on the package and writes the helper apps into the app; a sandboxed script can do neither. |
   | `ARCHS` | `$(NATIVE_ARCH_ACTUAL)` | A CEF distribution holds one architecture; Release builds otherwise build for both. See [Universal apps](#universal-apps). |
   | `CEFSWIFT_PACKAGE_DIR` | `$(BUILD_DIR)/../../SourcePackages/checkouts/CefSwift` | Where Xcode put the package, to find the phase's script. For a local package, its path. |
   | `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION` | `YES`, only while the target signs ad hoc | See [Signing in Xcode](#signing-in-xcode). |

   A setting in the target's Build Settings wins over the file, so remove
   the target's own `ENABLE_APP_SANDBOX` (step 2 does) if it is there.
4. In Build Phases, add a Run Script phase after all the others, turn off
   "Based on dependency analysis" (the phase decides for itself what is
   out of date), and set it to run:

   ```sh
   "$CEFSWIFT_PACKAGE_DIR/Scripts/xcode-embed.sh"
   ```

5. Make the app's `@main` type a `CefSwiftApp` instead of an `App`, and
   Run.

[`Examples/Xcode`](../Examples/Xcode) is a project set up this way; see
[Examples](../Examples/README.md#xcode).

The phase (`Scripts/xcode-embed.sh`, then `cefswift embed`):

- builds `cefswift`, `cefswift-helper` and its startup library with
  SwiftPM, in release, into `$(OBJROOT)/CefSwift` (about a minute, the
  first time; later, only when their sources change), with a clean
  environment so that Xcode's settings do not reach that build;
- downloads the pinned CEF distribution into `CEF_CACHE_DIR` on first use;
- adds `LSEnvironment` (`MallocNanoZone = 0`) and `NSPrincipalClass` to the
  app's Info.plist and, from `CEF_CAPABILITIES`, the capabilities' keys;
  Xcode's own keys win;
- copies the framework, trimmed ([locale packs](#locale-packs),
  [SwiftShader](#software-gpu-fallback)), the startup library and the five
  [helper apps](#helper-apps) into `Contents/Frameworks`, and signs them
  inside out with the build's identity (`EXPANDED_CODE_SIGN_IDENTITY`),
  hardened runtime (`ENABLE_HARDENED_RUNTIME`) and keychain
  (`OTHER_CODE_SIGN_FLAGS`), giving each helper what it needs of the app's
  entitlements: get-task-allow (so a debugger can attach), camera and
  microphone access for the base helper, and `allow-jit` for the renderer
  and GPU helpers;
- runs `cef doctor`'s checks of the helpers, the framework, linking and
  features on the app as Xcode is about to sign it, as Xcode errors and
  warnings in the Issue navigator (`CEF_DOCTOR = NO` turns them off).

When nothing that decides these parts has changed, an incremental build
leaves them as they are (what decides them: the CEF version and
framework, the architectures, the app's Info.plist and localizations,
every entitlement and its value, the signing identity, keychain and
flags, the trimming settings, cefapp.json's contents, and the helper and
`cefswift` as built), without running SwiftPM, and the phase takes
about 2 seconds, most of it `cef doctor`'s checks (measured with the Xcode
example on an M3; the whole incremental build took 3.7 s). Xcode then signs the app, sealing everything inside.

The app's own entitlements stay Xcode's (`CODE_SIGN_ENTITLEMENTS` and the
entitlement build settings). When a capability or the signature needs one
the app lacks, the phase stops the build and names the setting, such as
`ENABLE_RESOURCE_ACCESS_CAMERA = YES`.

The app executable is not linked to the framework, as `cef bundle` links
it (the helpers are): CefKit loads the framework with `dlopen`, so the app
process holds the framework's 12 MB of fixed-up pointers privately (see
[architecture](architecture.md#loading-the-framework-at-launch)). Linking
the app needs the framework before the target links, which a binary
framework product gives Xcode ([Where CEF comes from](#where-cef-comes-from)).

### Signing in Xcode

Xcode signs with "Sign to Run Locally" (ad hoc) until the target has a
team. Library validation, part of the hardened runtime, loads a library
only when it carries the process's team identifier, and an ad hoc
signature has none, so an ad hoc, hardened app cannot load CEF's framework
(nor Xcode's own `.debug.dylib`: "mapping process and mapped file
(non-platform) have different Team IDs"). Xcode 27 turns the hardened
runtime off for Debug builds signed ad hoc, so they run; Release builds
keep it, and need `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = YES`
until the target signs with a team. The phase stops a build that would
fail this way. With a team (Apple Development, Developer ID), every part
carries the team, and no exception is needed.

Xcode turns `RUNTIME_EXCEPTION_*` build settings into entitlements from
version 26. With an older Xcode, add the
`com.apple.security.cs.disable-library-validation` entitlement to the
target's `.entitlements` file instead, for as long as it signs ad hoc.

### Debugging and previews

Run in Xcode starts the app, Chromium's browser process, under the
debugger. Renderers, the GPU process and utilities are the helper
processes; to debug one, use Debug › Attach to Process by PID or Name with
`<App> Helper (Renderer)` (or another helper) and "Wait for the next
launch", then do what starts it, such as opening a page. The helpers have
get-task-allow whenever the app does, as in Debug builds. Chromium's
switches go in the scheme's arguments: `--renderer-startup-dialog` pauses
each renderer until a debugger attaches, and `--no-sandbox` runs without
Chromium's sandbox once.

SwiftUI previews run the app's code inside a process of Xcode's, where
Chromium cannot start its helpers. `CefSwiftApp` does not start Chromium in
previews (`XCODE_RUNNING_FOR_PREVIEWS`), and a `CefWebView` shows a
placeholder until Chromium runs, so a `#Preview` of a view that contains
one renders the rest of the view. Run the app to see the page. An AppKit
host view (`CefWindowedBrowserView`) needs a running runtime; keep it out
of previews.

### Universal apps

A CEF distribution, and so the framework the phase embeds, holds one
architecture, so the target builds for the Mac it builds on
(`ARCHS = $(NATIVE_ARCH_ACTUAL)`); `swift package cef bundle` does the
same. An app for both Apple silicon and Intel needs a universal framework,
which the XCFramework of [pull request #27](#where-cef-comes-from) is.

## Settings

Each setting has one place in each track: Xcode's own build setting where
Xcode has one, a `CEF_…` build setting where only CefSwift does, and a key
of [`cefapp.json`](#per-product-settings) (or an option of `cef bundle`) for
SwiftPM. `CEF_APP_CONFIG` names a `cefapp.json` for an Xcode build to read
as well, so a project built both ways keeps CefSwift's settings in one
file: a `CEF_…` setting wins over it, and for the keys Xcode owns, the
phase warns, at the key's line, when the file disagrees with Xcode.

| Setting | Xcode | `cefapp.json` (option) |
|---|---|---|
| Bundle identifier (helpers: `<id>.helper…`) | `PRODUCT_BUNDLE_IDENTIFIER` | `bundleIdentifier` (`--bundle-id`) |
| App and executable name (helpers: `<name> Helper…`) | `PRODUCT_NAME` | The product name (`--name`) |
| Display name | `INFOPLIST_KEY_CFBundleDisplayName` | `displayName` |
| Version, build | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` | `version`, `build` |
| Minimum macOS | `MACOSX_DEPLOYMENT_TARGET` | `minimumSystemVersion` |
| Info.plist keys | `INFOPLIST_KEY_…`, `INFOPLIST_FILE` | `infoPlist` (`--info-plist`) |
| Usage descriptions | `INFOPLIST_KEY_NSCameraUsageDescription`, … | `usageDescriptions` |
| Capabilities ([features](#features)) | `CEF_CAPABILITIES`; camera and microphone also follow from `ENABLE_RESOURCE_ACCESS_CAMERA` and `…_AUDIO_INPUT` | `capabilities` (`--capability`) |
| App entitlements | `CODE_SIGN_ENTITLEMENTS`, `ENABLE_RESOURCE_ACCESS_…`, `RUNTIME_EXCEPTION_…` | `entitlements` (`--entitlements`) |
| Helper entitlements | `CEF_HELPER_ENTITLEMENTS_HELPER`, `…_ALERTS`, `…_GPU`, `…_PLUGIN`, `…_RENDERER` | `helperEntitlements` |
| Signing identity, team | `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM` | `signingIdentity`, `teamIdentifier` (`--sign`, `--team-id`) |
| Keychain | `OTHER_CODE_SIGN_FLAGS = --keychain <file>` | `signingKeychain` (`--keychain`) |
| Hardened runtime | `ENABLE_HARDENED_RUNTIME` | `hardenedRuntime` (`--[no-]hardened-runtime`) |
| Secure timestamp | `OTHER_CODE_SIGN_FLAGS = --timestamp`; Xcode's Developer ID export adds one | `timestamp` (`--[no-]timestamp`) |
| Provisioning profile | Signing & Capabilities (`PROVISIONING_PROFILE_SPECIFIER`) | `provisioningProfile` |
| Locale packs kept | `CEF_LOCALIZATIONS` (`application`, `all`, or a list: `en fr`) | `cef.localizations` (`--localizations`) |
| SwiftShader | `CEF_SOFTWARE_GPU_FALLBACK` (`include`, `exclude`) | `cef.softwareGPUFallback` (`--software-gpu-fallback`) |
| CEF version | `CEF_MANIFEST` (a `CEF_VERSION.json`) | `--manifest` |
| CEF flavor | `CEF_FLAVOR` | `--flavor` |
| CEF cache | `CEF_CACHE_DIR`, default `$(PROJECT_DIR)/.cef` | `.cef/` in the package |
| Notarization | The Organizer, or `xcrun notarytool` ([Distribution](#distribution)) | `notarization` (`--notarize`) |
| `cef doctor` | Every build (`CEF_DOCTOR = NO` turns it off), and `cefswift doctor <App.app>` | `swift package cef doctor` |

Helper names and bundle identifiers derive from the app's, because
Chromium finds the helpers by name; neither is a setting.

For CI and offline builds, keep the cache between runs: `.cef/downloads`
holds the archive (about 135 MB) and `.cef/dist` the prepared framework.
With the archive there, nothing is downloaded; a clone of another `.cef`
(`cp -Rc`) works as well.

## Where CEF comes from

Both tracks download the official CEF distribution that `CEF_VERSION.json`
pins (the minimal flavor, for the build machine's architecture) from
`cef-builds.spotifycdn.com`, check its size and SHA-1, convert the
framework to the versioned layout, and keep it in the cache: `.cef/` in the
package for SwiftPM, `CEF_CACHE_DIR` for Xcode. An app that depends on
CefSwift uses the version CefSwift pins.

[Pull request #27](https://github.com/Rajaniraiyn/CefSwift/pull/27), not
merged, packages the same official framework, both architectures, as an
XCFramework binary target that SwiftPM and Xcode fetch and verify
themselves (`ChromiumEmbeddedFramework`). With it, an Xcode target adds
that product, so Xcode embeds and signs the framework (Embed & Sign), links
the app to it, and builds universal apps; the build phase then sets
`CEF_EMBED_FRAMEWORK = NO`, keeps Xcode's copy, and adds the startup
library and helpers, which no binary target can provide: their names and
bundle identifiers derive from the app's, and the helper must link the
startup library before the framework. The SwiftPM track would take the
framework from the same binary target instead of `.cef/`.

## Per-product settings

A `cefapp.json` beside the sources of the product's executable target (the
target, whatever its name, that the product's `targets` names) sets what the command-line
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
  "notarization": { "keychainProfile": "notary", "format": "zip" }
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
| `cef.localizations` | `"application"` | Which of Chromium's locale packs the app keeps: `"application"`, `"all"`, or a list of localizations. As `--localizations`. See [Locale packs](#locale-packs). |
| `cef.softwareGPUFallback` | `"include"` | `"exclude"` leaves out SwiftShader. As `--software-gpu-fallback`. See [Software GPU fallback](#software-gpu-fallback). |

An Xcode target takes these from its build settings instead, or reads a
`cefapp.json` named by `CEF_APP_CONFIG`: see [Settings](#settings).

If you keep `cefapp.json` and entitlements files in the target's directory,
exclude them in `Package.swift` (`exclude: ["cefapp.json",
"MyApp.entitlements"]`), as the examples do, so SwiftPM does not warn about
unhandled files. The Browser example's
[`cefapp.json`](../Examples/Sources/Browser/cefapp.json) uses most keys, and
its `Browser-Distribution.entitlements` is a template for a team-signed
build.

## What `bundle` puts in the app

`bundle` collects what the SwiftPM build of the product produced:

- The executable.
- The resource bundle of each target the product is built from, its
  dependencies' targets included, that declares resources:
  `<Package>_<Target>.bundle`, the bundle `Bundle.module` loads, CefKit's
  and CefPasskeys' (the built-in sheets' strings) among them. They go in
  `Contents/Resources/` (`Bundle.main.resourceURL`), where CefSwift's
  targets look, as does the `Bundle.module` that Xcode and SwiftPM's
  Swift Build system generate. A missing one is an error. The
  `Bundle.module` of SwiftPM's older native build system, Swift 6.1's
  default, looks in the app's root directory instead, where code signing
  allows no files, and then in the build directory: on the Mac that built
  the app it works, elsewhere it stops the app. A target of your own that
  loads resources and is built that way should look in
  `Bundle.main.resourceURL` first, as CefSwift's do.
- Each dynamic library and framework the executable loads through `@rpath`
  from the build directory, such as a `.dynamic` library product of a
  dependency, and the ones those load. They go in `Contents/Frameworks/`.
  The Swift runtime and the system's libraries are part of macOS and are
  not copied.

The build links executables with run paths into the build directory and
the toolchain. `bundle` removes each absolute run path outside `/usr/lib`
and `/System` from the binaries it copies, and adds
`@executable_path/../Frameworks` to the app's executable, so the app loads
its libraries from the bundle on every Mac, the build machine included.
Every Mach-O file in the bundle must have the product's architecture.

`bundle` assembles the app in a staging directory beside the destination,
signs it there, and only then replaces `<Name>.app`. A build that fails
leaves the previous app as it was. `cef doctor` lists the app's libraries
and resource bundles and reports code that loads or searches for
libraries outside the bundle.

## What `bundle` leaves out of the framework

The framework's binary is 226 MiB of the 333 MiB a bundle with every part
of the framework takes. Of the rest, `bundle` can leave out two parts that
an app may not need. It removes them from the copy in the bundle, before
signing; the shared cache in `.cef/` keeps everything.

| Part | Size | Default |
|---|---|---|
| Locale packs for languages the app is not localized in (55 packs, 0.6 to 1.5 MiB each) | 48.9 MiB for an English-only app | Left out |
| SwiftShader (`libvk_swiftshader.dylib`, `libvulkan.dylib`, `vk_swiftshader_icd.json`) | 16.1 MiB | Kept |

Measured with the Minimal example (English only), CEF 156.0.28 arm64,
logical size:

| Bundle | Size |
|---|---|
| `--localizations all` | 333.0 MiB |
| Default (`application`: `en` only) | 284.0 MiB |
| Default and `--software-gpu-fallback exclude` | 268.0 MiB |

The rest stays: `resources.pak` and the two `chrome_*_percent.pak` files
hold resources every runtime style loads (DevTools' frontend among them,
4.5 MiB, with no separate file to drop); `icudtl.dat` is the Unicode and
locale data behind text segmentation, collation and `Intl`; the V8
snapshot is what renderers start from; `libcef_sandbox.dylib` seals the
helpers' sandbox. `cef doctor` reports what a bundle contains (see
[cef doctor](#cef-doctor)).

### Locale packs

Chromium's interface strings come in one pack per locale,
`Resources/<locale>.lproj/locale.pak`, with three small grammatical-gender
variants beside each. With `"localizations": "application"`, the default,
`bundle` keeps the packs for:

- each localization in the app's `CFBundleLocalizations`, from
  `cefapp.json`'s `infoPlist`. When the Info.plist does not set it and the
  app's resource bundles are localized (`.lproj` directories, as a String
  Catalog produces), `bundle` sets `CFBundleLocalizations` to their
  localizations, so that macOS picks the app's language from them.
  CefSwift's own bundles do not count: their languages are not the app's;
- the development language, `CFBundleDevelopmentRegion` (`en`);
- English, Chromium's last fallback.

Localizations map onto packs as `CefRuntime.Localization` resolves them at run
time, so the runtime only asks for packs the bundle has: `fr-CA` keeps
`fr`, `pt` keeps `pt_BR`, `zh-Hant` keeps `zh_TW`, `en-AU` keeps `en_GB`.
`bundle` warns about a localization Chromium has no pack for (`ga`, `eu`,
…); Chromium's interface uses the development language there.

```json
{
  "infoPlist": { "CFBundleLocalizations": ["en", "fr", "de", "pt-BR"] },
  "cef": { "localizations": "application" }
}
```

`"all"` keeps every pack, for a browser whose users pick any interface
language. A list, such as `["en", "ja"]`, keeps those packs, the
development language's and English, whatever the app declares.
`--localizations application|all|en,ja` overrides `cefapp.json`.

### Software GPU fallback

SwiftShader is Chromium's software implementation of Vulkan, which ANGLE
can run WebGL on without a GPU. In CEF 156 Chromium uses it only when told
to (`--use-angle=swiftshader` or `--enable-unsafe-swiftshader`); it does not
fall back to it by itself. Measured with SelfTest on an M3:

| Bundle, switches | Pages render, windowed and offscreen | WebGL |
|---|---|---|
| With SwiftShader | Yes | ANGLE on Metal |
| With SwiftShader, `--disable-gpu` | Yes, composited on the CPU | None |
| With SwiftShader, `--disable-gpu --enable-unsafe-swiftshader` | Yes | ANGLE on SwiftShader |
| Without SwiftShader | Yes | ANGLE on Metal |
| Without SwiftShader, `--disable-gpu` (with or without `--enable-unsafe-swiftshader`) | Yes | None |

`"softwareGPUFallback": "exclude"` (or `--software-gpu-fallback exclude`)
saves 16.1 MiB and removes WebGL only where an app asks for SwiftShader,
typically for a GPU-less virtual machine or a CI runner. Accelerated
offscreen frames (IOSurfaces) need the GPU either way.

## Bundle anatomy

```
MyApp.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo
    ├── embedded.provisionprofile              # when provisioningProfile is set
    ├── MacOS/
    │   └── MyApp                          # your product
    ├── Resources/
    │   ├── MyApp_MyApp.bundle             # each target's resources (Bundle.module)
    │   └── CefSwift_CefKit.bundle         # the built-in sheets' strings
    └── Frameworks/
        ├── libMyLibrary.dylib             # dynamic libraries the product loads
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
("alerts") services as separate processes. The Alerts helper runs only
when the app turns system notifications on
([`services.systemNotifications`](guide.md#system-notifications)); it is
bundled either way. On macOS each process type is an
app of its own, with its own bundle identifier and `Info.plist`. All five
contain the same binary, copied and renamed.

That binary is CefSwift's `cefswift-helper` product, a Swift executable
(`Sources/CefHelper`) with no code of the app's, which both tracks build
with SwiftPM, together with the `cefswift_helper_startup` library. The
helper links `libcefswift_helper_startup.dylib` and then the framework, so
dyld loads both at launch (`HelperLink.swift` has the linker flags), and
`cef bundle` builds the app product with a weak link to the framework
(`-weak_framework`). Libraries loaded at launch keep the framework's 12 MB
of fixed-up pointers as shared, clean memory in every process; see
[architecture](architecture.md#loading-the-framework-at-launch). An app
executable without the link, as an Xcode target's is, runs as well, since
CefKit loads the framework with `dlopen` if dyld has not, but that process
then holds the 12 MB privately.

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

In Xcode, the identity is the build's, `EXPANDED_CODE_SIGN_IDENTITY`, and
the team `DEVELOPMENT_TEAM`: the phase signs the parts inside the app with
what Xcode then signs the app with ([Signing in Xcode](#signing-in-xcode)).

### Order and options

The plugin signs inside out, each item before what contains it, and never
with `--deep`:

1. Each Mach-O file in the framework's `Libraries/`. CEF ships them
   linker-signed ad hoc; re-signing them with the app's identity is what lets
   library validation load them.
2. The framework.
3. `libcefswift_helper_startup.dylib`.
4. The app's own libraries and frameworks.
5. Each resource bundle that has an `Info.plist`; a flat one is sealed as
   resources by the app's signature.
6. Each helper app, with its entitlements.
7. The app, with its entitlements and the embedded profile.

Executables (the app and helpers) get `--options runtime` when the hardened
runtime is on; libraries and the framework take no options or entitlements,
since they run with those of the process that loads them. `--timestamp`
adds a secure timestamp (it needs a network connection); otherwise the
plugin passes `--timestamp=none`, so signing works offline.

| Identity | Hardened runtime | Timestamp | `get-task-allow` |
|---|---|---|---|
| Ad hoc | Off (with `--hardened-runtime`, `disable-library-validation` is added) | Off | No |
| Apple Development | On | Off | Added, so the app can be debugged |
| Developer ID Application | On | On | Refused: notarization rejects it |

### Entitlements

Each part's entitlements are built from:

| Part | Built in | Added |
|---|---|---|
| App | None | Each capability's; the `entitlements` file's; with a profile, `com.apple.application-identifier` and `com.apple.developer.team-identifier` from it, as Xcode adds them |
| Renderer, GPU helpers | `com.apple.security.cs.allow-jit` | `helperEntitlements` |
| Base helper | None | `device.camera` and `device.audio-input` from those capabilities (Chromium can run its video capture and audio services there); `cs.disable-library-validation` from `protectedMedia`, for Widevine; `helperEntitlements` |
| Alerts, Plugin helpers | None | `helperEntitlements` |

The built-in ones follow CEF's
[code signing guide](https://chromiumembedded.github.io/cef/code_signing)
and Chromium's `chrome/app/helper-renderer-entitlements.plist` and
`helper-gpu-entitlements.plist`: V8 and the GPU process's shader compilers
generate code at run time, which the hardened runtime allows only with
`allow-jit`.

Library validation, part of the hardened runtime, loads a library only when
it carries the process's team identifier (or Apple's). With a team
signature that holds for every library, since the plugin signs each one,
the startup library and CEF's own included, with the app's identity; no part
needs `com.apple.security.cs.disable-library-validation`, except for
Google's Widevine CDM. Chromium downloads the CDM at run time, Google's team
signs it, and it loads into the base helper (`<App> Helper.app`, in the
utility process `media.mojom.CdmServiceBroker`), where a team signature's
library validation refuses it. The `protectedMedia` capability adds
`disable-library-validation` to that helper only. Chrome needs no such
entitlement because Google signs both Chrome and the CDM. A signature without
a team (ad hoc or self-signed) matches nothing, and the framework fails to
load with "mapping process and mapped file (non-platform) have different
Team IDs". With the hardened runtime on such a signature, the plugin adds
`disable-library-validation` to the app and every helper and says so.

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
  "<bundle identifier> Safe Storage", and Always Allow lasts across rebuilds.

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
      --notarize --keychain-profile notary
  ```

  This signs with the hardened runtime and a secure timestamp, zips the app
  with `ditto`, submits it with `xcrun notarytool submit --wait`, prints the
  notary log when Apple rejects it, staples the ticket to the app with
  `xcrun stapler staple`, and zips the stapled app again (a zip cannot carry
  a ticket of its own). With `--package dmg` it wraps the app in a disk
  image signed with the same identity and staples the disk image instead;
  see [SwiftPM's plugin sandbox](#swiftpms-plugin-sandbox) for where that
  runs. This path follows Apple's notarization documentation and has not
  been run against Apple's service.
- [ ] `swift package … cef doctor dist/MyApp.app` reports no errors, and
  `spctl --assess --type execute -vv dist/MyApp.app` prints
  `source=Notarized Developer ID`.
- [ ] For Widevine, with `"protectedMedia"` in `capabilities`: the
  Browser example's `browser://playground/widevine.html` plays and says
  "Playing with com.widevine.alpha". (Not yet run with a team signature.)

### With Xcode

Signing with a team, archiving and exporting are Xcode's, as for any app;
the build phase signs the parts inside with the archive's identity. Not
yet run with a team signature or against Apple's notary service:

- [ ] Choose the team in Signing & Capabilities; remove
  `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION` if the target has it.
- [ ] Product › Archive (`xcodebuild archive -scheme MyApp -archivePath
  MyApp.xcarchive`).
- [ ] Organizer › Distribute App › Direct Distribution, which exports with
  the Developer ID identity, notarizes and staples; or
  `xcodebuild -exportArchive -archivePath MyApp.xcarchive -exportPath out
  -exportOptionsPlist options.plist` with `method` `developer-id`, then
  `swift package … cef notarize out/MyApp.app --keychain-profile notary`
  (or `xcrun notarytool submit` and `xcrun stapler staple` yourself).
  Xcode's export signs the app again with the Developer ID identity and a
  secure timestamp, nested code first; whether it re-signs the helper apps
  in `Contents/Frameworks` itself is unverified, so check the result.
- [ ] `cefswift doctor out/MyApp.app` (the tool the phase built, in
  `$(OBJROOT)/CefSwift`) or `swift package … cef doctor` from a package
  reports no errors, and `spctl --assess --type execute -vv out/MyApp.app`
  prints `source=Notarized Developer ID`.

Without a team, `Examples/Xcode/ExportOptions.plist` (`method`
`mac-application`) exports the archived app as it is signed, ad hoc; it
runs on the Mac that built it. Mac App Store distribution is not possible:
see [App Sandbox](#app-sandbox).

### SwiftPM's plugin sandbox

`swift package` runs the plugin in a sandbox. Inside it:

- `codesign` and `security` see the keychains of the search list (the
  login keychain), not other keychain files: `--keychain` with a file
  outside the search list fails with "no identity found".
- `hdiutil` cannot create disk images, so `--format dmg` fails; `zip` works.
- `spctl` cannot assess apps (see [cef doctor](#cef-doctor)).
- Whether `notarytool` reaches its keychain profile and Apple's service from
  inside the sandbox has not been tested.

Where a step fails for this reason, the plugin's message says so; run the
command it prints in Terminal, or pass `--disable-sandbox` to
`swift package`, which turns the sandbox off for the whole run.

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
| `protectedMedia` | None | `com.apple.security.cs.disable-library-validation` (base helper) | Any signature | Lets a team-signed, hardened helper load Google's Widevine CDM, which Chromium downloads when `CefRuntime.Configuration.services.protectedMedia` is `.automatic`. Ad hoc builds without the hardened runtime load it without the capability. It does not give the app Verified Media Path: see [Playing streaming services](guide.md#playing-streaming-services). |

Under the hardened runtime, a missing resource entitlement makes the access
fail silently; without it, the entitlements are not enforced. The usage
description is needed either way: without it macOS ends the process that
asks.

Other features:

| Feature | Needs |
|---|---|
| Safe storage in the keychain (`keychainItem`, by default "<bundle identifier> Safe Storage") | A team signature: `.automatic` picks the keychain then. Ad hoc builds use `--use-mock-keychain`. See [Keychain access](guide.md#keychain-access). |
| Chromium's profile passkeys with Touch ID | Not available with CEF 156: Chromium checks for the keychain access group `.org.chromium.Chromium.webauthn`, compiled in from Chromium's branding with an empty team identifier, and a provisioning profile authorizes only groups that start with a team identifier. CefPasskeys' `CefPasskeyController` with `.app(CefKeychainPasskeyStore())` verifies the user with Touch ID instead. |
| `CefKeychainPasskeyStore` (CefPasskeys) | A team signature with a provisioning profile, which gives the app the `com.apple.application-identifier` entitlement the data protection keychain needs. Ad hoc builds get `errSecMissingEntitlement` (-34018). |
| Screen sharing (`getDisplayMedia`) | Nothing in the bundle; macOS asks the user for Screen Recording permission. |
| Notifications | Nothing: by default Chromium shows pages' notifications in its own popups and never asks macOS. With `services.systemNotifications = .automatic`, macOS asks the user at the first launch, for the app and for the Alerts helper, which gets `NSUserNotificationAlertStyle`. See [System notifications](guide.md#system-notifications). |
| `NSAppTransportSecurity` | Nothing: Chromium does its own networking, which App Transport Security does not cover. |
| FairPlay in a `WKWebView` beside Chromium (the Browser example's WebKit tabs) | Nothing: no entitlement, capability or team signature. |
| Widevine Verified Media Path | Not available with stock CEF: CEF 156 gives the CDM no host binary to verify, so no signature of yours is checked. See [Playing streaming services](guide.md#playing-streaming-services). |

### App Sandbox

The App Sandbox (`com.apple.security.app-sandbox`) is not supported with
official CEF builds, so a CefSwift app cannot ship in the Mac App Store.
`cef bundle` and the Xcode build phase refuse entitlements that claim it,
whatever identity signs the bundle, and name the fix: remove App Sandbox
in Signing & Capabilities (Xcode's app template turns it on), or the key
from the entitlements file. Chromium's own sandbox, which confines the
renderers and other helpers, is separate and on by default: see
[Sandbox](sandbox.md).

What was measured, with the Xcode example signed ad hoc (CEF 156.0.28,
macOS 27.2): with App Sandbox on, and every helper given
`com.apple.security.app-sandbox` and `com.apple.security.inherit` as App
Sandbox child processes require, the browser process stops at launch:

```
FATAL:base/apple/mach_port_rendezvous_mac.cc:159] Check failed: kr == KERN_SUCCESS.
bootstrap_check_in <bundle ID>.MachPortRendezvousServer.<pid>: Permission denied (1100)
```

Why, and what is reasoned rather than measured for a team signature:

- Chromium's processes find each other through a Mach service the
  browser process registers as `<bundle ID>.MachPortRendezvousServer.<pid>`.
  The App Sandbox lets an app register Mach services only under one of its
  application groups (`<team ID>.<group>…`), and the name Chromium builds
  is not one; official CEF builds offer no way to change it. A Developer
  ID or Apple Development signature with an application group does not
  rename the service, so the same refusal is expected. That has not been
  run, since it needs a team.
- The Mac App Store additionally rejects apps that use private API, and
  Chromium uses several on macOS.
- Electron, the one Chromium-based framework with a Mac App Store build,
  gets there with a patched Chromium (its MAS build names Chromium's Mach services
  under the application group and avoids the private API), not with
  stock Chromium. Chromium's own signing never uses the App Sandbox, and
  CEF documents Developer ID distribution only.

[`CefAppCapabilities`](guide.md#signing-and-capabilities) still reports
`isAppSandboxed` and the `.appStore` signature kind, for diagnostics:
they describe a configuration CefSwift refuses to bundle, so an app never
sees them in a build it made with `cef bundle` or the Xcode build phase.

## cef doctor

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef doctor dist/MyApp.app [--json]
```

For an app built any other way, such as an Xcode archive's export, the
`cefswift` tool takes the same arguments: `cefswift doctor MyApp.app`
(`swift run --package-path <CefSwift> cefswift doctor …`, or the copy the
Xcode phase built in `$(OBJROOT)/CefSwift`). The Xcode phase runs the checks
of the helpers, framework, linking and features on every build.

It reads the bundle with `codesign`, `security`, `spctl`, `stapler` and
`xattr`, and prints:

- the signature (ad hoc, Apple Development, Developer ID), the team, the
  hardened runtime and the secure timestamp;
- each helper's signature and entitlements, and whether the framework, its
  libraries, and the app's own libraries and resource bundles are signed
  like the app;
- linking: the app's libraries and resource bundles, and an error for code
  without the app's architecture, or that loads or searches for libraries
  outside the bundle (it would run on the build machine and fail on
  others);
- the embedded profile and its checks;
- Gatekeeper's verdict, the stapled ticket and the quarantine attribute;
- per feature, whether it works and what is missing; the safe-storage
  policy `.automatic` picks; the passkey authenticators Chromium can
  offer; whether the base helper can load the Widevine CDM; and that the
  build has no Verified Media Path, so services that require it refuse
  Widevine playback. Whether Chromium has downloaded the CDM is known only
  at run time (`CefRuntime.shared.widevine`);
- the footprint: the bundle's logical size, with the framework binary, its
  resources and the helpers; the locale packs it keeps and the pack each
  of the app's localizations gets, with a warning for one that gets none
  and the size of packs no localization uses; and whether SwiftShader is
  in it.

It exits non-zero when it finds an error, something that stops the app from
launching, from loading a part, or from passing notarization. `--json`
prints the same report as JSON, with `errors` and `warnings` counts.

In SwiftPM's plugin sandbox `spctl` cannot assess apps; the report says so
and the Gatekeeper line is informational. Run `spctl --assess --type execute
-vv <App.app>` in Terminal for that verdict.

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
| `CefError.loadFailed` or a helper exit with `code signature … not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs` | Library validation: a library signed by another team, ad hoc under a team signature, or any library under a team-less signature with the hardened runtime | Bundle again with `cef bundle`; `cef doctor` names the part. |
| Renderers crash at start under the hardened runtime | The renderer helper lacks `allow-jit` | Keep the built-in helper entitlements; `cef doctor` flags it. |
| "MyApp is damaged" or "cannot be opened" on another Mac | The download is quarantined and the app is not notarized | Notarize. For a test only: `xattr -dr com.apple.quarantine MyApp.app`. |
| Notarization `Invalid` | Missing hardened runtime or timestamp, `get-task-allow`, or an unsigned nested binary | `cef notarize` prints the notary log; `cef doctor` names the part. |
| Camera, microphone or location requests fail without a prompt | A missing usage description or, under the hardened runtime, entitlement | Add the capability. |
| Phones are not offered as passkeys | No `NSBluetoothAlwaysUsageDescription`, or the app was started from a terminal, which becomes the responsible process | Add `bluetooth`; launch with `open`. |
| `CefError.frameworkNotFound` when the app starts | The app runs without the framework and helpers: `swift run`, `.build/…`, or an Xcode target without the CefSwift phase | Run the bundle from `cef bundle`, or add the phase ([Xcode](#xcode)). |
| The app stops at launch with `bootstrap_check_in …MachPortRendezvousServer…: Permission denied (1100)` | The App Sandbox | Remove App Sandbox; both tracks refuse it ([App Sandbox](#app-sandbox)). |
| Xcode: `Sandbox: … deny(1) file-read-data …` or `deny(1) file-write-create …` in the CefSwift phase | User Script Sandboxing | `ENABLE_USER_SCRIPT_SANDBOXING = NO` for the target. |
| Xcode: `…/xcode-embed.sh: No such file or directory` | `CEFSWIFT_PACKAGE_DIR` does not point at the package | Set it: `$(BUILD_DIR)/../../SourcePackages/checkouts/CefSwift` for a remote package, the path of a local one; with `xcodebuild -clonedSourcePackagesDirPath <dir>`, `<dir>/checkouts/CefSwift`. |
| Xcode: "This build is for arm64 and x86_64, but CEF's distributions hold one architecture each" | A Release build's default `ARCHS` | `ARCHS = $(NATIVE_ARCH_ACTUAL)` ([Universal apps](#universal-apps)). |
| Xcode: "The app lacks the entitlement com.apple.security.cs.disable-library-validation" | A Release build signed ad hoc keeps the hardened runtime | Sign with a team, or set `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = YES` until then ([Signing in Xcode](#signing-in-xcode)). |
| `dyld: Library not loaded: @rpath/MyApp.debug.dylib … different Team IDs` | An ad hoc, hardened Debug build (hardened runtime forced on) | As above, or leave `ENABLE_HARDENED_RUNTIME` to Xcode for ad hoc Debug builds. |
| A SwiftUI preview of a view with a `CefWebView` shows a globe | Previews cannot start Chromium | Expected: run the app to see the page ([Debugging and previews](#debugging-and-previews)). |

## Flavors

| Flavor | Contents | Download (arm64 / x86_64) |
|---|---|---|
| `minimal` | The Release framework | About 135 MB / 142 MB |
| `standard` | Release and Debug builds | About 312 MB / 361 MB |

Bundles always contain the Release framework. `standard` is useful only when
you need CEF's Debug build from `.cef/dist/`.
