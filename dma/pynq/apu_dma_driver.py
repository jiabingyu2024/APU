#!/usr/bin/env python3
"""Zero-copy PYNQ driver for the APU DMA overlay."""

import asyncio
import time
from dataclasses import dataclass

import numpy as np

try:
    from pynq import MMIO, Overlay, allocate
except ImportError as error:
    raise ImportError("apu_dma_driver.py must run on a PYNQ image") from error

try:
    from .dma_job import (
        ResponseType,
        Status,
        find_response_used_bytes,
        iter_response_packets,
    )
except ImportError:
    from dma_job import (
        ResponseType,
        Status,
        find_response_used_bytes,
        iter_response_packets,
    )


REG_ID = 0x00
REG_PROTOCOL_VERSION = 0x04
REG_STATUS = 0x08
REG_LAST_ERROR = 0x0C
REG_ACTIVE_SEQUENCE = 0x10
REG_JOB_CYCLES = 0x14
REG_RX_BYTES_LO = 0x18
REG_TX_BYTES_LO = 0x20
REG_BUSY_CYCLES_LO = 0x28
REG_MM2S_STALL_LO = 0x30
REG_S2MM_STALL_LO = 0x38
REG_COMPLETED_JOBS_LO = 0x40
REG_ERROR_JOBS_LO = 0x48
REG_IRQ_STATUS = 0x50
REG_IRQ_ENABLE = 0x54
REG_CONTROL = 0x58


class ApuDmaError(RuntimeError):
    def __init__(self, status, sequence_id, command_id):
        try:
            name = Status(status).name
        except ValueError:
            name = "UNKNOWN"
        super().__init__(
            "APU DMA error %s (0x%02X), sequence=%d command=%d"
            % (name, status, sequence_id, command_id)
        )
        self.status = int(status)
        self.sequence_id = int(sequence_id)
        self.command_id = int(command_id)


@dataclass
class DmaResponse:
    buffer: object
    used_bytes: int
    packets: list
    owned: bool = True

    def close(self):
        if self.buffer is not None and self.owned:
            self.buffer.freebuffer()
            self.buffer = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()


