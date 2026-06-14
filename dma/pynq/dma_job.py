#!/usr/bin/env python3
"""Shared DMA job protocol builder and decoder.

This module has no PYNQ dependency. It can be imported by PC-side generators,
unit tests, and the board driver. Job data is written directly into a writable
uint64 NumPy view, including a pynq.allocate buffer.
"""

from dataclasses import dataclass
from enum import IntEnum

import numpy as np


PROTOCOL_VERSION = 1
JOB_MAGIC = 0x4A555041  # Little-endian bytes: APUJ
RESPONSE_MAGIC = 0x52555041  # Little-endian bytes: APUR
HEADER_BEATS = 4
HEADER_BYTES = 32
SAFE_INSTRUCTION_LIMIT = 15


class Opcode(IntEnum):
    NOP = 0x00
    LOAD = 0x01
    RUN = 0x02
    READ_RESULT = 0x03
    END_JOB = 0xFF


class Target(IntEnum):
    ACT = 0x00
    OUT = 0x01
    WEIGHT = 0x02
    BN = 0x03
    INSTRUCTION = 0x04
    NONE = 0xFF


class ResponseType(IntEnum):
    DATA = 0x01
    FINAL = 0x02
    ERROR = 0xFF


class Status(IntEnum):
    OK = 0x00
    BAD_MAGIC = 0x01
    BAD_VERSION = 0x02
    BAD_OPCODE = 0x03
    BAD_TARGET = 0x04
    BAD_LENGTH = 0x05
    BAD_ALIGNMENT = 0x06
    ADDRESS_RANGE = 0x07
    BANK_RANGE = 0x08
    TLAST_EARLY = 0x09
    TLAST_MISSING = 0x0A
    RUN_WITHOUT_PROGRAM = 0x0B
    APU_TIMEOUT = 0x0C
    BUSY = 0x0D
    INTERNAL = 0x7F


TARGET_ELEMENT_BYTES = {
    Target.ACT: 8,
    Target.OUT: 8,
    Target.WEIGHT: 8,
    Target.BN: 4,
    Target.INSTRUCTION: 4,
}


def padded_bytes(byte_count):
    return (int(byte_count) + 7) & ~7


def _as_uint64_buffer(buffer):
    view = np.asarray(buffer)
    if view.dtype != np.uint64 or view.ndim != 1 or not view.flags.c_contiguous:
        raise TypeError("DMA job buffer must be a contiguous one-dimensional np.uint64 array")
    if not view.flags.writeable:
        raise TypeError("DMA job buffer must be writable")
    return view


def _require_payload(payload, dtype):
    view = np.asarray(payload)
    expected = np.dtype(dtype)
    if view.dtype != expected or view.ndim != 1 or not view.flags.c_contiguous:
        raise TypeError("Payload must be a contiguous one-dimensional %s array" % expected)
    return view


@dataclass(frozen=True)
class PacketHeader:
    magic: int
    version: int
    opcode: int
    target: int
    flags: int
    sequence_id: int
    payload_bytes: int
    address: int
    element_count: int
    arg0: int
    command_id: int


