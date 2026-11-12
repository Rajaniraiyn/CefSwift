#!/usr/bin/env python3
"""Web-compatibility matrix: what pages can observe about a CefSwift browser.

Loads a local probe page (Scripts/compat/probe.html) and, optionally, public
bot-detection test pages, in each kind of host with each CefSwift feature
turned on by itself, and in stock Google Chrome for comparison. The probe
posts its readings back to this script's server, so reading them never
touches the browser under test; public pages are recorded as screenshots
taken from outside the app.

    # Bundle the harness once (in the foreground):
    swift package --package-path Examples --allow-writing-to-package-directory \\
        --allow-network-connections all cef bundle --product Compat --output dist

    Scripts/compat-matrix.py probe --out /tmp/compat          # local probe, every cell
    Scripts/compat-matrix.py sites --out /tmp/compat          # public pages, a few cells
    Scripts/compat-matrix.py table --out /tmp/compat          # Markdown table of the probe results

Reading the public pages: the Turnstile demo uses Cloudflare's always-pass
test key, so it shows only that the widget runs. Compare each cell with the
Chrome column rather than with the page's own verdict alone.

COMPAT_APP=<path to Compat.app> measures another bundle, such as one built
from an earlier commit. COMPAT_LOCK=<file> serializes every app run with lockf(1), for machines where
other Chromium apps run at the same time. Public pages are loaded once per
cell; keep the cell list short.
"""

import argparse
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE_DIR = ROOT / "Scripts" / "compat"
APP = Path(os.environ.get("COMPAT_APP", ROOT / "Examples" / "dist" / "Compat.app")) / "Contents" / "MacOS" / "Compat"
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
PORT = 8765

# Hosts: (name, Compat -host, -preset). "chrome" is stock Google Chrome.
COLUMNS = [
    ("chrome", None, None),
    ("window", "window", "browser"),
    ("windowed", "windowed", "embedded"),
    ("offscreen", "offscreen", "embedded"),
]

# Rows: one CefSwift feature at a time. (name, -features, -preset override)
ROWS = [
    ("nothing", "", None),
    ("devtools", "devtools", None),
    ("Runtime.enable", "runtime", None),
    ("Page.enable", "page", None),
    ("bridge", "bridge", None),
    ("user script", "userscript", None),
    ("evaluateJavaScript", "evaluate", None),
    ("passkeys .app", "passkeys", None),
    ("accessibility", "accessibility", None),
    ("preset default", "", "default"),
    ("preset browser", "", "browser"),
    ("preset embedded", "", "embedded"),
]

