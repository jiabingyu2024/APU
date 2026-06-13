# 阶段 1：PicoRV32 + RAM + 基础外设仿真记录

## 1. 日期与范围

- 日期：2026-06-13
- 工作目录：`/home/jiabingyu/prj/26_myprj/APU`
- 范围：只做无需 Vivado 的 CPU、RTL、固件和 Verilator 仿真
- 备份：按用户要求未创建 backup
- 原 APU RTL：未修改
- PicoRV32 第三方源码：未修改

## 2. 工具与版本

| 工具 | 版本/标识 |
| --- | --- |
| PicoRV32 commit | `87c89acc18994c8cf9a2311e871818e87d304568` |
| Verilator | `5.046` |
| Icarus Verilog | `12.0 stable` |
| RISC-V GCC | `riscv64-unknown-elf-gcc 13.2.0` |
| GNU objcopy | `2.42` |

虽然编译器名字以 `riscv64` 开头，但实际参数为 `-march=rv32imc -mabi=ilp32`。ELF 检查
结果为 `ELF32`、little-endian、Machine 为 RISC-V、入口地址 `0x0000_0000`，不是 64-bit
程序。

## 3. 新增工程文件

```text
soc/
|-- rtl/
|   |-- picorv32_wrapper.sv
|   |-- boot_ram.sv
|   |-- sim_console.sv
|   |-- soc_timer.sv
|   |-- default_slave.sv
|   |-- soc_interconnect.sv
|   `-- riscv_apu_soc_top.sv
|-- firmware/
|   |-- start.S
|   |-- link.ld
|   `-- main.c
|-- tb/
|   `-- tb_soc.sv
`-- Makefile
```

根目录 Makefile 新增：

- `make soc-toolchain-check`
- `make soc-firmware`
- `make soc-check`

## 4. 官方 CPU 基线

执行：

```bash
cd third_party/picorv32
make test_ez
```

结果：Icarus 正常完成 1000 个测试周期，日志中连续出现 instruction fetch、RAM read 和
RAM write，最终由官方 testbench 调用 `$finish`。这证明当前 clone、Icarus 和 PicoRV32
源码本身可工作。

## 5. 固件构建

执行：

```bash
make soc-firmware
```

生成物位于 `soc/build/`：

| 文件 | 作用 |
| --- | --- |
| `firmware.elf` | 带符号和段信息的 RISC-V 可执行文件 |
| `firmware.bin` | 去除 ELF 元数据后的原始机器码 |
| `firmware.hex` | 测试平台加载到 32-bit RAM word 的文本 |
| `firmware.dis` | 带 C/汇编对应关系的反汇编 |
| `firmware.map` | 链接段和符号地址，用于检查 RAM 占用 |

当前固件大小：`text=608 bytes, data=0, bss=0`。链接脚本强制至少保留 4 KiB 栈空间，
若程序镜像过大将由 linker `ASSERT` 直接报错。

### 构建中发现的问题

第一次生成 HEX 时，官方 `makehex.py` 报错：二进制长度不是 4 的整数倍。原因是 `.text`
长度为 585 字节，而 HEX 以 32-bit word 为单位。修复是在链接脚本的 `.text` 末尾执行
`ALIGN(4)`，修复后长度为 588 字节。这里没有修改官方脚本，也没有给机器码随意补未知字节。

## 6. SoC 回归

执行：

```bash
CCACHE_DISABLE=1 timeout 180s make soc-check
```

固件输出：

```text
HELLO RISCV APU SOC
RAM BYTE/HALF/WORD PASS
RV32IM PASS
TIMER PASS cycles=0x00000961
DEFAULT SLAVE PASS
SOC STAGE1 PASS
SIM PASS cycles=10970
```

结果说明：

- CPU 已从地址 0 进入自己编译的 `start.S` 和 C `main()`；
- `sb/sh/sw` 对应的 RAM byte strobe 均能正确工作；
- 乘除指令与硬件 M 扩展匹配；
- Timer MMIO 读路径有效；
- 固件设置 `COMPARE_LO/CONTROL` 后，测试平台观察到 `timer_irq=1`；
- `0x3000_0000` 未映射访问能返回，不会死锁；
- 测试平台观察到 `bus_fault_addr=0x3000_0000`；
- `trap=0`；
- 固件主动写 `EXIT=0`，仿真在 10,970 周期结束。

## 7. Verilator 告警判断

主要告警来自未修改的 `third_party/picorv32/picorv32.v`，包括文件内包含多个 module、
未命名 generate block、官方顺序逻辑中的 blocking assignment 和未启用调试信号。它们不影响
本次功能结果，也不能通过修改第三方 CPU 源码来消除。

本项目侧剩余告警主要是当前阶段暂未使用的 `mem_instr`、`timer_irq` 和 CPU look-ahead/
trace 输出。它们属于明确保留的接口，不是悬空输入，也没有发现 width、latch 或多驱动错误。

## 8. 阶段结论与下一入口

阶段 1 已达到退出条件，可以进入 APU bridge 单元测试。下一步不应立刻运行完整神经网络，
而应按以下顺序推进：

```text
native-to-AHB bridge 空载时序
 -> APU RAM_CTRL/RAM_SEL 寄存器读写
 -> ActSRAM 64-bit low32/high32 写入和读回
 -> Weight/SIMD/WorkSheet 单元访问
 -> PicoRV32 C 固件执行同一组 MMIO smoke test
 -> 最小 APU 指令和单层卷积
```

APU bridge 阶段仍可完全在 Verilator 中完成，不需要 Vivado。
