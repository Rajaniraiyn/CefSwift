#!/usr/bin/env python3
"""Measures what CefKit's internal-page services (bookmarks, history,
most-visited, favicons, autocomplete, tab discarding) cost: processes,
physical footprint and call latency.

Two measurements, each on a bundled example:

    Scripts/measure-services.py selftest Examples/dist/SelfTest.app [--idle 40]
    Scripts/measure-services.py browser Examples/dist/Browser.app [--runs 3] [--idle 40]

`selftest` runs SelfTest with `-benchmarkServices YES`
(`Examples/Sources/SelfTest/ServiceBenchmark.swift`): it calls each service
once cold and five times warm and pauses after each, and this script reads
the footprint of the app and every helper process at each pause. `--idle N`
also waits N seconds without calls and measures again.

`browser` launches the Browser example on a fresh profile with one static
local page, measures five seconds after the page loaded, then sends it the
`use` command (type "swi" into the address field, bookmark the page, open
the menu bar) and measures five seconds later; `--idle N` measures again
N seconds after that. Each figure is the median of `--runs` runs, after one
discarded warm-up run on the same profile.

Memory is `footprint`'s physical footprint, as Activity Monitor shows it;
1 MiB is 2^20 bytes.
"""

import argparse
import importlib.util
import os
import pathlib
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location(
    "measure_footprint", pathlib.Path(__file__).with_name("measure-footprint.py"))
footprint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(footprint)

MIB = 1024 * 1024


def snapshot(pid):
    tree = footprint.process_tree(pid)
    total, per_process = footprint.footprints(tree)
    kinds = [(footprint.kind(args), per_process.get(p, 0)) for p, args in tree.items()]
    renderers = [size for kind, size in kinds if kind == "renderer"]
    return {
        "processes": len(kinds),
        "renderers": len(renderers),
        "renderer_mib": sum(renderers) / MIB,
        "gpu_mib": sum(size for kind, size in kinds if kind == "gpu-process") / MIB,
        "browser_mib": sum(size for kind, size in kinds if kind == "browser") / MIB,
        "total_mib": total / MIB,
    }


def row(label, s, previous=None, extra=""):
    delta = ""
    if previous:
        delta = (f"  Δ {s['processes'] - previous['processes']:+d} proc "
                 f"{s['total_mib'] - previous['total_mib']:+6.1f} MiB")
    print(f"{label:<34} {s['processes']:>3} proc  {s['renderers']:>2} rend {s['renderer_mib']:6.1f}  "
          f"gpu {s['gpu_mib']:5.1f}  app {s['browser_mib']:5.1f}  total {s['total_mib']:6.1f} MiB{delta}  {extra}")


def run_selftest(app, idle):
    exe = footprint.executable(app)
    env = dict(os.environ, MallocNanoZone="0", CEFSWIFT_BENCH_IDLE=str(idle))
    process = subprocess.Popen([str(exe), "-benchmarkServices", "YES"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
    previous, timing = None, ""
    print(f"{'step':<34} processes, renderers (MiB), GPU, app process, total; Δ from the step before; latency")
    for line in process.stdout:
        line = line.strip()
        if line.startswith("bench "):
            parts = line.split()
            if parts[1] == "error":
                print(line)
                continue
            # bench <name...> cold <ms> warm <ms>
            timing = f"cold {parts[-3]} ms, warm {parts[-1]} ms"
        elif line.startswith("bench-measure "):
            time.sleep(1)
            s = snapshot(process.pid)
            row(line[len("bench-measure "):], s, previous, timing)
            previous, timing = s, ""
            process.stdin.write("next\n")
            process.stdin.flush()
        elif line.startswith("FAIL"):
            print(line)
    process.wait()
    print(f"exit status {process.returncode}")


def browser_once(app, data_dir, url, idle):
    exe = footprint.executable(app)
    env = dict(os.environ, MallocNanoZone="0")
    process = subprocess.Popen(
        [str(exe), "-benchmark", "YES", "-urls", url, "-cacheDirectory", str(data_dir)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
    samples = {}
    try:
        for line in process.stdout:
            if "cefswift-benchmark loaded" in line:
                break
        time.sleep(5)
        samples["at launch"] = snapshot(process.pid)
        process.stdin.write("use\n")
        process.stdin.flush()
        for line in process.stdout:
            if "cefswift-benchmark used" in line:
                break
        time.sleep(5)
        samples["after typing, bookmarking, menu"] = snapshot(process.pid)
        if idle:
            time.sleep(idle)
            samples[f"{idle} s later"] = snapshot(process.pid)
    finally:
        footprint.quit_app(process)
    return samples


def run_browser(app, runs, idle):
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="cefswift-services-"))
    page = scratch / "page.html"
    page.write_text(footprint.DEFAULT_PAGE)
    data_dir = scratch / "profile"
    try:
        browser_once(app, data_dir, page.as_uri(), 0)  # warm-up: creates the profile
        results = [browser_once(app, data_dir, page.as_uri(), idle) for _ in range(runs)]
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    print(f"Browser example, median of {runs} runs")
    for label in results[0]:
        median = {key: statistics.median(r[label][key] for r in results) for key in results[0][label]}
        median["processes"] = int(median["processes"])
        median["renderers"] = int(median["renderers"])
        row(label, median)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["selftest", "browser"])
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--idle", type=int, default=0, help="also measure after this many seconds without calls")
    options = parser.parse_args()
    app = options.app.resolve()
    if options.mode == "selftest":
        run_selftest(app, options.idle)
    else:
        run_browser(app, options.runs, options.idle)


if __name__ == "__main__":
    sys.exit(main())