class JobBuilder:
    def __init__(self, uint64_buffer, sequence_id):
        self.buffer = _as_uint64_buffer(uint64_buffer)
        self.sequence_id = int(sequence_id) & 0xFFFFFFFF
        self.offset_beats = 0
        self.command_id = 0
        self.ended = False
        self.expected_response_bytes = HEADER_BYTES

    @property
    def used_bytes(self):
        return self.offset_beats * 8

    def _reserve(self, payload_bytes):
        total_beats = HEADER_BEATS + padded_bytes(payload_bytes) // 8
        end = self.offset_beats + total_beats
        if end > self.buffer.size:
            raise BufferError(
                "Job buffer capacity exceeded: need %d bytes, have %d"
                % (end * 8, self.buffer.nbytes)
            )
        start = self.offset_beats
        self.buffer[start:end] = 0
        self.offset_beats = end
        return start

    def _append_header(
        self, opcode, target, payload_bytes, address, element_count, arg0=0, flags=0
    ):
        if self.ended:
            raise RuntimeError("No packet may be appended after END_JOB")
        start = self._reserve(payload_bytes)
        self.buffer[start + 0] = np.uint64(
            JOB_MAGIC
            | (PROTOCOL_VERSION << 32)
            | ((int(opcode) & 0xFF) << 40)
            | ((int(target) & 0xFF) << 48)
            | ((int(flags) & 0xFF) << 56)
        )
        self.buffer[start + 1] = np.uint64(
            self.sequence_id | ((int(payload_bytes) & 0xFFFFFFFF) << 32)
        )
        self.buffer[start + 2] = np.uint64(
            (int(address) & 0xFFFFFFFF) | ((int(element_count) & 0xFFFFFFFF) << 32)
        )
        self.buffer[start + 3] = np.uint64(
            (int(arg0) & 0xFFFFFFFF) | ((self.command_id & 0xFFFFFFFF) << 32)
        )
        self.command_id += 1
        return start

    def load_u64(self, target, address, payload, bank=0, flags=0):
        target = Target(target)
        if target not in (Target.ACT, Target.OUT, Target.WEIGHT):
            raise ValueError("64-bit LOAD target must be ACT, OUT, or WEIGHT")
        values = _require_payload(payload, np.uint64)
        start = self._append_header(
            Opcode.LOAD,
            target,
            values.nbytes,
            address,
            values.size,
            arg0=bank,
            flags=flags,
        )
        self.buffer[start + HEADER_BEATS : start + HEADER_BEATS + values.size] = values
        return self

    def load_u32(self, target, address, payload, bank=0, flags=0):
        target = Target(target)
        if target not in (Target.BN, Target.INSTRUCTION):
            raise ValueError("32-bit LOAD target must be BN or INSTRUCTION")
        values = _require_payload(payload, np.uint32)
        start = self._append_header(
            Opcode.LOAD,
            target,
            values.nbytes,
            address,
            values.size,
            arg0=bank,
            flags=flags,
        )
        payload_bytes = self.buffer[start + HEADER_BEATS :].view(np.uint8)
        payload_bytes[: values.nbytes] = values.view(np.uint8)
        return self

    def run(self, instruction_count, timeout_cycles, flags=0):
        if instruction_count <= 0 or instruction_count > SAFE_INSTRUCTION_LIMIT:
            raise ValueError(
                "instruction_count must be in the range 1..%d"
                % SAFE_INSTRUCTION_LIMIT
            )
        self._append_header(
            Opcode.RUN,
            Target.NONE,
            0,
            0,
            instruction_count,
            arg0=timeout_cycles,
            flags=flags,
        )
        return self

    def read_result(self, target, address, element_count, bank=0, flags=0):
        target = Target(target)
        if target not in (Target.ACT, Target.OUT):
            raise ValueError("READ_RESULT target must be ACT or OUT")
        if element_count <= 0:
            raise ValueError("element_count must be positive")
        self._append_header(
            Opcode.READ_RESULT,
            target,
            0,
            address,
            element_count,
            arg0=bank,
            flags=flags,
        )
        self.expected_response_bytes += HEADER_BYTES + element_count * 8
        return self

    def end(self, flags=0):
        self._append_header(Opcode.END_JOB, Target.NONE, 0, 0, 0, flags=flags)
        self.ended = True
        return self.used_bytes


