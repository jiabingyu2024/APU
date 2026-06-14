#!/usr/bin/env python3
"""Measure the legacy PS-GP0/AHB RAM-window transfer baseline on PYNQ."""

import argparse
import csv
import json
import os
import sys
import time

import numpy as np


def timed_call(function, *args):
    wall_start = time.perf_counter()
    cpu_start = time.process_time()
    value = function(*args)
    cpu_seconds = time.process_time() - cpu_start
    wall_seconds = time.perf_counter() - wall_start
    return value, wall_seconds, cpu_seconds


def make_record(direction, size_bytes, iteration, wall_seconds, cpu_seconds):
    return {
        "direction": direction,
        "size_bytes": size_bytes,
        "iteration": iteration,
        "wall_seconds": wall_seconds,
        "cpu_seconds": cpu_seconds,
        "cpu_percent": 100.0 * cpu_seconds / wall_seconds if wall_seconds else 0.0,
        "mb_per_second": size_bytes / wall_seconds / 1e6 if wall_seconds else 0.0,
    }


def summarize(records):
    summaries = []
    keys = sorted({(row["direction"], row["size_bytes"]) for row in records})
    for direction, size_bytes in keys:
        selected = [
            row
            for row in records
            if row["direction"] == direction and row["size_bytes"] == size_bytes
        ]
        bandwidth = np.asarray([row["mb_per_second"] for row in selected])
        cpu = np.asarray([row["cpu_percent"] for row in selected])
        summaries.append(
            {
                "direction": direction,
                "size_bytes": size_bytes,
                "iterations": len(selected),
                "mbps_mean": float(np.mean(bandwidth)),
                "mbps_min": float(np.min(bandwidth)),
                "mbps_p50": float(np.percentile(bandwidth, 50)),
                "mbps_p95": float(np.percentile(bandwidth, 95)),
                "mbps_max": float(np.max(bandwidth)),
                "cpu_percent_mean": float(np.mean(cpu)),
            }
        )
    return summaries


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    default_apu_dir = os.path.join(repo_root, "apuYjb")
    default_output_dir = os.path.join(repo_root, "dma", "reports", "raw")

    parser = argparse.ArgumentParser()
    parser.add_argument("--apu-dir", default=default_apu_dir)
    parser.add_argument("--bitstream", default="myDesign.bit")
    parser.add_argument("--ip-name", default="APU_0")
    parser.add_argument("--sizes", default="256,1024,4096,8192")
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--iterations", type=int, default=50)
    parser.add_argument("--output-dir", default=default_output_dir)
    args = parser.parse_args()

    apu_dir = os.path.abspath(args.apu_dir)
    sys.path.insert(0, apu_dir)
    try:
        from apu_driver import APUDriver
    except ImportError as error:
        raise SystemExit("Run this benchmark on a PYNQ image with the pynq package: %s" % error)

    sizes = [int(value) for value in args.sizes.split(",") if value.strip()]
    if not sizes or any(size <= 0 or size > 8192 or size % 8 for size in sizes):
        raise SystemExit("Each size must be an 8-byte multiple in the range 8..8192")

    driver = APUDriver(
        bitstream_file=os.path.join(apu_dir, args.bitstream),
        axi_apu_ip_name=args.ip_name,
        param_file_dir=os.path.join(apu_dir, "param"),
    )
    driver._ahb_write_single_reg_py(driver.RAM_CTRL_ADDR, 0x3)
    driver._ahb_write_single_reg_py(driver.RAM_SEL_ADDR, driver.IN_RAM_SEL)

    records = []
    try:
        for size_bytes in sizes:
            words = size_bytes // 4
            pattern = [
                (0xA5A50000 ^ (index * 0x10204081)) & 0xFFFFFFFF
                for index in range(words)
            ]

            for _ in range(args.warmup):
                driver._ahb_write_burst_py(0, pattern)
                driver._ahb_read_single_reg_py(0)
                driver._ahb_read_burst_py(0, words)

            for iteration in range(args.iterations):
                _, wall_seconds, cpu_seconds = timed_call(
                    driver._ahb_write_burst_py, 0, pattern
                )
                records.append(
                    make_record(
                        "ps_to_pl", size_bytes, iteration, wall_seconds, cpu_seconds
                    )
                )

                driver._ahb_read_single_reg_py(0)
                readback, wall_seconds, cpu_seconds = timed_call(
                    driver._ahb_read_burst_py, 0, words
                )
                if readback != pattern:
                    mismatch = next(
                        index
                        for index, pair in enumerate(zip(readback, pattern))
                        if pair[0] != pair[1]
                    )
                    raise RuntimeError(
                        "MMIO readback mismatch at word %d: got 0x%08X expected 0x%08X"
                        % (mismatch, readback[mismatch], pattern[mismatch])
                    )
                records.append(
                    make_record(
                        "pl_to_ps", size_bytes, iteration, wall_seconds, cpu_seconds
                    )
                )
    finally:
        driver.cleanup()

    os.makedirs(args.output_dir, exist_ok=True)
    csv_path = os.path.join(args.output_dir, "mmio_transfer_samples.csv")
    json_path = os.path.join(args.output_dir, "mmio_transfer_summary.json")

    with open(csv_path, "w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0].keys()))
        writer.writeheader()
        writer.writerows(records)

    result = {
        "schema_version": 1,
        "transport": "PS M_AXI_GP0 -> AXI-to-AHB-Lite bridge -> APU_0",
        "bitstream": os.path.abspath(os.path.join(apu_dir, args.bitstream)),
        "ip_name": args.ip_name,
        "warmup": args.warmup,
        "iterations": args.iterations,
        "summaries": summarize(records),
    }
    with open(json_path, "w", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write("\n")

    print(json.dumps(result["summaries"], indent=2))
    print(csv_path)
    print(json_path)


if __name__ == "__main__":
    main()

