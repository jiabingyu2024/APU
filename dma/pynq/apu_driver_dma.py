#!/usr/bin/env python3
"""Compatibility adapter exposing the legacy driver's execute_apu_network API."""

import os
import time

try:
    from .inference_dma import ApuDmaNetwork
except ImportError:
    from inference_dma import ApuDmaNetwork


class APUDriver:
    def __init__(
        self,
        bitstream_file,
        axi_apu_ip_name=None,
        param_file_dir="./param",
        output_debug_dir="./debug_outputs_dma",
        clock_mhz=25.0,
    ):
        del axi_apu_ip_name
        self.output_debug_dir = output_debug_dir
        self.clock_mhz = float(clock_mhz)
        self.last_transfer_metrics = None
        self.network = ApuDmaNetwork(bitstream_file, param_file_dir)

    def execute_apu_network(
        self,
        input_tensor_ps_01,
        save_input_debug_file=False,
        input_debug_filename="packed_apu_input_dma.txt",
        save_output_debug_files=False,
        output_raw_filename="apu_output_dma_raw.txt",
        output_unpacked_filename="apu_output_dma_unpacked.txt",
    ):
        self.network.driver.clear_counters()
        wall_start = time.perf_counter()
        cpu_start = time.process_time()
        output = self.network.execute(input_tensor_ps_01)
        cpu_seconds = time.process_time() - cpu_start
        wall_seconds = time.perf_counter() - wall_start
        status = self.network.driver.read_status()
        total_bytes = status["rx_bytes"] + status["tx_bytes"]
        hardware_seconds = status["busy_cycles"] / (self.clock_mhz * 1_000_000.0)
        self.last_transfer_metrics = {
            "transport": "apu_dma",
            "wait_mode": self.network.driver.wait_mode,
            "ps_to_pl_bytes": status["rx_bytes"],
            "pl_to_ps_bytes": status["tx_bytes"],
            "total_bytes": total_bytes,
            "wall_seconds": wall_seconds,
            "cpu_seconds": cpu_seconds,
            "cpu_percent": 100.0 * cpu_seconds / wall_seconds if wall_seconds else 0.0,
            "wall_mbps": total_bytes / wall_seconds / 1e6 if wall_seconds else 0.0,
            "hardware_mbps": (
                total_bytes / hardware_seconds / 1e6 if hardware_seconds else 0.0
            ),
            "busy_cycles": status["busy_cycles"],
            "clock_mhz": self.clock_mhz,
        }
        if save_input_debug_file or save_output_debug_files:
            os.makedirs(self.output_debug_dir, exist_ok=True)
        if save_output_debug_files:
            output_path = os.path.join(self.output_debug_dir, output_unpacked_filename)
            array = output.detach().cpu().numpy() if hasattr(output, "detach") else output
            with open(output_path, "w", encoding="utf-8") as stream:
                for value in array.reshape(-1):
                    stream.write("%d\n" % int(value))
        del input_debug_filename, output_raw_filename
        return output

    def cleanup(self):
        self.network.close()