def decode_header(beats, offset_beats=0, expected_magic=JOB_MAGIC):
    view = np.asarray(beats, dtype=np.uint64)
    if offset_beats < 0 or offset_beats + HEADER_BEATS > view.size:
        raise ValueError("Header extends beyond supplied buffer")
    word0, word1, word2, word3 = [int(value) for value in view[offset_beats : offset_beats + 4]]
    header = PacketHeader(
        magic=word0 & 0xFFFFFFFF,
        version=(word0 >> 32) & 0xFF,
        opcode=(word0 >> 40) & 0xFF,
        target=(word0 >> 48) & 0xFF,
        flags=(word0 >> 56) & 0xFF,
        sequence_id=word1 & 0xFFFFFFFF,
        payload_bytes=(word1 >> 32) & 0xFFFFFFFF,
        address=word2 & 0xFFFFFFFF,
        element_count=(word2 >> 32) & 0xFFFFFFFF,
        arg0=word3 & 0xFFFFFFFF,
        command_id=(word3 >> 32) & 0xFFFFFFFF,
    )
    if header.magic != expected_magic:
        raise ValueError("Bad magic 0x%08X" % header.magic)
    if header.version != PROTOCOL_VERSION:
        raise ValueError("Unsupported protocol version %d" % header.version)
    return header


def iter_job_packets(beats, used_bytes=None):
    view = np.asarray(beats, dtype=np.uint64)
    limit_bytes = view.nbytes if used_bytes is None else int(used_bytes)
    if limit_bytes < 0 or limit_bytes > view.nbytes or limit_bytes % 8:
        raise ValueError("used_bytes must be an aligned range inside the supplied buffer")
    limit_beats = limit_bytes // 8
    offset = 0
    while offset < limit_beats:
        header = decode_header(view, offset)
        packet_beats = HEADER_BEATS + padded_bytes(header.payload_bytes) // 8
        if offset + packet_beats > limit_beats:
            raise ValueError("Packet payload extends beyond used_bytes")
        payload_start = offset + HEADER_BEATS
        payload = view[payload_start : offset + packet_beats].view(np.uint8)[
            : header.payload_bytes
        ]
        yield header, payload
        offset += packet_beats
        if header.opcode == Opcode.END_JOB:
            if offset != limit_beats:
                raise ValueError("Trailing data found after END_JOB")
            return
    raise ValueError("Job does not contain END_JOB")


def response_payload_bytes(header):
    return padded_bytes(header.payload_bytes)


def iter_response_packets(beats, used_bytes=None):
    view = np.asarray(beats, dtype=np.uint64)
    limit_bytes = view.nbytes if used_bytes is None else int(used_bytes)
    if limit_bytes < HEADER_BYTES or limit_bytes > view.nbytes or limit_bytes % 8:
        raise ValueError("used_bytes must be an aligned response range")
    limit_beats = limit_bytes // 8
    offset = 0
    while offset < limit_beats:
        header = decode_header(view, offset, expected_magic=RESPONSE_MAGIC)
        packet_beats = HEADER_BEATS + padded_bytes(header.payload_bytes) // 8
        if offset + packet_beats > limit_beats:
            raise ValueError("Response payload extends beyond used_bytes")
        payload_start = offset + HEADER_BEATS
        payload = view[payload_start : offset + packet_beats].view(np.uint8)[
            : header.payload_bytes
        ]
        yield header, payload
        offset += packet_beats
        if header.opcode in (ResponseType.FINAL, ResponseType.ERROR):
            if offset != limit_beats:
                raise ValueError("Trailing data found after terminal response")
            return
    raise ValueError("Response does not contain FINAL or ERROR")


def find_response_used_bytes(beats, limit_bytes=None):
    view = np.asarray(beats, dtype=np.uint64)
    limit = view.nbytes if limit_bytes is None else int(limit_bytes)
    if limit < HEADER_BYTES or limit > view.nbytes or limit % 8:
        raise ValueError("limit_bytes must be an aligned response range")
    offset = 0
    while offset + HEADER_BYTES <= limit:
        header = decode_header(view, offset // 8, expected_magic=RESPONSE_MAGIC)
        packet_bytes = HEADER_BYTES + padded_bytes(header.payload_bytes)
        offset += packet_bytes
        if offset > limit:
            raise ValueError("Response payload extends beyond limit_bytes")
        if header.opcode in (ResponseType.FINAL, ResponseType.ERROR):
            return offset
    raise ValueError("Response does not contain FINAL or ERROR")
