#!/bin/bash
# Manages the `cef-<version>` GitHub releases that host the CEF XCFramework
# Package.swift links (docs/automation.md). Needs `gh` with GH_REPO set and
# a token that can write releases, `jq`, and `git` with the tags fetched.
#
#   Scripts/cef-release.sh publish <tag> <zip> <sha256> <target>
#       Creates <tag> as a prerelease at <target> (a branch or commit) with
#       the zip, or uploads it to the prerelease <tag>. Does nothing when the
#       asset already has that checksum. Refuses to replace the asset of a
#       promoted release: released CefSwift versions pin its checksum.
#   Scripts/cef-release.sh verify <tag> <sha256>
#       Fails unless the published asset has that checksum.
#   Scripts/cef-release.sh promote <tag>
#       Marks <tag> as a full release once a branch or version tag pins it.
#   Scripts/cef-release.sh prune <default branch> [<keep>]
#       Deletes `cef-*` releases nothing pins, per the retention rule below.
#
# Retention: a release stays while CEF_VERSION.json pins it at the default
# branch, at any `v*` tag, or on the open update branches (cef-update,
# cef-api-update). Of the others, prereleases (update pull requests that never
# merged) are deleted, and promoted releases beyond the newest <keep>
# (default 3) are deleted, since only commits between version tags pinned them.
set -euo pipefail

asset=ChromiumEmbeddedFramework.xcframework.zip

die() { echo "cef-release: $*" >&2; exit 1; }

published_checksum() {
    local directory
    directory="$(mktemp -d)"
    if gh release download "$1" --pattern "$asset" --dir "$directory" >/dev/null 2>&1; then
        shasum -a 256 "$directory/$asset" | cut -d' ' -f1
    fi
    rm -rf "$directory"
}

pinned_tag() {  # <git revision>: the release tag CEF_VERSION.json pins there
    git show "$1:CEF_VERSION.json" 2>/dev/null | jq -r '.xcframework.tag // empty' || true
}

case "${1:-}" in
publish)
    [ $# -eq 5 ] || die "usage: publish <tag> <zip> <sha256> <target>"
    tag="$2" zip="$3" checksum="$4" target="$5"
    [ "$(shasum -a 256 "$zip" | cut -d' ' -f1)" = "$checksum" ] || die "$zip does not have checksum $checksum"
    if ! state="$(gh release view "$tag" --json isPrerelease --jq .isPrerelease 2>/dev/null)"; then
        gh release create "$tag" "$zip" --prerelease --latest=false --target "$target" \
            --title "CEF framework $tag" \
            --notes "The official CEF minimal distributions for macOS arm64 and x86_64, repackaged without changes to their files as one XCFramework by Scripts/package-cef.py. SHA-256 (what Package.swift pins): \`$checksum\`. CEF is BSD-licensed; LICENSE.txt and CREDITS.html are inside the archive. A prerelease until a version of CefSwift pins it."
        echo "cef-release: created the prerelease $tag"
    elif [ "$(published_checksum "$tag")" = "$checksum" ]; then
        echo "cef-release: $tag already has this asset"
    elif [ "$state" = true ]; then
        gh release upload "$tag" "$zip" --clobber
        echo "cef-release: replaced the asset of the prerelease $tag"
    else
        die "the release $tag is promoted and holds another $asset; released versions pin its checksum, so " \
            "it is never replaced. Bump PACKAGING_REVISION in Scripts/package-cef.py to publish under a new tag."
    fi
    ;;
verify)
    [ $# -eq 3 ] || die "usage: verify <tag> <sha256>"
    actual="$(published_checksum "$2")"
    [ -n "$actual" ] || die "the release $2 has no $asset; publish it (docs/automation.md, 'Publishing the framework')"
    [ "$actual" = "$3" ] || die "the $2 asset has checksum $actual, not the pinned $3"
    echo "cef-release: $2 matches the pin"
    ;;
promote)
    [ $# -eq 2 ] || die "usage: promote <tag>"
    state="$(gh release view "$2" --json isPrerelease --jq .isPrerelease)" || die "no release $2"
    if [ "$state" = true ]; then
        gh release edit "$2" --prerelease=false --latest=false
        echo "cef-release: promoted $2"
    fi
    ;;
prune)
    [ $# -ge 2 ] || die "usage: prune <default branch> [<keep>]"
    keep_promoted="${3:-3}"
    git fetch --quiet --tags origin
    pinned="$(
        for branch in "$2" cef-update cef-api-update; do
            git fetch --quiet --depth=1 origin "$branch" 2>/dev/null && pinned_tag FETCH_HEAD
        done
        for tag in $(git tag --list 'v*'); do pinned_tag "$tag"; done
    )"
    promoted=0
    # Newest first.
    while IFS=$'\t' read -r tag prerelease; do
        if grep -qxF "$tag" <<<"$pinned"; then continue; fi
        if [ "$prerelease" = true ]; then
            gh release delete "$tag" --cleanup-tag --yes
            echo "cef-release: deleted the superseded prerelease $tag"
        elif [ $((promoted += 1)) -gt "$keep_promoted" ]; then
            gh release delete "$tag" --cleanup-tag --yes
            echo "cef-release: deleted $tag, which no branch or version tag pins"
        fi
    done < <(gh release list --limit 500 --json tagName,isPrerelease,createdAt \
        --jq 'map(select(.tagName | startswith("cef-"))) | sort_by(.createdAt) | reverse | .[] | [.tagName, .isPrerelease] | @tsv')
    ;;
*)
    die "usage: $0 publish|verify|promote|prune …"
    ;;
esac
