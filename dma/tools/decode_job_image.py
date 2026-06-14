#!/usr/bin/env python3
"""Decode and validate a DMA job binary."""

import argparse
import json
import os
import sys

import numpy as np


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dma_root = os.path.abspath(os.path.join(script_dir, ".."))
    sys.path.insert(0, os.path.join(dma_root, "pynq"))
    from dma_job import iter_job_packets

    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    args = parser.parse_args()

    byte_count = os.path.getsize(args.image)
    if byte_count % 8:
        raise SystemExit("Job image size must be an 8-byte multiple")
    beats = np.fromfile(args.image, dtype=np.uint64)
    decoded = []
    for header, payload in iter_job_packets(beats, byte_count):
        entry = dict(header.__dict__)
        entry["payload_hex"] = bytes(payload).hex()
        decoded.append(entry)
    print(json.dumps(decoded, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

