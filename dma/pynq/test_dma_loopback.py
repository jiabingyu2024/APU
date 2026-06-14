#!/usr/bin/env python3
"""PYNQ AXI DMA loopback correctness, bandwidth, and CPU benchmark."""

import argparse
import asyncio
import csv
import json
import os
import time

import numpy as np

try:
    from pynq import Overlay, allocate
except ImportError as error:
    raise SystemExit("This script must run on a PYNQ image: %s" % error)


async def wait_channels_async(send_channel, recv_channel):
    await asyncio.gather(send_channel.wait_async(), recv_channel.wait_async())


def wait_channels_polling(send_channel, recv_channel):
    send_channel.wait()
    recv_channel.wait()


def channel_has_interrupt(channel):
    return getattr(channel, "_interrupt", None) is not None


def percentile(values, value):
    return float(np.percentile(np.asarray(values, dtype=np.float64), value))


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dma_root = os.path.abspath(os.path.join(script_dir, ".."))
    default_bit = os.path.join(dma_root, "overlay", "loopback", "apu_dma_loopback.bit")
    default_output = os.path.join(dma_root, "reports", "raw")

    parser = argparse.ArgumentParser()
    parser.add_argument("--bitstream", default=default_bit)
    parser.add_argument("--dma-name", default="axi_dma_0")
    parser.add_argument("--sizes", default="4096,65536,1048576,4194304")
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--output-dir", default=default_output)
    parser.add_argument("--allow-polling", action="store_true")
    args = parser.parse_args()

    sizes = [int(value) for value in args.sizes.split(",") if value.strip()]
    if not sizes or any(size <= 0 or size % 8 for size in sizes):
        raise SystemExit("Every transfer size must be a positive multiple of 8 bytes")

    overlay = Overlay(os.path.abspath(args.bitstream))
    if not hasattr(overlay, args.dma_name):
        raise RuntimeError("DMA instance not found in HWH: " + args.dma_name)
    dma = getattr(overlay, args.dma_name)

    interrupt_mode = channel_has_interrupt(dma.sendchannel) and channel_has_interrupt(
        dma.recvchannel
    )
    if not interrupt_mode and not args.allow_polling:
        raise RuntimeError(
            "DMA interrupts are unavailable. CPU<10% acceptance requires interrupt-backed "
            "wait_async; use --allow-polling only for functional diagnosis."
        )

    records = []
    for size_bytes in sizes:
        words = size_bytes // 8
        tx = allocate(shape=(words,), dtype=np.uint64)
        rx = allocate(shape=(words,), dtype=np.uint64)
        try:
            indices = np.arange(words, dtype=np.uint64)
            tx[:] = np.uint64(0xA5A5000000000000) ^ (
                indices * np.uint64(0x0102040810204081)
            )

            for iteration in range(args.warmup + args.iterations):
                rx[:] = 0
                tx.flush()
                rx.flush()

                wall_start = time.perf_counter()
                cpu_start = time.process_time()
                dma.recvchannel.transfer(rx, nbytes=size_bytes)
                dma.sendchannel.transfer(tx, nbytes=size_bytes)
                if interrupt_mode:
                    asyncio.run(wait_channels_async(dma.sendchannel, dma.recvchannel))
                else:
                    wait_channels_polling(dma.sendchannel, dma.recvchannel)
                cpu_seconds = time.process_time() - cpu_start
                wall_seconds = time.perf_counter() - wall_start
                rx.invalidate()

                if not np.array_equal(tx, rx):
                    mismatch = int(np.flatnonzero(tx != rx)[0])
                    raise RuntimeError(
                        "Loopback mismatch at uint64 word %d: got 0x%016X expected 0x%016X"
                        % (mismatch, int(rx[mismatch]), int(tx[mismatch]))
                    )

                if iteration >= args.warmup:
                    records.append(
                        {
                            "size_bytes": size_bytes,
                            "iteration": iteration - args.warmup,
                            "wait_mode": "interrupt" if interrupt_mode else "polling",
                            "wall_seconds": wall_seconds,
                            "cpu_seconds": cpu_seconds,
                            "cpu_percent": 100.0 * cpu_seconds / wall_seconds,
                            "roundtrip_payload_mb_per_second": (
                                2.0 * size_bytes / wall_seconds / 1e6
                            ),
                            "one_way_equivalent_mb_per_second": (
                                size_bytes / wall_seconds / 1e6
                            ),
                        }
                    )
        finally:
            tx.freebuffer()
            rx.freebuffer()

    os.makedirs(args.output_dir, exist_ok=True)
    csv_path = os.path.join(args.output_dir, "dma_loopback_samples.csv")
    json_path = os.path.join(args.output_dir, "dma_loopback_summary.json")
    with open(csv_path, "w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0].keys()))
        writer.writeheader()
        writer.writerows(records)

    summaries = []
    for size_bytes in sizes:
        selected = [row for row in records if row["size_bytes"] == size_bytes]
        bandwidth = [row["one_way_equivalent_mb_per_second"] for row in selected]
        cpu = [row["cpu_percent"] for row in selected]
        summaries.append(
            {
                "size_bytes": size_bytes,
                "iterations": len(selected),
                "wait_mode": selected[0]["wait_mode"],
                "mbps_mean": float(np.mean(bandwidth)),
                "mbps_p50": percentile(bandwidth, 50),
                "mbps_p95": percentile(bandwidth, 95),
                "mbps_min": float(np.min(bandwidth)),
                "mbps_max": float(np.max(bandwidth)),
                "cpu_percent_mean": float(np.mean(cpu)),
                "passes_200mbps": bool(np.mean(bandwidth) >= 200.0),
                "passes_cpu_10percent": bool(np.mean(cpu) < 10.0),
            }
        )

    result = {
        "schema_version": 1,
        "bitstream": os.path.abspath(args.bitstream),
        "dma_name": args.dma_name,
        "interrupt_mode": interrupt_mode,
        "warmup": args.warmup,
        "iterations": args.iterations,
        "bandwidth_definition": "size_bytes / simultaneous MM2S+S2MM elapsed time / 1e6",
        "summaries": summaries,
    }
    with open(json_path, "w", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write("\n")

    print(json.dumps(summaries, indent=2, sort_keys=True))
    print(csv_path)
    print(json_path)


if __name__ == "__main__":
    main()

