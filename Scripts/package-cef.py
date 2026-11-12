#!/usr/bin/env python3
"""Repackages the pinned official CEF distributions as an XCFramework.

  Scripts/package-cef.py                # build the XCFramework and its zip in .cef/xcframework
  Scripts/package-cef.py --no-zip       # only the XCFramework, which Package.swift then uses
  Scripts/package-cef.py --write        # also pin the zip's URL and checksum in
                                        # CEF_VERSION.json and Package.swift
  Scripts/package-cef.py --check        # fail unless the zip matches the pinned checksum
  Scripts/package-cef.py --self-test    # offline checks of this script's logic

Input: the minimal distributions for both macOS architectures that
CEF_VERSION.json pins, downloaded into .cef/downloads and verified against
their size and SHA-1 (shared with Scripts/update-cef.py). The binaries are
not rebuilt or edited:

  - each Mach-O file (the framework binary and Libraries/*.dylib) becomes a
    universal file with `lipo -create`, whose two slices are the official
    files byte for byte (checked with `lipo -thin`);
  - every other file must be identical in the two distributions, except the
    V8 snapshots, which CEF names by architecture
    (v8_context_snapshot.arm64.bin, v8_context_snapshot.x86_64.bin) and the
    framework carries side by side;
  - the framework gets the versioned bundle layout (Versions/A with
    top-level symlinks) its README.txt describes;
  - LICENSE.txt and CREDITS.html from the distribution sit at the
    XCFramework's top level.

Output, in .cef/xcframework/:

  ChromiumEmbeddedFramework.xcframework      what `.binaryTarget(path:)` links
  ChromiumEmbeddedFramework.xcframework.zip  the release asset; its entries are
                                             sorted, with fixed dates and modes,
                                             so the same input gives the same
                                             bytes with the same zlib

The SHA-256 of the zip is what `swift package compute-checksum` prints and
what `.binaryTarget(url:checksum:)` verifies. Results go to $GITHUB_OUTPUT (or
standard output): tag, url, checksum, size, zip.
"""

import argparse
import filecmp
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "CEF_VERSION.json"
PACKAGE_SWIFT = ROOT / "Package.swift"
OUTPUT = ROOT / ".cef" / "xcframework"

FRAMEWORK = "Chromium Embedded Framework"
XCFRAMEWORK = "ChromiumEmbeddedFramework.xcframework"
ASSET = XCFRAMEWORK + ".zip"
LIBRARY_IDENTIFIER = "macos-arm64_x86_64"
# CEF platform name → architecture name, in the order lipo lists them.
ARCHITECTURES = {"macosx64": "x86_64", "macosarm64": "arm64"}
FLAVOR = "minimal"
NOTICES = ("LICENSE.txt", "CREDITS.html")
DEFAULT_REPOSITORY = "Rajaniraiyn/CefSwift"
# Bump when the packaging changes the zip's bytes for the same CEF version:
# a published asset is never replaced, since released CefSwift versions pin
# its checksum.
PACKAGING_REVISION = 1

SNAPSHOT = re.compile(r"^v8_context_snapshot\.(arm64|x86_64)\.bin$")
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"}
ZIP_DATE = (1980, 1, 1, 0, 0, 0)


def log(message):
    print(f"package-cef: {message}", file=sys.stderr)


def fail(message):
    sys.exit(f"package-cef: {message}")


def update_cef():
    """Scripts/update-cef.py as a module, for its verified download."""
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("update_cef", ROOT / "Scripts" / "update-cef.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{' '.join(command)} failed:\n{result.stderr.strip()}")
    return result.stdout


# --- naming ------------------------------------------------------------------


def release_tag(cef_version, revision=PACKAGING_REVISION):
    """'156.0.28+g57389f0+chromium-…' → 'cef-156.0.28' (…-r2 for a later packaging)."""
    match = re.match(r"^(\d+\.\d+\.\d+)\+", cef_version)
    if not match:
        fail(f"cannot read a CEF version number from '{cef_version}'")
    return f"cef-{match.group(1)}" + (f"-r{revision}" if revision > 1 else "")


def asset_url(repository, tag):
    return f"https://github.com/{repository}/releases/download/{tag}/{ASSET}"


# --- merging the two distributions -------------------------------------------


def is_macho(path):
    with open(path, "rb") as file:
        return file.read(4) in MACHO_MAGICS


