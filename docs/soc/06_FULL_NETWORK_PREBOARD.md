# 阶段 4：完整网络与预上板 SoC

## 1. 完成范围

PicoRV32 已自主完成完整 12-op APU 网络：读取模型、装载输入/权重/BN/指令、分批启动、
等待完成并把最终 `8x8x256` 输出与 golden 逐 bit 比较。整个过程不依赖 Zynq ARM PS，
也不由 testbench 代替 CPU 写 APU 参数。

## 2. 模型 ROM

| 英文变量/模块 | 中文含义 | 当前值 |
| --- | --- | --- |
| `MODEL_BASE` | CPU 模型只读窗口基址 | `0x4000_0000` |
| `model_rom` | 输入、权重、BN 和最终 golden 存储 | 512 KiB，32-bit word |
| `model.hex` | ROM 初始化文件 | 构建时生成，90880 word，363520 byte |
| `model_layout.h` | 每个参数文件的 word 偏移和长度 | 构建时生成，供 C 固件引用 |
| `build_model_image.py` | 模型打包工具 | 校验每行必须是 32-bit 二进制 |
| `FIRMWARE_INIT_FILE` | boot RAM 固件初始化文件 | 默认 `soc/build/firmware.hex` |
| `MODEL_INIT_FILE` | model ROM 初始化文件 | 默认 `soc/build/model.hex` |

工具运行在开发电脑。`boot_ram` 和 `model_rom` 均在 RTL 中执行 `$readmemh`，因此脱离
testbench 的板级顶层也能初始化。板上 RISC-V 不编译 C，也不解析文本文件；它只读取已经转换好的
32-bit ROM 机器数据。Vivado 阶段可把同一 `model.hex` 初始化进 Block RAM，或将
`model_rom` 替换为 QSPI/外部存储控制器而不改变 APU 装载算法。

## 3. `apu_operation_t` 字段

| 字段 | 中文含义 | 如何参与地址计算 |
| --- | --- | --- |
| `weight_offset` | 此层权重在 model ROM 的首 word | 计算每个 output group/bank 的源地址 |
| `bn_offset` | 此层 BN 参数首 word | 每组 64 个 channel 顺序读取 |
| `instruction` | 写入 WorkSheet 的 32-bit 指令 | 决定 H/W/Cin/Cout/kernel/stride |
| `weight_base` | APU 每个 Weight bank 的 64-bit 基地址 | 对应指令字段 `wAddr` |
| `bn_base` | SIMD 参数 entry 基地址 | 对应指令字段 `bnAddr` |
| `worksheet_index` | 指令 RAM 写地址 | 前 8 条为 0..7，layer3 每次覆盖 0 |
| `weight_words_per_bank` | 每个 group、每个 bank 的 32-bit 行数 | normal 为 `2*9*IG`，residual 为 `19*IG` |
| `output_groups` | `Cout/64` | 决定 group 外层循环次数 |

## 4. 权重映射

固件严格复现原 testbench：

```text
for output_group in 0..OG-1:
  for bank in 0..63:
    RAM_SEL = 64 + bank
    source = weight_offset
             + (output_group*64 + bank)*weight_words_per_bank
    destination byte address = weight_base*8
                               + output_group*weight_words_per_bank*4
```

每两个连续 32-bit 写由 `ram_mux` 拼成一个 64-bit WeightSRAM word。`weight_base` 是
64-bit 地址，因此乘 8；`weight_words_per_bank` 是 32-bit 行数，因此 group 偏移乘 4。
混淆这两个单位会让第二个 output group 从错误地址开始。

BN 映射为：

```text
RAM_SEL = channel 0..63
APU address = (bn_base + output_group)*4
model source = bn_offset + output_group*64 + channel
```

## 5. H/W/Cin/Cout 执行顺序

前 8 条指令的权重占 bank 地址 `0..163`，一次装载并一次启动。它们按 WorkSheet 0..7
顺序完成 layer1 和 layer2。layer3 单层权重大但每次都能放入 256 深度 WeightSRAM，
因此四条操作依次覆盖 weight/BN/worksheet 地址 0 并分别启动。

```text
input 32x32x64
 -> 4 个 32x32x64 op
 -> 32x32x64 到 16x16x128 + residual + 2 个 16x16x128 op
 -> 16x16x128 到 8x8x256
 -> 8x8x256 residual
 -> 2 个 8x8x256 op
```

12 条指令使 `pingpong` 翻转 12 次，最终结果回到 ActSRAM。每个像素的物理 64-channel
组顺序是 `3,2,1,0`，golden 是 `0,1,2,3`，固件比较时使用：

```text
physical_index = pixel*4 + (3-canonical_group)
```

## 6. UART 与板级顶层

`riscv_apu_board_top.sv` 已提供：

- 外部低有效复位的异步拉低、两拍同步释放；
- 参数化 `CLK_HZ` 和 `UART_BAUD`；
- 8-N-1 `uart_tx`；
- console `STATUS` 根据 `tx_ready` 对固件施加背压；
- `trap_o`、`done_o`、`apu_done_o` 板级观察信号。

SoC 顶层没有实例化 Zynq Processing System IP。ARM PS 是否在目标板上保持未配置/复位，
以及相应验收截图，属于 Vivado 和上板阶段。

## 7. 回归证据

```text
MODEL IMAGE PASS words=90880 bytes=363520
UART UNIT PASS
BRIDGE UNIT PASS
APU FULL NETWORK PASS
APU ZERO CONV PASS
APU MMIO BRIDGE PASS
SOC PREBOARD PASS
SIM PASS cycles=3984895
```

最终输出与 `data/data_flow/layer3.1_bn3_output.txt` 的 512 个 32-bit golden word 完全一致。
