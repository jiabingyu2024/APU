#!/usr/bin/env python3
"""Board smoke test for APU DMA control, loader, result streamer, and zero-copy DMA."""

import argparse
import os
import sys

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from apu_dma_driver import ApuDmaOverlay
from dma_job import JobBuilder, ResponseType, Target


def main():
    dma_root = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bitstream", default=os.path.join(dma_root, "overlay", "apu_dma.bit")
    )
    parser.add_argument("--words", type=int, default=256)
    parser.add_argument("--sequence-id", type=int, default=1)
    parser.add_argument(
        "--require-interrupts",
        action="store_true",
        help="Fail if PYNQ cannot create DMA interrupt objects.",
    )
    parser.add_argument(
        "--allow-polling",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()

    if args.words <= 0 or args.words > 1024:
        raise SystemExit("--words must be in the range 1..1024")

    driver = ApuDmaOverlay(
        os.path.abspath(args.bitstream),
        require_interrupts=args.require_interrupts,
    )
    tx = driver.allocate_job_buffer(32 + args.words * 8 + 32 + 32)
    try:
        pattern = np.arange(args.words, dtype=np.uint64)
        pattern = pattern * np.uint64(0x0102040810204081) ^ np.uint64(
            0xA55A000000000000
        )
        builder = JobBuilder(tx, sequence_id=args.sequence_id)
        builder.load_u64(Target.ACT, address=0, payload=pattern)
        builder.read_result(Target.ACT, address=0, element_count=args.words)
        used_bytes = builder.end()

        driver.clear_counters()
        driver.clear_irqs()
        driver.enable_irqs()
        with driver.execute(
            tx, used_bytes, builder.expected_response_bytes
        ) as response:
            data_packets = [
                packet
                for packet in response.packets
                if packet[0].opcode == ResponseType.DATA
            ]
            if len(data_packets) != 1:
                raise RuntimeError("Expected exactly one DATA response")
            actual = data_packets[0][1].view(np.uint64)
            if not np.array_equal(actual, pattern):
                mismatch = int(np.flatnonzero(actual != pattern)[0])
                raise RuntimeError(
                    "ACT roundtrip mismatch at word %d: got 0x%016X expected 0x%016X"
                    % (mismatch, int(actual[mismatch]), int(pattern[mismatch]))
                )

        print("APU DMA smoke test PASS")
        print("wait_mode:", driver.wait_mode)
        if not driver.interrupt_mode:
            print(
                "NOTE: polling is functional-only; CPU<10% acceptance requires "
                "PYNQ DMA interrupts."
            )
        print(driver.read_status())
    finally:
        tx.freebuffer()


if __name__ == "__main__":
    main()
