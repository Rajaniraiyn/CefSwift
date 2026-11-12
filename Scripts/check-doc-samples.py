#!/usr/bin/env python3
"""Compiles the Swift samples in README.md and docs/*.md against CefSwift.

Each fenced ```swift block becomes a file of a scratch package that depends
on this checkout's CefSwiftUI, and the package is built for macOS 14, the
oldest system CefSwift supports. A block compiles as one of:

- declarations (types, `@main` apps): inside an enum of its own, with
  `@main` removed, so that blocks can reuse names;
- members (`@State var`, `static var`, `var body` at the left margin):
  inside a struct of its own;
- statements, functions included: inside an async throwing `@MainActor`
  function.

Samples use names a real app defines (`browser`, `options`, `openTab`, …).
PRELUDE declares them, as stubs; it declares no CefSwift API. A sample
that needs a name it does not have fails, and so does one that uses API
CefSwift does not have.

    Scripts/check-doc-samples.py            # build every sample
    Scripts/check-doc-samples.py --list     # print the samples and how each compiles

A sample that needs a later macOS says so in a comment (`// macOS 15`) and
compiles as available from it.

The scratch package is .build/doc-samples (or --scratch), so a second run
reuses the build. A block that is not Swift for the app, such as a
Package.swift manifest, is left out; mark one to leave out by putting
`// doc-samples: skip` in it.
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCUMENTS = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]

PRELUDE = """\
import AppKit
import CefSwiftUI
import SwiftUI

// Names the samples use that an app defines. Stubs only: no CefSwift API.

@MainActor var browser = CefBrowser()
@MainActor var tab = CefBrowser()
@MainActor var options = CefBrowserOptions()
@MainActor var configuration = CefConfiguration.embedded
@MainActor var window = CefBrowserWindow(browser: CefBrowser())
@MainActor var profile = CefProfile.default
@MainActor var bridge = CefBridge(name: "app")
@MainActor var store = CefKeychainPasskeyStore()
@MainActor var documents = DocumentStore()
@MainActor var controller = BrowserController()
@MainActor var policy = Policy()
@MainActor var settings = AppSettings()
@MainActor var statusBanner = NSView()
@MainActor var addressField = NSView()
@MainActor var qrButton = NSView()
@MainActor var fallbackIcon = NSImage()
let url = URL(string: "https://example.com")!
let home = URL(string: "https://example.com")!
let cookie = HTTPCookie()

struct Size: Decodable { var w: Double; var h: Double }
struct Document: Decodable {}
enum AppError: Error { case forbidden }
struct DocumentStore { func save(_ document: Document) throws {} }
struct AppSettings { var blockedHosts: [String] = [] }
@MainActor final class Library { var html = "" }
struct MediaLibrary: Sendable { func file(for url: URL?) -> URL? { nil } }

@MainActor final class BrowserController: CefBrowserDelegate { func openTab() {} }
@MainActor final class Policy: CefBrowserDelegate {}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {}

@MainActor func openTab(_ url: URL?) {}
@MainActor func openTab(_ url: URL?, inBackground: Bool) {}
@MainActor func showInNewTab(_ browser: CefSystemBrowser) {}
@MainActor func search(_ text: String) {}
@MainActor func askUser(about kinds: CefPermissionKind, from origin: String?) async -> Bool { true }
@MainActor func askUserRemembering(about kinds: CefPermissionKind, from origin: String?) async -> (Bool, Bool) { (true, false) }
@MainActor func chooseFolder() async -> URL? { nil }
@MainActor func confirm(_ message: String) async -> Bool { true }
@MainActor func choose(from passkeys: [CefPasskey]) async -> CefPasskey? { nil }

struct ContentView: View { var body: some View { EmptyView() } }
struct NavigationButtons: View { let browser: CefBrowser; var body: some View { EmptyView() } }
struct AddressBar: View { let browser: CefBrowser; var body: some View { EmptyView() } }
struct AddressField: View { let browser: CefBrowser; var body: some View { EmptyView() } }
struct MyIndicator: View { let progress: Double; var body: some View { EmptyView() } }
struct FindBar: View { let session: CefFindSession; var body: some View { EmptyView() } }
struct TabIcon: View { let browser: CefBrowser; var body: some View { EmptyView() } }
struct StatusBubble: View { let text: String; var body: some View { EmptyView() } }
"""

DECLARATION = re.compile(r"^(@main|@MainActor|@objc|struct |final class |class |enum |actor |extension |protocol )")
MEMBER = re.compile(r"^(@State |@Environment|static var |static let |var body|private var |let [a-z]\w*: )")
GLOBAL_ACTOR_VAR = re.compile(r"^@\w+Actor var ")


def samples():
    """(document, line, source) for each ```swift block."""
    for document in DOCUMENTS:
        lines = document.read_text().splitlines()
        index = 0
        while index < len(lines):
            if lines[index].strip() == "```swift":
                start = index + 1
                end = start
                while end < len(lines) and lines[end].strip() != "```":
                    end += 1
                yield document, start + 1, "\n".join(lines[start:end])
                index = end
            index += 1


