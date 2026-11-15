#!/usr/bin/env python3
"""Moves the pinned CEF to the newest stable release.

  Scripts/update-cef.py                       # update if a newer stable exists
  Scripts/update-cef.py --check               # only report whether one exists
  Scripts/update-cef.py --to <version>        # vendor that stable release (also repairs a tree)
  Scripts/update-cef.py --api-version latest  # only move CEF_API_VERSION (or pass a number)
  Scripts/update-cef.py --api-version latest --to latest
                                              # both: newest CEF and its newest API version
  Scripts/update-cef.py --index index.json    # read a saved copy of the CDN index
  Scripts/update-cef.py --self-test           # offline checks of this script's logic

A release counts only when it is stable and ships the minimal and standard
distributions for both macOS architectures. Updating:

  1. downloads the arm64 minimal distribution into .cef/downloads (resumed,
     size- and SHA-1-verified, one fresh retry if a resumed download does not
     verify; shared with the CefPlugin cache),
  2. stages a copy of Sources/CCef/include in .cef/update with the new headers,
  3. regenerates the C bridge there (Scripts/generate-bindings.py), which also
     fails clearly if the new headers no longer support the pinned API version,
  4. only then swaps the staged files into the tree and rewrites CEF_VERSION.json.

A failure at any step leaves the tree untouched. Running it twice is a no-op.

CEF_API_VERSION stays pinned unless --api-version is given, so a CEF update
never changes the C API the Swift code sees. --api-version alone works on the
headers already vendored and leaves the CEF version alone.

Results: $GITHUB_OUTPUT (or stdout) gets updated, cef_old, cef_new, api_old,
api_new and subject; .cef/update/ gets commit-message.txt and pr-body.md.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "CEF_VERSION.json"
CCEF_INCLUDE = ROOT / "Sources" / "CCef" / "include"
VENDORED = CCEF_INCLUDE / "include"
GENERATED = ("ccef_config.h", "ccef_capi.h", "ccef_symbols.h")
GENERATOR = ROOT / "Scripts" / "generate-bindings.py"
DOWNLOADS = ROOT / ".cef" / "downloads"
WORK = ROOT / ".cef" / "update"

CDN = "https://cef-builds.spotifycdn.com"
PLATFORMS = ("macosarm64", "macosx64")
FLAVORS = ("minimal", "standard")
HEADERS_FROM = ("macosarm64", "minimal")

# 156.0.26+g8ea0c73+chromium-156.0.8078.88. Releases before CEF 73 used another
# scheme ("3.3626.1895.g7001d56"); they are never candidates, so they are skipped.
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)\+g[0-9a-f]+\+chromium-(\d+(?:\.\d+)+)$")


def log(message):
    print(f"update-cef: {message}", file=sys.stderr)


def fail(message):
    sys.exit(f"update-cef: {message}")


def version_key(version):
    """'156.0.26+g8ea0c73+chromium-…' → (156, 0, 26); None for other schemes."""
    match = VERSION.match(version or "")
    return tuple(int(part) for part in match.groups()[:3]) if match else None


def bindings():
    """Scripts/generate-bindings.py as a module, for its pin helpers."""
    sys.dont_write_bytecode = True  # no Scripts/__pycache__ in the tree
    spec = importlib.util.spec_from_file_location("generate_bindings", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --- network -----------------------------------------------------------------


def curl(url, output, resume=False, max_time=1800):
    # curl rather than urllib: it uses the system trust store (python.org
    # builds ship without certificates), retries transient failures and resumes.
    command = ["curl", "--fail", "--location", "--silent", "--show-error",
               "--retry", "4", "--retry-all-errors", "--retry-delay", "5",
               "--connect-timeout", "30", "--max-time", str(max_time), "--output", str(output)]
    if resume:
        command += ["--continue-at", "-"]
    if subprocess.run(command + [url]).returncode != 0:
        fail(f"could not download {url} (network down or CDN unavailable); run again later")


def load_index(path=None):
    if path is None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "index.json"
            curl(f"{CDN}/index.json", target, max_time=300)
            text = target.read_text()
    else:
        text = Path(path).read_text()
    try:
        index = json.loads(text)
    except ValueError as error:
        fail(f"the CDN index is not valid JSON ({error})")
    for platform in PLATFORMS:
        if not isinstance(index.get(platform, {}).get("versions") if isinstance(index, dict) else None, list):
            fail(f"unexpected CDN index shape: no '{platform}.versions' list")
    return index


def sha1(path):
    digest = hashlib.sha1()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(artifact):
    """The verified archive in .cef/downloads, downloading or resuming it as needed."""
    name, size = artifact["name"], artifact["size"]
    target = DOWNLOADS / name
    partial = DOWNLOADS / (name + ".part")
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if target.stat().st_size == size and sha1(target) == artifact["sha1"]:
            log(f"using cached {name}")
            return target
        # The CefPlugin downloads in place, so a short file is a resumable partial.
        if target.stat().st_size < size:
            os.replace(target, partial)
        else:
            target.unlink()
    if partial.exists() and partial.stat().st_size >= size:
        partial.unlink()
    # A resumed partial can be stale (an interrupted download of an earlier
    # upload of the same name), so a mismatch after resuming earns one fresh try.
    for attempt in ("resume", "fresh") if partial.exists() else ("fresh",):
        log(f"{'resuming' if attempt == 'resume' else 'downloading'} {name} ({size // 1_000_000} MB)")
        curl(f"{CDN}/{urllib.parse.quote(name)}", partial, resume=True)
        if partial.exists() and partial.stat().st_size == size and sha1(partial) == artifact["sha1"]:
            os.replace(partial, target)
            return target
        partial.unlink(missing_ok=True)
        log(f"{name} does not match the size and SHA-1 in the CDN index; deleted it")
    fail(f"{name} does not match the size and SHA-1 in the CDN index; run again later")


# --- release selection -------------------------------------------------------


def stable_releases(index):
    """{cef version: {platform: entry}} for stable entries that ship every flavor."""
    found = {}
    for platform in PLATFORMS:
        for entry in index[platform]["versions"]:
            if not isinstance(entry, dict) or entry.get("channel") != "stable":
                continue
            if version_key(entry.get("cef_version")) is None:
                continue
            files = {f.get("type"): f for f in entry.get("files", []) if isinstance(f, dict)}
            if all(isinstance(files.get(flavor), dict) and {"name", "sha1", "size"} <= set(files[flavor])
                   for flavor in FLAVORS):
                found.setdefault(entry["cef_version"], {})[platform] = dict(entry, files=files)
    return found


def complete_releases(index):
    """Stable releases available for every platform, newest first."""
    found = stable_releases(index)
    complete = [v for v, platforms in found.items() if set(platforms) == set(PLATFORMS)]
    return sorted(complete, key=version_key, reverse=True), found


def select_release(index, wanted=None):
    """(version, {platform: entry}, newer versions that only one platform has)."""
    complete, found = complete_releases(index)
    if wanted:
        if wanted not in complete:
            fail(f"{wanted} is not a stable release for both macOS architectures in the CDN index")
        version = wanted
    elif complete:
        version = complete[0]
    else:
        fail("the CDN index lists no stable release for both macOS architectures")
    waiting = sorted((v for v in found if v not in complete and version_key(v) > version_key(version)),
                     key=version_key)
    return version, found[version], {v: sorted(found[v]) for v in waiting}


def build_manifest(version, release):
    chromium = release[PLATFORMS[0]].get("chromium_version") or VERSION.match(version).group(4)
    return {
        "cef": version,
        "chromium": chromium,
        "channel": "stable",
        "platforms": {
            platform: {
                flavor: {key: release[platform]["files"][flavor][key] for key in ("name", "sha1", "size")}
                for flavor in FLAVORS
            }
            for platform in PLATFORMS
        },
    }


# --- headers -----------------------------------------------------------------


def extract_headers(tarball, destination):
    """Writes <top>/include/** from `tarball` into `destination`.

    Members are copied by hand instead of extractall(filter="data"): that
    filter is missing from the macOS system Python, and only plain files and
    directories under include/ are wanted anyway.
    """
    top, count = None, 0
    destination.mkdir(parents=True)
    with tarfile.open(tarball, "r:*") as archive:
        for member in archive:
            parts = PurePosixPath(member.name).parts
            if member.name.startswith("/") or ".." in parts:
                fail(f"refusing unsafe path in {tarball.name}: {member.name}")
            if len(parts) < 3 or parts[1] != "include":
                continue
            if top is None:
                top = parts[0]
            elif parts[0] != top:
                fail(f"{tarball.name} has more than one top-level directory")
            target = destination.joinpath(*parts[2:])
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open("wb") as sink:
                    shutil.copyfileobj(source, sink)
                count += 1
            else:
                fail(f"unexpected link or special file in {tarball.name}: {member.name}")
    if not (destination / "cef_api_versions.h").is_file():
        fail(f"{tarball.name} has no include/cef_api_versions.h ({count} headers found)")
    return count


def same_tree(a, b):
    def listing(root):
        return {p.relative_to(root): p for p in root.rglob("*") if p.is_file()}
    left, right = listing(a), listing(b)
    return left.keys() == right.keys() and all(left[k].read_bytes() == right[k].read_bytes() for k in left)


def move(source, destination):
    shutil.move(str(source), str(destination))


# --- describing the change ---------------------------------------------------


def describe(cef_old, cef_new, chromium_old, chromium_new, api_old, api_new, symbols):
    """(subject, commit body, pull-request description)."""
    cef_moved, api_moved = cef_old != cef_new, api_old != api_new
    if cef_moved and api_moved:
        subject = f"Update CEF to {cef_new} and CEF_API_VERSION to {api_new}"
        body = f"From CEF {cef_old} and CEF_API_VERSION {api_old}."
    elif api_moved:
        subject = f"Update CEF_API_VERSION to {api_new}"
        body = f"From CEF_API_VERSION {api_old}."
    else:
        subject = f"Update CEF to {cef_new}"
        body = f"From {cef_old}."

    if api_moved:
        intro = ("Moves the `CEF_API_VERSION` pin, which changes the C API the Swift code sees. "
                 "It does not merge itself: review the function changes below and the struct/enum "
                 "changes in the header diff.")
    else:
        intro = ("Moves the pinned CEF to the newest stable release. `CEF_API_VERSION` is unchanged, "
                 "so the Swift code sees the same C API. This merges itself once CI passes.")

    def row(label, before, after):
        return f"| {label} | `{before}` | `{after}` |" if before != after else f"| {label} | `{before}` | unchanged |"

    description = "\n".join([
        intro, "",
        "| | Before | After |", "|---|---|---|",
        row("CEF", cef_old, cef_new),
        row("Chromium", chromium_old, chromium_new),
        row("`CEF_API_VERSION`", api_old, api_new), "",
        symbols.strip(), "",
        "CI builds and tests the package, checks the generated bridge against the headers and "
        "the framework's exports, and runs the SelfTest app against the real Chromium.", "",
    ])
    return subject, body, description


def write_outputs(**values):
    target = os.environ.get("GITHUB_OUTPUT")
    lines = "".join(f"{key}={value}\n" for key, value in values.items())
    if target:
        with open(target, "a") as file:
            file.write(lines)
    else:
        sys.stdout.write(lines)


# --- main --------------------------------------------------------------------


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description="Moves the pinned CEF to the newest stable release.")
    parser.add_argument("--check", action="store_true", help="only report whether a newer stable exists")
    parser.add_argument("--api-version", metavar="latest|N", help="also move the CEF_API_VERSION pin")
    parser.add_argument("--to", metavar="latest|VERSION",
                        help="vendor this stable CEF release (default: the newest, unless --api-version is given)")
    parser.add_argument("--index", metavar="FILE", help="read the CDN index from a file instead of the network")
    parser.add_argument("--self-test", action="store_true", help="run the offline self-checks and exit")
    arguments = parser.parse_args(argv)
    if arguments.check and (arguments.api_version or arguments.to):
        parser.error("--check only reports; it cannot be combined with --api-version or --to")
    return arguments


def main(argv=None):
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    if arguments.self_test:
        return self_test()

    current = json.loads(MANIFEST.read_text())
    if version_key(current.get("cef")) is None:
        fail(f"cannot parse the pinned version '{current.get('cef')}' in CEF_VERSION.json")
    api_old = bindings().read_pin(CCEF_INCLUDE)
    # --api-version on its own is a pin-only change on the vendored headers.
    to = arguments.to or ("latest" if not arguments.api_version else None)
    version, release = current["cef"], None
    revendor = False
    if to:
        version, release, waiting = select_release(load_index(arguments.index), None if to == "latest" else to)
        for newer, platforms in waiting.items():
            log(f"{newer} is out for {', '.join(platforms)} only; waiting for the other architecture")
        # An explicit version is re-vendored even when it is the pinned one (repair).
        revendor = version_key(version) > version_key(current["cef"]) or to != "latest"
        if not revendor and version_key(version) < version_key(current["cef"]):
            log(f"the pinned {current['cef']} is newer than the CDN's newest stable {version}; keeping it")

    if arguments.check or not (revendor or arguments.api_version):
        updated = revendor and arguments.check
        if updated:
            log(f"{version} is available (pinned: {current['cef']})")
        else:
            log(f"{current['cef']} is the newest stable")
        if not arguments.check:
            # No stale commit message or PR body from an earlier run.
            shutil.rmtree(WORK, ignore_errors=True)
        write_outputs(updated=str(updated).lower(), cef_old=current["cef"],
                      cef_new=version if updated else current["cef"], api_old=api_old, api_new=api_old)
        return

    # Stage: a copy of Sources/CCef/include with the new headers and bridge.
    shutil.rmtree(WORK, ignore_errors=True)
    stage = WORK / "include"
    shutil.copytree(CCEF_INCLUDE, stage)
    manifest = current
    if revendor:
        manifest = build_manifest(version, release)
        tarball = download(manifest["platforms"][HEADERS_FROM[0]][HEADERS_FROM[1]])
        shutil.rmtree(stage / "include")
        extract_headers(tarball, stage / "include")
    command = [sys.executable, str(GENERATOR), "--include", str(stage), "--summary", str(WORK / "symbols.md")]
    if arguments.api_version:
        command += ["--api-version", arguments.api_version]
    if subprocess.run(command).returncode != 0:
        hint = ("\n  If the new headers dropped the pinned API version, move both at once:"
                "\n  Scripts/update-cef.py --to latest --api-version latest") if revendor and not arguments.api_version else ""
        fail(f"could not generate the bridge for CEF {version}; the working tree is unchanged{hint}")
    api_new = bindings().read_pin(stage)

    headers_changed = not same_tree(stage / "include", VENDORED)
    changed_files = [n for n in GENERATED if (stage / n).read_bytes() != (CCEF_INCLUDE / n).read_bytes()]
    manifest_changed = manifest != current
    if not (headers_changed or changed_files or manifest_changed):
        log("the tree already matches; nothing to do")
        shutil.rmtree(WORK)
        write_outputs(updated="false", cef_old=current["cef"], cef_new=current["cef"],
                      api_old=api_old, api_new=api_new)
        return

    # Swap: renames only, manifest last.
    if headers_changed:
        move(VENDORED, WORK / "previous-include")
        move(stage / "include", VENDORED)
    for name in changed_files:
        os.replace(stage / name, CCEF_INCLUDE / name)
    if manifest_changed:
        temporary = MANIFEST.with_name(MANIFEST.name + ".tmp")
        temporary.write_text(json.dumps(manifest, indent=2) + "\n")
        os.replace(temporary, MANIFEST)
    shutil.rmtree(WORK / "previous-include", ignore_errors=True)
    shutil.rmtree(stage)

    subject, body, description = describe(current["cef"], manifest["cef"], current["chromium"],
                                           manifest["chromium"], api_old, api_new,
                                           (WORK / "symbols.md").read_text())
    (WORK / "commit-message.txt").write_text(f"{subject}\n\n{body}\n")
    (WORK / "pr-body.md").write_text(description)
    write_outputs(updated="true", cef_old=current["cef"], cef_new=manifest["cef"],
                  api_old=api_old, api_new=api_new, subject=subject)
    log(subject)


# --- self-test ---------------------------------------------------------------


def self_test():
    import io
    import unittest

    def entry(version, channel="stable", flavors=FLAVORS, platform="macosarm64"):
        files = [{"type": f, "name": f"cef_binary_{version}_{platform}_{f}.tar.bz2", "sha1": f"{f}-sha",
                  "size": 1, "last_modified": "x"} for f in flavors]
        files.append({"type": "tools", "name": "tools.tar.bz2", "sha1": "t", "size": 1})
        return {"cef_version": version, "channel": channel, "chromium_version": version.split("chromium-")[-1],
                "files": files}

    def v(number):
        return f"{number}+g0123abc+chromium-{number.split('.')[0]}.0.1.2"

    def index(arm, x64):
        return {"macosarm64": {"versions": arm}, "macosx64": {"versions": x64}, "linux64": {"versions": []}}

    class Tests(unittest.TestCase):
        def test_version_ordering_is_numeric(self):
            versions = [v("157.0.10"), v("156.0.26"), v("157.0.9"), v("157.1.0")]
            self.assertEqual(sorted(versions, key=version_key),
                             [v("156.0.26"), v("157.0.9"), v("157.0.10"), v("157.1.0")])
            self.assertIsNone(version_key("3.3626.1895.g7001d56"))
            self.assertIsNone(version_key(None))

        def test_selects_newest_stable_for_both_architectures(self):
            arm = [entry(v("158.0.1"), "beta"), entry(v("157.0.11")), entry(v("157.0.10")),
                   entry(v("157.0.9")), entry(v("157.0.12"), flavors=("standard",))]
            x64 = [entry(v(n), platform="macosx64") for n in ("157.0.10", "157.0.9")]
            x64 += [entry(v("158.0.1"), "beta", platform="macosx64"),
                    entry("3.3626.1895.g7001d56", platform="macosx64")]
            version, release, waiting = select_release(index(arm, x64))
            self.assertEqual(version, v("157.0.10"))
            self.assertEqual(set(release), set(PLATFORMS))
            self.assertEqual(waiting, {v("157.0.11"): ["macosarm64"]})
            self.assertEqual(select_release(index(arm, x64), v("157.0.9"))[0], v("157.0.9"))
            with self.assertRaises(SystemExit):
                select_release(index(arm, x64), v("157.0.11"))
            with self.assertRaises(SystemExit):
                select_release(index([entry(v("157.0.1"))], []))

        def test_manifest_matches_the_plugin_schema(self):
            version = v("157.0.10")
            release = {p: dict(entry(version, platform=p), files={f["type"]: f for f in entry(version, platform=p)["files"]})
                       for p in PLATFORMS}
            manifest = build_manifest(version, release)
            self.assertEqual(list(manifest), ["cef", "chromium", "channel", "platforms"])
            self.assertEqual(manifest["chromium"], "157.0.1.2")
            self.assertEqual(list(manifest["platforms"]), list(PLATFORMS))
            for platform in PLATFORMS:
                self.assertEqual(list(manifest["platforms"][platform]), list(FLAVORS))
                self.assertEqual(list(manifest["platforms"][platform]["minimal"]), ["name", "sha1", "size"])
            self.assertEqual(list(manifest), list(json.loads(MANIFEST.read_text())))

        def test_rejects_unexpected_index_shapes(self):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "index.json"
                for text in ("[]", "{}", '{"macosarm64": {"versions": []}}', "not json"):
                    path.write_text(text)
                    with self.assertRaises(SystemExit):
                        load_index(path)

        def test_extracts_only_headers_and_refuses_unsafe_members(self):
            def tarball(directory, members):
                path = Path(directory) / f"t{len(list(Path(directory).iterdir()))}.tar.bz2"
                with tarfile.open(path, "w:bz2") as archive:
                    for name, kind in members:
                        info = tarfile.TarInfo(name)
                        if kind == "dir":
                            info.type = tarfile.DIRTYPE
                            archive.addfile(info)
                        elif kind == "link":
                            info.type, info.linkname = tarfile.SYMTYPE, "/etc/passwd"
                            archive.addfile(info)
                        else:
                            info.size = len(kind)
                            archive.addfile(info, io.BytesIO(kind.encode()))
                return path

            with tempfile.TemporaryDirectory() as directory:
                good = tarball(directory, [("cef/include", "dir"), ("cef/include/cef_api_versions.h", "v"),
                                           ("cef/include/capi/cef_app_capi.h", "a"), ("cef/Release/x", "x"),
                                           ("cef/libcef_dll/include/y.h", "y")])
                out = Path(directory) / "out"
                self.assertEqual(extract_headers(good, out), 2)
                self.assertEqual(sorted(p.relative_to(out).as_posix() for p in out.rglob("*") if p.is_file()),
                                 ["capi/cef_app_capi.h", "cef_api_versions.h"])
                for members in ([("cef/include/../../evil.h", "e")], [("/cef/include/a.h", "a")],
                                [("cef/include/cef_api_versions.h", "v"), ("cef/include/l.h", "link")],
                                [("cef/include/a.h", "a")]):
                    with self.assertRaises(SystemExit):
                        extract_headers(tarball(directory, members), Path(tempfile.mkdtemp(dir=directory)) / "o")

        def test_download_verifies_and_retries_a_stale_partial_once(self):
            content = b"the real archive"
            artifact = {"name": "cef.tar.bz2", "size": len(content), "sha1": hashlib.sha1(content).hexdigest()}
            calls = []

            def fake_curl(url, output, resume=False, max_time=None, serve=content):
                calls.append(output.stat().st_size if output.exists() else 0)
                done = output.stat().st_size if output.exists() else 0
                with output.open("ab") as file:
                    file.write(serve[done:])

            global DOWNLOADS, curl
            saved = DOWNLOADS, curl
            try:
                with tempfile.TemporaryDirectory() as directory:
                    DOWNLOADS, curl = Path(directory), fake_curl
                    # A stale partial: the resume yields a mismatch, the fresh try succeeds.
                    (DOWNLOADS / "cef.tar.bz2.part").write_bytes(b"stale")
                    self.assertEqual(download(artifact).read_bytes(), content)
                    self.assertEqual(calls, [5, 0])
                    calls.clear()
                    download(artifact)  # cached and verified: no network
                    self.assertEqual(calls, [])
                    # A CDN that keeps serving the wrong bytes fails after one retry, leaving nothing.
                    (DOWNLOADS / "cef.tar.bz2").unlink()
                    (DOWNLOADS / "cef.tar.bz2.part").write_bytes(b"stale")
                    curl = lambda url, output, **kw: fake_curl(url, output, serve=b"x" * len(content))
                    with self.assertRaises(SystemExit):
                        download(artifact)
                    self.assertEqual(list(DOWNLOADS.iterdir()), [])
            finally:
                DOWNLOADS, curl = saved

        def test_api_version_pin_handling(self):
            gb = bindings()
            header = "\n".join(["#define CEF_API_VERSION_13300 13300", "#define CEF_API_VERSION_15600 15600",
                                "#define CEF_API_VERSION_15700 15700", "#define CEF_API_VERSION_999998 999998",
                                "#define CEF_API_VERSION_999999 999999",
                                "#define CEF_API_VERSION_MIN CEF_API_VERSION_13300",
                                "#define CEF_API_VERSION_LAST CEF_API_VERSION_15700"])
            released, oldest, newest = gb.released_api_versions(header)
            self.assertEqual((released, oldest, newest), ([13300, 15600, 15700], 13300, 15700))
            self.assertEqual(gb.resolve_api_version("latest", released, oldest, newest), 15700)
            self.assertEqual(gb.resolve_api_version("15600", released, oldest, newest), 15600)
            for bad in ("15500", "999999", "next"):
                with self.assertRaises(SystemExit):
                    gb.resolve_api_version(bad, released, oldest, newest)
            gb.validate_pin(15600, released, oldest, newest)
            for bad in (13000, 15650, 999998):
                with self.assertRaises(SystemExit):
                    gb.validate_pin(bad, released, oldest, newest)
            self.assertEqual(gb.read_pin(CCEF_INCLUDE), int(re.search(
                r"#define CEF_API_VERSION (\d+)", (CCEF_INCLUDE / "ccef_config.h").read_text()).group(1)))

        def test_symbol_diff(self):
            gb = bindings()
            before = gb.read_symbol_lines("// CCEF_SYM(return_type, name, (params), (args))\n"
                                          "CCEF_SYM(int, cef_a, (void), ())\nCCEF_SYM(int, cef_b, (void), ())\n"
                                          "CCEF_SYM(void, cef_c, (int x), (x))\n")
            after = dict(before, cef_d="CCEF_SYM(int, cef_d, (void), ())",
                         cef_c="CCEF_SYM(void, cef_c, (long x), (x))")
            del after["cef_b"]
            self.assertEqual(gb.diff_symbols(before, after), (["cef_d"], ["cef_b"], ["cef_c"]))
            self.assertEqual(gb.describe_diff(before, before, True), "C API: unchanged (3 functions).")
            self.assertIn("- Added: `cef_d`", gb.describe_diff(before, after, True))

        def test_describes_each_kind_of_change(self):
            a, b = v("156.0.26"), v("156.0.28")
            subject, body, text = describe(a, b, "1", "2", 15600, 15600, "C API: unchanged (1 functions).")
            self.assertEqual((subject, body), (f"Update CEF to {b}", f"From {a}."))
            self.assertIn("merges itself", text)
            self.assertIn("| `CEF_API_VERSION` | `15600` | unchanged |", text)
            subject, body, text = describe(a, a, "1", "1", 15600, 15700, "")
            self.assertEqual((subject, body), ("Update CEF_API_VERSION to 15700", "From CEF_API_VERSION 15600."))
            self.assertIn("does not merge itself", text)
            self.assertEqual(describe(a, b, "1", "2", 15600, 15700, "")[0],
                             f"Update CEF to {b} and CEF_API_VERSION to 15700")

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests))
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
