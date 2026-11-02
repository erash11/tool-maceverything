#!/usr/bin/env python3
"""Real-Mac checks that CI cannot run: live updates and search speed, measured through `ev`.

Run on the Mac with the daemon installed:  python3 -I scripts/parity_check.py
Writes only under ~/MacEverything-paritytest (removed at the end). Exits 1 if any check fails.
Bar: Everything shows a change "instantly"; here a change must show within LIVE_LIMIT seconds,
and every search must answer within SPEED_LIMIT_MS (that includes ~15 ms to start `ev`).
"""
import os
import shutil
import statistics
import subprocess
import sys
import time

EV = os.path.expanduser("~/.local/bin/ev")
ROOT = os.path.expanduser("~/MacEverything-paritytest")
LIVE_LIMIT = 5.0      # seconds
WAIT_CAP = 60.0       # give up after this; a miss is a fail, the time shows how bad
SPEED_LIMIT_MS = 100.0
BULK_SIZES = (50, 1000, 2500, 5000)
BULK_REPEATS = 3      # the bulk miss seen on 2026-11-02 was intermittent
QUERIES = ["report", "report 2026", "*.pdf", "ext:mp4;mov", "path:Football", "size:>1gb",
           "dm:thisweek", r"regex:^IMG_\d+", "video:", "report !temp:", "a", "e"]

failures = []


def count(query):
    out = subprocess.run([EV, "--count", query], capture_output=True, text=True, check=True)
    return int(out.stdout.strip())


def wait_for(label, query, want):
    start = time.monotonic()
    got = count(query)
    while got != want and time.monotonic() - start < WAIT_CAP:
        time.sleep(0.1)
        got = count(query)
    took = time.monotonic() - start
    ok = got == want and took <= LIVE_LIMIT
    note = "" if got == want else f"  (still {got}, want {want})"
    print(f"{'ok  ' if ok else 'FAIL'} {label:42} {took:5.1f} s{note}")
    if not ok:
        failures.append(label)


def touch(path):
    open(path, "w").close()


def live_checks():
    print(f"Live updates (pass: seen within {LIVE_LIMIT:.0f} s)")
    tok = f"zqparity{int(time.time())}"
    d = os.path.join(ROOT, "live")
    os.makedirs(d)
    a, b = f"{d}/{tok}_a.txt", f"{d}/{tok}_b.txt"
    touch(a)
    wait_for("create one file", f"{tok}_a", 1)
    os.rename(a, b)
    wait_for("rename: old name gone", f"{tok}_a", 0)
    wait_for("rename: new name found", f"{tok}_b", 1)
    os.makedirs(f"{d}/sub")
    os.rename(b, f"{d}/sub/{tok}_b.txt")
    wait_for("move into a subfolder", f'{tok}_b "path:/live/sub/"', 1)
    os.remove(f"{d}/sub/{tok}_b.txt")
    wait_for("delete one file", f"{tok}_b", 0)
    os.rename(d, d + "2")
    touch(f"{d}2/{tok}_c.txt")
    wait_for("rename the parent folder", f'{tok}_c "path:/live2/"', 1)

    for n in BULK_SIZES:
        for r in range(1, BULK_REPEATS + 1):
            bd = os.path.join(ROOT, f"bulk{n}_{r}")
            os.makedirs(bd)
            btok = f"zqbulk{n}r{r}t{int(time.time())}"
            for i in range(n):
                touch(f"{bd}/{btok}_{i}.dat")
            wait_for(f"create {n} files at once (run {r})", btok, n)
            shutil.rmtree(bd)
            wait_for(f"delete {n} files at once (run {r})", btok, 0)


def speed_checks():
    print(f"\nSearch speed, median of 5 (pass: under {SPEED_LIMIT_MS:.0f} ms)")
    for q in ["zzzz-no-match-zzzz"] + QUERIES:
        times, hits = [], 0
        for _ in range(5):
            start = time.perf_counter()
            hits = count(q)
            times.append((time.perf_counter() - start) * 1000)
        ms = statistics.median(times)
        ok = ms <= SPEED_LIMIT_MS
        print(f"{'ok  ' if ok else 'FAIL'} {q:42} {ms:6.1f} ms  {hits} hits")
        if not ok:
            failures.append(f"speed: {q}")


def main():
    if not os.access(EV, os.X_OK):
        sys.exit(f"{EV} not found; install MacEverything first")
    if os.path.exists(ROOT):
        sys.exit(f"{ROOT} already exists; remove it first (left by an interrupted run?)")
    os.makedirs(ROOT)
    try:
        live_checks()
    finally:
        shutil.rmtree(ROOT, ignore_errors=True)
    speed_checks()
    print(f"\n{len(failures)} failed" + (": " + "; ".join(failures) if failures else ""))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
