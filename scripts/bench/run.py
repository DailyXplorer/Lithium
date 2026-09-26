#!/usr/bin/env python3
"""Lithium vs Helium: memory with 1 and 7 pages, then CPU and energy over a minute of idling.

Each browser runs alone. Helium runs as a separate instance with a throwaway profile, so the
user's own Helium (tabs, logins, extensions) is never touched. Prints one JSON object.
Usage: run.py <path to probe binary> [lithium|helium ...]
"""

import json
import os
import subprocess
import sys
import tempfile
import time

PROBE = sys.argv[1]
BROWSERS = sys.argv[2:] or ["lithium", "helium"]
LITHIUM_APP = os.path.join(os.path.dirname(__file__), "../../.build/Lithium.app")
HELIUM_APP = "/Applications/Helium.app"
HELIUM_PROFILE = os.path.join(tempfile.gettempdir(), "lithium-bench-helium-profile")
START = "https://search.brave.com/"
SITES = [
    "https://en.wikipedia.org/wiki/WebKit",
    "https://github.com/WebKit/WebKit",
    "https://www.lemonde.fr/",
    "https://www.youtube.com/",
    "https://www.reddit.com/r/apple/",
    "https://www.amazon.fr/",
]


def pid_of(pattern):
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def probe(pid):
    return json.loads(subprocess.run([PROBE, str(pid)], capture_output=True, text=True).stdout)


def wait_for(pattern, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        pid = pid_of(pattern)
        if pid:
            return pid
        time.sleep(0.5)
    raise RuntimeError(f"{pattern} did not start")


def quit_all():
    subprocess.run(["osascript", "-e", 'tell application id "app.lithium.browser" to quit'], capture_output=True)
    subprocess.run(["pkill", "-f", "Contents/MacOS/Helium --user-data-dir=" + HELIUM_PROFILE], capture_output=True)
    for _ in range(60):
        if not pid_of("Lithium.app/Contents/MacOS/Lithium") and not pid_of("Contents/MacOS/Helium --user-data-dir=" + HELIUM_PROFILE):
            return
        time.sleep(0.5)
    subprocess.run(["pkill", "-x", "Lithium"], capture_output=True)


def run(browser):
    quit_all()
    time.sleep(3)
    if browser == "lithium":
        pattern = "Lithium.app/Contents/MacOS/Lithium"
        subprocess.run(["open", "-a", LITHIUM_APP])  # the start page is Brave Search
        open_page = lambda url: subprocess.run(["open", "-a", LITHIUM_APP, url])
    else:
        pattern = "Contents/MacOS/Helium --user-data-dir=" + HELIUM_PROFILE
        flags = ["--user-data-dir=" + HELIUM_PROFILE, "--no-first-run", "--no-default-browser-check"]
        subprocess.run(["open", "-na", HELIUM_APP, "--args", *flags, START])
        open_page = lambda url: subprocess.run(["open", "-na", HELIUM_APP, "--args", *flags, url])

    pid = wait_for(pattern)
    time.sleep(15)
    one_page = probe(pid)

    for url in SITES:
        open_page(url)
        time.sleep(1.5)
    time.sleep(45)
    seven_pages = probe(pid)

    before = probe(pid)
    time.sleep(60)
    after = probe(pid)
    idle = {
        "cpuSecondsPerMinute": round(after["cpuSeconds"] - before["cpuSeconds"], 3),
        "energyJoulesPerMinute": round(after["energyJ"] - before["energyJ"], 3),
    }
    return {"onePage": one_page, "sevenPages": seven_pages, "idle": idle}


results = {}
for browser in BROWSERS:
    results[browser] = run(browser)
    print(browser, json.dumps(results[browser]), file=sys.stderr, flush=True)
quit_all()
print(json.dumps(results))