def relative_files(root):
    """Paths of the regular files under `root`, relative to it; links are refused."""
    found = []
    for directory, subdirectories, files in os.walk(root):
        for name in subdirectories + files:
            path = Path(directory) / name
            if path.is_symlink():
                fail(f"unexpected symbolic link in the distribution: {path.relative_to(root)}")
        found += [(Path(directory) / name).relative_to(root) for name in files]
    return sorted(found)


def lipo_create(slices, output):
    run(["xcrun", "lipo", "-create", *map(str, slices), "-output", str(output)])


def lipo_check(universal, slices):
    """Each slice of `universal` is the corresponding input byte for byte."""
    with tempfile.TemporaryDirectory() as directory:
        for architecture, original in slices.items():
            thin = Path(directory) / architecture
            run(["xcrun", "lipo", str(universal), "-thin", architecture, "-output", str(thin)])
            if not filecmp.cmp(thin, original, shallow=False):
                fail(f"the {architecture} slice of {universal.name} differs from the official file")


def merge_frameworks(frameworks, destination, lipo=lipo_create, check=lipo_check):
    """Writes the universal framework's contents (flat) into `destination`.

    `frameworks` maps an architecture to its official flat framework.
    """
    listings = {arch: set(relative_files(path)) for arch, path in frameworks.items()}
    every = sorted(set().union(*listings.values()))
    for relative in every:
        present = [arch for arch in frameworks if relative in listings[arch]]
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        snapshot = SNAPSHOT.match(relative.name)
        if snapshot:
            if present != [snapshot.group(1)]:
                fail(f"{relative} should ship only in the {snapshot.group(1)} distribution, not in {present}")
            shutil.copyfile(frameworks[present[0]] / relative, target)
            continue
        if len(present) != len(frameworks):
            fail(f"{relative} ships only for {', '.join(present)}; the CEF layout changed — "
                 "review the distributions before packaging them")
        sources = {arch: frameworks[arch] / relative for arch in frameworks}
        kinds = {is_macho(path) for path in sources.values()}
        if kinds == {True}:
            lipo([sources[arch] for arch in frameworks], target)
            check(target, sources)
        elif kinds == {False}:
            first, *others = sources.values()
            if not all(filecmp.cmp(first, other, shallow=False) for other in others):
                fail(f"{relative} differs between the architectures and is not a Mach-O file; "
                     "the CEF layout changed — review the distributions before packaging them")
            shutil.copyfile(first, target)
        else:
            fail(f"{relative} is a Mach-O file for some architectures only")
        os.chmod(target, 0o755 if os.access(next(iter(sources.values())), os.X_OK) else 0o644)
    snapshots = sorted(p.name for p in every if SNAPSHOT.match(p.name))
    if len(snapshots) != len(frameworks):
        fail(f"expected one V8 snapshot per architecture, found {snapshots}")
    return every


def make_versioned(flat, framework):
    """Moves `flat`'s contents into `framework`/Versions/A and adds the symlinks."""
    version = framework / "Versions" / "A"
    version.parent.mkdir(parents=True)
    shutil.move(str(flat), str(version))
    (framework / "Versions" / "Current").symlink_to("A")
    for entry in sorted(os.listdir(version)):
        (framework / entry).symlink_to(f"Versions/Current/{entry}")


def xcframework_info_plist():
    return {
        "AvailableLibraries": [{
            "BinaryPath": f"{FRAMEWORK}.framework/Versions/A/{FRAMEWORK}",
            "LibraryIdentifier": LIBRARY_IDENTIFIER,
            "LibraryPath": f"{FRAMEWORK}.framework",
            "SupportedArchitectures": sorted(ARCHITECTURES.values()),
            "SupportedPlatform": "macos",
        }],
        "CFBundlePackageType": "XFWK",
        "XCFrameworkFormatVersion": "1.0",
    }


def assemble(frameworks, notices, xcframework, lipo=lipo_create, check=lipo_check):
    """Builds `xcframework` from the official flat frameworks and notice files."""
    if xcframework.exists():
        shutil.rmtree(xcframework)
    library = xcframework / LIBRARY_IDENTIFIER
    flat = xcframework / ".flat"
    flat.mkdir(parents=True)
    merge_frameworks(frameworks, flat, lipo, check)
    make_versioned(flat, library / f"{FRAMEWORK}.framework")
    (xcframework / "Info.plist").write_bytes(plistlib.dumps(xcframework_info_plist(), sort_keys=True))
    for notice in notices:
        shutil.copyfile(notice, xcframework / notice.name)


# --- extracting --------------------------------------------------------------


