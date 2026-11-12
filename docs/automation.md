# Automation

## CEF updates

`.github/workflows/cef-update.yml` (CEF Update) runs every Monday and
Thursday at 06:17 UTC and keeps the pinned CEF on the newest stable release.

1. `Scripts/update-cef.py` reads the CEF build index and picks the newest
   stable release that ships the minimal and standard distributions for both
   macOS architectures. A newer release that is out for one architecture
   only is logged and waited for.
2. If that release is newer than `CEF_VERSION.json`, the script downloads the
   arm64 minimal distribution into `.cef/downloads` (resuming a partial
   download, verifying size and SHA-1, and starting over once if a resumed
   download does not verify). It stages the new headers in `.cef/update`,
   regenerates the C bridge there, and only then moves the headers and
   generated files into `Sources/CCef` and rewrites `CEF_VERSION.json`. A
   failure at any step leaves the tree unchanged, and a second run does
   nothing.
3. The workflow commits the change to the `cef-update` branch, opens a pull
   request or refreshes the open one, saves the download to the Actions
   cache for CI, starts CI on the branch, and enables auto-merge. An open
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

Update commits are authored by `github-actions[bot]` and carry a
`Co-authored-by:` trailer, so a person is credited as well. Set the
repository variable `CEF_UPDATE_COAUTHOR` to `Name <email>` to choose who;
without it, the workflow uses the default written in `cef-update.yml`. Use
an address GitHub associates with the account, such as its `noreply`
address.

### One-time repository setup

- Settings → General: enable **Allow auto-merge**.
- Protect `main` with the `ci` job as a required status check. Without it,
  auto-merge would merge before CI has run.
- Settings → Actions → General: allow GitHub Actions to create pull
  requests.
- Optional: set the `CEF_UPDATE_COAUTHOR` variable.

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
Scripts/generate-bindings.py                         # regenerate the C bridge
Scripts/generate-bindings.py --check                 # fail if the bridge is out of date
Scripts/generate-bindings.py --check --framework <path to Chromium Embedded Framework.framework>
```

`--check` only reports and cannot be combined with `--to` or
`--api-version`. The update script writes its results (`updated`, `cef_old`,
`cef_new`, `api_old`, `api_new`, `subject`) to `$GITHUB_OUTPUT`, or to
standard output outside Actions, and the commit message and pull-request
description to `.cef/update/`.

## CI

`.github/workflows/ci.yml` runs on pushes and pull requests to `main`, and
when dispatched, on one `macos-15` runner:

1. The update script's self-test.
2. Download CEF (minimal, arm64), cached by CEF version.
3. `Scripts/generate-bindings.py --check --framework …`: the generated
   bridge must match the headers, and the framework must export every
   function it binds.
4. `swift build` and `swift test`.
5. Build the Examples package, then bundle SelfTest. The Examples package
   gets a copy-on-write clone of the downloaded archive instead of
   downloading it again.
6. Run SelfTest. It exits with the number of failed checks; its `FAIL` and
   `SKIP` lines go to the run summary.
7. Check that the build left the working tree clean.

## Releases

Pushing a `v*` tag creates a GitHub release with generated notes
(`.github/workflows/release.yml`). SwiftPM resolves the tag itself, so there
are no assets to build.
