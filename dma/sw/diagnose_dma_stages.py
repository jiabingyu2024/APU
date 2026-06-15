#!/usr/bin/env python3
"""Read each real DMA execution stage and compare it with the software model."""

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


STAGE_INFO = (
    ("layer2.1.conv2", Target.ACT, 128, 16, 16),
    ("layer3.0.conv1", Target.OUT, 256, 8, 8),
    ("layer3.0.conv2", Target.ACT, 256, 8, 8),
    ("layer3.1.conv1", Target.OUT, 256, 8, 8),
    ("layer3.1.conv2", Target.ACT, 256, 8, 8),
)


def unpack(payload, channels, height, width):
    bits = np.unpackbits(np.asarray(payload, dtype=np.uint8), bitorder="little")
    expected = channels * height * width
    if bits.size != expected:
        raise ValueError("payload has %d bits, expected %d" % (bits.size, expected))
    return bits.reshape(1, height, width, channels).transpose(0, 3, 1, 2)


def main():
    param_dir = ROOT / "apuYjb/param"
    bitstream = ROOT / "dma/overlay/apu_dma.bit"
    input_bits = np.load(ROOT / "dma/sw/output/ideal_apu_input.npy")
    _, golden = ApuBinaryReference(param_dir).execute(
        torch.from_numpy(input_bits), capture=True
    )

    driver = ApuDmaOverlay(os.path.abspath(bitstream))
    tx = driver.allocate_job_buffer(1024 * 1024)
    try:
        builder = JobBuilder(tx, sequence_id=9001)
        builder.load_u64(Target.ACT, address=0, payload=pack_input_nchw(input_bits))
        for stage, (_, target, channels, height, width) in zip(STAGES, STAGE_INFO):
            _append_stage(builder, os.path.abspath(param_dir), stage, 100_000_000)
            builder.read_result(
                target, address=0, element_count=channels * height * width // 64
            )
        used_bytes = builder.end()
        response = driver.execute(tx, used_bytes, builder.expected_response_bytes)
        with response:
            packets = [
                packet for packet in response.packets
                if packet[0].opcode == ResponseType.DATA
            ]
            if len(packets) != len(STAGE_INFO):
                raise RuntimeError("expected %d DATA packets, got %d" % (len(STAGE_INFO), len(packets)))
            for packet, (name, _, channels, height, width) in zip(packets, STAGE_INFO):
                actual = unpack(packet[1], channels, height, width)
                expected = golden[name].numpy()
                mismatch = int(np.count_nonzero(actual != expected))
                print("%s mismatch_bits=%d total_bits=%d" % (name, mismatch, expected.size))
    finally:
        tx.freebuffer()


if __name__ == "__main__":
    main()