def extract(tarball, destination):
    """The framework and notice files of one distribution, extracted into `destination`."""
    top = tarball.name.removesuffix(".tar.bz2")
    destination.mkdir(parents=True)
    members = [f"{top}/Release/{FRAMEWORK}.framework", *(f"{top}/{n}" for n in NOTICES)]
    # bsdtar refuses absolute paths and '..' members by default.
    result = subprocess.run(["tar", "-xjf", str(tarball), "-C", str(destination), *members],
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"could not extract {', '.join(members)} from {tarball.name}:\n{result.stderr.strip()}")
    return destination / top / "Release" / f"{FRAMEWORK}.framework", [destination / top / n for n in NOTICES]


# --- zipping -----------------------------------------------------------------


def deterministic_zip(source, archive):
    """Zips `source` (a directory) as its own top-level entry.

    Entries are sorted and carry fixed dates and modes, and no extra
    fields, so the bytes depend only on the files and on zlib.
    """
    base = source.parent
    entries = [source]
    for directory, subdirectories, files in os.walk(source):
        subdirectories.sort()
        for name in sorted(subdirectories + files):
            entries.append(Path(directory) / name)
    entries.sort(key=lambda p: p.relative_to(base).as_posix())
    temporary = archive.with_name(archive.name + ".tmp")
    with zipfile.ZipFile(temporary, "w") as zip_file:
        for path in entries:
            name = path.relative_to(base).as_posix()
            if path.is_symlink():
                info = zipfile.ZipInfo(name, ZIP_DATE)
                info.external_attr = (stat.S_IFLNK | 0o755) << 16
                info.create_system = 3
                zip_file.writestr(info, os.readlink(path), zipfile.ZIP_STORED)
            elif path.is_dir():
                info = zipfile.ZipInfo(name + "/", ZIP_DATE)
                info.external_attr = ((stat.S_IFDIR | 0o755) << 16) | 0x10
                info.create_system = 3
                zip_file.writestr(info, b"", zipfile.ZIP_STORED)
            else:
                mode = 0o755 if os.access(path, os.X_OK) else 0o644
                info = zipfile.ZipInfo(name, ZIP_DATE)
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                with path.open("rb") as file, zip_file.open(info, "w", force_zip64=True) as sink:
                    shutil.copyfileobj(file, sink, 1 << 20)
    os.replace(temporary, archive)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --- pinning -----------------------------------------------------------------

PACKAGE_PIN = re.compile(
    r'(let cefFramework = \(\s*url: ")([^"]*)(",\s*checksum: ")([^"]*)(")', re.S)


def pin_package_swift(text, url, checksum):
    if not PACKAGE_PIN.search(text):
        fail("Package.swift has no `let cefFramework = (url: \"…\", checksum: \"…\")` to update")
    return PACKAGE_PIN.sub(lambda m: f"{m.group(1)}{url}{m.group(3)}{checksum}{m.group(5)}", text, count=1)


def read_package_pin(text):
    match = PACKAGE_PIN.search(text)
    return (match.group(2), match.group(4)) if match else (None, None)


def write_atomically(path, text):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text)
    os.replace(temporary, path)


def write_outputs(**values):
    target = os.environ.get("GITHUB_OUTPUT")
    lines = "".join(f"{key}={value}\n" for key, value in values.items())
    if target:
        with open(target, "a") as file:
            file.write(lines)
    else:
        sys.stdout.write(lines)


# --- main --------------------------------------------------------------------


def build(manifest, output=OUTPUT, make_zip=True):
    """(xcframework, zip or None) for the distributions `manifest` pins."""
    downloader = update_cef()
    tarballs = {}
    for platform in ARCHITECTURES:
        try:
            artifact = manifest["platforms"][platform][FLAVOR]
        except KeyError:
            fail(f"CEF_VERSION.json pins no {platform} {FLAVOR} distribution")
        tarballs[platform] = downloader.download(artifact)

    output.mkdir(parents=True, exist_ok=True)
    work = output / ".work"
    shutil.rmtree(work, ignore_errors=True)
    frameworks, notices = {}, {}
    for platform, tarball in tarballs.items():
        log(f"extracting {tarball.name}")
        frameworks[ARCHITECTURES[platform]], notices[platform] = extract(tarball, work / platform)
    first, *others = notices.values()
    for notice, *copies in zip(first, *others):
        if not all(filecmp.cmp(notice, copy, shallow=False) for copy in copies):
            fail(f"{notice.name} differs between the architectures")

    xcframework = output / XCFRAMEWORK
    staged = work / XCFRAMEWORK
    log("merging the architectures (lipo) and laying out the framework")
    assemble(frameworks, first, staged)
    if xcframework.exists():
        shutil.rmtree(xcframework)
    os.replace(staged, xcframework)
    shutil.rmtree(work)

    archive = None
    if make_zip:
        archive = output / ASSET
        log(f"zipping {XCFRAMEWORK} (zlib {zlib.ZLIB_RUNTIME_VERSION})")
        deterministic_zip(xcframework, archive)
    return xcframework, archive


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description="Repackages the pinned CEF distributions as an XCFramework.")
    parser.add_argument("--no-zip", action="store_true", help="build only the XCFramework, not its zip")
    parser.add_argument("--write", action="store_true",
                        help="pin the zip's URL and checksum in CEF_VERSION.json and Package.swift")
    parser.add_argument("--check", action="store_true", help="fail unless the zip matches the pinned checksum")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY") or DEFAULT_REPOSITORY,
                        help=f"the GitHub repository whose release hosts the zip (default: {DEFAULT_REPOSITORY})")
    parser.add_argument("--self-test", action="store_true", help="run the offline self-checks and exit")
    arguments = parser.parse_args(argv)
    if arguments.no_zip and (arguments.write or arguments.check):
        parser.error("--write and --check need the zip")
    return arguments