class ApuDmaOverlay:
    def __init__(
        self,
        bitstream,
        dma_name="axi_dma_0",
        ctrl_name="apu_dma_0",
        require_interrupts=False,
    ):
        self.overlay = Overlay(bitstream)
        self.dma = getattr(self.overlay, dma_name)
        ctrl_key = self._resolve_ip_key(ctrl_name)
        ctrl_info = self.overlay.ip_dict[ctrl_key]
        self.ctrl = MMIO(ctrl_info["phys_addr"], ctrl_info["addr_range"])
        self.interrupt_mode = (
            getattr(self.dma.sendchannel, "_interrupt", None) is not None
            and getattr(self.dma.recvchannel, "_interrupt", None) is not None
        )
        self.wait_mode = "interrupt" if self.interrupt_mode else "polling"
        self.last_transfer_profile = None
        if require_interrupts and not self.interrupt_mode:
            raise RuntimeError(
                "DMA interrupts are unavailable. Functional tests can run with "
                "polling, but CPU<10% acceptance requires interrupt-backed waits."
            )
        if self.ctrl.read(REG_ID) != 0x44555041:
            raise RuntimeError("APU DMA control ID mismatch; bit and hwh may not match")
        self._event_loop = None

    def _resolve_ip_key(self, requested):
        if requested in self.overlay.ip_dict:
            return requested
        matches = [key for key in self.overlay.ip_dict if key.endswith("/" + requested)]
        if len(matches) != 1:
            raise KeyError("Unable to resolve control IP %r in HWH" % requested)
        return matches[0]

    @staticmethod
    def allocate_job_buffer(size_bytes):
        if size_bytes <= 0 or size_bytes % 8:
            raise ValueError("Job buffer size must be a positive multiple of 8")
        return allocate(shape=(size_bytes // 8,), dtype=np.uint64)

    def clear_counters(self):
        self.ctrl.write(REG_CONTROL, 1)

    def enable_irqs(self, done=True, error=True):
        self.ctrl.write(REG_IRQ_ENABLE, int(bool(done)) | (int(bool(error)) << 1))

    def clear_irqs(self):
        self.ctrl.write(REG_IRQ_STATUS, 0x3)

    def _read64(self, low_offset):
        while True:
            high_before = self.ctrl.read(low_offset + 4)
            low = self.ctrl.read(low_offset)
            high_after = self.ctrl.read(low_offset + 4)
            if high_before == high_after:
                return (high_after << 32) | low

    def read_status(self):
        status = self.ctrl.read(REG_STATUS)
        return {
            "job_busy": bool(status & 0x1),
            "core_busy": bool(status & 0x2),
            "last_error": self.ctrl.read(REG_LAST_ERROR) & 0xFF,
            "active_sequence_id": self.ctrl.read(REG_ACTIVE_SEQUENCE),
            "job_cycle_count": self.ctrl.read(REG_JOB_CYCLES),
            "rx_bytes": self._read64(REG_RX_BYTES_LO),
            "tx_bytes": self._read64(REG_TX_BYTES_LO),
            "busy_cycles": self._read64(REG_BUSY_CYCLES_LO),
            "mm2s_stall_cycles": self._read64(REG_MM2S_STALL_LO),
            "s2mm_stall_cycles": self._read64(REG_S2MM_STALL_LO),
            "completed_jobs": self._read64(REG_COMPLETED_JOBS_LO),
            "error_jobs": self._read64(REG_ERROR_JOBS_LO),
            "irq_status": self.ctrl.read(REG_IRQ_STATUS) & 0x3,
        }

    async def execute_async(
        self,
        tx_buffer,
        used_bytes,
        expected_response_bytes,
        rx_buffer=None,
    ):
        tx_view = np.asarray(tx_buffer)
        if tx_view.dtype != np.uint64 or tx_view.ndim != 1:
            raise TypeError("tx_buffer must be a one-dimensional uint64 CMA buffer")
        if not hasattr(tx_buffer, "physical_address"):
            raise TypeError("tx_buffer must come from pynq.allocate")
        if used_bytes <= 0 or used_bytes % 8 or used_bytes > tx_view.nbytes:
            raise ValueError("used_bytes is outside tx_buffer or not 8-byte aligned")
        if expected_response_bytes < 32 or expected_response_bytes % 8:
            raise ValueError("expected_response_bytes must be aligned and at least 32")

        owned_rx_buffer = rx_buffer is None
        profile = {}
        if rx_buffer is None:
            wall_alloc = time.perf_counter()
            cpu_alloc = time.process_time()
            rx_buffer = allocate(
                shape=(expected_response_bytes // 8,), dtype=np.uint64
            )
            profile["rx_allocate_wall_seconds"] = time.perf_counter() - wall_alloc
            profile["rx_allocate_cpu_seconds"] = time.process_time() - cpu_alloc
        else:
            rx_view = np.asarray(rx_buffer)
            if rx_view.dtype != np.uint64 or rx_view.ndim != 1:
                raise TypeError("rx_buffer must be a one-dimensional uint64 CMA buffer")
            if not hasattr(rx_buffer, "physical_address"):
                raise TypeError("rx_buffer must come from pynq.allocate")
            if rx_view.nbytes < expected_response_bytes:
                raise ValueError("rx_buffer is smaller than expected_response_bytes")
            profile["rx_allocate_wall_seconds"] = 0.0
            profile["rx_allocate_cpu_seconds"] = 0.0
        try:
            wall_zero = time.perf_counter()
            cpu_zero = time.process_time()
            rx_buffer[:] = 0
            profile["rx_zero_wall_seconds"] = time.perf_counter() - wall_zero
            profile["rx_zero_cpu_seconds"] = time.process_time() - cpu_zero

            wall_t0 = time.perf_counter()
            cpu_t0 = time.process_time()
            tx_buffer.flush()
            profile["tx_flush_wall_seconds"] = time.perf_counter() - wall_t0
            profile["tx_flush_cpu_seconds"] = time.process_time() - cpu_t0

            wall_t1 = time.perf_counter()
            cpu_t1 = time.process_time()
            rx_buffer.flush()
            profile["rx_flush_wall_seconds"] = time.perf_counter() - wall_t1
            profile["rx_flush_cpu_seconds"] = time.process_time() - cpu_t1

            wall_t2 = time.perf_counter()
            cpu_t2 = time.process_time()
            self.dma.recvchannel.transfer(
                rx_buffer, nbytes=expected_response_bytes
            )
            self.dma.sendchannel.transfer(tx_buffer, nbytes=used_bytes)
            if self.interrupt_mode:
                await asyncio.gather(
                    self.dma.sendchannel.wait_async(),
                    self.dma.recvchannel.wait_async(),
                )
            else:
                self.dma.sendchannel.wait()
                self.dma.recvchannel.wait()
            profile["dma_wait_wall_seconds"] = time.perf_counter() - wall_t2
            profile["dma_wait_cpu_seconds"] = time.process_time() - cpu_t2

            wall_t3 = time.perf_counter()
            cpu_t3 = time.process_time()
            rx_buffer.invalidate()
            response_bytes = find_response_used_bytes(
                rx_buffer, limit_bytes=expected_response_bytes
            )
            packets = list(iter_response_packets(rx_buffer, response_bytes))
            profile["invalidate_parse_wall_seconds"] = time.perf_counter() - wall_t3
            profile["invalidate_parse_cpu_seconds"] = time.process_time() - cpu_t3
            terminal = packets[-1][0]
            if terminal.opcode == ResponseType.ERROR or terminal.flags != Status.OK:
                raise ApuDmaError(
                    terminal.flags, terminal.sequence_id, terminal.command_id
                )
            self.last_transfer_profile = profile
            return DmaResponse(rx_buffer, response_bytes, packets, owned=owned_rx_buffer)
        except Exception:
            if owned_rx_buffer:
                rx_buffer.freebuffer()
            raise

    def execute(self, tx_buffer, used_bytes, expected_response_bytes, rx_buffer=None):
        if not self.interrupt_mode:
            return asyncio.run(
                self.execute_async(
                    tx_buffer, used_bytes, expected_response_bytes, rx_buffer=rx_buffer
                )
            )
        try:
            self._event_loop = asyncio.get_event_loop()
        except RuntimeError:
            self._event_loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self._event_loop)
        if self._event_loop.is_closed():
            self._event_loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self._event_loop)
        return self._event_loop.run_until_complete(
            self.execute_async(
                tx_buffer, used_bytes, expected_response_bytes, rx_buffer=rx_buffer
            )
        )
