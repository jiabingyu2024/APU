#!/usr/bin/env python3

import os
import sys
import unittest

import numpy as np


DMA_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO_ROOT = os.path.abspath(os.path.join(DMA_ROOT, ".."))
sys.path.insert(0, os.path.join(DMA_ROOT, "pynq"))

from dma_job import Opcode, Target, iter_job_packets
from dma_network_job import build_full_network_job, pack_input_nchw, unpack_output_payload


class DmaNetworkJobTest(unittest.TestCase):
    def test_pack_round_trip_bit_order(self):
        source = np.zeros((1, 64, 32, 32), dtype=np.uint8)
        source.reshape(-1)[::17] = 1
        packed = pack_input_nchw(source)
        restored = np.unpackbits(packed.view(np.uint8), bitorder="little")
        expected = source.transpose(0, 2, 3, 1).reshape(-1)
        np.testing.assert_array_equal(restored, expected)

    def test_output_unpack_shape(self):
        payload = np.arange(256, dtype=np.uint64).view(np.uint8)
        output = unpack_output_payload(payload)
        self.assertEqual(output.shape, (1, 256, 8, 8))

    def test_full_job_layout(self):
        storage = np.zeros(1024 * 1024 // 8, dtype=np.uint64)
        params = os.path.join(REPO_ROOT, "apuYjb", "param")
        builder, used_bytes = build_full_network_job(
            storage, params, np.zeros(1024, dtype=np.uint64)
        )
        packets = list(iter_job_packets(storage, used_bytes))
        for expected_command_id, (header, _) in enumerate(packets):
            self.assertEqual(header.command_id, expected_command_id)
            if header.opcode == Opcode.LOAD and header.target == Target.WEIGHT:
                self.assertLessEqual(header.address + header.element_count, 256)
            if header.opcode == Opcode.LOAD and header.target == Target.BN:
                self.assertLessEqual(header.address + header.element_count, 32)
        runs = [packet[0].element_count for packet in packets if packet[0].opcode == Opcode.RUN]
        self.assertEqual(runs, [8, 1, 1, 1, 1])
        reads = [packet[0] for packet in packets if packet[0].opcode == Opcode.READ_RESULT]
        self.assertEqual(len(reads), 1)
        self.assertEqual(reads[0].target, Target.ACT)
        self.assertEqual(reads[0].element_count, 256)
        self.assertEqual(builder.expected_response_bytes, 32 + 32 + 256 * 8)
        self.assertLess(used_bytes, storage.nbytes)


if __name__ == "__main__":
    unittest.main()
