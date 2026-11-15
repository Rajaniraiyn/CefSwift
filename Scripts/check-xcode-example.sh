#!/bin/sh
# Builds the Xcode example (Examples/Xcode) with xcodebuild against this
# checkout, Debug and Release, archives and exports it, and runs each app's
# smoke test (launch, load a page, quit). Then runs cef doctor on the
# exported app. Signs ad hoc; needs no team, keychain or network once the
# CEF distribution is in Examples/Xcode/.cef (CEF_CACHE_DIR overrides).
#
#   Scripts/check-xcode-example.sh
#
# XCODE_EXAMPLE_BUILD_DIR (default Examples/Xcode/build) holds the derived
# data, the archive and the export; delete it afterwards to free about 2 GB.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
example="$root/Examples/Xcode"
build="${XCODE_EXAMPLE_BUILD_DIR:-$example/build}"
derived="$build/dd"

xcodebuild() {
    /usr/bin/xcodebuild -project "$example/XcodeExample.xcodeproj" -scheme XcodeExample \
        -derivedDataPath "$derived" -quiet "$@"
}

smoke() {
    echo "== smoke: $1"
    "$1/Contents/MacOS/XcodeExample" -smoke YES
}

for configuration in Debug Release; do
    echo "== xcodebuild build, $configuration"
    xcodebuild -configuration "$configuration" build
    smoke "$derived/Build/Products/$configuration/XcodeExample.app"
done

echo "== xcodebuild archive"
rm -rf "$build/XcodeExample.xcarchive" "$build/export"
xcodebuild -configuration Release archive -archivePath "$build/XcodeExample.xcarchive"
echo "== xcodebuild -exportArchive"
/usr/bin/xcodebuild -exportArchive -archivePath "$build/XcodeExample.xcarchive" -exportPath "$build/export" \
    -exportOptionsPlist "$example/ExportOptions.plist" -quiet
smoke "$build/export/XcodeExample.app"

echo "== cef doctor"
# The cefswift the build phase built.
tool="$(/usr/bin/xcrun swift build --package-path "$root" --scratch-path "$derived/Build/Intermediates.noindex/CefSwift" \
    --configuration release --show-bin-path)/cefswift"
"$tool" doctor "$build/export/XcodeExample.app"
