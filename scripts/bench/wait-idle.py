#!/usr/bin/env python3
"""Waits until a browser's CPU use settles: a benchmark is over once its processes go quiet.
Usage: wait-idle.py <probe> <pid> [minimum seconds before checking]"""

import json
import subprocess
import sys
import time

probe, pid = sys.argv[1], sys.argv[2]
minimum = float(sys.argv[3]) if len(sys.argv) > 3 else 30


def cpu():
    return json.loads(subprocess.run([probe, pid], capture_output=True, text=True).stdout)["cpuSeconds"]


start = time.time()
time.sleep(minimum)
quiet = 0
last = cpu()
while time.time() - start < 900:
    time.sleep(5)
    now = cpu()
    # Under a fifth of a core over 5 seconds, three times in a row.
    quiet = quiet + 1 if now - last < 1.0 else 0
    last = now
    if quiet >= 3:
        print(f"idle after {time.time() - start:.0f}s")
        sys.exit(0)
print("still busy after 15 min")
sys.exit(1)
