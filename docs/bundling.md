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
  `<Package>_<Target>.bundle`, the bundle `Bundle.module` loads. They go in
  `Contents/Resources/`, the first place SwiftPM's generated accessor looks
  (`Bundle.main.resourceURL`). A missing one is an error.
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
  localizations, so that macOS picks the app's language from them;
- the development language, `CFBundleDevelopmentRegion` (`en`);
- English, Chromium's last fallback.

Localizations map onto packs as `CefLocalization` resolves them at run
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
    │   └── MyApp_MyApp.bundle             # each target's resources (Bundle.module)
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
("alerts") services as separate processes. On macOS each process type is an
app of its own, with its own bundle identifier and `Info.plist`. All five
contain the same binary, copied and renamed.

That binary is CefSwift's `cefswift-helper` product, a Swift executable
(`Sources/CefHelper`), which `cef bundle` builds with SwiftPM alongside the
app, together with the `cefswift_helper_startup` library. The helper links
`libcefswift_helper_startup.dylib` and then the framework, so dyld loads
both at launch, and the app product is built with a weak link to the
framework (`-weak_framework`). Libraries loaded at launch
keep the framework's 12 MB of fixed-up pointers as shared, clean memory in
every process; see [architecture](architecture.md#loading-the-framework-at-launch).
An app bundled another way, for example by an Xcode project, builds the
same two products with the same link order (see `HelperBuilder.swift` in
the plugin for the exact linker flags). Its app
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
| `protectedMedia` | None | `com.apple.security.cs.disable-library-validation` (base helper) | Any signature | Lets a team-signed, hardened helper load Google's Widevine CDM, which Chromium downloads when `CefConfiguration.protectedMedia` is `.automatic`. Ad hoc builds without the hardened runtime load it without the capability. It does not give the app Verified Media Path: see [Playing streaming services](guide.md#playing-streaming-services). |

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
| FairPlay in `CefSystemBrowser` (WebKit) | Nothing: no entitlement, capability or team signature. |
| Widevine Verified Media Path | Not available with stock CEF: CEF 156 gives the CDM no host binary to verify, so no signature of yours is checked. See [Playing streaming services](guide.md#playing-streaming-services). |

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

## Flavors

| Flavor | Contents | Download (arm64 / x86_64) |
|---|---|---|
| `minimal` | The Release framework | About 135 MB / 142 MB |
| `standard` | Release and Debug builds | About 312 MB / 361 MB |

Bundles always contain the Release framework. `standard` is useful only when
you need CEF's Debug build from `.cef/dist/`.
