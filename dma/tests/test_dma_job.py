#!/usr/bin/env python3

import os
import sys
import unittest

import numpy as np


DMA_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(DMA_ROOT, "pynq"))

from dma_job import (
    HEADER_BEATS,
    PROTOCOL_VERSION,
    RESPONSE_MAGIC,
    JobBuilder,
    Opcode,
    ResponseType,
    Target,
    iter_job_packets,
    iter_response_packets,
)


class JobProtocolTest(unittest.TestCase):
    def test_round_trip(self):
        storage = np.zeros(64, dtype=np.uint64)
        u64_payload = np.asarray([1, 2, 3], dtype=np.uint64)
        u32_payload = np.asarray([0x11223344, 0x55667788, 0x99AABBCC], dtype=np.uint32)
        builder = JobBuilder(storage, sequence_id=0x12345678)
        builder.load_u64(Target.WEIGHT, address=7, payload=u64_payload, bank=63)
        builder.load_u32(Target.BN, address=2, payload=u32_payload, bank=4)
        builder.run(instruction_count=1, timeout_cycles=1234)
        builder.read_result(Target.ACT, address=0, element_count=8)
        used_bytes = builder.end()

        packets = list(iter_job_packets(storage, used_bytes))
        self.assertEqual([packet[0].opcode for packet in packets], [1, 1, 2, 3, 255])
        self.assertEqual(packets[0][0].sequence_id, 0x12345678)
        self.assertEqual(packets[0][0].arg0, 63)
        self.assertEqual(bytes(packets[0][1]), u64_payload.tobytes())
        self.assertEqual(bytes(packets[1][1]), u32_payload.tobytes())
        self.assertEqual(packets[2][0].element_count, 1)
        self.assertEqual(packets[2][0].arg0, 1234)
        self.assertEqual(packets[-1][0].opcode, Opcode.END_JOB)

    def test_reject_trailing_data(self):
        storage = np.zeros(16, dtype=np.uint64)
        builder = JobBuilder(storage, sequence_id=1)
        used_bytes = builder.end()
        with self.assertRaisesRegex(ValueError, "Trailing data"):
            list(iter_job_packets(storage, used_bytes + 8))

    def test_capacity_check(self):
        storage = np.zeros(4, dtype=np.uint64)
        builder = JobBuilder(storage, sequence_id=1)
        with self.assertRaises(BufferError):
            builder.load_u64(
                Target.ACT, address=0, payload=np.asarray([1], dtype=np.uint64)
            )

    def test_dtype_is_part_of_contract(self):
        storage = np.zeros(16, dtype=np.uint64)
        builder = JobBuilder(storage, sequence_id=1)
        with self.assertRaises(TypeError):
            builder.load_u64(
                Target.ACT, address=0, payload=np.asarray([1], dtype=np.uint32)
            )

    def test_instruction_limit_matches_worksheet(self):
        storage = np.zeros(16, dtype=np.uint64)
        builder = JobBuilder(storage, sequence_id=1)
        with self.assertRaisesRegex(ValueError, "1..15"):
            builder.run(instruction_count=16, timeout_cycles=100)

    def test_response_parser(self):
        storage = np.zeros(16, dtype=np.uint64)
        storage[0] = np.uint64(
            RESPONSE_MAGIC
            | (PROTOCOL_VERSION << 32)
            | (int(ResponseType.DATA) << 40)
            | (int(Target.ACT) << 48)
        )
        storage[1] = np.uint64(7 | (16 << 32))
        storage[2] = np.uint64(0 | (2 << 32))
        storage[3] = np.uint64(10 | (3 << 32))
        storage[4:6] = np.asarray([0x11, 0x22], dtype=np.uint64)
        offset = HEADER_BEATS + 2
        storage[offset] = np.uint64(
            RESPONSE_MAGIC
            | (PROTOCOL_VERSION << 32)
            | (int(ResponseType.FINAL) << 40)
            | (int(Target.NONE) << 48)
        )
        storage[offset + 1] = np.uint64(7)
        storage[offset + 2] = np.uint64(0)
        storage[offset + 3] = np.uint64(12 | (4 << 32))
        packets = list(iter_response_packets(storage, used_bytes=(offset + 4) * 8))
        self.assertEqual([packet[0].opcode for packet in packets], [1, 2])
        self.assertEqual(bytes(packets[0][1]), storage[4:6].tobytes())


if __name__ == "__main__":
    unittest.main()
