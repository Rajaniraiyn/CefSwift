#!/bin/sh
# Creates a CefSwift app package from a template, without a CefSwift
# checkout of your own: fetches CefSwift into a cache, builds its
# `cefswift` tool and runs `cefswift new` in the current directory.
#
#   curl -fsSL https://raw.githubusercontent.com/Rajaniraiyn/CefSwift/main/Scripts/new-app.sh \
#       | sh -s -- MyBrowser --template browser
#   cd MyBrowser
#   swift package --allow-writing-to-package-directory --allow-network-connections all \
#       cef bundle --product MyBrowser --open
#
# Arguments are those of `cefswift new` (`--template browser|app|minimal`,
# `--xcode`, `--bundle-id`, …). CEFSWIFT_REF picks the branch or release tag
# to take the templates and the dependency from (default: main);
# CEFSWIFT_REPO another repository. A tag (v1.2.3) makes the new package
# depend on that release; a branch, on that branch.
set -eu

repo="${CEFSWIFT_REPO:-https://github.com/Rajaniraiyn/CefSwift}"
ref="${CEFSWIFT_REF:-main}"
cache="${CEFSWIFT_CACHE:-$HOME/Library/Caches/CefSwift}/checkouts/$(printf '%s' "$ref" | tr '/' '_')"

if [ "$#" -eq 0 ]; then
    echo "usage: new-app.sh <Name> [--template browser|app|minimal] [--xcode] …" >&2
    exit 64
fi

if [ -d "$cache/.git" ]; then
    echo "[cef] Updating CefSwift ($ref) in $cache"
    git -C "$cache" fetch --quiet --depth 1 origin "$ref"
    git -C "$cache" checkout --quiet --force FETCH_HEAD
else
    echo "[cef] Fetching CefSwift ($ref) into $cache"
    mkdir -p "$(dirname "$cache")"
    git clone --quiet --depth 1 --branch "$ref" "$repo" "$cache"
fi

echo "[cef] Building the cefswift tool"
swift build --package-path "$cache" --configuration release --product cefswift >&2
tool="$(swift build --package-path "$cache" --configuration release --show-bin-path)/cefswift"

case "$ref" in
    v[0-9]*) dependency="--cefswift-version $ref" ;;
    *) dependency="--cefswift-branch $ref" ;;
esac
# A dependency the caller chose wins.
case " $* " in
    *" --cefswift-path "*|*" --cefswift-version "*|*" --cefswift-branch "*) dependency="" ;;
esac

# shellcheck disable=SC2086 # $dependency is two words or none.
exec "$tool" new "$@" --cefswift-root "$cache" $dependency
