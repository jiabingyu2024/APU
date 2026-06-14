#!/usr/bin/env python3
"""Full-network APU inference wrapper using one aggregate DMA job."""

import os

import numpy as np

try:
    from .apu_dma_driver import ApuDmaOverlay
    from .dma_job import ResponseType
    from .dma_network_job import (
        build_full_network_job,
        pack_input_nchw,
        unpack_output_payload,
    )
except ImportError:
    from apu_dma_driver import ApuDmaOverlay
    from dma_job import ResponseType
    from dma_network_job import (
        build_full_network_job,
        pack_input_nchw,
        unpack_output_payload,
    )


class ApuDmaNetwork:
    def __init__(
        self,
        bitstream,
        param_dir,
        job_buffer_bytes=1024 * 1024,
        timeout_cycles=100_000_000,
    ):
        self.driver = ApuDmaOverlay(os.path.abspath(bitstream))
        self.tx = self.driver.allocate_job_buffer(job_buffer_bytes)
        self.input_slice = slice(4, 4 + 1024)
        zeros = np.zeros(1024, dtype=np.uint64)
        self.builder, self.used_bytes = build_full_network_job(
            self.tx,
            os.path.abspath(param_dir),
            zeros,
            timeout_cycles=timeout_cycles,
        )

    async def execute_async(self, input_tensor):
        self.tx[self.input_slice] = pack_input_nchw(input_tensor)
        response = await self.driver.execute_async(
            self.tx, self.used_bytes, self.builder.expected_response_bytes
        )
        return self._parse_response(response, input_tensor)

    def _parse_response(self, response, input_tensor):
        with response:
            data_packets = [
                packet
                for packet in response.packets
                if packet[0].opcode == ResponseType.DATA
            ]
            if len(data_packets) != 1:
                raise RuntimeError("Expected one final ACT DATA response")
            output = unpack_output_payload(data_packets[0][1])

        if hasattr(input_tensor, "detach"):
            import torch

            return torch.from_numpy(output)
        return output

    def execute(self, input_tensor):
        self.tx[self.input_slice] = pack_input_nchw(input_tensor)
        response = self.driver.execute(
            self.tx, self.used_bytes, self.builder.expected_response_bytes
        )
        return self._parse_response(response, input_tensor)

    def close(self):
        if self.tx is not None:
            self.tx.freebuffer()
            self.tx = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
