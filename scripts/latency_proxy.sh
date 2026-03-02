#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import os
import select
import signal
import statistics
import subprocess
import time

def wait_for(fd: int, needle: bytes, timeout_s: float = 5.0) -> float:
    start = time.perf_counter()
    buf = b""
    while True:
        if time.perf_counter() - start > timeout_s:
            raise TimeoutError(f"timed out waiting for {needle!r}")
        r, _, _ = select.select([fd], [], [], 0.25)
        if not r:
            continue
        chunk = os.read(fd, 4096)
        if not chunk:
            continue
        buf += chunk
        if needle in buf:
            return (time.perf_counter() - start) * 1000.0

def percentile(values, pct):
    if not values:
        return 0.0
    idx = int(round((len(values) - 1) * pct))
    return sorted(values)[idx]

proc = subprocess.Popen(
    ["/bin/cat"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)

assert proc.stdin is not None
assert proc.stdout is not None
out_fd = proc.stdout.fileno()

try:
    idle = []
    for i in range(30):
        token = f"idle_{i}\n".encode()
        proc.stdin.write(token)
        proc.stdin.flush()
        idle.append(wait_for(out_fd, token))

    heavy = []
    burst = b"x" * (64 * 1024)
    for i in range(10):
        proc.stdin.write(burst + b"\n")
        proc.stdin.flush()
        marker = f"marker_{i}\n".encode()
        t0 = time.perf_counter()
        proc.stdin.write(marker)
        proc.stdin.flush()
        wait_for(out_fd, marker, timeout_s=10.0)
        heavy.append((time.perf_counter() - t0) * 1000.0)

    print("Latency proxy results (ms)")
    print(f"idle_p50={statistics.median(idle):.2f}")
    print(f"idle_p95={percentile(idle, 0.95):.2f}")
    print(f"burst_p50={statistics.median(heavy):.2f}")
    print(f"burst_p95={percentile(heavy, 0.95):.2f}")
finally:
    try:
        proc.send_signal(signal.SIGTERM)
    except Exception:
        pass
PY
