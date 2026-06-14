#!/usr/bin/env python3
"""Compatibility adapter exposing the legacy driver's execute_apu_network API."""

import os

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
    ):
        del axi_apu_ip_name
        self.output_debug_dir = output_debug_dir
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
        output = self.network.execute(input_tensor_ps_01)
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
