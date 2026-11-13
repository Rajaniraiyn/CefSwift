#!/usr/bin/env python3
"""Measures launch time, process count and memory footprint of a bundled
CefSwift app.

The app must support the `-benchmark YES` launch argument, as the Minimal
and Browser examples do: it prints `cefswift-benchmark loaded <time>` when
its first page finishes loading and quits when standard input closes.

Each run starts the app's executable, records the time from starting it to
that line, waits for the page to settle, then reads the physical footprint
(`footprint`, the figure Activity Monitor's Memory column shows, not RSS)
of the app and every helper process it started, and quits the app.

    Scripts/measure-footprint.py Examples/dist/Minimal.app
    Scripts/measure-footprint.py Examples/dist/Browser.app --runs 7 \\
        --url file:///path/page.html -- --js-flags=--lite-mode

Runs come in two kinds:

- first launch: a new, empty data directory every run, as on an app's first
  start (Chromium creates its profile).
- relaunch: one data directory reused across runs, after one discarded
  warm-up run.

Neither kind clears the system's file cache, which needs root, so every run
after the first reads the framework from memory. Arguments after `--` go to
the app, which passes Chromium switches through to Chromium.
"""

import argparse
import json
import os
import pathlib
import plistlib
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

LOADED = re.compile(r"cefswift-benchmark loaded ([0-9.]+)")
DEFAULT_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Footprint test page</title>
<style>body{font:16px -apple-system,sans-serif;margin:40px;max-width:640px}</style></head>
<body><h1>Footprint test page</h1>
<p>A static local page with no network requests.</p>
<ul><li>One</li><li>Two</li><li>Three</li></ul></body></html>
"""


def quit_app(app):
    """Closes the app's standard input, which makes a `-benchmark YES` app
    quit, and kills it if it has not quit within 30 s."""
    app.stdin.close()
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()
        app.wait()
        print("warning: the app did not quit within 30 s and was killed", file=sys.stderr)


def executable(app: pathlib.Path) -> pathlib.Path:
    with open(app / "Contents/Info.plist", "rb") as file:
        name = plistlib.load(file)["CFBundleExecutable"]
    return app / "Contents/MacOS" / name


def process_table():
    output = subprocess.run(
        ["ps", "-A", "-o", "pid=,ppid=,args="], capture_output=True, text=True, check=True
    ).stdout
    table = {}
    for line in output.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2:
            table[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else "")
    return table


def process_tree(root: int):
    """The root and its descendants, as {pid: args}."""
    table = process_table()
    tree, frontier = {}, [root]
    while frontier:
        pid = frontier.pop()
        if pid in table:
            tree[pid] = table[pid][1]
            frontier += [child for child, (parent, _) in table.items() if parent == pid]
    return tree


def kind(args: str) -> str:
    match = re.search(r"--type=(\S+)", args)
    if not match:
        return "browser"
    process_type = match.group(1)
    if process_type == "utility":
        sub = re.search(r"--utility-sub-type=(\S+)", args)
        name = sub.group(1).split(".")[0] if sub else "?"
        return f"utility:{name}"
    return process_type


def footprints(pids):
    with tempfile.NamedTemporaryFile(suffix=".json") as output:
        command = ["footprint", "-j", output.name]
        for pid in pids:
            command += ["-p", str(pid)]
        subprocess.run(command, capture_output=True, check=False)
        data = json.load(open(output.name))
    per_process = {entry["pid"]: entry["footprint"] for entry in data["processes"]}
    return data["total footprint"], per_process


def run_once(exe, url, data_dir, settle, extra, timeout):
    environment = dict(os.environ, MallocNanoZone="0")  # as LSEnvironment sets it
    arguments = [str(exe), "-benchmark", "YES", "-url", url, "-urls", url,
                 "-cacheDirectory", str(data_dir), *extra]
    started = time.time()
    app = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, env=environment, text=True)
    loaded = None
    try:
        deadline = started + timeout
        while time.time() < deadline:
            line = app.stdout.readline()
            if not line:
                break
            match = LOADED.search(line)
            if match:
                loaded = float(match.group(1))
                break
        if loaded is None:
            raise RuntimeError("the app did not report a finished load")
        time.sleep(settle)
        tree = process_tree(app.pid)
        total, per_process = footprints(tree)
        processes = sorted(
            ({"pid": pid, "kind": kind(args), "footprint": per_process.get(pid, 0)}
             for pid, args in tree.items()),
            key=lambda entry: (entry["kind"] != "browser", entry["kind"]))
    finally:
        quit_started = time.time()
        quit_app(app)
        quit_seconds = time.time() - quit_started
    return {
        "launch": loaded - started,
        "quit": quit_seconds,
        "exit_status": app.returncode,
        "processes": processes,
        "total": total,
    }


def summarize(label, runs):
    def median(values):
        return statistics.median(values)

    mib = 1024 * 1024
    launches = [run["launch"] * 1000 for run in runs]
    totals = [run["total"] / mib for run in runs]
    counts = [len(run["processes"]) for run in runs]
    print(f"\n{label} ({len(runs)} runs)")
    print(f"  launch to first load: median {median(launches):.0f} ms "
          f"(min {min(launches):.0f}, max {max(launches):.0f})")
    print(f"  processes:            median {median(counts):.0f} (min {min(counts)}, max {max(counts)})")
    print(f"  total footprint:      median {median(totals):.1f} MiB "
          f"(min {min(totals):.1f}, max {max(totals):.1f})")
    kinds = {}
    for run in runs:
        seen = {}
        for process in run["processes"]:
            seen.setdefault(process["kind"], []).append(process["footprint"] / mib)
        for name, values in seen.items():
            kinds.setdefault(name, []).append((len(values), sum(values)))
    for name, samples in sorted(kinds.items(), key=lambda item: item[0] != "browser"):
        count = median([sample[0] for sample in samples])
        total = median([sample[1] for sample in samples])
        print(f"    {name:<28} x{count:<3g} {total:6.1f} MiB")
    statuses = sorted({run["exit_status"] for run in runs})
    print(f"  quit: median {median([run['quit'] for run in runs]) * 1000:.0f} ms, exit status {statuses}")
    return {
        "label": label,
        "launch_ms_median": median(launches),
        "processes_median": median(counts),
        "total_mib_median": median(totals),
        "per_kind_mib_median": {name: median([s[1] for s in samples]) for name, samples in kinds.items()},
        "runs": runs,
    }


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=pathlib.Path, help="the bundled .app")
    parser.add_argument("--url", help="page to load (default: a static local page)")
    parser.add_argument("--runs", type=int, default=5, help="runs of each kind (default 5)")
    parser.add_argument("--settle", type=float, default=5,
                        help="seconds between the load and the footprint reading (default 5)")
    parser.add_argument("--kinds", choices=["first", "relaunch", "both"], default="both")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--json", type=pathlib.Path, help="also write every run to this file")
    arguments = sys.argv[1:]
    extra = arguments[arguments.index("--") + 1:] if "--" in arguments else []
    options = parser.parse_args(arguments[:arguments.index("--")] if "--" in arguments else arguments)
    options.extra = extra

    exe = executable(options.app.resolve())
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="cefswift-footprint-"))
    url = options.url
    if url is None:
        page = scratch / "page.html"
        page.write_text(DEFAULT_PAGE)
        url = page.as_uri()

    print(f"{exe.name}: {url} {' '.join(options.extra)}".rstrip())
    results = []
    try:
        if options.kinds in ("first", "both"):
            runs = []
            for index in range(options.runs):
                data_dir = scratch / f"first-{index}"
                runs.append(run_once(exe, url, data_dir, options.settle, options.extra, options.timeout))
                shutil.rmtree(data_dir, ignore_errors=True)
            results.append(summarize("first launch", runs))
        if options.kinds in ("relaunch", "both"):
            data_dir = scratch / "relaunch"
            run_once(exe, url, data_dir, options.settle, options.extra, options.timeout)  # warm-up
            runs = [run_once(exe, url, data_dir, options.settle, options.extra, options.timeout)
                    for _ in range(options.runs)]
            results.append(summarize("relaunch", runs))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
        # Helpers exit shortly after the app; Chromium's code-sign clone
        # cleanup process outlives it by design.
        for _ in range(10):
            leftovers = [f"{pid} {kind(args)}" for pid, (_, args) in process_table().items()
                         if str(options.app.resolve()) in args and "code-sign-clone-cleanup" not in args]
            if not leftovers:
                break
            time.sleep(0.5)
        else:
            print(f"warning: processes still running: {leftovers}", file=sys.stderr)

    if options.json:
        options.json.write_text(json.dumps(
            {"app": str(options.app), "url": url, "extra": options.extra, "results": results}, indent=2))


if __name__ == "__main__":
    main()
