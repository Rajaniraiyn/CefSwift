# Automation

## Staying on current CEF

`.github/workflows/cef-update.yml` runs every Monday and Thursday:

1. `Scripts/update-cef.py` asks the CEF build index for the newest stable
   release that ships the minimal and standard builds for both macOS
   architectures. A release out for one architecture only is reported and
   waited for.
2. If it is newer than `CEF_VERSION.json`, the script downloads the arm64
   minimal build (resumed, size- and SHA-1-verified), stages the new headers
   and regenerates the C bridge in `.cef/update`, and only then swaps them
   into `Sources/CCef` and rewrites the manifest. A failure leaves the tree
   untouched; a second run is a no-op.
3. The workflow commits to the `cef-update` branch, opens one pull request
   (or refreshes the open one in place), starts CI for it and enables
   auto-merge. When there is nothing to do, an update pull request still
   open is closed as obsolete.

The pull request lists CEF, Chromium and `CEF_API_VERSION` before and after,
and the C functions added, removed or changed. CI builds the package, runs
the unit tests, checks the generated bridge against the headers and the
framework's exports, and runs the SelfTest app against the new Chromium.
The update merges only if all of that passes.

The squash commit on `main` is exactly:

```
Update CEF to <new version>

From <old version>.

Co-authored-by: <CEF_UPDATE_COAUTHOR>
```

## Moving `CEF_API_VERSION`

The pin in `Sources/CCef/include/ccef_config.h` keeps the C API stable across
CEF updates, so new CEF APIs stay invisible until it moves. Moving it is a
separate, reviewed change:

- Run **CEF Update** by hand with `api_version` set to `latest` (the newest
  released version in the vendored `cef_api_versions.h`) or a number. It
  opens a `cef-api-update` pull request that does not merge itself.
- Or locally: `Scripts/update-cef.py --api-version latest`.

If a CEF update drops the pinned version, the scheduled run fails and says
so. Move both at once with
`Scripts/update-cef.py --to latest --api-version latest`, then adapt the
Swift code.

### Attribution

Update commits are authored by `github-actions[bot]` and carry a
`Co-authored-by:` trailer, so they are credited to a person as well. The
default is the repository owner; set the repository variable
`CEF_UPDATE_COAUTHOR` (`Name <email>`) to change it. Use the address GitHub
associates with the account — its `noreply` address works.

### One-time repository setup

- Settings → General → enable **Allow auto-merge**.
- Protect `main` with the `ci` job as a required status check.
- Settings → Actions → General → allow Actions to create pull requests.

### Running it by hand

```sh
Scripts/update-cef.py --check               # is there a newer stable?
Scripts/update-cef.py                       # update the working tree
Scripts/update-cef.py --to <version>        # vendor a specific stable (or repair)
Scripts/update-cef.py --api-version latest  # move only the API pin
Scripts/update-cef.py --index index.json    # use a saved copy of the CDN index
Scripts/update-cef.py --self-test           # offline checks of the script
Scripts/generate-bindings.py [--check]      # regenerate (or verify) the bridge
```

## CI

`.github/workflows/ci.yml` runs on pushes and pull requests to `main`: the
update script's self-test, download CEF (cached by version),
`Scripts/generate-bindings.py --check --framework …`, build, `swift test`,
build the examples, then bundle and run SelfTest. SelfTest exits with the
number of failed checks.

## Releases

Pushing a `v*` tag creates a GitHub release with generated notes
(`.github/workflows/release.yml`).
