#!/bin/sh
# Adds Chromium's helper apps to an app that an Xcode app target builds.
#
# Run it from a Run Script build phase placed after "Embed Frameworks", with
# "Based on dependency analysis" off and User Script Sandboxing off for the
# target (ENABLE_USER_SCRIPT_SANDBOXING = NO):
#
#   "$BUILD_DIR/../../SourcePackages/checkouts/CefSwift/Scripts/xcode-embed.sh"
#
# (or the path of a local CefSwift checkout). Arguments after the script name
# go to `cef embed`, for example --capability camera. It runs
# `swift package cef embed` on this CefSwift checkout with the identity,
# hardened runtime and configuration of the Xcode build, so the helpers are
# signed as Xcode signs the app, which Xcode does after this phase.
# See docs/bundling.md, "Xcode".
set -eu

package="$(cd "$(dirname "$0")/.." && pwd)"
: "${CODESIGNING_FOLDER_PATH:?run this from an Xcode build phase}"

configuration=release
[ "${CONFIGURATION:-Release}" = Debug ] && configuration=debug
hardened=--no-hardened-runtime
[ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ] && hardened=--hardened-runtime
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$identity" ] || identity=-
[ -n "${DEVELOPMENT_TEAM:-}" ] && set -- --team-id "$DEVELOPMENT_TEAM" "$@"

# SwiftPM gets a plain environment: Xcode's build settings (SDKROOT, ARCHS,
# deployment targets and the like) would otherwise leak into its build of the
# helper. Its build products go under Xcode's intermediates.
exec env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
    CEFSWIFT_LOCAL_FRAMEWORK="${CEFSWIFT_LOCAL_FRAMEWORK:-}" \
    /usr/bin/swift package --package-path "$package" \
    --scratch-path "${OBJROOT}/CefSwift" \
    --allow-writing-to-package-directory --allow-writing-to-directory "$TARGET_BUILD_DIR" \
    --allow-network-connections all \
    cef embed "$CODESIGNING_FOLDER_PATH" \
    --configuration "$configuration" --sign "$identity" "$hardened" "$@"
