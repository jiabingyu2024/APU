#!/usr/bin/env python3
"""Benchmark aggregate MM2S job transport through the real APU DMA loader."""

import argparse
import csv
import json
import os
import sys
import time

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DMA_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
sys.path.insert(0, os.path.join(DMA_ROOT, "pynq"))

from apu_dma_driver import ApuDmaOverlay
from dma_job import JobBuilder, Target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bitstream", default=os.path.join(DMA_ROOT, "overlay", "apu_dma.bit")
    )
    parser.add_argument("--repeats", type=int, default=16)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument(
        "--output-dir", default=os.path.join(DMA_ROOT, "reports", "raw")
    )
    args = parser.parse_args()

    if args.repeats <= 0:
        raise SystemExit("--repeats must be positive")

    payload = np.arange(256, dtype=np.uint64) ^ np.uint64(0x5AA5000000000000)
    packet_count = args.repeats * 64
    capacity = packet_count * (32 + payload.nbytes) + 32
    driver = ApuDmaOverlay(os.path.abspath(args.bitstream), require_interrupts=True)
    tx = driver.allocate_job_buffer(capacity)
    try:
        builder = JobBuilder(tx, sequence_id=1)
        for _ in range(args.repeats):
            for bank in range(64):
                builder.load_u64(Target.WEIGHT, address=0, payload=payload, bank=bank)
        used_bytes = builder.end()

        records = []
        for iteration in range(args.warmup + args.iterations):
            driver.clear_counters()
            wall_start = time.perf_counter()
            cpu_start = time.process_time()
            with driver.execute(tx, used_bytes, builder.expected_response_bytes):
                pass
            cpu_seconds = time.process_time() - cpu_start
            wall_seconds = time.perf_counter() - wall_start
            status = driver.read_status()

            if iteration >= args.warmup:
                hardware_seconds = status["busy_cycles"] / 100_000_000.0
                records.append(
                    {
                        "iteration": iteration - args.warmup,
                        "job_bytes": used_bytes,
                        "wall_seconds": wall_seconds,
                        "cpu_seconds": cpu_seconds,
                        "cpu_percent": 100.0 * cpu_seconds / wall_seconds,
                        "wall_mb_per_second": used_bytes / wall_seconds / 1e6,
                        "hardware_busy_cycles": status["busy_cycles"],
                        "hardware_mb_per_second": (
                            used_bytes / hardware_seconds / 1e6
                            if hardware_seconds > 0
                            else 0.0
                        ),
                        "mm2s_stall_cycles": status["mm2s_stall_cycles"],
                        "s2mm_stall_cycles": status["s2mm_stall_cycles"],
                    }
                )

        os.makedirs(args.output_dir, exist_ok=True)
        csv_path = os.path.join(args.output_dir, "apu_dma_transport_samples.csv")
        json_path = os.path.join(args.output_dir, "apu_dma_transport_summary.json")
        with open(csv_path, "w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(records[0].keys()))
            writer.writeheader()
            writer.writerows(records)

        wall_bw = np.asarray(
            [record["wall_mb_per_second"] for record in records], dtype=np.float64
        )
        hardware_bw = np.asarray(
            [record["hardware_mb_per_second"] for record in records], dtype=np.float64
        )
        cpu = np.asarray([record["cpu_percent"] for record in records], dtype=np.float64)
        summary = {
            "schema_version": 1,
            "bitstream": os.path.abspath(args.bitstream),
            "job_bytes": used_bytes,
            "repeats": args.repeats,
            "iterations": args.iterations,
            "wall_mbps_mean": float(np.mean(wall_bw)),
            "wall_mbps_p50": float(np.percentile(wall_bw, 50)),
            "hardware_mbps_mean": float(np.mean(hardware_bw)),
            "cpu_percent_mean": float(np.mean(cpu)),
            "passes_200mbps_wall": bool(np.mean(wall_bw) >= 200.0),
            "passes_cpu_10percent": bool(np.mean(cpu) < 10.0),
        }
        with open(json_path, "w", encoding="utf-8") as stream:
            json.dump(summary, stream, indent=2, sort_keys=True)
            stream.write("\n")
        print(json.dumps(summary, indent=2, sort_keys=True))
        print(csv_path)
        print(json_path)
    finally:
        tx.freebuffer()


if __name__ == "__main__":
    main()
