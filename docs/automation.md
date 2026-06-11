# CEF auto-update automation

CefSwift pins an exact CEF build in `CEF_VERSION.json`. Keeping that pin
current is fully automated: Chromium security releases arrive as pull requests
that merge themselves once CI proves them.

## How the flow works

```
cron (Mon & Thu 06:17 UTC)            .github/workflows/cef-update.yml
        │
        ▼
Scripts/cef-update.sh
  1. Conditional-GET https://cef-builds.spotifycdn.com/index.json (ETag-cached)
  2. Pick the HIGHEST cef_version where channel == "stable" and both
     macosarm64 and macosx64 ship minimal + standard files.
     (index entries are not version-ordered, and several stable major
     lines coexist — the script sorts numerically and takes the max.)
  3. Same as the pin? → "up to date", exit 0. Done.
  4. Newer? →
     - Rewrite CEF_VERSION.json (names/sha1/sizes for both platforms, both flavors)
     - Download + sha1-verify the new macosarm64 minimal tarball
     - Re-vendor the CEF include/ tree into Sources/CCef (the vendored tree is
       discovered at runtime; CefSwift-authored files are untouched)
     - Check the pinned CEF_API_VERSION still exists in the new
       include/cef_api_versions.h → WARNING into the PR if not
     - Write a PR body (old→new, chromium version, distro sizes)
        │
        ▼
Workflow: branch cef-update/<version> → commit → push → gh pr create
        → gh pr merge --auto --squash
        │
        ▼
CI runs on the PR: build, unit tests, bundle the Browser example, and a live
smoke test that launches CEF and loads a page (--cef-smoke-test).
Green → auto-merge fires → main is on the new CEF.
```

API-version pinning is what makes this safe: CefSwift compiles against a fixed
`CEF_API_VERSION`, which CEF guarantees ABI-stable across releases. If a
future CEF ever drops the pinned version, the script detects it, puts a loud
warning in the PR, and the workflow **skips auto-merge** so a human migrates
the pin deliberately.

You can also run the whole check by hand, locally or via the workflow's
**Run workflow** button:

```sh
Scripts/cef-update.sh   # prints "up to date" or prepares the update in-place
```

## Required repository settings

The pipeline needs four things configured once on GitHub:

1. **Allow auto-merge** — Settings → General → Pull Requests → check
   *Allow auto-merge*. Without it, `gh pr merge --auto` fails (the workflow
   degrades to a plain PR with a warning annotation).

2. **Branch protection with a required check** — Settings → Branches →
   protect `main` and mark the CI job (`ci`) as a **required status check**.
   Auto-merge only fires after required checks pass; with no required checks,
   auto-merge would merge instantly without waiting for CI.

3. **Actions may create PRs** — Settings → Actions → General → check
   *Allow GitHub Actions to create and approve pull requests*.

4. **`CEF_UPDATE_TOKEN` secret (strongly recommended)** — a fine-grained PAT
   with **contents: read/write** and **pull requests: read/write** on this
   repository, stored as an Actions secret named `CEF_UPDATE_TOKEN`.

   **Why:** events caused by the default `GITHUB_TOKEN` do not trigger other
   workflows — GitHub's recursion guard. A PR created with `GITHUB_TOKEN`
   therefore never gets a CI run, the required check never reports, and
   auto-merge never completes. The workflow falls back to `GITHUB_TOKEN` if
   the secret is absent (the PR is still created), but you'd have to kick CI
   manually (close/reopen the PR, or push an empty commit to its branch).
   Set the PAT and the loop closes itself.

Also note: **scheduled workflows only run on the default branch** — the cron
will not fire until `cef-update.yml` is on `main`.

## Failure modes & manual recovery

| Symptom | Cause | Fix |
|---|---|---|
| PR created but CI never ran | No `CEF_UPDATE_TOKEN` PAT | Add the PAT; for the stuck PR, close & reopen it |
| PR open but not merging | Auto-merge disabled, or no required checks on `main` | Settings per above; merge manually meanwhile |
| PR carries a CEF_API_VERSION warning | New CEF dropped the pinned API version | Bump `CEF_API_VERSION` in `Sources/CCef` (ccef_config.h) to a version listed in the new `include/cef_api_versions.h`, fix any compile fallout, push to the PR branch |
| Workflow fails in the script | CDN/index change | Run `Scripts/cef-update.sh` locally; it logs each step |

The update is always an ordinary PR — review it, push to it, or close it like
any other.