SITES = {
    "sannysoft": "https://bot.sannysoft.com/",
    "creepjs": "https://abrahamjuliot.github.io/creepjs/",
    "browserscan": "https://www.browserscan.net/bot-detection",
    "botd": "https://fingerprintjs.github.io/BotD/main/",
    "deviceinfo": "https://deviceandbrowserinfo.com/are_you_a_bot",
    "rebrowser": "https://bot-detector.rebrowser.net/",
    "turnstile": "https://demo.turnstile.workers.dev/",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    out: Path = Path(".")

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(PROBE_DIR), **kwargs)

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/headers":
            body = json.dumps({k.lower(): v for k, v in self.headers.items()}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def do_POST(self):
        if self.path != "/report":
            self.send_error(404)
            return
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            report = json.loads(data)
        except ValueError:
            self.send_error(400)
            return
        tag = "".join(c if c.isalnum() or c in "-_." else "_" for c in report.get("tag", "untagged"))
        (self.out / "probe").mkdir(parents=True, exist_ok=True)
        (self.out / "probe" / f"{tag}.json").write_text(json.dumps(report, indent=1))
        self.send_response(204)
        self.end_headers()


def serve(out: Path):
    Handler.out = out
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def locked(command):
    lock = os.environ.get("COMPAT_LOCK")
    return ["lockf", "-t", "3600", lock] + command if lock else command


def run_cef(column, row_features, preset, url, out: Path, tag, wait, capture=None):
    _, host, column_preset = next(c for c in COLUMNS if c[0] == column)
    cache = Path(tempfile.mkdtemp(prefix="cefswift-compat-"))
    command = [str(APP), "-host", host, "-preset", preset or column_preset, "-features", row_features,
               "-url", url, "-wait", str(wait), "-cacheDirectory", str(cache)]
    if capture:
        command += ["-capture", str(capture)]
    try:
        subprocess.run(locked(command), timeout=wait + 90, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        print(f"  {tag}: timed out", file=sys.stderr)
    finally:
        shutil.rmtree(cache, ignore_errors=True)


def run_chrome(url, wait, capture=None):
    profile = Path(tempfile.mkdtemp(prefix="cefswift-compat-chrome-"))
    command = [str(CHROME), f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
               "--window-position=60,60", "--window-size=1280,900", "--new-window", url]
    script = (
        f"import subprocess,time,sys\n"
        f"p=subprocess.Popen({command!r},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
        f"time.sleep({wait})\n"
        + (f"subprocess.run(['screencapture','-x','-R','60,60,1280,900',{str(capture)!r}])\n" if capture else "")
        + "p.terminate()\ntry:\n p.wait(15)\nexcept Exception:\n p.kill()\n"
    )
    try:
        subprocess.run(locked([sys.executable, "-I", "-c", script]), timeout=wait + 90)
    finally:
        shutil.rmtree(profile, ignore_errors=True)


def probe(args):
    out = Path(args.out)
    server = serve(out)
    columns = args.columns.split(",") if args.columns else [c[0] for c in COLUMNS]
    rows = [r for r in ROWS if not args.rows or r[0] in args.rows.split(",")]
    try:
        for column in columns:
            for name, features, preset in (rows if column != "chrome" else [ROWS[0]]):
                if name == "accessibility" and column != "offscreen":
                    continue
                tag = f"{args.label}-{column}-{name}".replace(" ", "_")
                url = f"http://127.0.0.1:{PORT}/probe.html#{tag}"
                print(f"probe {tag}")
                if column == "chrome":
                    run_chrome(url, args.wait)
                else:
                    run_cef(column, features, preset, url, out, tag, args.wait)
    finally:
        server.shutdown()


def sites(args):
    out = Path(args.out) / "sites"
    out.mkdir(parents=True, exist_ok=True)
    cells = [cell.split(":") for cell in args.cells.split(",")]
    names = args.sites.split(",") if args.sites else list(SITES)
    for column, row in cells:
        features, preset = next(((f, p) for n, f, p in ROWS if n == row), (row, None))
        for site in names:
            tag = f"{args.label}-{column}-{row}-{site}".replace(" ", "_")
            capture = out / f"{tag}.png"
            print(f"site {tag}")
            if column == "chrome":
                run_chrome(SITES[site], args.wait, capture)
            else:
                run_cef(column, features, preset, SITES[site], out, tag, args.wait, capture)


SUMMARY_KEYS = [
    ("Runtime probe", lambda r: "fires" if (r.get("runtimeEnabledAtStart") or r.get("runtimeEnabledLater")) else "silent"),
    ("console touched", lambda r: ",".join(sorted(set(r["consoleVariantsAtStart"]["touched"] + r["consoleVariantsLater"]["touched"]))) or "-"),
    ("big log ms", lambda r: "{}/{}".format(r["consoleVariantsAtStart"]["bigLogMs"], r["consoleVariantsLater"]["bigLogMs"])),
    ("debugger ms", lambda r: r.get("debuggerStatementMs")),
    ("globals", lambda r: ",".join(r.get("automationGlobals", []) + r.get("automationGlobalsLater", [])) or "-"),
    ("webdriver", lambda r: r.get("webdriver")),
    ("outer-inner", lambda r: "{}x{}".format(
        r["geometryLater"]["outer"][0] - r["geometryLater"]["inner"][0],
        r["geometryLater"]["outer"][1] - r["geometryLater"]["inner"][1]) if r.get("geometryLater") else "?"),
    ("screenXY", lambda r: r.get("geometryLater", {}).get("screenXY")),
    ("avail", lambda r: r.get("geometryLater", {}).get("avail")),
    ("visible/focus", lambda r: "{}/{}".format(r.get("geometryLater", {}).get("visibility"), r.get("geometryLater", {}).get("hasFocus"))),
    ("rAF/s", lambda r: r.get("animationFramesPerSecond")),
    ("chrome keys", lambda r: ",".join(r.get("windowChrome") or []) or "-"),
    ("plugins", lambda r: len(r.get("plugins", []))),
    ("brands", lambda r: "; ".join(b for b in (r.get("uaBrands") or []) if "Brand" not in b)),
    ("h264/aac", lambda r: "{}/{}".format(r.get("canPlay", {}).get("h264") or "no", r.get("canPlay", {}).get("aac") or "no")),
    ("WebGL", lambda r: (r.get("webgl") or {}).get("renderer", "")[:40] if isinstance(r.get("webgl"), dict) else r.get("webgl")),
    ("notif", lambda r: f"{r.get('notificationPermission')}/{r.get('notificationsQuery')}"),
    ("voices", lambda r: r.get("speechVoices")),
    ("media", lambda r: len(r.get("mediaDevices") or [])),
]


def table(args):
    directory = Path(args.out) / "probe"
    reports = sorted(directory.glob(f"{args.label}-*.json"))
    print("| cell | " + " | ".join(k for k, _ in SUMMARY_KEYS) + " |")
    print("|---" * (len(SUMMARY_KEYS) + 1) + "|")
    for path in reports:
        report = json.loads(path.read_text())
        cells = []
        for _, read in SUMMARY_KEYS:
            try:
                cells.append(str(read(report)))
            except Exception:  # noqa: BLE001 - a missing reading shows as "?"
                cells.append("?")
        print(f"| {path.stem[len(args.label) + 1:]} | " + " | ".join(cells) + " |")
    if args.detail:
        for path in reports:
            report = json.loads(path.read_text())
            print(f"\n{path.stem}: UA {report.get('userAgent')}\n  sec-ch-ua {report.get('requestHeaders', {}).get('sec-ch-ua')}"
                  f"\n  stack {report.get('stackAtTop')}\n  flags {report.get('flags')}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("probe", "sites", "table"):
        p = sub.add_parser(name)
        p.add_argument("--out", required=True)
        p.add_argument("--label", default="run")
        p.add_argument("--wait", type=int, default=10)
        if name == "probe":
            p.add_argument("--columns", help="comma-separated: chrome,window,windowed,offscreen")
            p.add_argument("--rows", help="comma-separated row names")
        if name == "sites":
            p.add_argument("--cells", default="chrome:nothing,window:nothing,windowed:nothing,offscreen:nothing",
                           help="comma-separated column:row pairs")
            p.add_argument("--sites", help="comma-separated: " + ",".join(SITES))
        if name == "table":
            p.add_argument("--detail", action="store_true")
    args = parser.parse_args()
    {"probe": probe, "sites": sites, "table": table}[args.command](args)


if __name__ == "__main__":
    main()
