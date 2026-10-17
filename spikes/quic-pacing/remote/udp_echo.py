#!/usr/bin/env python3
"""rMDP spike — remote UDP echo/sink for real-WAN path measurement.

Runs unprivileged in userspace on a remote host. Two modes:

  sink  : receive only, report arrival timing + inter-packet dispersion.
          This is what measures *downstream* capacity of the path.
  echo  : bounce every datagram straight back, so the sender can measure
          true RTT and one-way-delay trend per packet.

Deliberately dependency-free (stdlib only) and binds to a high port. It
touches nothing on the host: no root, no firewall, no services.
"""
import argparse
import json
import os
import signal
import socket
import struct
import sys
import time

HDR = struct.Struct("!IQ")  # seq, send_ts_ns


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["sink", "echo"], default="echo")
    ap.add_argument("--port", type=int, default=7443)
    ap.add_argument("--idle-exit", type=float, default=45.0,
                    help="exit after this many seconds with no traffic")
    ap.add_argument("--max-seconds", type=float, default=300.0)
    args = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
    s.bind(("0.0.0.0", args.port))
    s.settimeout(1.0)

    print(json.dumps({"event": "listening", "mode": args.mode,
                      "port": args.port, "pid": os.getpid()}), flush=True)

    count = 0
    bytes_rx = 0
    first_ns = None
    last_ns = None
    arrivals = []          # (seq, arrival_ns) — capped
    started = time.monotonic()
    last_traffic = started

    while True:
        now = time.monotonic()
        if now - last_traffic > args.idle_exit and count > 0:
            break
        if now - started > args.max_seconds:
            break
        try:
            data, addr = s.recvfrom(65536)
        except socket.timeout:
            continue
        except OSError:
            break

        t_ns = time.monotonic_ns()
        count += 1
        bytes_rx += len(data)
        last_traffic = now
        if first_ns is None:
            first_ns = t_ns
        last_ns = t_ns

        if len(data) >= HDR.size:
            seq, _ = HDR.unpack_from(data, 0)
            if len(arrivals) < 200000:
                arrivals.append((seq, t_ns))

        if args.mode == "echo":
            try:
                s.sendto(data, addr)
            except OSError:
                pass

    # ---- report ----
    dur = (last_ns - first_ns) / 1e9 if (first_ns and last_ns and last_ns > first_ns) else 0.0
    mbit = (bytes_rx * 8 / dur / 1e6) if dur > 0 else 0.0

    # inter-arrival dispersion: the receiver-side signal a pacer would use
    gaps = []
    for i in range(1, len(arrivals)):
        gaps.append((arrivals[i][1] - arrivals[i - 1][1]) / 1000.0)  # us
    gaps.sort()

    def pct(xs, p):
        if not xs:
            return None
        return round(xs[min(len(xs) - 1, int(len(xs) * p))], 1)

    seqs = [a[0] for a in arrivals]
    expected = (max(seqs) - min(seqs) + 1) if seqs else 0
    lost = expected - len(set(seqs)) if expected else 0

    print(json.dumps({
        "event": "report",
        "datagrams": count,
        "bytes": bytes_rx,
        "duration_s": round(dur, 3),
        "goodput_mbit": round(mbit, 2),
        "expected_by_seq": expected,
        "unique_received": len(set(seqs)),
        "lost_by_seq": lost,
        "loss_pct": round(100.0 * lost / expected, 3) if expected else None,
        "interarrival_us": {
            "p50": pct(gaps, 0.50), "p95": pct(gaps, 0.95),
            "p99": pct(gaps, 0.99), "max": round(gaps[-1], 1) if gaps else None,
        },
    }), flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    main()
