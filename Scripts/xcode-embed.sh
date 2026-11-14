#!/bin/sh
# The CefSwift build phase of an Xcode app target: adds Chromium's framework,
# the helpers' startup library and the five helper apps to the app Xcode just
# built, signed with the build's identity, and checks the result. Xcode then
# signs the app. It runs `cefswift embed`, the code behind
# `swift package cef bundle`, so both build the same bundle.
#
# Add a Run Script phase as the target's last phase, with "Based on
# dependency analysis" off, that runs
#
#   "$CEFSWIFT_PACKAGE_DIR/Scripts/xcode-embed.sh"
#
# and set, in the target's build settings (or an .xcconfig, such as
# Examples/Xcode/CefSwift.xcconfig):
#
#   ENABLE_USER_SCRIPT_SANDBOXING = NO
#   ARCHS = $(NATIVE_ARCH_ACTUAL)
#   CEFSWIFT_PACKAGE_DIR = $(BUILD_DIR)/../../SourcePackages/checkouts/CefSwift
#
# (for a local package, its path instead). See docs/bundling.md, "Xcode",
# for the CEF_… settings it reads.
set -eu

: "${CODESIGNING_FOLDER_PATH:?This script runs from a Run Script phase of an Xcode app target}"
package="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${CEFSWIFT_SCRATCH_DIR:-${OBJROOT}/CefSwift}"

if [ "${ENABLE_USER_SCRIPT_SANDBOXING:-NO}" = YES ]; then
    echo "error: User Script Sandboxing is on for $TARGET_NAME, so the CefSwift phase cannot read the CEF cache or write the helper apps. Set ENABLE_USER_SCRIPT_SANDBOXING = NO for the target (Build Settings > User Script Sandboxing)." >&2
    exit 1
fi

# SwiftPM gets a plain environment: Xcode's build settings (SDKROOT, ARCHS,
# deployment targets and the like) would otherwise leak into its build.
swiftpm() {
    env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
        DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
        /usr/bin/xcrun swift build --package-path "$package" --scratch-path "$scratch" --configuration release "$@"
}

# Build cefswift unless it is newer than its sources: SwiftPM takes seconds
# to find that out itself.
bin=""
[ -f "$scratch/cefswift-bin-path" ] && bin="$(cat "$scratch/cefswift-bin-path")"
if [ -z "$bin" ] || [ ! -x "$bin/cefswift" ] || [ -n "$(find "$package/Package.swift" \
        "$package/Sources/CefBundling" "$package/Sources/CefSwiftTool" \
        "$package/Sources/CefKit/Runtime/ChromiumLocales.swift" -newer "$bin/cefswift" 2>/dev/null | head -n 1)" ]; then
    swiftpm --product cefswift --quiet
    bin="$(swiftpm --show-bin-path)"
    printf '%s\n' "$bin" > "$scratch/cefswift-bin-path"
fi

CEFSWIFT_PACKAGE_DIR="$package" CEFSWIFT_SCRATCH_DIR="$scratch" CEFSWIFT_BIN_DIR="$bin" exec "$bin/cefswift" embed
