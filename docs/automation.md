# Automation

## CEF updates

`.github/workflows/cef-update.yml` (CEF Update) runs every Monday and
Thursday at 06:17 UTC and keeps the pinned CEF on the newest stable release.

1. `Scripts/update-cef.py` reads the CEF build index and picks the newest
   stable release that ships the minimal and standard distributions for both
   macOS architectures. A newer release that is out for one architecture
   only is logged and waited for.
2. If that release is newer than `CEF_VERSION.json`, the script downloads the
   minimal distributions of both architectures into `.cef/downloads`
   (resuming a partial download, verifying size and SHA-1, and starting
   over once if a resumed download does not verify). It stages the new
   headers in `.cef/update`, regenerates the C bridge there, repackages the
   two frameworks as the XCFramework zip in `.cef/xcframework`
   (`Scripts/package-cef.py`), and only then moves the headers and
   generated files into `Sources/CCef`, pins the zip's release URL and
   checksum in `Package.swift`, and rewrites `CEF_VERSION.json`. A failure
   at any step leaves the tree unchanged, and a second run does nothing.
3. The workflow publishes the zip as the prerelease `cef-<version>`
   ([Publishing the framework](#publishing-the-framework)), commits the
   change to the `cef-update` branch, opens a pull request or refreshes the
   open one, saves the downloads to the Actions cache for CI, starts CI on
   the branch, and enables auto-merge. An open
   pull request that already pins the same CEF and `CEF_API_VERSION` is left
   alone, so fixes pushed to it survive later runs.
4. When there is nothing to update and a `cef-update` pull request is still
   open, the workflow closes it as obsolete and deletes the branch.

The pull request lists CEF, Chromium and `CEF_API_VERSION` before and after,
and the C functions added, removed or changed. It merges only when CI
passes. The squash commit on `main` is:

```
Update CEF to <new version>

From <old version>.

Co-authored-by: <CEF_UPDATE_COAUTHOR>
```

The `Co-authored-by:` line is present only when a co-author is configured
(see [Attribution](#attribution)).

### Failure reports

- **CI fails on an update branch.** CI for `cef-update` and `cef-api-update`
  is started with the workflow token, which notifies nobody. When it fails,
  CI's `report` job comments on the open pull request with a link to the
  run, whose summary lists the SelfTest `FAIL` lines. Auto-merge keeps
  waiting. Push a fix to the branch; later update runs leave it alone until
  a newer CEF is released.
- **The update run fails.** For example, the release's headers do not
  support the pinned API version. The workflow comments on the open issue titled
  **CEF update failed**, or opens it. Close the issue once a run succeeds; it
  is not closed automatically.

### Attribution

Update commits are authored by `github-actions[bot]`. To credit a person
as well, set the repository variable `CEF_UPDATE_COAUTHOR` to
`Name <email>`, using an address GitHub associates with the account, such
as its `noreply` address; the commits then carry a `Co-authored-by:`
trailer. Without the variable, `Rajaniraiyn/CefSwift` credits its
maintainer and any other repository, a fork included, adds no trailer.

### One-time repository setup

- Settings → General: enable **Allow auto-merge**.
- Protect `main` with the `ci` job as a required status check. Without it,
  auto-merge would merge before CI has run.
- Settings → Actions → General: allow GitHub Actions to create pull
  requests.
- Optional: set the `CEF_UPDATE_COAUTHOR` variable to credit a co-author.

## Moving `CEF_API_VERSION`

The pin in `Sources/CCef/include/ccef_config.h` selects a versioned CEF ABI.
Newer versioned CEF APIs stay hidden until the pin moves. Swift also imports
unversioned headers such as Chromium's command IDs, which can change with
the CEF release. Moving the API pin is a separate, reviewed change:

- Run **CEF Update** by hand with `api_version` set to `latest` (the newest
  version in the vendored `cef_api_versions.h`) or a number such as `15700`.
  It works on the headers already vendored and opens a `cef-api-update` pull
  request that does not merge itself.
- Or run `Scripts/update-cef.py --api-version latest` locally.

If a new CEF release drops the pinned API version, the scheduled run fails
and says so. Move both at once with
`Scripts/update-cef.py --to latest --api-version latest`, then adapt the
Swift code.

## Running the scripts

```sh
Scripts/update-cef.py --check                        # report whether a newer stable exists
Scripts/update-cef.py                                # update the working tree
Scripts/update-cef.py --to <version>                 # vendor that stable release (also repairs a tree)
Scripts/update-cef.py --api-version latest           # move only the API pin, on the vendored headers
Scripts/update-cef.py --to latest --api-version latest
Scripts/update-cef.py --index index.json             # use a saved copy of the CDN index
Scripts/update-cef.py --self-test                    # offline checks of the script
Scripts/generate-bindings.py                         # regenerate the C bridge
Scripts/generate-bindings.py --check                 # fail if the bridge is out of date
Scripts/generate-bindings.py --check --framework <path to Chromium Embedded Framework.framework>
```

`--check` only reports and cannot be combined with `--to` or
`--api-version`. The update script writes its results (`updated`, `cef_old`,
`cef_new`, `api_old`, `api_new`, `subject`, `xcframework_tag`,
`xcframework_checksum`) to `$GITHUB_OUTPUT`, or to standard output outside
Actions, and the commit message and pull-request description to
`.cef/update/`.

## Publishing the framework

`Package.swift` links CEF from the asset of a GitHub release,
`cef-<version>`: `ChromiumEmbeddedFramework.xcframework.zip`, the official
minimal distributions of both architectures in one XCFramework, made by
`Scripts/package-cef.py` without changes to CEF's files (each Mach-O file
is a `lipo -create` of the two official ones, checked slice by slice;
every other file is identical in both, except the resources CEF names by
architecture). The zip's entries are sorted, with fixed dates and modes,
so the same distributions give the same bytes with the same zlib; CI
rebuilds it and requires the pinned checksum.

```sh
Scripts/package-cef.py                # the XCFramework and its zip in .cef/xcframework
Scripts/package-cef.py --no-zip       # only the XCFramework, for CEFSWIFT_LOCAL_FRAMEWORK=1
Scripts/package-cef.py --write        # also pin the zip's URL and checksum
Scripts/package-cef.py --check        # fail unless the zip matches the pin
Scripts/package-cef.py --self-test    # offline checks
Scripts/cef-release.sh publish|verify|promote|prune …
```

A CEF update publishes the zip as a prerelease before it pushes the
branch, so CI on the pull request resolves it. The release workflow
checks that the asset a version tag pins exists with its checksum and
marks it as a full release. Each CEF Update run promotes the release the
default branch pins, and deletes `cef-*` releases nothing pins: a release
stays while the default branch, a `v*` tag or an open update branch pins
it. Once a version tag pins an asset, it is never deleted or replaced,
since every CefSwift version that pins it resolves it by checksum; a
packaging change for the same CEF version gets a new tag (`PACKAGING_REVISION`
in `Scripts/package-cef.py`, `cef-<version>-r2`).

A branch that pins an asset not yet published (one changed by hand rather
than by the update workflow) builds in CI against the rebuilt framework,
with a warning, through `CEFSWIFT_LOCAL_FRAMEWORK=1`; `main` and the update
branches fail instead.

## CI

`.github/workflows/ci.yml` runs on pushes and pull requests to `main`, and
when dispatched. Its `ci` job, on a `macos-15` runner, does everything
below; two jobs run beside it:

- `intel` compiles the package and its tests for x86_64
  (`swift build --build-tests --arch x86_64`) on the same arm64 runner,
  and checks that the result is x86_64 for macOS 14. CefKit loads the CEF
  framework at run time and the plugin builds the helper only when it
  bundles, so compiling needs nothing beyond the XCFramework SwiftPM
  resolves.
- `xcode` runs `Scripts/check-xcode-example.sh`: the Xcode example
  (`Examples/Xcode`) built with `xcodebuild`, Debug and Release, archived
  and exported, each build launched with `-smoke YES`, and `cef doctor` on
  the exported app. Its build phase takes the framework from the
  XCFramework SwiftPM resolved. It takes about 2.5 minutes on an M3 and is not a required
  check: release tags and CEF updates wait for `ci` and `intel` only. It
  had not run on GitHub when it was added; the runner's Xcode is older
  than the Xcode 27.2 it was written with.

The `ci` job:

1. Print the macOS, Xcode and Swift versions. The `macos-15` label selects
   an image family that GitHub updates in place, so these can change
   between runs without a commit.
2. The update and packaging scripts' self-tests.
3. Rebuild the XCFramework from the two minimal distributions (cached by
   CEF version) with `Scripts/package-cef.py --check`, which fails unless
   the zip has the pinned checksum; then check that the pinned release
   asset is published ([Publishing the framework](#publishing-the-framework)).
4. `Scripts/generate-bindings.py --check --framework …`: the generated
   bridge must match the headers, and the framework must export every
   function it binds.
5. `swift build --build-tests`, then check that the built code's
   deployment target is macOS 14.
6. `swift test`, with `CEF_FRAMEWORK_PATH` set, so the loader tests run;
   `swift test --package-path Examples`, the Browser example's unit tests;
   then the package's tests again with the Thread Sanitizer and with the
   Address Sanitizer.
7. `Scripts/check-doc-samples.py`: every Swift sample in the README and
   the docs compiles.
8. Build the Examples package in release, then bundle SelfTest and run `cef doctor`
   on it. The plugin takes the framework from the resolved XCFramework.
9. Run SelfTest with `SELFTEST_ISOLATED=1` (each group in a process of its
   own), `SELFTEST_STRICT=1` (a skip for a reason of the environment
   fails) and `SELFTEST_JSON`. `SELFTEST_EXPECTED_SKIPS` names the checks a
   hosted runner cannot run, being a virtual machine: frame rates that
   follow a display's refresh, and FairPlay playback. Those skips do not
   fail the run; they are verified on a Mac only. Its `FAIL` and `SKIP` lines and the counts
   go to the run summary. On failure, the log, the JSON results and the
   crash reports written during the run are uploaded as the
   `selftest-diagnostics` artifact.
10. Bundle the Gallery example and run `Gallery -smoke`, which opens each
    demo in turn and fails when one does not come up or leaves a page
    open.
11. Bundle the Minimal and Browser examples and measure their idle
    footprint with `Scripts/measure-footprint.py`, written to the run
    summary. The bounds are wide (about 1.5 times what an Apple M3
    measures), so only a gross regression fails.
12. Check that the build left the working tree clean.

What CI verifies, and what it does not:

- Compiling against the macOS 14 deployment target means the compiler
  rejects any newer API used without an availability check. Nothing runs
  on macOS 14, since GitHub no longer offers a macOS 14 runner: CefKit's
  macOS 14 executor path is compiled but not exercised, and the unit
  tests and SelfTest run on macOS 15 only.
- Everything compiles for Intel, and nothing runs there. Running on Intel
  needs an Intel runner (`macos-15-intel`), the `macosx64` CEF archive in
  the cache, `cef bundle --platform macosx64` there, and a SelfTest run;
  on a schedule rather than per pull request, given what those runners
  cost. (`cef bundle` cannot cross-bundle: it bundles for the architecture
  SwiftPM builds for.)
- One toolchain: whichever Xcode the runner image selects. CI does not
  build with the oldest Swift 6 toolchain the package claims.

## Releases

Pushing a `v*` tag creates a GitHub release with generated notes
(`.github/workflows/release.yml`). SwiftPM resolves the tag itself, so there
are no assets to build.

The release is made only for a commit CI passed: before it creates the
release, the workflow reads the tagged commit's check runs and requires
the latest `ci` and `intel` runs to have succeeded, waiting up
to 75 minutes for runs still in progress. A commit pushed to `main` has
those runs. For another commit, run CI on the tag first
(`gh workflow run ci.yml --ref v0.1.0`), then re-run the release workflow.
