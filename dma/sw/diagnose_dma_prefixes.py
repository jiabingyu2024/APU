#!/usr/bin/env python3
"""Locate the first bad layer by running prefixes of the first DMA stage."""

import gc
import argparse
import os
import sys
from pathlib import Path

import numpy as np
import torch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "dma/pynq"))
sys.path.insert(0, str(ROOT / "dma/sw"))

from apu_dma_driver import ApuDmaOverlay
from dma_job import JobBuilder, ResponseType, Target
from dma_network_job import STAGES, _append_stage, pack_input_nchw
from reference_model import ApuBinaryReference


FIRST_STAGE_NAMES = (
    "layer1.0.conv1",
    "layer1.0.conv2",
    "layer1.1.conv1",
    "layer1.1.conv2",
    "layer2.0.conv1",
    "layer2.0.conv2",
    "layer2.1.conv1",
    "layer2.1.conv2",
)


def unpack(payload, channels, height, width):
    bits = np.unpackbits(np.asarray(payload, dtype=np.uint8), bitorder="little")
    return bits.reshape(1, height, width, channels).transpose(0, 3, 1, 2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", type=int, choices=range(1, 9), default=None)
    args = parser.parse_args()
    param_dir = ROOT / "apuYjb/param"
    bitstream = ROOT / "dma/overlay/apu_dma.bit"
    input_bits = np.load(ROOT / "dma/sw/output/ideal_apu_input.npy")
    _, golden = ApuBinaryReference(param_dir).execute(
        torch.from_numpy(input_bits), capture=True
    )

    prefixes = [args.prefix] if args.prefix else range(1, len(FIRST_STAGE_NAMES) + 1)
    for prefix in prefixes:
        name = FIRST_STAGE_NAMES[prefix - 1]
        channels = 64 if prefix <= 4 else 128
        height = 32 if prefix <= 4 else 16
        target = Target.OUT if prefix % 2 else Target.ACT
        driver = ApuDmaOverlay(os.path.abspath(bitstream))
        tx = driver.allocate_job_buffer(1024 * 1024)
        try:
            builder = JobBuilder(tx, sequence_id=9100 + prefix)
            builder.load_u64(Target.ACT, address=0, payload=pack_input_nchw(input_bits))
            _append_stage(
                builder,
                os.path.abspath(param_dir),
                STAGES[0][:prefix],
                100_000_000,
            )
            builder.read_result(
                target,
                address=0,
                element_count=channels * height * height // 64,
            )
            used_bytes = builder.end()
            response = driver.execute(tx, used_bytes, builder.expected_response_bytes)
            with response:
                packets = [
                    packet for packet in response.packets
                    if packet[0].opcode == ResponseType.DATA
                ]
                actual = unpack(packets[0][1], channels, height, height)
            expected = golden[name].numpy()
            group_mismatches = [
                int(np.count_nonzero(actual[:, start:start + 64] != expected[:, start:start + 64]))
                for start in range(0, channels, 64)
            ]
            print(
                "%s mismatch_bits=%d total_bits=%d group_mismatches=%s"
                % (name, np.count_nonzero(actual != expected), expected.size, group_mismatches)
            )
        finally:
            tx.freebuffer()
            del driver
            gc.collect()


if __name__ == "__main__":
    main()
