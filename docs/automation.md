# Automation

## Staying on current CEF

`.github/workflows/cef-update.yml` runs every Monday and Thursday:

1. `Scripts/update-cef.py` asks the CEF build index for the newest stable
   release available for both macOS architectures.
2. If it is newer than `CEF_VERSION.json`, the script rewrites the manifest,
   downloads the arm64 minimal build (SHA-1 verified), replaces the vendored
   headers and regenerates the C bridge.
3. The workflow commits to the `cef-update` branch, opens or refreshes one
   pull request, starts CI for it and enables auto-merge.

CI builds the package, runs the unit tests, and runs the SelfTest app against
the new Chromium. The update merges only if all of that passes.

`CEF_API_VERSION` stays pinned throughout, so a CEF bump never changes the C
API the Swift code sees. To adopt newer APIs, raise the pin in
`Sources/CCef/include/ccef_config.h` and run `Scripts/generate-bindings.py`.

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
Scripts/update-cef.py --check   # is there a newer stable?
Scripts/update-cef.py           # update the working tree
```

## CI

`.github/workflows/ci.yml` runs on pushes and pull requests to `main`:
build, `swift test`, `Scripts/generate-bindings.py --check`, build the
examples, then bundle and run SelfTest. SelfTest exits with the number of
failed checks.

## Releases

Pushing a `v*` tag creates a GitHub release with generated notes
(`.github/workflows/release.yml`).
