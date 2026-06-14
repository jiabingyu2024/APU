#!/usr/bin/env python3
"""Build a deterministic protocol demonstration job binary."""

import argparse
import json
import os
import sys

import numpy as np


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dma_root = os.path.abspath(os.path.join(script_dir, ".."))
    sys.path.insert(0, os.path.join(dma_root, "pynq"))
    from dma_job import JobBuilder, Target, iter_job_packets

    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=os.path.join(dma_root, "build", "demo_job.bin"))
    parser.add_argument("--manifest", default=os.path.join(dma_root, "build", "demo_job.json"))
    args = parser.parse_args()

    buffer = np.zeros(256, dtype=np.uint64)
    input_words = np.asarray(
        [0x0123456789ABCDEF, 0xFEDCBA9876543210], dtype=np.uint64
    )
    instructions = np.asarray([0x01234567, 0x89ABCDEF], dtype=np.uint32)
    builder = JobBuilder(buffer, sequence_id=1)
    builder.load_u64(Target.ACT, address=0, payload=input_words)
    builder.load_u32(Target.INSTRUCTION, address=0, payload=instructions)
    builder.run(instruction_count=2, timeout_cycles=10_000_000)
    builder.read_result(Target.ACT, address=0, element_count=2)
    used_bytes = builder.end()

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    buffer[: used_bytes // 8].tofile(args.output)
    packets = []
    for header, payload in iter_job_packets(buffer, used_bytes):
        packet = dict(header.__dict__)
        packet["payload_hex"] = bytes(payload).hex()
        packets.append(packet)
    with open(args.manifest, "w", encoding="utf-8") as stream:
        json.dump(
            {"used_bytes": used_bytes, "packets": packets},
            stream,
            indent=2,
            sort_keys=True,
        )
        stream.write("\n")
    print(args.output)
    print(args.manifest)


if __name__ == "__main__":
    main()

