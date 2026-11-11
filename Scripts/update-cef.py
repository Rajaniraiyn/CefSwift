#!/usr/bin/env python3
"""Moves the pinned CEF to the newest stable release.

  Scripts/update-cef.py            # update the working tree if a newer stable exists
  Scripts/update-cef.py --check    # only report whether an update is available

When a newer stable CEF exists for both macOS architectures, this:

  1. rewrites CEF_VERSION.json from the CDN index,
  2. downloads the arm64 minimal distribution and verifies its SHA-1,
  3. replaces the vendored headers in Sources/CCef/include/include,
  4. regenerates the C bridge (Scripts/generate-bindings.py).

CEF_API_VERSION stays pinned, so the Swift code keeps compiling against the
same C API; bumping the pin is a deliberate, separate change.

In GitHub Actions the outcome is written to $GITHUB_OUTPUT (updated, old,
new) and a pull-request description to .cef/update-summary.md.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "CEF_VERSION.json"
VENDORED_HEADERS = ROOT / "Sources" / "CCef" / "include" / "include"
CACHE = ROOT / ".cef"
CDN = "https://cef-builds.spotifycdn.com"
PLATFORMS = ("macosarm64", "macosx64")
FLAVORS = ("minimal", "standard")


def version_key(version):
    """'156.0.26+g8ea0c73+chromium-…' → (156, 0, 26)."""
    return tuple(int(part) for part in version.split("+")[0].split("."))


def newest_stable(index):
    """The newest stable release that ships every flavor for every platform."""
    releases = {}
    for platform in PLATFORMS:
        for entry in index[platform]["versions"]:
            if entry["channel"] != "stable":
                continue
            files = {f["type"]: f for f in entry["files"] if f["type"] in FLAVORS}
            if len(files) == len(FLAVORS):
                releases.setdefault(entry["cef_version"], {})[platform] = (entry, files)
    complete = [v for v, platforms in releases.items() if len(platforms) == len(PLATFORMS)]
    if not complete:
        sys.exit("update-cef: the CDN index lists no complete stable release")
    version = max(complete, key=version_key)
    return version, releases[version]


def build_manifest(version, release):
    chromium = release[PLATFORMS[0]][0]["chromium_version"]
    return {
        "cef": version,
        "chromium": chromium,
        "channel": "stable",
        "platforms": {
            platform: {
                flavor: {key: files[flavor][key] for key in ("name", "sha1", "size")}
                for flavor in FLAVORS
            }
            for platform, (_, files) in release.items()
        },
    }


def download(artifact):
    destination = CACHE / "downloads" / artifact["name"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        print(f"update-cef: downloading {artifact['name']}", file=sys.stderr)
        urllib.request.urlretrieve(f"{CDN}/{urllib.parse.quote(artifact['name'])}", destination)
    digest = hashlib.sha1()
    with destination.open("rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    if digest.hexdigest() != artifact["sha1"]:
        destination.unlink()
        sys.exit(f"update-cef: SHA-1 mismatch for {artifact['name']}")
    return destination


def vendor_headers(tarball):
    """Replaces the vendored include/ tree with the one in `tarball`."""
    staging = CACHE / "update-staging"
    shutil.rmtree(staging, ignore_errors=True)
    with tarfile.open(tarball) as archive:
        members = [m for m in archive.getmembers() if "/include/" in f"/{m.name}/"]
        archive.extractall(staging, members=members, filter="data")
    (extracted,) = staging.glob("*/include")
    shutil.rmtree(VENDORED_HEADERS)
    shutil.move(extracted, VENDORED_HEADERS)
    shutil.rmtree(staging)


def write_outputs(**values):
    target = os.environ.get("GITHUB_OUTPUT")
    lines = "".join(f"{key}={value}\n" for key, value in values.items())
    if target:
        with open(target, "a") as file:
            file.write(lines)
    else:
        sys.stdout.write(lines)


def main():
    check_only = "--check" in sys.argv[1:]
    current = json.loads(MANIFEST.read_text())
    with urllib.request.urlopen(f"{CDN}/index.json") as response:
        version, release = newest_stable(json.load(response))

    if version_key(version) <= version_key(current["cef"]):
        print(f"update-cef: {current['cef']} is the newest stable", file=sys.stderr)
        write_outputs(updated="false", old=current["cef"], new=current["cef"])
        return
    if check_only:
        write_outputs(updated="true", old=current["cef"], new=version)
        return

    manifest = build_manifest(version, release)
    vendor_headers(download(manifest["platforms"]["macosarm64"]["minimal"]))
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    subprocess.run([sys.executable, str(ROOT / "Scripts" / "generate-bindings.py")], check=True)

    summary = CACHE / "update-summary.md"
    summary.write_text(
        f"Updates the pinned CEF to the newest stable release.\n\n"
        f"| | Before | After |\n|---|---|---|\n"
        f"| CEF | `{current['cef']}` | `{version}` |\n"
        f"| Chromium | `{current['chromium']}` | `{manifest['chromium']}` |\n\n"
        f"The vendored headers and generated C bridge were refreshed; "
        f"`CEF_API_VERSION` is unchanged. CI builds, runs the unit tests and "
        f"runs the SelfTest app against the new binary before this merges.\n"
    )
    write_outputs(updated="true", old=current["cef"], new=version)
    print(f"update-cef: {current['cef']} → {version}", file=sys.stderr)


if __name__ == "__main__":
    main()