def main(argv=None):
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    if arguments.self_test:
        return self_test()
    manifest = json.loads(MANIFEST.read_text())
    xcframework, archive = build(manifest, make_zip=not arguments.no_zip)
    log(f"built {xcframework.relative_to(ROOT)}")
    if archive is None:
        return

    checksum, size = sha256(archive), archive.stat().st_size
    tag = release_tag(manifest["cef"])
    url = asset_url(arguments.repository, tag)
    log(f"{archive.relative_to(ROOT)}: {size // 1_000_000} MB, checksum {checksum}")
    if arguments.check:
        pinned = manifest.get("xcframework", {}).get("checksum")
        if pinned != checksum:
            fail(f"the zip's checksum {checksum} does not match the pinned {pinned}; the packaging is "
                 "not reproducible here (another zlib?) or the pin is stale — run with --write")
        log("the zip matches the pinned checksum")
    if arguments.write:
        manifest["xcframework"] = {"tag": tag, "url": url, "checksum": checksum, "size": size}
        write_atomically(MANIFEST, json.dumps(manifest, indent=2) + "\n")
        write_atomically(PACKAGE_SWIFT, pin_package_swift(PACKAGE_SWIFT.read_text(), url, checksum))
        log(f"pinned {url}")
    write_outputs(tag=tag, url=url, checksum=checksum, size=size, zip=archive)


# --- self-test ---------------------------------------------------------------


