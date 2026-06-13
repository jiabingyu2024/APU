# -*- coding: utf-8 -*-
"""补全 layer3 的 APU 板端驱动。

原 ``apu_driver.py`` 保持不变。本文件继承原驱动，只重写网络执行流程：

1. layer1 和 layer2 的 8 条指令一次性执行；
2. layer3 的 4 条指令分别重新装载参数，并各启动一次 APU；
3. 最后读取 1x256x8x8 的输出。

这样安排与 APU 最终设计文档中的 worksheet 和 ping-pong 时序一致。
"""

import os
import time

from apu_driver import APUDriver as BaseAPUDriver

__all__ = ["APUDriver"]


class APUDriver(BaseAPUDriver):
    """执行完整 12 层 APU 网络的驱动。"""

    DEFAULT_TIMEOUT_SECONDS = 10.0

    def _start_and_wait(self, stage_name, timeout_seconds=None):
        """启动一个指令批次，并等待 APU 完成。"""
        timeout = self.DEFAULT_TIMEOUT_SECONDS if timeout_seconds is None else timeout_seconds
        deadline = time.monotonic() + timeout

        # 上一批 READY 拉低后，CPL 应回到 0。显式等待可以避免读取到残留完成状态。
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x0)
        while self._ahb_read_single_reg_py(self.CPL_ADDR) != 0:
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"APU 执行阶段 {stage_name} 启动前，CPL 未在 {timeout:.3f} 秒内清零"
                )
            time.sleep(0.00001)

        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x0)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x1)

        deadline = time.monotonic() + timeout
        while self._ahb_read_single_reg_py(self.CPL_ADDR) == 0:
            if time.monotonic() >= deadline:
                self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x0)
                raise TimeoutError(
                    f"APU 执行阶段 {stage_name} 超时，等待时间为 {timeout:.3f} 秒"
                )
            time.sleep(0.00001)

        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x0)

    def _load_layer1_layer2(self):
        """将前 8 条指令及其参数装入 APU。"""
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)

        self._conv_layer_py(
            "layer1.0.conv1.txt", "layer1.0.bn1_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=5, log_in_c=6, log_out_c=6,
            stride1=1, stride2=0,
            w_addr_arg=0, bn_addr_arg=0, worksheet_waddr=0,
        )
        self._conv_layer_py(
            "layer1.0.conv2.txt", "layer1.0.bn3_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=5, log_in_c=6, log_out_c=6,
            stride1=1, stride2=0,
            w_addr_arg=9, bn_addr_arg=1, worksheet_waddr=1,
        )
        self._conv_layer_py(
            "layer1.1.conv1.txt", "layer1.1.bn1_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=5, log_in_c=6, log_out_c=6,
            stride1=1, stride2=0,
            w_addr_arg=18, bn_addr_arg=2, worksheet_waddr=2,
        )
        self._conv_layer_py(
            "layer1.1.conv2.txt", "layer1.1.bn3_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=5, log_in_c=6, log_out_c=6,
            stride1=1, stride2=0,
            w_addr_arg=27, bn_addr_arg=3, worksheet_waddr=3,
        )
        self._conv_layer_py(
            "layer2.0.conv1.txt", "layer2.0.bn1_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=5, log_in_c=6, log_out_c=7,
            stride1=2, stride2=0,
            w_addr_arg=36, bn_addr_arg=4, worksheet_waddr=4,
        )
        self._conv_resident_layer_py(
            "layer2.0.conv2_combined.txt", "layer2.0.bn3_combined.txt",
            opcode=0b01, kernel_size_val=3,
            log_in_hw=4, log_in_c=7, log_out_c=7,
            stride1=1, stride2=2,
            w_addr_arg=54, bn_addr_arg=6, worksheet_waddr=5,
        )
        self._conv_layer_py(
            "layer2.1.conv1.txt", "layer2.1.bn1_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=4, log_in_c=7, log_out_c=7,
            stride1=1, stride2=0,
            w_addr_arg=92, bn_addr_arg=10, worksheet_waddr=6,
        )
        self._conv_layer_py(
            "layer2.1.conv2.txt", "layer2.1.bn3_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=4, log_in_c=7, log_out_c=7,
            stride1=1, stride2=0,
            w_addr_arg=128, bn_addr_arg=14, worksheet_waddr=7,
        )

    def _run_single_normal_layer(
        self, weight_file, bn_file, log_in_hw, log_in_c, log_out_c, stride, stage_name
    ):
        """覆盖地址 0 的参数和指令，并执行一个普通卷积层。"""
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)
        self._conv_layer_py(
            weight_file, bn_file,
            opcode=0b00, kernel_size_val=3,
            log_in_hw=log_in_hw, log_in_c=log_in_c, log_out_c=log_out_c,
            stride1=stride, stride2=0,
            w_addr_arg=0, bn_addr_arg=0, worksheet_waddr=0,
        )
        self._start_and_wait(stage_name)

    def _run_single_residual_layer(
        self, weight_file, bn_file, log_in_hw, log_in_c, log_out_c, stage_name
    ):
        """覆盖地址 0 的参数和指令，并执行一个 combined residual 层。"""
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)
        self._conv_resident_layer_py(
            weight_file, bn_file,
            opcode=0b01, kernel_size_val=3,
            log_in_hw=log_in_hw, log_in_c=log_in_c, log_out_c=log_out_c,
            stride1=1, stride2=2,
            w_addr_arg=0, bn_addr_arg=0, worksheet_waddr=0,
        )
        self._start_and_wait(stage_name)

    def _save_input_debug(self, input_tensor, filename):
        lines = self._pack_tensor_for_debug_file(
            input_tensor, self.apu_input_shape_expected_by_ps
        )
        path = os.path.join(self.output_debug_dir, filename)
        with open(path, "w") as stream:
            for line in lines:
                stream.write(line + "\n")

    def _save_output_debug(self, raw_words, unpacked_tensor, raw_filename, unpacked_filename):
        raw_path = os.path.join(self.output_debug_dir, raw_filename)
        with open(raw_path, "w") as stream:
            for value in raw_words:
                stream.write(f"{value:032b}\n")

        unpacked_lines = self._pack_tensor_for_debug_file(
            unpacked_tensor, self.apu_output_shape_expected_by_ps
        )
        unpacked_path = os.path.join(self.output_debug_dir, unpacked_filename)
        with open(unpacked_path, "w") as stream:
            for line in unpacked_lines:
                stream.write(line + "\n")

    def execute_apu_network(
        self,
        input_tensor_ps_01,
        save_input_debug_file=False,
        input_debug_filename="packed_apu_input_full_driver.txt",
        save_output_debug_files=False,
        output_raw_filename="apu_output_full_raw_integers.txt",
        output_unpacked_filename="apu_output_full_unpacked_01.txt",
    ):
        """运行 layer1、layer2 和 layer3，返回 NCHW 格式的 0/1 张量。"""
        if save_input_debug_file or save_output_debug_files:
            os.makedirs(self.output_debug_dir, exist_ok=True)

        if save_input_debug_file:
            self._save_input_debug(input_tensor_ps_01, input_debug_filename)

        packed_input = self._pack_input_tensor_for_apu_ram(input_tensor_ps_01)
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)
        self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, self.IN_RAM_SEL)
        self._ahb_write_burst_py(0, packed_input)

        # 前 8 条指令必须连续写入 worksheet 0..7，并在同一次启动中执行。
        self._load_layer1_layer2()
        self._start_and_wait("layer1 + layer2")

        # layer3 参数无法与前 8 层同时驻留。每次覆盖地址 0，并单独启动。
        self._run_single_normal_layer(
            "layer3.0.conv1.txt", "layer3.0.bn1_combined.txt",
            log_in_hw=4, log_in_c=7, log_out_c=8, stride=2,
            stage_name="layer3.0 conv1",
        )
        self._run_single_residual_layer(
            "layer3.0.conv2_combined.txt", "layer3.0.bn3_combined.txt",
            log_in_hw=3, log_in_c=8, log_out_c=8,
            stage_name="layer3.0 residual",
        )
        self._run_single_normal_layer(
            "layer3.1.conv1.txt", "layer3.1.bn1_combined.txt",
            log_in_hw=3, log_in_c=8, log_out_c=8, stride=1,
            stage_name="layer3.1 conv1",
        )
        self._run_single_normal_layer(
            "layer3.1.conv2.txt", "layer3.1.bn3_combined.txt",
            log_in_hw=3, log_in_c=8, log_out_c=8, stride=1,
            stage_name="layer3.1 conv2",
        )

        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)
        self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, self.IN_RAM_SEL)
        self._ahb_read_single_reg_py(0x0)
        raw_words = self._ahb_read_burst_py(0, self.apu_output_words_from_ram)
        output = self._unpack_output_data_from_apu_ram(
            raw_words, self.apu_output_shape_expected_by_ps
        )

        if save_output_debug_files:
            self._save_output_debug(
                raw_words,
                output,
                output_raw_filename,
                output_unpacked_filename,
            )

        return output
