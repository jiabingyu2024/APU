# RTL 审查与 Vivado 工程交付

## 1. 结论

当前架构是 `PicoRV32 + 本地 RAM/ROM + native interconnect + AHB bridge + APU`，全部位于
PL，Vivado 工程不需要 Block Design，也不实例化 Zynq Processing System。已有回归记录
表明完整网络在仿真中于 `3,984,895` 周期通过；25 MHz 下约 `0.16 s`。

本轮没有修改 `rtl/` 下 APU 数据通路。修改集中在固件阶段码、SoC 状态输出和 PYNQ-Z2
板级可观测性，避免因 LED0 不亮而盲查整个计算阵列。

## 2. 主要审查发现

### 严重：H16 不是完全独立的板载晶振

`H16` 的 125 MHz 由以太网 PHY 输出，PHY reset/初始化涉及 PS MIO。纯 PL 顶层本身没有
PS 依赖，但冷启动时不能假定 H16 一定存在。正确验收顺序是先让板卡基础设施初始化，
再只对 Cortex-A9 双核执行 reset + clock-stop；不要复位整个 PS 外设域。

### 严重：旧版 LED 无法说明失败位置

旧版只有 PASS、trap、APU seen 和 lock。固件任何 `fail(code)` 都只表现为 LED0 不亮，
无法区分 APU timeout、golden mismatch 或 MMIO 错误。本轮增加 8 位阶段/失败码和 RGB
状态，详见 [06_NO_USB_TTL_BOARD_DEBUG.md](06_NO_USB_TTL_BOARD_DEBUG.md)。

### 高：资源与时序尚未经过本次 Vivado 实现确认

模型 ROM 约占 89 个 BRAM36，Boot RAM 约 16 个，Feature RAM 约 4 个；64 组 Weight RAM
依赖 `FPGA_DISTRIBUTED_WEIGHT_RAM` 映射到 LUTRAM。必须在综合报告确认宏生效、BRAM 未
超限、WNS 非负。没有 post-route 报告时，不能把“仿真通过”等同于“板上可运行”。

### 中：WorkSheet ready 合同依赖单周期脉冲

当前 `addr_map` 对 `APU_READY` 写操作只产生一个周期的 `apu_ready`，与 `WorkSheet` 的
IDLE 启动条件一致，因此现有 SoC 路径正确。若以后绕过 `addr_map`，把 ready 长时间保持
为 1，则 WorkSheet 回到 IDLE 后可能再次启动；外部接口必须继续使用脉冲语义。

`totalInstrCount` 按写次数增加，不按最高地址计算。重复覆盖同一地址会错误增加指令数；
在没有任何有效指令时启动还会发生 `totalInstrCount-1` 下溢。当前固件严格顺序写入并在
每批前写入有效指令，所以不触发这两个边界。

### 中：APU AHB 从接口不是完整 wait-state 实现

APU 的 `hreadyout` 常高，但内部 RAM read 是注册返回。`native_to_apu_ahb` 已针对 RAM
窗口增加 priming/固定等待，对 CPL 控制寄存器则避免重复读取。该桥适用于当前 APU，
不应被当作通用 AHB bridge 复用。

### 中：InBuf 存在锁存器风格状态

`rtl/InBuf.sv` 的 `fromram/temp1/temp2` 在不完整 `always_comb` 中保持历史值，会推断 latch。
现有完整网络回归依赖其时序，故本轮未贸然重写。综合后应查看 latch 数量和相关路径；
若需要改为触发器，必须重新跑完整网络 bit-exact 回归。

## 3. 本轮文件变化

| 文件 | 作用 |
| --- | --- |
| `soc/firmware/main.c` | 写入阶段码和编码后的 fail code |
| `soc/rtl/sim_console.sv` | 新增 `0x1000_0004` DEBUG 寄存器 |
| `soc/rtl/riscv_apu_soc_top.sv` | 向板级传播 debug code |
| `soc/rtl/riscv_apu_board_top.sv` | 输出 PASS/FAIL/debug code |
| `fpga/rtl/pynq_z2_debug_display.sv` | LED、RGB、拨码和灯检逻辑 |
| `fpga/rtl/pynq_z2_top.sv` | 接入 BTN1、SW、RGB 和调试显示 |
| `fpga/constraints/pynq_z2.xdc` | 新增板载资源管脚约束 |
| `fpga/scripts/create_project.tcl` | 明确纯 RTL/无 PS/板级调试配置 |
| `soc/build/firmware.hex` | 已按新固件重新生成，供 Vivado 初始化 BRAM |

原文件备份位于 `backup/20260614_101038/`。

当前初始化文件校验值：

```text
firmware.hex  ca77eaadbfa6fc003c99c727814f5cd95bdc5cbc19fea3876d83190f9177e3af
model.hex     b9993654526ae9f33065e4260f4e044641df5cc821c8a1cf87d22a8807a41fb0
```

## 4. Vivado GUI 建工程

推荐在 Vivado Tcl Console 执行：

```tcl
cd /home/jiabingyu/prj/26_myprj/APU
source fpga/scripts/create_project.tcl
```

Windows 环境应把 `cd` 改成仓库实际绝对路径。脚本会创建：

```text
fpga/build/vivado/riscv_apu_pynq_z2.xpr
```

工程应满足：

1. Part 为 `xc7z020clg400-1`。
2. Top 为 `pynq_z2_top`。
3. Sources 中有 `firmware.hex`、`model.hex` 和 `pynq_z2_debug_display.sv`。
4. Verilog Define 中有 `FPGA_DISTRIBUTED_WEIGHT_RAM`。
5. Design Sources 中没有 `.bd`，IP Integrator 中没有 PS7。
6. Constraints 使用 `fpga/constraints/pynq_z2.xdc`。

## 5. 生成 bitstream 前必须检查

综合后：

1. `report_utilization -hierarchical` 中 Block RAM Tile 不超过器件上限。
2. WeightSRAM 主要进入 LUT as Memory，而不是额外占用约 64 个 BRAM36。
3. `report_clock_utilization` 能看到 125 MHz 输入和 25 MHz MMCM 输出。
4. 搜索 latch，重点确认 `InBuf`；若数量或时序异常，不直接生成验收 bit。
5. 检查 Critical Warnings，尤其 memory initialization、unconstrained port 和多驱动。

实现后：

1. WNS 必须 `>= 0`，TNS 必须为 0。
2. 所有顶层 I/O 均已 LOC 和 IOSTANDARD 约束。
3. DRC 不得有阻止 bitstream 的错误。
4. 保存 utilization、timing summary、clock utilization 和 DRC 报告。

## 6. 交付边界

仓库已准备 RTL、固件/模型初始化文件、XDC 和建工程 Tcl。按用户要求，本轮不代替用户在
Vivado GUI 中执行综合、实现、生成 bitstream 和上板下载。因此“板上最终正确运行”仍须
以 GUI 生成的 post-route 报告及 [06_NO_USB_TTL_BOARD_DEBUG.md](06_NO_USB_TTL_BOARD_DEBUG.md)
中的 LED/RGB 结果验收。
