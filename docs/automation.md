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
   (resuming a partial download, verifying size and SHA-1, and starting over
   once if a resumed download does not verify). It stages the new headers in
   `.cef/update`, regenerates the C bridge there, repackages the two
   frameworks as the XCFramework zip with `Scripts/package-cef.py`, and only
   then moves the headers and generated files into `Sources/CCef`, pins the
   zip's release URL and checksum in `Package.swift`, and rewrites
   `CEF_VERSION.json`. A failure at any step leaves the tree unchanged, and
   a second run does nothing.
3. The workflow publishes the zip as the asset of the prerelease
   `cef-<major.minor.patch>` (see [Publishing the framework](#publishing-the-framework)),
   commits the change to the `cef-update` branch, opens a pull request or
   refreshes the open one, saves the downloads to the Actions cache for CI,
   starts CI on the branch, and enables auto-merge. An open pull request
   that already pins the same CEF, framework and `CEF_API_VERSION` is left
   alone, so fixes pushed to it survive later runs.
4. When there is nothing to update and a `cef-update` pull request is still
   open, the workflow closes it as obsolete and deletes the branch.
5. Every run first promotes the framework release the default branch pins
   and last deletes the framework releases nothing pins.

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

### Publishing the framework

`Package.swift` names the framework by URL and checksum:

```swift
let cefFramework = (
    url: "https://github.com/Rajaniraiyn/CefSwift/releases/download/cef-156.0.28/ChromiumEmbeddedFramework.xcframework.zip",
    checksum: "426ccfde…"
)
```

SwiftPM resolves that URL for every package graph that contains CefSwift,
CefSwift's own CI included, so the asset must exist before any commit that
pins it is built. The order is:

1. `Scripts/update-cef.py` (or `Scripts/package-cef.py --write`) builds the
   zip and writes its URL and checksum into `Package.swift` and
   `CEF_VERSION.json`.
2. `Scripts/cef-release.sh publish` creates the `cef-<version>` release as
   a prerelease, with the default branch as its tag's target, and uploads
   the zip. A prerelease's assets are public, so SwiftPM can fetch them.
3. Only then is the branch pushed and CI started. CI resolves the asset and
   SwiftPM checks its checksum.
4. After the pull request merges, the next CEF Update run, and the Release
   workflow for a `v*` tag, promote the release to a full one.

The workflow does all four for CEF updates. By hand, for example for the
first release of a pin or after a packaging change:

```sh
Scripts/package-cef.py --write          # build, pin, print tag and checksum
GH_REPO=Rajaniraiyn/CefSwift Scripts/cef-release.sh publish \
    "$(jq -r .xcframework.tag CEF_VERSION.json)" \
    .cef/xcframework/ChromiumEmbeddedFramework.xcframework.zip \
    "$(jq -r .xcframework.checksum CEF_VERSION.json)" main
```

The zip is deterministic: its entries are sorted and carry fixed dates and
modes, so the same distributions and the same zlib give the same bytes, and
CI rebuilds it and requires the pinned checksum (`package-cef.py --check`).
The update workflow and CI both run on the pinned `macos-15` runner.

An asset of a promoted release is never replaced, because released CefSwift
versions pin its checksum. A change to the packaging that changes the bytes
bumps `PACKAGING_REVISION` in `Scripts/package-cef.py`, which publishes under
`cef-<version>-r<n>`.

Retention (`Scripts/cef-release.sh prune`): a framework release stays while
`CEF_VERSION.json` pins it on the default branch, at any `v*` tag, or on an
open update branch. Of the others, prereleases, which belong to update pull
requests that never merged, are deleted, and promoted releases beyond the
newest three are deleted.

Before a branch's pin is published, set `CEFSWIFT_LOCAL_FRAMEWORK=1` to build
against the XCFramework `Scripts/package-cef.py` writes to
`.cef/xcframework`. CI does that on pull requests from other branches, with
a warning; on `main` and the update branches an unpublished asset fails the
run.

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

The pin in `Sources/CCef/include/ccef_config.h` keeps the C API the Swift
code sees the same across CEF updates; newer CEF APIs stay hidden until the
pin moves. Moving it is a separate, reviewed change:

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
Scripts/package-cef.py                               # build .cef/xcframework/ChromiumEmbeddedFramework.xcframework(.zip)
Scripts/package-cef.py --no-zip                      # only the XCFramework, for CEFSWIFT_LOCAL_FRAMEWORK=1
Scripts/package-cef.py --write                       # also pin the zip's URL and checksum
Scripts/package-cef.py --check                       # fail unless the zip has the pinned checksum
Scripts/package-cef.py --self-test                   # offline checks of the script
Scripts/cef-release.sh publish|verify|promote|prune  # the cef-<version> releases (gh)
Scripts/generate-bindings.py                         # regenerate the C bridge
Scripts/generate-bindings.py --check                 # fail if the bridge is out of date
Scripts/generate-bindings.py --check --framework <path to Chromium Embedded Framework.framework>
```

`--framework` checks every architecture of a universal framework.

`--check` only reports and cannot be combined with `--to` or
`--api-version`. The update script writes its results (`updated`, `cef_old`,
`cef_new`, `api_old`, `api_new`, `subject`, `xcframework_tag`,
`xcframework_checksum`) to `$GITHUB_OUTPUT`, or to standard output outside
Actions, and the commit message and pull-request description to
`.cef/update/`.

## CI

`.github/workflows/ci.yml` runs on pushes and pull requests to `main`, and
when dispatched, on one `macos-15` runner:

1. The self-tests of the update and packaging scripts.
2. Restore the two minimal CEF distributions, cached by CEF version, and
   rebuild the XCFramework from them with `Scripts/package-cef.py --check`,
   which requires the checksum `Package.swift` pins.
3. Check that the pinned release asset is published; see
   [Publishing the framework](#publishing-the-framework) for branches where
   it is not yet.
4. `Scripts/generate-bindings.py --check --framework …`: the generated
   bridge must match the headers, and both architectures of the framework
   must export every function it binds.
5. `swift build --build-tests` and `swift test`. SwiftPM resolves the
   framework from the release asset and checks its checksum.
6. Build the Examples package, then bundle SelfTest.
7. Run SelfTest. It exits with the number of failed checks; its `FAIL` and
   `SKIP` lines go to the run summary.
8. Check that the build left the working tree clean.

## Releases

Pushing a `v*` tag creates a GitHub release with generated notes
(`.github/workflows/release.yml`). SwiftPM resolves the tag itself. Before
that, the workflow checks that the framework release the tag pins has the
pinned checksum and promotes it, so the retention rule keeps it for as long
as the version exists.
