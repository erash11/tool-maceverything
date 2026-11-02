#!/usr/bin/env python3
"""Real-Mac checks that CI cannot run: live updates and search speed, measured through `ev`.

Run on the Mac with the daemon installed:  python3 -I scripts/parity_check.py
Writes only under ~/MacEverything-paritytest (removed at the end). Exits 1 if any check fails.
Bar: Everything shows a change "instantly"; here a change must show within LIVE_LIMIT seconds,
and each search's median of 5 runs must be within SPEED_LIMIT_MS and its slowest run within
SPEED_MAX_MS (both include ~15 ms to start `ev`).
"""
import os
import shutil
import statistics
import subprocess
import sys
import time
import uuid

EV = os.path.expanduser("~/.local/bin/ev")
ROOT = os.path.expanduser("~/MacEverything-paritytest")
LIVE_LIMIT = 5.0      # seconds
WAIT_CAP = 60.0       # give up after this; a miss is a fail, the time shows how bad
SPEED_LIMIT_MS = 100.0  # median of 5; starting `ev` adds jitter
SPEED_MAX_MS = 250.0    # no single run may be slower than this
EV_TIMEOUT = 10         # seconds per `ev` call, so a stuck daemon cannot hang the check
BULK_SIZES = (50, 1000, 2500, 5000)
BULK_REPEATS = 3      # the bulk miss seen on 2026-11-02 was intermittent
QUERIES = ["report", "report 2026", "*.pdf", "ext:mp4;mov", "path:Football", "size:>1gb",
           "dm:thisweek", r"regex:^IMG_\d+", "video:", "report !temp:", "a", "e"]

failures = []
RUN = "zq" + uuid.uuid4().hex  # unique token in every test file name


def count(query):
    # A timeout raises out of live_checks(); main()'s finally still removes the test folder.
    out = subprocess.run([EV, "--count", query], capture_output=True, text=True, check=True,
                         timeout=EV_TIMEOUT)
    return int(out.stdout.strip())


def q(name, folder=""):
    """Query for test files whose name contains `name`, under ROOT or ROOT/<folder>/ (substring
    match, so ROOT/live/ also matches ROOT/live/sub/)."""
    scope = f'"path:{ROOT}/{folder}/"' if folder else f'"path:{ROOT}/"'
    return f"{RUN}{name} {scope}"


def check(label, change, expect):
    """expect: [(query, count before, count after)]. Confirms the before counts, starts the clock,
    runs change(), and requires every after count within LIVE_LIMIT of that one start time."""
    wrong = [(qq, b, count(qq)) for qq, b, _ in expect if count(qq) != b]
    if wrong:
        print(f"FAIL {label:42}   bad start: " + "; ".join(f"{qq} is {g}, want {b}" for qq, b, g in wrong))
        failures.append(label)
        return
    start = time.monotonic()
    change()
    # Re-check every expectation on each poll: all must hold in the same poll (a move whose old
    # entry lingers can satisfy "total is 1" before the new entry appears, then break it).
    while True:
        pending = [e for e in expect if count(e[0]) != e[2]]
        if not pending or time.monotonic() - start >= WAIT_CAP:
            break
        time.sleep(0.1)
    took = time.monotonic() - start
    ok = not pending and took <= LIVE_LIMIT
    note = "".join(f"  (still {count(qq)}, want {a}: {qq})" for qq, _, a in pending)
    print(f"{'ok  ' if ok else 'FAIL'} {label:42} {took:5.1f} s{note}")
    if not ok:
        failures.append(label)


def touch(path):
    open(path, "w").close()


def live_checks():
    print(f"Live updates (pass: seen within {LIVE_LIMIT:.0f} s, timed from the file change)")
    d = os.path.join(ROOT, "live")
    os.makedirs(d)
    a, b = f"{d}/{RUN}_a.txt", f"{d}/{RUN}_b.txt"
    check("create one file", lambda: touch(a), [(q("_a"), 0, 1)])
    check("rename one file", lambda: os.rename(a, b), [(q("_a"), 1, 0), (q("_b"), 0, 1)])
    os.makedirs(f"{d}/sub")
    check("move into a subfolder", lambda: os.rename(b, f"{d}/sub/{RUN}_b.txt"),
          [(q("_b", "live/sub"), 0, 1), (q("_b"), 1, 1)])  # total stays 1: no stale old entry
    check("delete one file", lambda: os.remove(f"{d}/sub/{RUN}_b.txt"), [(q("_b"), 1, 0)])
    check("create a file to move with its folder", lambda: touch(f"{d}/{RUN}_c.txt"),
          [(q("_c", "live"), 0, 1)])
    check("rename the parent folder", lambda: os.rename(d, d + "2"),
          [(q("_c", "live"), 1, 0), (q("_c", "live2"), 0, 1)])

    for n in BULK_SIZES:
        for r in range(1, BULK_REPEATS + 1):
            bd = os.path.join(ROOT, f"bulk{n}_{r}")
            name = f"_bulk{n}r{r}_"
            os.makedirs(bd)
            check(f"create {n} files at once (run {r})",
                  lambda: [touch(f"{bd}/{RUN}{name}{i}.dat") for i in range(n)], [(q(name), 0, n)])
            check(f"delete {n} files at once (run {r})", lambda: shutil.rmtree(bd), [(q(name), n, 0)])


def speed_checks():
    print(f"\nSearch speed (pass: median of 5 under {SPEED_LIMIT_MS:.0f} ms, slowest under {SPEED_MAX_MS:.0f} ms)")
    for query in ["zzzz-no-match-zzzz"] + QUERIES:
        times, hits = [], 0
        for _ in range(5):
            start = time.perf_counter()
            hits = count(query)
            times.append((time.perf_counter() - start) * 1000)
        ms, worst = statistics.median(times), max(times)
        ok = ms <= SPEED_LIMIT_MS and worst <= SPEED_MAX_MS
        print(f"{'ok  ' if ok else 'FAIL'} {query:42} {ms:6.1f} ms (slowest {worst:5.1f})  {hits} hits")
        if not ok:
            failures.append(f"speed: {query}")


def main():
    if not os.access(EV, os.X_OK):
        sys.exit(f"{EV} not found; install MacEverything first")
    try:
        os.makedirs(ROOT)  # fails if it exists, so the cleanup below only ever removes our own folder
    except FileExistsError:
        sys.exit(f"{ROOT} already exists; remove it first (left by an interrupted run?)")
    try:
        live_checks()
    finally:
        try:
            shutil.rmtree(ROOT)
        except OSError as err:
            failures.append(f"cleanup: {err}")
        if os.path.exists(ROOT):
            failures.append(f"cleanup: {ROOT} still exists")
    speed_checks()
    print(f"\n{len(failures)} failed" + (": " + "; ".join(failures) if failures else ""))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
