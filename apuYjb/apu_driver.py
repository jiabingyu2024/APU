# -*- coding: utf-8 -*-
import os
import time
import numpy as np
import torch

try:
    from pynq import Overlay, MMIO
except ImportError:
    Overlay = None 
    MMIO = None


class APUDriver:
    RAM_CTRL_ADDR = 0x2000; RAM_SEL_ADDR = 0x2004; APU_READY_ADDR = 0x2008
    CPL_ADDR = 0x200C; IN_RAM_SEL = 128; OUT_RAM_SEL = 129; IR_RAM_SEL = 130

    AHB_DATA_RAM_BASE_OFFSET_IN_MMIO = 0x0000


    def __init__(self, bitstream_file, axi_apu_ip_name, param_file_dir, output_debug_dir="./debug_outputs_real/"):
        self.param_file_dir = param_file_dir
        self.output_debug_dir = output_debug_dir

        if Overlay is None or MMIO is None:
            raise ImportError("PYNQ库 (Overlay, MMIO) 未加载。无法初始化真实APU驱动。")

        print("加载 Overlay...")
        try:
            self.overlay = Overlay(bitstream_file)
        except Exception as e: print(f"错误: 无法加载比特流 '{bitstream_file}'. {e}"); raise
        print("获取MMIO接口...")
        try:
            apu_mmio_base = self.overlay.ip_dict[axi_apu_ip_name]['phys_addr']
            apu_mmio_range = self.overlay.ip_dict[axi_apu_ip_name]['addr_range']
            self.mmio = MMIO(apu_mmio_base, apu_mmio_range)
            print(f"IP核 {axi_apu_ip_name} 的MMIO接口已在地址 0x{apu_mmio_base:X} 初始化，范围 0x{apu_mmio_range:X}")
        except KeyError: print(f"错误: IP核 '{axi_apu_ip_name}' 在Overlay中未找到."); print(f"可用的IP核: {list(self.overlay.ip_dict.keys())}"); raise
        except Exception as e: print(f"初始化MMIO时发生错误: {e}"); raise

        self.apu_input_shape_expected_by_ps = (1, 64, 32, 32)  # NCHW格式, batch_size=1
        self.apu_output_shape_expected_by_ps = (1, 256, 8, 8) # NCHW格式, batch_size=1

        self.apu_input_words_for_ram = int(np.prod(self.apu_input_shape_expected_by_ps) / 32)
        self.apu_output_words_from_ram = int(np.prod(self.apu_output_shape_expected_by_ps) / 32)

    def _reverse_integer_bits(self, n, bit_length=32):
        """反转一个整数的指定长度的比特位"""
        result = 0
        for i in range(bit_length):
            if (n >> i) & 1: result |= 1 << (bit_length - 1 - i)
        return result

    def _pack_tensor_for_debug_file(self, tensor_01_nchw, expected_shape_nchw): 
        """将一个 0/1 的 NCHW 张量打包成用于调试文件的字符串。"""
        if tensor_01_nchw.shape != expected_shape_nchw: raise ValueError(f"输入张量形状 {tensor_01_nchw.shape} 与期望的 {expected_shape_nchw} 不匹配")
        tensor_01_nchw_int = tensor_01_nchw.cpu().int(); tensor_nhwc = tensor_01_nchw_int.permute(0, 2, 3, 1)
        values = tensor_nhwc.flatten().tolist(); output_lines = []
        for i in range(0, len(values), 32):
            current_block_int_list = values[i:i+32]
            if len(current_block_int_list) < 32: current_block_int_list.extend([0] * (32 - len(current_block_int_list)))
            reversed_values_str = [str(b) for b in current_block_int_list[::-1]]; output_lines.append(''.join(reversed_values_str))
        return output_lines

    def _pack_input_tensor_for_apu_ram(self, tensor_01_nchw_float):
        """将 PyTorch NCHW 张量打包成一个 32 位整数列表，用于 APU RAM。"""
        if tensor_01_nchw_float.shape != self.apu_input_shape_expected_by_ps: raise ValueError(f"输入张量形状 {tensor_01_nchw_float.shape} 与期望的 {self.apu_input_shape_expected_by_ps} 不匹配")
        tensor_01_nhwc_int = tensor_01_nchw_float.cpu().int().permute(0, 2, 3, 1)
        flat_bits_nhwc_order = tensor_01_nhwc_int.numpy().astype(np.uint8).flatten()
        if len(flat_bits_nhwc_order) != self.apu_input_words_for_ram * 32: raise ValueError(f"展平后的NHWC数据长度 {len(flat_bits_nhwc_order)} 与期望的 {self.apu_input_words_for_ram*32} 比特不匹配。")
        packed_integers_ram_order = []
        for i in range(0, len(flat_bits_nhwc_order), 32):
            word_logical_msb_first = 0
            for j in range(32): bit_val = flat_bits_nhwc_order[i + j]; word_logical_msb_first |= (int(bit_val) << (31 - j))
            word_ram_storage_order = self._reverse_integer_bits(word_logical_msb_first, 32)
            packed_integers_ram_order.append(word_ram_storage_order)
        return packed_integers_ram_order

    def _unpack_output_data_from_apu_ram(self, packed_integers_from_ram, target_shape_nchw_ps): # (保持不变)
        """将从 APU RAM 读取的 32 位整数列表解包为 NCHW PyTorch 张量。"""
        N, C, H, W = target_shape_nchw_ps; num_expected_total_bits = N * C * H * W; num_expected_words = num_expected_total_bits // 32
        if len(packed_integers_from_ram) < num_expected_words: print(f"警告: 从APU RAM读取的数据 ({len(packed_integers_from_ram)}字) 少于所需 ({num_expected_words}字)。")
        words_to_process = min(num_expected_words, len(packed_integers_from_ram)); unpacked_bits_nhwc_stream = []
        for i in range(words_to_process):
            word_ram_storage_order = packed_integers_from_ram[i]; word_logical_msb_first = self._reverse_integer_bits(word_ram_storage_order, 32)
            for j in range(32): bit_val = (word_logical_msb_first >> (31 - j)) & 1; unpacked_bits_nhwc_stream.append(bit_val)
        if len(unpacked_bits_nhwc_stream) < num_expected_total_bits:
            padding_needed = num_expected_total_bits - len(unpacked_bits_nhwc_stream)
            if padding_needed > 0: unpacked_bits_nhwc_stream.extend([0] * padding_needed)
        elif len(unpacked_bits_nhwc_stream) > num_expected_total_bits:
            unpacked_bits_nhwc_stream = unpacked_bits_nhwc_stream[:num_expected_total_bits]
        np_data_nhwc = np.array(unpacked_bits_nhwc_stream, dtype=np.uint8).reshape((N, H, W, C))
        np_data_nchw = np.transpose(np_data_nhwc, (0, 3, 1, 2))
        return torch.from_numpy(np_data_nchw.copy())

    def _load_binary_data_from_file(self, filepath): # (保持不变)
        data = []; full_path = os.path.join(self.param_file_dir, filepath)
        if not os.path.isfile(full_path): raise FileNotFoundError(f"参数文件未找到: {full_path}")
        try:
            with open(full_path, 'r') as f:
                for line_idx, line in enumerate(f):
                    line_stripped = line.strip()
                    if not line_stripped: continue
                    for val_idx, val_str in enumerate(line_stripped.split()):
                        if val_str:
                            try: data.append(int(val_str, 2))
                            except ValueError: print(f"警告: 无法转换 '{val_str}'. 文件: '{filepath}', 行: {line_idx+1}. 跳过.")
        except Exception as e: print(f"读取文件 '{full_path}' 错误: {e}"); raise
        if not data: print(f"警告: 从文件 '{full_path}' 未加载任何数据.")
        return data

    def _ahb_write_single_reg_py(self, ahb_reg_address, data_int):
        """写入单个32位整数到AHB地址 (通常用于控制寄存器)"""
        # ahb_reg_address 是相对于AHB总线的地址，对于MMIO，它就是偏移量
        self.mmio.write(ahb_reg_address, int(data_int) & 0xFFFFFFFF)

    def _ahb_read_single_reg_py(self, ahb_reg_address):
        """从AHB地址读取单个32位整数 (通常用于状态寄存器)"""
        return self.mmio.read(ahb_reg_address)

    def _ahb_write_burst_py(self, target_ahb_start_addr_in_ram, data_list_of_integers):
        if not data_list_of_integers:
            return

        # 将整数列表转换为NumPy uint32数组，然后转换为字节串
        try:
            # 确保所有元素都是有效的整数，并且在uint32范围内
            # np.array 会尝试转换，如果失败会报错
            np_data = np.array(data_list_of_integers, dtype=np.uint32)
        except Exception as e:
            print(f"错误 (_ahb_write_burst_py): 无法将 data_list 转换为 np.uint32 数组: {e}")
            print(f"部分数据 (前5个): {data_list_of_integers[:5]}")
            raise

        byte_data = np_data.tobytes()

        # 计算MMIO的绝对偏移量
        absolute_mmio_offset = self.AHB_DATA_RAM_BASE_OFFSET_IN_MMIO + target_ahb_start_addr_in_ram

        # 执行批量写入
        self.mmio.write(absolute_mmio_offset, byte_data)

    def _ahb_read_burst_py(self, target_ahb_start_addr_in_ram, num_words_to_read):
        if num_words_to_read <= 0:
            return []

        num_bytes_to_read = num_words_to_read * 4
        absolute_mmio_offset = self.AHB_DATA_RAM_BASE_OFFSET_IN_MMIO + target_ahb_start_addr_in_ram
        data_read_integers = []
        for i in range(num_words_to_read):
            word_val = self.mmio.read(absolute_mmio_offset + (i * 4))
            data_read_integers.append(word_val)
        return data_read_integers


    def _pack_instruction(self, op, ks, lihw, lic, loc, s1, s2, wa, bna): 
        i = 0; i |= (op&3)<<30 | (ks&3)<<28 | (lihw&7)<<25 | (lic&15)<<21 | (loc&15)<<17 | (s1&3)<<15 | (s2&3)<<13 | (wa&255)<<5 | (bna&31); return i

    def _conv_layer_py(self, cwf, bpf, opcode, kernel_size_val, log_in_hw, log_in_c, log_out_c, stride1, stride2, w_addr_arg, bn_addr_arg, worksheet_waddr):
        cwd_all = self._load_binary_data_from_file(cwf) # 加载所有权重
        wpcke = 2; nicpg = (1<<log_in_c)//64
        if nicpg==0 and (1<<log_in_c)>0: nicpg=1
        lwc = wpcke * kernel_size_val * kernel_size_val * nicpg # 每个RAM slice需要写入的权重字数

        for j in range((1<<log_out_c)//64): # 遍历输出通道组 (每组64个输出通道)
            for i in range(64): # 遍历当前输出通道组内的每个输出通道 (对应一个RAM slice)
                self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, i+64) # 选择权重RAM slice
                target_ahb_ram_addr = (w_addr_arg*8) + (lwc*j*4) # 当前slice内权重的起始AHB地址 (字节)
                # 从 cwd_all 中提取当前slice需要的权重数据
                data_start_index_in_cwd = (lwc*i) + (j*lwc*64)
                data_for_this_slice = cwd_all[data_start_index_in_cwd : data_start_index_in_cwd + lwc]

                if data_for_this_slice: # 确保有数据才写入
                    self._ahb_write_burst_py(target_ahb_ram_addr, data_for_this_slice)
                # else: # 调试用
                #     print(f"警告 (_conv_layer_py weights): 无数据写入。j={j}, i={i}, start_idx={data_start_index_in_cwd}, lwc={lwc}, len(cwd_all)={len(cwd_all)}")


        bpd_all = self._load_binary_data_from_file(bpf) # 加载所有BN参数
        lwb = 1 # 每个RAM slice需要写入的BN参数字数 (这里是1个字，因为每个通道一个BN参数，分散到不同slice)

        for j in range((1<<log_out_c)//64): # 遍历输出通道组
            for i in range(64): # 遍历当前输出通道组内的每个输出通道 (对应一个RAM slice)
                self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, i) # 选择BN RAM slice
                target_ahb_ram_addr_bn = (bn_addr_arg*4) + (j*4) # 当前slice内BN参数的起始AHB地址 (字节)
                # 从 bpd_all 中提取当前slice需要的BN数据
                data_start_index_in_bpd = i + (j*64)
                # BN参数是每个slice一个字
                if data_start_index_in_bpd < len(bpd_all):
                    data_for_this_bn_slice = [bpd_all[data_start_index_in_bpd]] # 列表包含一个整数
                    self._ahb_write_burst_py(target_ahb_ram_addr_bn, data_for_this_bn_slice)
                # else: # 调试用
                #    print(f"警告 (_conv_layer_py bn): 无数据写入。j={j}, i={i}, start_idx={data_start_index_in_bpd}, len(bpd_all)={len(bpd_all)}")


        inst = self._pack_instruction(opcode,kernel_size_val,log_in_hw,log_in_c,log_out_c,stride1,stride2,w_addr_arg,bn_addr_arg)
        self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, self.IR_RAM_SEL); self._ahb_write_single_reg_py(worksheet_waddr*4, inst)

    def _conv_resident_layer_py(self, cwf, bpf, opcode, kernel_size_val, log_in_hw, log_in_c, log_out_c, stride1, stride2, w_addr_arg, bn_addr_arg, worksheet_waddr):
        # 与 _conv_layer_py 类似，只是 lwc (lwcr) 计算不同
        cwd_all = self._load_binary_data_from_file(cwf); nicpg = (1<<log_in_c)//64
        if nicpg==0 and (1<<log_in_c)>0: nicpg=1
        lwcr = (2*kernel_size_val*kernel_size_val+1)*nicpg # 每个RAM slice需要写入的权重字数 (resident)

        for j in range((1<<log_out_c)//64):
            for i in range(64):
                self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, i+64)
                target_ahb_ram_addr = (w_addr_arg*8) + (lwcr*j*4)
                data_start_index_in_cwd = (lwcr*i) + (j*lwcr*64)
                data_for_this_slice = cwd_all[data_start_index_in_cwd : data_start_index_in_cwd + lwcr]
                if data_for_this_slice:
                    self._ahb_write_burst_py(target_ahb_ram_addr, data_for_this_slice)

        bpd_all = self._load_binary_data_from_file(bpf); lwb = 1
        for j in range((1<<log_out_c)//64):
            for i in range(64):
                self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, i)
                target_ahb_ram_addr_bn = (bn_addr_arg*4) + (j*4)
                data_start_index_in_bpd = i + (j*64)
                if data_start_index_in_bpd < len(bpd_all):
                    data_for_this_bn_slice = [bpd_all[data_start_index_in_bpd]]
                    self._ahb_write_burst_py(target_ahb_ram_addr_bn, data_for_this_bn_slice)

        inst = self._pack_instruction(opcode,kernel_size_val,log_in_hw,log_in_c,log_out_c,stride1,stride2,w_addr_arg,bn_addr_arg)
        self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, self.IR_RAM_SEL); self._ahb_write_single_reg_py(worksheet_waddr*4, inst)


    def execute_apu_network(self,
                            input_tensor_ps_01,
                            save_input_debug_file=False,
                            input_debug_filename="packed_apu_input_real_driver.txt",
                            save_output_debug_files=False,
                            output_raw_filename="apu_output_raw_integers.txt",
                            output_unpacked_filename="apu_output_unpacked_01.txt"):

        if save_input_debug_file or save_output_debug_files:
            if not os.path.exists(self.output_debug_dir):
                os.makedirs(self.output_debug_dir)
                print(f"创建真实APU调试输出目录: {self.output_debug_dir}")

        if save_input_debug_file:
            debug_lines = self._pack_tensor_for_debug_file(input_tensor_ps_01, self.apu_input_shape_expected_by_ps)
            filepath = os.path.join(self.output_debug_dir, input_debug_filename)
            print(f"真实APU驱动: 保存打包后的APU输入数据 (调试格式) 到: {filepath}")
            with open(filepath, 'w') as f:
                for line_str in debug_lines: f.write(line_str + "\n")
            print(f"真实APU驱动: 已将 {len(debug_lines)} 行写入 {filepath}")

        packed_integers_for_ram = self._pack_input_tensor_for_apu_ram(input_tensor_ps_01)

        # 写入输入数据到APU的输入RAM (假设输入RAM也从AHB地址0x0开始)
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3) # 使能PS写入RAM
        self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, self.IN_RAM_SEL) # 选择输入特征图RAM
        # 使用批量写入输入数据
        # 假设输入数据应该写入AHB RAM的起始地址0 (字节偏移)
        self._ahb_write_burst_py(0, packed_integers_for_ram)
        # print(f"真实APU驱动: 已批量写入 {len(packed_integers_for_ram)} 个输入字到APU RAM。") # 调试用

        # --- 加载层参数并执行 (使用已优化的 _conv_layer_py 和 _conv_resident_layer_py) ---
        # 每次APU执行前，都需要重新加载权重和BN参数，因为它们可能被后续操作覆盖
        # 或者如果你的APU设计有分段执行，每次执行前加载对应段的参数

        # APU 执行段 1
        # print("真实APU驱动: 配置并准备执行段1...")
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3) # 确保PS可以写权重/BN/指令
        self._conv_layer_py("layer1.0.conv1.txt", "layer1.0.bn1_combined.txt", opcode=0b00, kernel_size_val=3, log_in_hw=5, log_in_c=6, log_out_c=6, stride1=1, stride2=0, w_addr_arg=0, bn_addr_arg=0, worksheet_waddr=0)
        self._conv_layer_py("layer1.0.conv2.txt", "layer1.0.bn3_combined.txt", opcode=0b00, kernel_size_val=3, log_in_hw=5, log_in_c=6, log_out_c=6, stride1=1, stride2=0, w_addr_arg=9, bn_addr_arg=1, worksheet_waddr=1)
        self._conv_layer_py("layer1.1.conv1.txt", "layer1.1.bn1_combined.txt", opcode=0b00, kernel_size_val=3, log_in_hw=5, log_in_c=6, log_out_c=6, stride1=1, stride2=0, w_addr_arg=18, bn_addr_arg=2, worksheet_waddr=2)
        self._conv_layer_py("layer1.1.conv2.txt", "layer1.1.bn3_combined.txt", opcode=0b00, kernel_size_val=3, log_in_hw=5, log_in_c=6, log_out_c=6, stride1=1, stride2=0, w_addr_arg=27, bn_addr_arg=3, worksheet_waddr=3)
        self._conv_layer_py("layer2.0.conv1.txt", "layer2.0.bn1_combined.txt", opcode=0b00, kernel_size_val=3, log_in_hw=5, log_in_c=6, log_out_c=7, stride1=2, stride2=0, w_addr_arg=36, bn_addr_arg=4, worksheet_waddr=4)
        self._conv_resident_layer_py("layer2.0.conv2_combined.txt", "layer2.0.bn3_combined.txt", opcode=0b01, kernel_size_val=3, log_in_hw=4, log_in_c=7, log_out_c=7, stride1=1, stride2=2, w_addr_arg=54, bn_addr_arg=6, worksheet_waddr=5)
        self._conv_layer_py("layer2.1.conv1.txt", "layer2.1.bn1_combined.txt", opcode=0b00, kernel_size_val=3, log_in_hw=4, log_in_c=7, log_out_c=7, stride1=1, stride2=0, w_addr_arg=92, bn_addr_arg=10, worksheet_waddr=6)
        self._conv_layer_py("layer2.1.conv2.txt", "layer2.1.bn3_combined.txt", opcode=0b00, kernel_size_val=3, log_in_hw=4, log_in_c=7, log_out_c=7, stride1=1, stride2=0, w_addr_arg=128, bn_addr_arg=14, worksheet_waddr=7)

        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x0) # 禁止PS写入，APU准备运行
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x1) # APU启动信号
        # print("真实APU驱动: APU段1已启动，等待完成...")
        while self._ahb_read_single_reg_py(self.CPL_ADDR) == 0: time.sleep(0.00001) # 缩短sleep时间以更快响应
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x0) # 清除启动信号
        # print("真实APU驱动: APU段1完成。")

        # APU 执行段 2：layer3.0.conv1
        # layer3 的参数不能与前 8 层同时驻留，因此每层均从地址 0
        # 重新加载权重、BN 参数和 worksheet 指令，并单独启动一次 APU。
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)
        self._conv_layer_py(
            "layer3.0.conv1.txt", "layer3.0.bn1_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=4, log_in_c=7, log_out_c=8,
            stride1=2, stride2=0,
            w_addr_arg=0, bn_addr_arg=0, worksheet_waddr=0
        )
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x0)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x1)
        while self._ahb_read_single_reg_py(self.CPL_ADDR) == 0: time.sleep(0.00001)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x0)

        # APU 执行段 3：layer3.0.conv2 + downsample residual
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)
        self._conv_resident_layer_py(
            "layer3.0.conv2_combined.txt", "layer3.0.bn3_combined.txt",
            opcode=0b01, kernel_size_val=3,
            log_in_hw=3, log_in_c=8, log_out_c=8,
            stride1=1, stride2=2,
            w_addr_arg=0, bn_addr_arg=0, worksheet_waddr=0
        )
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x0)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x1)
        while self._ahb_read_single_reg_py(self.CPL_ADDR) == 0: time.sleep(0.00001)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x0)

        # APU 执行段 4：layer3.1.conv1
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)
        self._conv_layer_py(
            "layer3.1.conv1.txt", "layer3.1.bn1_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=3, log_in_c=8, log_out_c=8,
            stride1=1, stride2=0,
            w_addr_arg=0, bn_addr_arg=0, worksheet_waddr=0
        )
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x0)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x1)
        while self._ahb_read_single_reg_py(self.CPL_ADDR) == 0: time.sleep(0.00001)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x0)

        # APU 执行段 5：layer3.1.conv2
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3)
        self._conv_layer_py(
            "layer3.1.conv2.txt", "layer3.1.bn3_combined.txt",
            opcode=0b00, kernel_size_val=3,
            log_in_hw=3, log_in_c=8, log_out_c=8,
            stride1=1, stride2=0,
            w_addr_arg=0, bn_addr_arg=0, worksheet_waddr=0
        )
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x0)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x1)
        while self._ahb_read_single_reg_py(self.CPL_ADDR) == 0: time.sleep(0.00001)
        self._ahb_write_single_reg_py(self.APU_READY_ADDR, 0x0)

        # 读取输出结果
        # print("真实APU驱动: 读取输出结果...")
        self._ahb_write_single_reg_py(self.RAM_CTRL_ADDR, 0x3) # 允许PS读取
        self._ahb_write_single_reg_py(self.RAM_SEL_ADDR, self.IN_RAM_SEL) # 假设输出结果写回到了输入特征图RAM区域
                                                                     # 或者使用 self.OUT_RAM_SEL 如果有专门的输出RAM选择
        # 你之前的代码中有一个 dummy read，这里保留，但其作用需要根据你的硬件设计确认
        self._ahb_read_single_reg_py(0x0) # Dummy read?
        # 使用批量读取
        # 假设输出数据从AHB RAM的起始地址0 (字节偏移) 开始读取
        raw_integers_from_ram = self._ahb_read_burst_py(0, self.apu_output_words_from_ram)
        # print(f"真实APU驱动: 已批量读取 {len(raw_integers_from_ram)} 个输出字。") # 调试用

        if save_output_debug_files:
            filepath_raw = os.path.join(self.output_debug_dir, output_raw_filename)
            # print(f"真实APU驱动: 保存原始APU输出整数到: {filepath_raw}")
            with open(filepath_raw, 'w') as f:
                for val_int in raw_integers_from_ram: f.write(f"{val_int:032b}\n")
            # print(f"真实APU驱动: 已将 {len(raw_integers_from_ram)} 个原始整数写入 {filepath_raw}")

        unpacked_output_tensor_01_uint8 = self._unpack_output_data_from_apu_ram(
            raw_integers_from_ram,
            self.apu_output_shape_expected_by_ps
        )

        if save_output_debug_files:
            debug_lines_unpacked = self._pack_tensor_for_debug_file(
                unpacked_output_tensor_01_uint8,
                self.apu_output_shape_expected_by_ps
            )
            filepath_unpacked = os.path.join(self.output_debug_dir, output_unpacked_filename)
            # print(f"真实APU驱动: 保存解包后的APU输出 (调试格式) 到: {filepath_unpacked}")
            with open(filepath_unpacked, 'w') as f:
                for line_str in debug_lines_unpacked: f.write(line_str + "\n")
            # print(f"真实APU驱动: 已将 {len(debug_lines_unpacked)} 行写入 {filepath_unpacked}")

        return unpacked_output_tensor_01_uint8

    def cleanup(self):
        pass