def kind(source):
    if "import PackageDescription" in source or "doc-samples: skip" in source:
        return "skipped"
    top = [line for line in source.splitlines()
           if line and not line[0].isspace() and not line.startswith(("//", "}", ")", "]", "import "))]
    if top and all(DECLARATION.match(line) for line in top):
        return "declarations"
    if top and MEMBER.match(top[0]):
        return "members"
    return "statements"


def render(number, source):
    """The Swift file for a sample, and the imports it hoists."""
    lines = source.splitlines()
    imports = [line for line in lines if line.startswith("import ")]
    body = [line for line in lines if not line.startswith("import ")]
    sample_kind = kind(source)
    name = f"DocSample{number}"
    # A sample that says, in a comment, that it needs a later macOS.
    newer = re.search(r"//.*\bmacOS (1[5-9]|2\d)\b", source)
    available = f"@available(macOS {newer.group(1)}, *)\n" if newer else ""
    if sample_kind == "declarations":
        body = [line for line in body if line.strip() != "@main"]
        text = f"{available}enum {name} {{\n" + "\n".join(body) + "\n}\n"
    elif sample_kind == "members":
        text = f"{available}@MainActor struct {name} {{\n" + "\n".join(body) + "\n}\n"
    else:
        hoisted = [line for line in body if GLOBAL_ACTOR_VAR.match(line)]
        body = [line for line in body if not GLOBAL_ACTOR_VAR.match(line)]
        text = ("\n".join(hoisted) + f"\n{available}@MainActor func docSample{number}() async throws {{\n"
                + "\n".join(body) + "\n}\n")
    return imports, text


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scratch", type=Path, default=ROOT / ".build" / "doc-samples")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    found = list(samples())
    if args.list:
        for number, (document, line, source) in enumerate(found, 1):
            print(f"{number:3} {document.relative_to(ROOT)}:{line} {kind(source)}")
        return 0

    package = args.scratch
    sources = package / "Sources" / "DocSamples"
    if sources.exists():
        shutil.rmtree(sources)
    sources.mkdir(parents=True)
    (package / "Package.swift").write_text(f"""\
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DocSamples",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "CefSwift", path: "{ROOT}")],
    targets: [
        .target(name: "DocSamples", dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")]),
    ]
)
""")
    (sources / "Prelude.swift").write_text(PRELUDE)
    origins = {}
    for number, (document, line, source) in enumerate(found, 1):
        if kind(source) == "skipped":
            continue
        imports, text = render(number, source)
        file = sources / f"Sample{number:03}.swift"
        header = "\n".join(sorted(set(imports) | {"import AppKit", "import CefSwiftUI", "import SwiftUI"}))
        file.write_text(f"// {document.relative_to(ROOT)}:{line}\n{header}\n\n{text}")
        origins[file.name] = f"{document.relative_to(ROOT)}:{line}"

    print(f"Building {len(origins)} samples in {package}…", flush=True)
    result = subprocess.run(
        ["swift", "build", "--package-path", str(package), "-Xswiftc", "-no-color-diagnostics"],
        capture_output=True, text=True)
    output = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout + result.stderr)
    errors = sorted({line.strip() for line in output.splitlines() if ": error: " in line and "Sample" in line})
    for line in errors:
        match = re.search(r"(Sample\d+\.swift)", line)
        origin = origins.get(match.group(1)) if match else None
        print(f"{origin}: {line}" if origin else line)
    if result.returncode != 0:
        if not errors:
            print("\n".join(line for line in output.splitlines() if "error" in line))
        print(f"FAILED: doc samples do not compile (generated sources in {sources}).")
        return 1
    print(f"All {len(origins)} samples compile.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