def self_test():
    import unittest

    def tree(root, files):
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            if name.endswith(".dylib") or "/" not in name:
                path.chmod(0o755)

    macho = b"\xcf\xfa\xed\xfe"

    def fake_lipo(slices, output):
        output.write_bytes(b"\xca\xfe\xba\xbe" + b"".join(Path(s).read_bytes() for s in slices))

    def no_check(universal, slices):
        pass

    def official(arch):
        return {FRAMEWORK: macho + arch.encode(), "Libraries/libcef_sandbox.dylib": macho + b"s" + arch.encode(),
                "Libraries/vk_swiftshader_icd.json": b"{}", "Resources/icudtl.dat": b"icu",
                "Resources/en.lproj/locale.pak": b"en", "Resources/Info.plist": b"plist",
                f"Resources/v8_context_snapshot.{arch}.bin": arch.encode()}

    class Tests(unittest.TestCase):
        def setUp(self):
            self.directory = Path(tempfile.mkdtemp())

        def tearDown(self):
            shutil.rmtree(self.directory)

        def frameworks(self, changes=None):
            result = {}
            for arch in ARCHITECTURES.values():
                files = official(arch)
                files.update((changes or {}).get(arch, {}))
                root = self.directory / arch / f"{FRAMEWORK}.framework"
                tree(root, {k: v for k, v in files.items() if v is not None})
                result[arch] = root
            return result

        def test_merges_into_a_versioned_universal_framework(self):
            notice = self.directory / "LICENSE.txt"
            notice.write_text("BSD")
            xcf = self.directory / XCFRAMEWORK
            assemble(self.frameworks(), [notice], xcf, fake_lipo, no_check)
            framework = xcf / LIBRARY_IDENTIFIER / f"{FRAMEWORK}.framework"
            self.assertEqual(os.readlink(framework / "Versions" / "Current"), "A")
            self.assertEqual(sorted(os.listdir(framework)), [FRAMEWORK, "Libraries", "Resources", "Versions"])
            self.assertEqual(os.readlink(framework / FRAMEWORK), f"Versions/Current/{FRAMEWORK}")
            version = framework / "Versions" / "A"
            self.assertEqual((version / FRAMEWORK).read_bytes(), b"\xca\xfe\xba\xbe" + macho + b"x86_64" + macho + b"arm64")
            self.assertTrue(os.access(version / FRAMEWORK, os.X_OK))
            self.assertFalse(os.access(version / "Resources/icudtl.dat", os.X_OK))
            self.assertEqual(sorted(p.name for p in (version / "Resources").glob("v8_*")),
                             ["v8_context_snapshot.arm64.bin", "v8_context_snapshot.x86_64.bin"])
            self.assertEqual((xcf / "LICENSE.txt").read_text(), "BSD")
            info = plistlib.loads((xcf / "Info.plist").read_bytes())
            self.assertEqual(info["AvailableLibraries"][0]["SupportedArchitectures"], ["arm64", "x86_64"])
            self.assertEqual(info["AvailableLibraries"][0]["BinaryPath"],
                             f"{FRAMEWORK}.framework/Versions/A/{FRAMEWORK}")

        def test_refuses_layout_changes(self):
            for changes in ({"arm64": {"Resources/icudtl.dat": b"other"}},            # differs, not Mach-O
                            {"arm64": {"Resources/new.pak": b"n"}},                   # one architecture only
                            {"arm64": {"Resources/v8_context_snapshot.x86_64.bin": b"x"}},
                            {"x86_64": {"Libraries/libcef_sandbox.dylib": b"not mach-o"}}):
                shutil.rmtree(self.directory)
                self.directory.mkdir()
                with self.assertRaises(SystemExit, msg=str(changes)):
                    merge_frameworks(self.frameworks(changes), self.directory / "out", fake_lipo, no_check)

        def test_zip_is_deterministic_and_keeps_links_and_modes(self):
            source = self.directory / "a" / XCFRAMEWORK
            tree(source, {"bin": macho, "Sub/data.txt": b"data" * 1000})
            (source / "link").symlink_to("Sub/data.txt")
            first, second = self.directory / "1.zip", self.directory / "2.zip"
            deterministic_zip(source, first)
            os.utime(source / "Sub/data.txt", (1, 1))
            deterministic_zip(source, second)
            self.assertEqual(sha256(first), sha256(second))
            with zipfile.ZipFile(first) as archive:
                infos = {i.filename: i for i in archive.infolist()}
                self.assertEqual(list(infos), sorted(infos))
                self.assertIn(f"{XCFRAMEWORK}/", infos)
                link = infos[f"{XCFRAMEWORK}/link"]
                self.assertTrue(stat.S_ISLNK(link.external_attr >> 16))
                self.assertEqual(archive.read(link), b"Sub/data.txt")
                self.assertEqual((infos[f"{XCFRAMEWORK}/bin"].external_attr >> 16) & 0o777, 0o755)
                self.assertEqual((infos[f"{XCFRAMEWORK}/Sub/data.txt"].external_attr >> 16) & 0o777, 0o644)
                self.assertEqual({i.date_time for i in infos.values()}, {ZIP_DATE})
            # unzip, as SwiftPM uses, restores the link.
            out = self.directory / "unzipped"
            subprocess.run(["unzip", "-q", str(first), "-d", str(out)], check=True)
            self.assertEqual(os.readlink(out / XCFRAMEWORK / "link"), "Sub/data.txt")

        def test_names_and_pins(self):
            version = "156.0.28+g57389f0+chromium-156.0.8078.88"
            self.assertEqual(release_tag(version), "cef-156.0.28")
            self.assertEqual(release_tag(version, 2), "cef-156.0.28-r2")
            self.assertEqual(asset_url("o/r", "cef-1.2.3"),
                             f"https://github.com/o/r/releases/download/cef-1.2.3/{ASSET}")
            text = 'x\nlet cefFramework = (\n    url: "old",\n    checksum: "0"\n)\ny'
            pinned = pin_package_swift(text, "new", "abc")
            self.assertEqual(read_package_pin(pinned), ("new", "abc"))
            self.assertTrue(pinned.startswith("x\n") and pinned.endswith(")\ny"))
            with self.assertRaises(SystemExit):
                pin_package_swift("no pin here", "u", "c")
            self.assertNotEqual(read_package_pin(PACKAGE_SWIFT.read_text()), (None, None),
                                "Package.swift must keep the cefFramework pin")

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
