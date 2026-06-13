# 阶段 1 SoC 规格与地址空间

## 1. 设计目标

阶段 1 的目标是先证明“RISC-V 处理器、存储器、总线和裸机软件工具链”可以独立闭环，
不连接 APU，也不使用 Vivado。PicoRV32 从片上 RAM 的地址 `0x0000_0000` 取指，执行由
开发电脑交叉编译得到的 RV32IMC C 程序，并通过 memory-mapped I/O 完成自检和日志输出。

这一步存在的原因是隔离问题：若直接连接 APU，CPU 启动、链接地址、RAM 字节写、地址
译码和 AHB 桥中的任意错误都会表现为“CPU 不运行”。阶段 1 先冻结 CPU 侧基线，后续只需
检查新增的 APU 访问路径。

## 2. 已实现与未实现边界

已实现：

- PicoRV32，ISA 为 RV32IMC，ABI 为 ILP32；
- 统一指令/数据 RAM，容量 64 KiB；
- 单主机、无 outstanding 的 native valid/ready 互连；
- 仿真字符输出与固件退出寄存器；
- 64-bit 自由运行 Timer；
- 未映射地址的 default slave；
- startup、链接脚本、C 固件、ELF/BIN/HEX/反汇编生成；
- Verilator 自动测试和超时保护。

本阶段不实现：

- `0x2000_0000` APU 地址区的实际 slave；
- PicoRV32 native 到 APU AHB 的协议转换；
- APU 参数装载、启动、完成轮询和推理；
- 板级 UART、时钟生成、复位同步、XDC、bitstream 和 JTAG；
- ARM PS 的板级复位或时钟门控证明。

## 3. CPU 配置

| 参数 | 当前值 | 中文含义 | 必须与软件保持的关系 |
| --- | ---: | --- | --- |
| `PROGADDR_RESET` | `0x0000_0000` | 复位后第一条指令地址 | 链接脚本入口 `_start` 必须位于同一地址 |
| `STACKADDR` | `0x0001_0000` | CPU 栈指针初值，即 64 KiB RAM 顶部 | `__stack_top` 必须相同 |
| `COMPRESSED_ISA` | 1 | 支持 16-bit 压缩指令 C 扩展 | GCC 使用 `-march=rv32imc` |
| `ENABLE_MUL` | 1 | 支持整数乘法 M 扩展 | C 可生成 `mul` 指令 |
| `ENABLE_DIV` | 1 | 支持整数除法 M 扩展 | C 可生成 `div/divu` 指令 |
| `ENABLE_IRQ` | 0 | 第一阶段不进入中断处理 | Timer IRQ 只导出，不连接 CPU |
| `CATCH_MISALIGN` | 1 | 非对齐访问进入 trap | 固件必须遵守数据自然对齐 |
| `CATCH_ILLINSN` | 1 | 非法指令进入 trap | ISA 编译选项不可超出硬件配置 |

## 4. 全局地址空间

| 起始地址 | 结束地址 | 大小 | 当前模块 | 访问属性 | 状态 |
| --- | --- | ---: | --- | --- | --- |
| `0x0000_0000` | `0x0000_FFFF` | 64 KiB | `boot_ram` | RWX | 已实现 |
| `0x1000_0000` | `0x1000_0FFF` | 4 KiB | `sim_console` | RW | 已实现，仅仿真 |
| `0x1000_1000` | `0x1000_1FFF` | 4 KiB | `soc_timer` | RW | 已实现 |
| `0x1000_2000` | `0x1000_2FFF` | 4 KiB | GPIO | RW | 预留 |
| `0x2000_0000` | `0x2000_3FFF` | 16 KiB | APU bridge | RW | 已实现 |
| `0x4000_0000` | `0x4007_FFFF` | 512 KiB | `model_rom` | RO | 已实现 |
| 其他地址 | - | - | `default_slave` | 读回 `0xDEAD_BEEF` | 已实现 |

所有范围天然对齐且不重叠。阶段 1 访问 APU 预留区也会进入 default slave，这是有意行为，
防止尚未接入的地址让 CPU 永久等待。

## 5. Console 寄存器

基地址为 `0x1000_0000`。

| 偏移 | 英文名 | 访问 | 复位值 | 中文含义 |
| ---: | --- | --- | ---: | --- |
| `0x00` | `TXDATA` | WO | 0 | 写入低 8 bit 后，测试平台输出一个字符 |
| `0x08` | `STATUS` | RO | 1 | bit0 为 1，表示仿真 console 始终可接收字符 |
| `0x0C` | `EXIT` | WO | 0 | 固件写退出码；0 表示通过，非 0 表示失败编号 |

`sim_console` 不是板级 UART。它只把 MMIO 写转换成测试平台可观察的 `tx_valid/tx_data`，
因此不会引入波特率和串行移位逻辑。上板阶段必须替换或并联真正 UART TX/RX。

## 6. Timer 寄存器

基地址为 `0x1000_1000`。

| 偏移 | 英文名 | 访问 | 复位值 | 中文含义 |
| ---: | --- | --- | ---: | --- |
| `0x00` | `COUNT_LO` | RO | 0 | 自由运行周期计数器低 32 bit |
| `0x04` | `COUNT_HI` | RO | 0 | 自由运行周期计数器高 32 bit |
| `0x08` | `COMPARE_LO` | RW | `0xFFFF_FFFF` | 与周期计数低 32 bit 比较的阈值 |
| `0x0C` | `CONTROL` | RW | 0 | bit0 使能比较，bit1 使能 IRQ 输出 |

当前固件只读取 `COUNT_LO` 测量循环耗时。`timer_irq` 已在 RTL 顶层导出，但 PicoRV32 的
`ENABLE_IRQ=0`，因此中断路径尚未形成验收功能。

## 7. 时钟与复位假设

- 仿真时钟周期为 10 ns；它只用于功能验证，不代表最终 FPGA 目标频率。
- 全部模块处于同一 `clk` 时钟域，无 CDC。
- `resetn` 为低有效复位。
- 测试平台保持复位 10 个上升沿，再释放 CPU 和所有 slave。
- RAM 内容不由复位清零；测试平台在释放复位前用 `firmware.hex` 初始化。

上板阶段会增加“外部复位异步拉低、同步释放”，但当前不生成任何 Vivado Clock Wizard
或约束文件。

## 8. 阶段 1 验收条件

- ELF 为 32-bit little-endian RISC-V，入口地址为 `0x0`；
- CPU 能进入 C `main()` 并输出 `HELLO RISCV APU SOC`；
- RAM 的 8/16/32-bit 写入和读回一致；
- 乘法和除法结果正确，证明软件与 RV32IM 硬件配置一致；
- Timer 结束计数大于开始计数；
- 未映射地址在有限拍内返回 `0xDEAD_BEEF` 并记录 fault 地址；
- 固件打印 `SOC STAGE1 PASS` 并写 `EXIT=0`；
- Verilator 在超时前执行 `$finish`，PicoRV32 的 `trap` 始终为 0。

## 9. 当前预上板扩展

阶段 2 至阶段 4 在不改变 CPU 配置的前提下增加：

- native-to-AHB APU bridge；
- 512 KiB 只读 model ROM；
- 完整 12-op APU 固件驱动和最终 golden 对拍；
- 参数化 8-N-1 UART TX 与 console ready 背压；
- `riscv_apu_board_top` 纯 PL 板级顶层。

当前全局地址没有重叠。`0x4000_0000` 窗口只接受读取，写请求有限时完成并返回
`0xBAD0_4000`，避免错误 store 锁死 PicoRV32。
