#!/usr/bin/env python3
"""rMDP spike 001G — real QUIC datagram server (aioquic).

Terminates a genuine QUIC connection from the Swift client on the far side of a
real WAN path, so we measure Apple's QUIC congestion control end-to-end rather
than inferring it from a calibrated local relay.

Accepts RFC 9221 DATAGRAM frames, echoes each one straight back, and reports
arrival stats on exit. Runs entirely inside a throwaway venv; touches nothing
on the host outside /tmp.
"""
import argparse
import asyncio
import json
import os
import ssl
import struct
import time

from aioquic.asyncio import serve
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import DatagramFrameReceived, ConnectionTerminated

HDR = struct.Struct("!IQ")  # seq, send_ts_ns


class Stats:
    def __init__(self):
        self.count = 0
        self.bytes = 0
        self.first_ns = None
        self.last_ns = None
        self.seqs = set()
        self.max_seq = -1
        self.arrivals = []

    def record(self, data):
        t = time.monotonic_ns()
        self.count += 1
        self.bytes += len(data)
        if self.first_ns is None:
            self.first_ns = t
        self.last_ns = t
        if len(data) >= 4:
            seq = struct.unpack_from("!I", data, 0)[0]
            self.seqs.add(seq)
            self.max_seq = max(self.max_seq, seq)
            if len(self.arrivals) < 200000:
                self.arrivals.append(t)

    def report(self):
        dur = ((self.last_ns - self.first_ns) / 1e9
               if self.first_ns and self.last_ns and self.last_ns > self.first_ns else 0.0)
        mbit = (self.bytes * 8 / dur / 1e6) if dur > 0 else 0.0
        gaps = sorted((self.arrivals[i] - self.arrivals[i - 1]) / 1000.0
                      for i in range(1, len(self.arrivals)))

        def pct(xs, p):
            return round(xs[min(len(xs) - 1, int(len(xs) * p))], 1) if xs else None

        expected = self.max_seq + 1 if self.max_seq >= 0 else 0
        lost = expected - len(self.seqs) if expected else 0
        return {
            "event": "report",
            "datagrams": self.count,
            "bytes": self.bytes,
            "duration_s": round(dur, 3),
            "goodput_mbit": round(mbit, 2),
            "expected_by_seq": expected,
            "unique_received": len(self.seqs),
            "lost_by_seq": lost,
            "loss_pct": round(100.0 * lost / expected, 3) if expected else None,
            "interarrival_us": {"p50": pct(gaps, 0.50), "p95": pct(gaps, 0.95),
                                "p99": pct(gaps, 0.99),
                                "max": round(gaps[-1], 1) if gaps else None},
        }


STATS = Stats()
LAST_ACTIVITY = [time.monotonic()]


class EchoQuicProtocol(QuicConnectionProtocol):
    def quic_event_received(self, event):
        if isinstance(event, DatagramFrameReceived):
            STATS.record(event.data)
            LAST_ACTIVITY[0] = time.monotonic()
            # Echo straight back so the client can measure true RTT.
            try:
                self._quic.send_datagram_frame(event.data)
                self.transmit()
            except Exception:
                pass
        elif isinstance(event, ConnectionTerminated):
            print(json.dumps({"event": "conn_closed",
                              "reason": str(event.reason_phrase)}), flush=True)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7443)
    ap.add_argument("--cert", default="/tmp/rmdp_cert.pem")
    ap.add_argument("--key", default="/tmp/rmdp_key.pem")
    ap.add_argument("--alpn", default="rmdp-spike")
    ap.add_argument("--idle-exit", type=float, default=30.0)
    ap.add_argument("--max-seconds", type=float, default=240.0)
    args = ap.parse_args()

    cfg = QuicConfiguration(
        is_client=False,
        alpn_protocols=[args.alpn],
        max_datagram_frame_size=1400,   # enables RFC 9221 DATAGRAM support
        idle_timeout=60.0,
    )
    cfg.load_cert_chain(args.cert, args.key)
    cfg.verify_mode = ssl.CERT_NONE

    await serve("0.0.0.0", args.port, configuration=cfg,
                create_protocol=EchoQuicProtocol)
    print(json.dumps({"event": "listening", "port": args.port,
                      "alpn": args.alpn, "pid": os.getpid()}), flush=True)

    started = time.monotonic()
    while True:
        await asyncio.sleep(1.0)
        now = time.monotonic()
        if now - started > args.max_seconds:
            break
        if STATS.count > 0 and now - LAST_ACTIVITY[0] > args.idle_exit:
            break

    print(json.dumps(STATS.report()), flush=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print(json.dumps(STATS.report()), flush=True)
