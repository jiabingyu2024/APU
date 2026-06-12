# PicoRV32 克隆后学习与接入 APU 操作手册

## 0. 这份文档解决什么问题

你已经执行了：

```bash
git clone https://github.com/YosysHQ/picorv32.git
```

接下来不要立刻把整个 PicoRV32 仓库复制到当前 APU 的 `rtl/`，也不要马上连接 APU。
正确顺序是：

```text
确认源码版本
 -> 跑官方最小测试
 -> 看懂 CPU 外部接口
 -> 跑自己编译的 C 程序
 -> 建立独立 SoC 目录
 -> CPU + BRAM + 仿真输出
 -> 加地址译码
 -> 单独验证 CPU-to-AHB bridge
 -> 最后连接当前 APU
```

本文将告诉你：

1. PicoRV32 仓库中哪些文件与你有关；
2. 每个文件应该看什么，不需要陷入哪些内部细节；
3. 克隆后应该先执行哪些命令；
4. 如何把 PicoRV32 作为第三方 CPU IP 接入当前 APU 工程；
5. 每一步怎样证明自己做对了；
6. 哪些错误会让 CPU 卡死或让 APU写错数据。

当前 APU 工作区没有检测到 PicoRV32 目录，因此下面用：

```text
<PICORV32_DIR>
```

表示你实际克隆的位置。先执行以下命令确定路径：

```bash
cd <PICORV32_DIR>
pwd
git remote -v
git rev-parse HEAD
```

把 `pwd` 输出和 commit ID 记录到项目报告。第三方 IP 必须固定版本，不能只写“使用
了 GitHub 最新版”，因为以后最新版可能变化。

## 1. 先建立正确认识

### 1.1 PicoRV32 只是一颗 CPU 核

`picorv32.v` 主要实现：

- 取指；
- 指令译码；
- 寄存器堆；
- 算术逻辑；
- 分支跳转；
- load/store 请求；
- 可选乘除、压缩指令和中断。

它默认不包含：

- 程序 ROM/RAM；
- 数据 RAM；
- UART；
- Timer；
- APU 总线桥；
- 地址译码；
- 启动固件；
- 链接脚本；
- FPGA 时钟和复位。

所以你不能只实例化 `picorv32` 就期待它运行 C 程序。一个可以工作的系统至少是：

```text
PicoRV32 + Memory + Interconnect + Firmware
```

接入 APU 后才变成：

```text
PicoRV32 + Memory + Interconnect + APU Bridge + APU + Firmware
```

### 1.2 你不是要修改 PicoRV32 内核

第一版将 PicoRV32 当成已经验证过的第三方 IP：

- 不改 `picorv32.v`；
- 不在 CPU 内部加入 APU 指令；
- 不使用 PCPI 自定义协处理接口；
- APU 通过 memory-mapped I/O 挂在 CPU 总线上；
- 所有本项目逻辑写在 wrapper、interconnect 和 bridge 中。

这符合课程要求中的“RISC-V 通过总线挂载 APU”，也更容易解释和验证。

### 1.3 为什么暂时不用 PCPI

PicoRV32 的 PCPI 用于扩展 `MUL/DIV` 或自定义非分支指令。你的 APU 是一个需要：

- 装载大量输入、权重和参数；
- 写入多条 WorkSheet 指令；
- 启动；
- 等待较长时间；
- 读回结果；

的独立加速器。它更适合 MMIO 外设模型，不适合做成一条 PCPI 指令。PCPI 不能代替
参数存储、地址映射和软件驱动。

## 2. PicoRV32 仓库文件导航

官方仓库大致包含：

```text
picorv32/
|-- README.md
|-- COPYING
|-- picorv32.v
|-- Makefile
|-- testbench.v
|-- testbench_ez.v
|-- testbench.cc
|-- firmware/
|-- tests/
|-- picosoc/
|-- dhrystone/
|-- scripts/
`-- .github/
```

### 2.1 必须阅读的文件

| 优先级 | 文件 | 你要看什么 |
| ---: | --- | --- |
| 1 | `README.md` | 模块类型、参数、native memory interface、工具链要求 |
| 2 | `testbench_ez.v` | CPU 最小实例化、memory 握手、复位和 trap |
| 3 | `picorv32.v` 顶层声明 | 参数、端口和未使用接口如何绑常量 |
| 4 | `picosoc/picosoc.v` | CPU、RAM、UART、用户外设怎样共享地址空间 |
| 5 | `picosoc/start.s` | 复位后如何进入 C 程序 |
| 6 | `picosoc/sections.lds` | 程序段和内存地址如何对应 |
| 7 | `picosoc/firmware.c` | C 如何访问 memory-mapped UART/寄存器 |
| 8 | `firmware/start.S` | 更完整的测试固件启动流程 |
| 9 | `firmware/print.c` | 不依赖 libc 的最小打印方法 |
| 10 | `Makefile` | 源码、固件、hex 和仿真的依赖关系 |

### 2.2 暂时只浏览的文件

| 文件/目录 | 现在为什么不需要深入 |
| --- | --- |
| `tests/` | 指令级回归，先知道它用于验证 CPU 即可 |
| `dhrystone/` | 性能测试，不解决 SoC 接入问题 |
| `scripts/` | 针对多种综合/板卡流程，等确定 FPGA 后再选 |
| `picosoc/spiflash.v` | 第一版使用片上 BRAM，不先做 SPI Flash |
| `picosoc/spimemio.v` | 同上 |
| `picosoc/icebreaker*.v` | Lattice 板级例程，不能直接当 Zynq XDC/顶层使用 |
| `testbench_wb.v` | Wishbone 版本，本项目选 native interface |
| AXI 相关模块 | 当前 APU 是 AHB 风格接口，第一版不绕 AXI |
| formal/RVFI 逻辑 | 很有价值，但不是当前接入的最短路径 |

### 2.3 不要直接照搬 PicoSoC

`picosoc/` 很值得学习，但不能整个复制后改名，原因是：

- 它主要从 SPI Flash 执行代码；
- reset vector 和你的 BRAM 方案不同；
- memory map 不同；
- 它面向 Lattice iCE40 示例板；
- UART、Flash 和用户外设地址是示例定义；
- 你的 APU 需要专门的 AHB 数据相位适配。

正确用法是学习它的结构：

```text
CPU 发 mem_valid
 -> 地址译码选择 RAM/UART/user peripheral
 -> 对应模块产生 ready/rdata
 -> 返回 CPU
```

然后在自己的 `soc/` 目录重新实现适合 APU 的版本。

## 3. 第一轮阅读：只看 CPU 外部合同

不要从 `picorv32.v` 第一行开始逐行阅读四千行 CPU 内部 RTL。你现在要掌握的是
“如何正确使用这个 IP”，不是立刻重新设计 RISC-V 微架构。

### 3.1 第一遍看 README 的这些章节

按顺序阅读：

1. `Features and Typical Applications`
2. `Files in this Repository`
3. `Verilog Module Parameters`
4. `PicoRV32 Native Memory Interface`
5. `Pico Co-Processor Interface`，只了解它存在
6. `Custom Instructions for IRQ Handling`，第一版不启用

第一遍阅读完成后，你应该能回答：

- 为什么选择 `picorv32`，而不是 `picorv32_axi`？
- CPU 什么时候发起一次 memory request？
- `mem_ready` 由谁产生？
- 如何区分读和写？
- 如何区分取指和数据访问？
- CPU 请求等待期间哪些信号必须保持不变？
- `COMPRESSED_ISA` 与 GCC `-march` 有什么关系？
- `STACKADDR` 是否由硬件设置，还是由 startup 设置？

回答不出来就不要进入 APU 接线。

### 3.2 native memory interface 必须掌握

核心信号：

| 信号 | 方向（相对 CPU） | 含义 |
| --- | --- | --- |
| `mem_valid` | 输出 | CPU 当前有一笔有效请求 |
| `mem_instr` | 输出 | 该请求是取指请求 |
| `mem_ready` | 输入 | 外部 slave 已完成该请求 |
| `mem_addr[31:0]` | 输出 | byte address |
| `mem_wdata[31:0]` | 输出 | 写数据 |
| `mem_wstrb[3:0]` | 输出 | 每个 byte 的写使能；全 0 表示读 |
| `mem_rdata[31:0]` | 输入 | 读返回值 |

一次读事务：

```text
CPU: mem_valid=1, mem_wstrb=0000, mem_addr=A
外设等待若干拍
外设: mem_ready=1, mem_rdata=D
CPU 在该拍接收 D，事务结束
```

一次写事务：

```text
CPU: mem_valid=1, mem_wstrb!=0000, mem_addr=A, mem_wdata=D
外设完成写入
外设: mem_ready=1
CPU 结束事务
```

最重要的不变量：

```text
mem_valid=1 且 mem_ready=0 时，CPU 保持地址、写数据和 wstrb 稳定。
```

如果你的互连没有最终产生 `mem_ready`，CPU 会停在当前 load/store 或 instruction
fetch，看起来像“仿真不结束”。

### 3.3 `mem_instr` 不是另一个总线

PicoRV32 使用统一 memory interface：指令和数据共享 `mem_*`。`mem_instr=1` 只是在
告诉外部“这是取指”。第一版 BRAM 可以同时存程序和数据，不必设计独立 I-Bus/D-Bus。

### 3.4 `mem_wstrb` 必须真的支持

PicoRV32 可能产生：

```text
0000：读
1111：32-bit 写
0011/1100：16-bit 写
0001/0010/0100/1000：8-bit 写
```

你的 Boot RAM 必须支持 byte write。否则 C 中的 `char`、字符串、栈变量可能错误。

但当前 APU 只接受 32-bit 对齐全字，因此 APU bridge 必须要求：

```text
mem_addr[1:0] == 0
mem_wstrb == 0000 或 1111
```

这是 RAM slave 和 APU slave 的重要区别。

## 4. 第二轮阅读：看最小测试平台

### 4.1 先看 `testbench_ez.v`

这个文件很短，重点找四部分：

1. 时钟和低有效复位；
2. `picorv32` 实例；
3. `memory[]`；
4. 产生 `mem_ready/mem_rdata` 的 always block。

你要画出：

```text
picorv32
  mem_valid/addr/wdata/wstrb
              |
              v
            memory
              |
              v
       mem_ready/mem_rdata
```

它证明 CPU 不需要 AXI/AHB 才能工作。native valid/ready 已足够构成最小计算机。

### 4.2 运行官方无工具链测试

在 PicoRV32 仓库执行：

```bash
cd <PICORV32_DIR>
make test_ez
```

该测试不依赖外部 firmware hex，适合先确认 Verilog 仿真环境。官方 Makefile 默认使用
Icarus Verilog；若本机没有：

```bash
iverilog -V
vvp -V
```

如果未安装 Icarus，不要因此修改 PicoRV32 RTL。你也可以后续为自己的工程编写
Verilator testbench，但第一次应先理解官方目标的源文件组成。

运行前后记录：

```bash
git status --short
git rev-parse HEAD
make test_ez
git status --short
```

第三方仓库应保持无修改。若官方测试失败，先解决工具依赖，不要把失败带入 APU 工程。

### 4.3 再运行官方标准测试

确认 RISC-V GCC 后执行：

```bash
riscv64-unknown-elf-gcc --version
make test TOOLCHAIN_PREFIX=riscv64-unknown-elf-
```

或者工具链名为：

```bash
riscv32-unknown-elf-gcc --version
make test TOOLCHAIN_PREFIX=riscv32-unknown-elf-
```

官方示例历史上可能默认查找 `/opt/riscv32...` 工具链，所以明确传
`TOOLCHAIN_PREFIX` 更可控。

如果 `make test` 需要的 ISA/ABI 与本机工具链 multilib 不匹配，先用：

```bash
riscv64-unknown-elf-gcc -print-multi-lib
```

检查是否支持 `rv32i/ilp32` 或 `rv32imc/ilp32`。

### 4.4 此阶段退出条件

- 官方 `test_ez` 能结束；
- 有工具链时，官方 `make test` 能通过；
- PicoRV32 clone 没有被你修改；
- 你能从波形指出一笔 instruction fetch；
- 你能从波形指出一笔 data write；
- 你能解释 `mem_ready` 晚三拍时 CPU 为什么不会丢请求。

## 5. 第三轮阅读：看 PicoSoC，不照搬

### 5.1 `picosoc/picosoc.v` 看什么

只追踪以下路径：

```text
picorv32 mem_* 输出
 -> memory address decode
 -> SRAM / SPI memory / UART / user peripheral
 -> ready 和 rdata 返回
```

重点记录：

- CPU 在顶层怎样实例化；
- 内存地址怎样划分；
- 多个 slave 的 `ready` 怎样合并；
- 多个 slave 的 `rdata` 怎样选择；
- UART 是怎样被 C 程序通过固定地址访问的；
- reset vector 为什么与 linker script 一致。

不要求现在理解 SPI Flash 状态机。

### 5.2 `picosoc/start.s` 看什么

关注：

- 复位入口 label；
- 栈指针怎样设置；
- 怎样调用 `main`；
- `main` 返回后做什么；
- 是否清零 `.bss`、复制 `.data`。

PicoSoC 的启动文件是示例，不一定满足你的 C 运行时需求。你自己的最终 startup 至少要
明确处理：

```text
sp
.bss
.data（若 load address 与 run address 不同）
main
main 返回后的 halt
```

### 5.3 `picosoc/sections.lds` 看什么

链接脚本必须回答：

- `.text` 从哪个地址开始；
- `.rodata` 放哪里；
- `.data/.bss` 放哪里；
- 栈顶在哪里；
- 是否超过物理 BRAM；
- reset vector 是否真的有代码。

CPU 参数：

```text
PROGADDR_RESET
STACKADDR
```

硬件 memory map 与 linker script 三者必须一致。任何一个不一致，CPU 都可能从空地址
取指或把栈写进外设地址。

### 5.4 `picosoc/firmware.c` 看什么

关注它怎样使用 `volatile` 指针访问 UART 和用户寄存器。你以后写 APU 驱动采用同一
机制：

```c
*(volatile uint32_t *)REGISTER_ADDRESS = value;
value = *(volatile uint32_t *)REGISTER_ADDRESS;
```

不要复制它的外设地址。你的 SoC memory map 由自己定义。

## 6. 如何把 PicoRV32 放进当前工程

### 6.1 推荐：作为固定版本第三方依赖

推荐目录：

```text
APU/
|-- rtl/                         # 原 APU RTL，保持现有回归
|-- third_party/
|   `-- picorv32/
|       |-- picorv32.v
|       |-- COPYING
|       `-- VERSION.md
|-- soc/
|   |-- rtl/
|   |-- firmware/
|   |-- tb/
|   |-- tools/
|   `-- Makefile
|-- Makefile                     # 原 APU 回归入口
`-- docs/
```

`VERSION.md` 建议记录：

```text
upstream: https://github.com/YosysHQ/picorv32
commit: <git rev-parse HEAD 输出>
license: ISC
local modifications: none
```

### 6.2 三种版本管理方式

**方式 A：Git submodule，推荐。**

```bash
cd /home/jiabingyu/prj/26_myprj/APU
git submodule add https://github.com/YosysHQ/picorv32.git third_party/picorv32
cd third_party/picorv32
git checkout <固定commit>
```

优点：版本清楚、可更新、保留完整官方例程。缺点：其他人 clone 后要执行：

```bash
git submodule update --init --recursive
```

**方式 B：vendor 必要文件。**

只复制：

```text
picorv32.v
COPYING
```

并记录来源 commit。官方 README 明确说明 `picorv32.v` 可以直接复制进项目。优点是
工程简单；缺点是更新和来源追踪靠你维护。

**方式 C：引用仓库外部绝对路径，不推荐作为最终交付。**

例如 Makefile 使用：

```make
PICORV32_DIR ?= /home/user/ip/picorv32
```

这只适合你本机初步实验，交给老师后路径会失效。最终应改成 submodule 或 vendor。

### 6.3 不要把整个仓库加入 `rtl/*.v` wildcard

当前 APU Makefile 使用：

```make
RTL_SRCS := $(sort $(wildcard rtl/*.sv))
```

不要把 PicoRV32 的 testbench、PicoSoC、多个板卡 top 和脚本都塞进 `rtl/`。这样会出现：

- 多个顶层模块；
- 测试平台被错误综合；
- 不同 memory map 混入工程；
- 编译时间增加；
- 宏定义和 module 名冲突；
- 原 APU `make check` 被破坏。

SoC 应使用独立 filelist 和独立 Makefile。原 Makefile 继续只验证 APU。

## 7. 新建 SoC 工程的最小目录

第一阶段建议只创建：

```text
soc/
|-- rtl/
|   |-- riscv_apu_soc_top.sv
|   |-- picorv32_wrapper.sv
|   |-- soc_interconnect.sv
|   |-- boot_ram.sv
|   |-- sim_console.sv
|   `-- native_to_apu_ahb.sv       # 后续阶段再加入 filelist
|-- firmware/
|   |-- start.S
|   |-- link.ld
|   |-- main.c
|   `-- Makefile
|-- tb/
|   |-- tb_soc.sv
|   `-- verilator_main.cpp
|-- filelist.f
`-- Makefile
```

第一阶段 filelist 不应包含 APU：

```text
third_party/picorv32/picorv32.v
soc/rtl/picorv32_wrapper.sv
soc/rtl/boot_ram.sv
soc/rtl/sim_console.sv
soc/rtl/soc_interconnect.sv
soc/rtl/riscv_apu_soc_top.sv
soc/tb/tb_soc.sv
```

等 CPU + BRAM + console 测试通过，再增加：

```text
soc/rtl/native_to_apu_ahb.sv
rtl/*.sv
```

## 8. 先写 PicoRV32 wrapper

### 8.1 wrapper 的职责

`picorv32_wrapper.sv` 只做：

- 固定 CPU 参数；
- 导出本项目需要的 native memory interface；
- 把未使用的 PCPI 输入绑 0；
- 第一阶段把 `irq` 绑 0；
- 导出 `trap` 便于 LED、波形和仿真检测；
- 不做地址译码；
- 不包含 RAM/APU。

### 8.2 第一阶段建议先用 RV32I

为了把问题减少到最少，第一次“HELLO”建议：

```text
COMPRESSED_ISA = 0
ENABLE_MUL     = 0
ENABLE_DIV     = 0
ENABLE_IRQ     = 0
```

编译：

```text
-march=rv32i -mabi=ilp32
```

等 CPU、内存和软件流程跑通后，再切换最终配置：

```text
COMPRESSED_ISA = 1
ENABLE_MUL     = 1
ENABLE_DIV     = 1
```

编译同步改成：

```text
-march=rv32imc -mabi=ilp32
```

这样出现非法指令时，你知道是配置切换问题，不会与首次启动问题混在一起。

### 8.3 wrapper 实例化骨架

下面是连接关系示意，不应直接跳过测试投入完整 SoC：

```systemverilog
module picorv32_wrapper (
    input  logic        clk,
    input  logic        resetn,
    output logic        trap,
    output logic        mem_valid,
    output logic        mem_instr,
    input  logic        mem_ready,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [ 3:0] mem_wstrb,
    input  logic [31:0] mem_rdata
);

    logic        mem_la_read;
    logic        mem_la_write;
    logic [31:0] mem_la_addr;
    logic [31:0] mem_la_wdata;
    logic [ 3:0] mem_la_wstrb;
    logic        pcpi_valid;
    logic [31:0] pcpi_insn;
    logic [31:0] pcpi_rs1;
    logic [31:0] pcpi_rs2;
    logic [31:0] eoi;
    logic        trace_valid;
    logic [35:0] trace_data;

    picorv32 #(
        .ENABLE_COUNTERS   (1),
        .ENABLE_COUNTERS64 (0),
        .COMPRESSED_ISA    (0),
        .ENABLE_MUL        (0),
        .ENABLE_DIV        (0),
        .ENABLE_IRQ        (0),
        .CATCH_MISALIGN    (1),
        .CATCH_ILLINSN     (1),
        .PROGADDR_RESET    (32'h0000_0000),
        .STACKADDR         (32'h0001_0000)
    ) u_cpu (
        .clk          (clk),
        .resetn       (resetn),
        .trap         (trap),
        .mem_valid    (mem_valid),
        .mem_instr    (mem_instr),
        .mem_ready    (mem_ready),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_wstrb    (mem_wstrb),
        .mem_rdata    (mem_rdata),
        .mem_la_read  (mem_la_read),
        .mem_la_write (mem_la_write),
        .mem_la_addr  (mem_la_addr),
        .mem_la_wdata (mem_la_wdata),
        .mem_la_wstrb (mem_la_wstrb),
        .pcpi_valid   (pcpi_valid),
        .pcpi_insn    (pcpi_insn),
        .pcpi_rs1     (pcpi_rs1),
        .pcpi_rs2     (pcpi_rs2),
        .pcpi_wr      (1'b0),
        .pcpi_rd      (32'b0),
        .pcpi_wait    (1'b0),
        .pcpi_ready   (1'b0),
        .irq          (32'b0),
        .eoi          (eoi),
        .trace_valid  (trace_valid),
        .trace_data   (trace_data)
    );

endmodule
```

关键点：未使用输入不能悬空。特别是 `pcpi_ready/pcpi_wait/irq` 若为 X，可能污染 CPU
行为。未使用输出可以接到内部 wire，便于 lint，也可以按工具允许留空。

### 8.4 关于 `STACKADDR`

64 KiB RAM 地址范围：

```text
0x0000_0000 .. 0x0000_FFFF
```

栈向低地址增长，栈初值可以设为第一个越界地址：

```text
STACKADDR = 0x0001_0000
```

它满足 16-byte 对齐。最后一个实际可写 word 是 `0x0000_FFFC`。

若 startup 自己设置 `sp`，可以把 `STACKADDR` 保持默认，但第一版由参数设置更容易观察。
不能同时让硬件和 startup 使用两个不同栈顶。

## 9. 第一个自己的系统：CPU + BRAM + console

### 9.1 为什么不先接 UART

仿真阶段可定义一个 console MMIO 地址，例如：

```text
0x1000_0000：写低 8 bit，testbench 用 $write 输出字符
```

这样暂时不需要实现 UART 波特率状态机，就能证明 C 程序执行和 MMIO 正确。上板前再
把相同地址连接到真正 UART TX。

### 9.2 最小 memory map

| 地址范围 | 模块 | 作用 |
| --- | --- | --- |
| `0x0000_0000..0x0000_FFFF` | Boot RAM | 指令、数据、栈 |
| `0x1000_0000..0x1000_0FFF` | Sim console | 仿真字符输出 |
| 其他 | Default slave | 返回 `0xDEAD_BEEF` 并完成 |

### 9.3 Boot RAM 要求

- 32-bit word；
- 16,384 words 对应 64 KiB；
- 支持 byte write enable；
- 仿真时通过 `$readmemh` 载入 firmware hex；
- FPGA 时应能推断 BRAM；
- 不对整个 memory 做异步复位。

地址换算：

```text
word_index = mem_addr[15:2]
byte_lane  = mem_addr[1:0]
```

写入：

```systemverilog
if (mem_wstrb[0]) memory[word_index][ 7: 0] <= mem_wdata[ 7: 0];
if (mem_wstrb[1]) memory[word_index][15: 8] <= mem_wdata[15: 8];
if (mem_wstrb[2]) memory[word_index][23:16] <= mem_wdata[23:16];
if (mem_wstrb[3]) memory[word_index][31:24] <= mem_wdata[31:24];
```

### 9.4 Default slave 必须完成事务

错误做法：

```text
地址未命中 -> mem_ready 永远为 0
```

结果：CPU 永久停住。

推荐：

```text
地址未命中 -> 下一拍 ready=1，rdata=0xDEAD_BEEF，并置 bus_fault
```

之后 UART/console 打印 fault 地址，便于调试。

### 9.5 第一份 C 程序

```c
#include <stdint.h>

#define CONSOLE_TX (*(volatile uint32_t *)0x10000000u)

static void putc(char c)
{
    CONSOLE_TX = (uint32_t)(uint8_t)c;
}

static void puts(const char *s)
{
    while (*s != '\0')
        putc(*s++);
}

int main(void)
{
    puts("HELLO RISCV\n");
    for (;;)
        ;
}
```

注意：这会对 console 产生 32-bit store，方便以后映射到 UART/APU 风格寄存器。

### 9.6 固件编译

RV32I 第一阶段：

```make
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

CFLAGS  := -march=rv32i -mabi=ilp32 -Os \
           -ffreestanding -fno-builtin -nostdlib -nostartfiles \
           -Wall -Wextra

LDFLAGS := -T link.ld -nostdlib -nostartfiles \
           -Wl,--gc-sections -Wl,-Map,firmware.map
```

生成并检查：

```bash
make firmware
riscv64-unknown-elf-readelf -h firmware.elf
riscv64-unknown-elf-objdump -d firmware.elf > firmware.dis
```

你必须检查：

- ELF 是 32-bit RISC-V；
- entry point 是 `0x00000000`；
- reset 位置确实有指令；
- `.text/.data/.bss` 没超过 64 KiB；
- 反汇编没有 `mul/div` 或 compressed 指令（RV32I 阶段）；
- 栈地址正确。

### 9.7 第一阶段波形必须观察

```text
resetn
trap
mem_valid
mem_instr
mem_ready
mem_addr
mem_wdata
mem_wstrb
mem_rdata
ram_ready
console_ready
```

你应当能找到：

1. 复位释放后的第一笔取指 `mem_addr=0`；
2. `mem_instr=1`；
3. BRAM 返回第一条指令并拉高 ready；
4. 若干取指后，访问 `0x1000_0000`；
5. `mem_wstrb=1111`；
6. console 输出字符 `H`；
7. `trap` 始终为 0。

## 10. Interconnect 该怎么写

### 10.1 第一版不是复杂 NoC

你只有一个 master：PicoRV32。第一版 interconnect 是：

```text
地址译码 + 请求分发 + 响应复用
```

不需要：

- 仲裁；
- cache coherency；
- burst；
- multiple outstanding；
- reorder buffer；
- AXI ID。

### 10.2 推荐全局 memory map

| 地址范围 | Slave |
| --- | --- |
| `0x0000_0000..0x0000_FFFF` | Boot/Data BRAM |
| `0x1000_0000..0x1000_0FFF` | UART/仿真 console |
| `0x1000_1000..0x1000_1FFF` | Timer |
| `0x1000_2000..0x1000_2FFF` | GPIO/错误状态 |
| `0x2000_0000..0x2000_3FFF` | APU |
| 其他 | Default slave |

### 10.3 为什么要锁存目标 slave

同步 RAM 或 APU 可能晚一拍以上响应。请求开始时锁存：

```text
pending
selected_slave
request_addr
request_wdata
request_wstrb
```

响应时按 `selected_slave` 选择 ready/rdata。不要只用当前组合 `mem_addr` 选择返回值，
否则在请求完成边界可能把下一笔地址与上一笔响应混在一起。

### 10.4 一次只允许一个 slave ready

建议断言：

```systemverilog
assert ($onehot0({ram_ready, uart_ready, timer_ready,
                  gpio_ready, apu_ready, default_ready}));
```

如果两个地址区间重叠，两个 slave 同时 ready，`mem_rdata` 会不确定。

## 11. 在接 APU 前先理解当前 AHB 边界

### 11.1 当前 APU 顶层接口

`rtl/Top_student.sv` 的模块名为 `Top`，外部总线信号包括：

```text
clk, nRst
hsel, haddr, htrans, hwrite, hsize, hburst, hwdata
hrdata, hresp, hreadyout
int_cal
```

另外还有输入 `hready`，但当前实现中未实际参与内部事务控制。

### 11.2 APU 局部地址

| 局部地址 | 寄存器/窗口 |
| ---: | --- |
| `0x0000..0x1FFF` | RAM 数据窗口 |
| `0x2000` | `RAM_CTRL` |
| `0x2004` | `RAM_SEL` |
| `0x2008` | `APU_READY` |
| `0x200C` | `CPL` |

全局 APU 基址建议为 `0x2000_0000`：

```text
global 0x2000_2008 -> local 0x2008
```

bridge 应显式执行：

```text
apu_haddr = cpu_mem_addr - APU_BASE
```

### 11.3 当前 APU 不支持 partial write

APU 软件访问统一使用：

```c
volatile uint32_t *
```

bridge 检查：

```text
read  : mem_wstrb == 0000
write : mem_wstrb == 1111
align : mem_addr[1:0] == 00
```

否则置 `apu_bus_fault`，并完成 CPU 事务，不能让 CPU 永久等待。

### 11.4 当前 APU AHB 并非标准零等待 SRAM slave

现有 `ahb_slave.sv`：

- `hready` 输出固定为 1；
- 写地址在地址相位锁存；
- 写使能延迟一拍；
- 同步 RAM 读数据又有内部延迟；
- 现有 testbench 通过额外等待和特定采样相位工作。

所以不要这样直接连：

```text
mem_valid -> hsel
mem_ready <- hreadyout
```

因为 `hreadyout=1` 不代表 Act/Out/Weight SRAM 读数据已经对 CPU 稳定。

## 12. CPU-to-APU AHB bridge 怎么做

### 12.1 bridge 端口分组

CPU 侧：

```text
req_valid
req_ready
req_addr
req_wdata
req_wstrb
resp_rdata
```

APU 侧：

```text
hsel
haddr
htrans
hwrite
hsize
hburst
hwdata
hrdata
hresp
hreadyout
```

### 12.2 推荐状态机

```text
IDLE
  |
  | req_valid 且地址命中 APU，锁存请求
  v
ADDR
  |
  | 发 AHB NONSEQ 地址相位
  +----------------------+
  | write                | read
  v                      v
WDATA                  RWAIT_0
  | 提供写数据             | 等内部地址/同步 RAM
  v                      v
WRESP                  RWAIT_1
  |                      | 再等返回稳定
  +-----------+----------+
              v
            RESP
              |
              | req_ready=1，读时给 resp_rdata
              v
            IDLE
```

具体读等待拍数不能凭感觉固定。必须分别测量：

- 控制寄存器读；
- WorkSheet 读；
- ActSRAM 读；
- OutSRAM 读；
- WeightSRAM 读；
- SIMD 参数读。

如果不同对象延迟不同，可在 bridge 中按目标选择等待拍，或优先规范化 APU wrapper，
让 `hreadyout` 真正代表数据完成。

### 12.3 写事务时序

现有 APU 写路径需要：

```text
第 N 拍：hsel=1, htrans=NONSEQ, hwrite=1, haddr=A
第 N+1 拍：hwdata=D，内部延迟 t_wren 有效
```

因此 bridge 在请求进入时锁存 `req_wdata`，并在整个 ADDR/WDATA 阶段保持稳定。

如果只在地址拍短暂输出写数据，`addr_map` 真正采样时可能已经变成下一笔数据或 0。

### 12.4 CPU ready 只能发一次

PicoRV32 在 `mem_valid && mem_ready` 后结束事务。bridge 的 `req_ready` 应产生一个完成
窗口，然后回 IDLE。不能在请求仍高时连续多拍 ready，否则同一请求可能被重复接受。

推荐用 `pending` 或 FSM 保证：

```text
每次 mem_valid 上升/空闲接受 -> 恰好一个 mem_ready
```

### 12.5 bridge 单元测试优先于 CPU 集成

先写 TB 直接驱动 bridge 的 CPU 侧：

1. 写 `RAM_CTRL=3`；
2. 读回 `RAM_CTRL`；
3. 写 `RAM_SEL=128`；
4. 写 ActSRAM low32；
5. 写 ActSRAM high32；
6. 读回两个 half；
7. 切换 `RAM_SEL=129` 重复；
8. 测 Weight bank；
9. 测 BN channel；
10. 测 WorkSheet；
11. 非对齐和 partial write 返回 fault；
12. 每笔请求设置 timeout。

只有该 TB 全通过，才把 PicoRV32 接到 bridge。否则 CPU 软件、bridge 和 APU 三层问题
会混在一起。

## 13. SoC 顶层如何连接

### 13.1 顶层层次

```text
riscv_apu_soc_top
|-- reset_sync
|-- picorv32_wrapper
|-- soc_interconnect
|-- boot_ram
|-- uart/sim_console
|-- timer
|-- native_to_apu_ahb
`-- Top u_apu
```

### 13.2 连接关系

```text
PicoRV32 mem_*
       |
       v
soc_interconnect
  |       |        |          |
  v       v        v          v
BRAM    UART     Timer    native_to_apu_ahb
                                  |
                                  v
                               APU Top
```

interconnect 不理解 AHB。它只把 native 请求交给 APU bridge。bridge 是唯一知道 AHB
地址相位和数据相位的模块。

### 13.3 APU 实例注意事项

```systemverilog
Top u_apu (
    .clk       (soc_clk),
    .nRst      (soc_resetn),
    .hsel      (apu_hsel),
    .haddr     (apu_haddr),
    .htrans    (apu_htrans),
    .hwrite    (apu_hwrite),
    .hsize     (apu_hsize),
    .hburst    (apu_hburst),
    .hwdata    (apu_hwdata),
    .hready    (1'b1),
    .hlock     (1'b0),
    .hprot     (4'b0011),
    .hrdata    (apu_hrdata),
    .hresp     (apu_hresp),
    .hreadyout (apu_hreadyout),
    .int_cal   (apu_int_cal)
);
```

第一版 CPU、bridge 和 APU 使用同一时钟，避免 CDC。`apu_int_cal` 暂时映射成 SoC
只读状态寄存器，先轮询；后续再连 PicoRV32 IRQ。

## 14. APU 软件接入顺序

不要一开始运行完整网络。C 驱动按四层递进。

### 14.1 Level 1：寄存器读写

```c
#define APU_BASE       0x20000000u
#define APU_RAM_CTRL   (*(volatile uint32_t *)(APU_BASE + 0x2000u))
#define APU_RAM_SEL    (*(volatile uint32_t *)(APU_BASE + 0x2004u))
#define APU_READY      (*(volatile uint32_t *)(APU_BASE + 0x2008u))
#define APU_CPL        (*(volatile uint32_t *)(APU_BASE + 0x200Cu))

APU_RAM_CTRL = 3u;
if (APU_RAM_CTRL != 3u)
    report_error();
```

先只证明 MMIO 地址和 bridge 正确。

### 14.2 Level 2：APU RAM 回读

```text
RAM_CTRL=3
RAM_SEL=128
写 ActSRAM word0 low32/high32
读回比较
```

再测 `RAM_SEL=129`、一个 Weight bank、一个 BN channel 和 WorkSheet。

### 14.3 Level 3：一条卷积指令

把当前 testbench 中 `conv_layer` 的行为翻译成 C：

```text
按 output group
 -> 按 64 个 Weight bank
 -> 每 bank 写对应权重
按 output group
 -> 按 64 个 SIMD channel
 -> 每 channel 写参数
写 worksheet[0]
RAM_CTRL=0
APU_READY=1
等待完成
```

第一条目标建议使用 layer1.0 conv1，因为：

- 输入输出通道都是 64；
- 只有一个 input group 和 output group；
- 没有 residual replay；
- 权重地址和输出布局最简单。

### 14.4 Level 4：完整网络

单层 0 mismatch 后再迁移：

- layer1+2 的八条 worksheet 批次；
- layer3 的逐 op 重载；
- residual；
- 128/256 channel 的物理组反序；
- 六个检查点。

完整协议见：

- [APU 编程模型](../design/final/02_PROGRAMMING_MODEL.md)
- [数据与存储布局](../design/final/04_DATA_AND_MEMORY_LAYOUT.md)
- [验证与重建](../design/final/08_VERIFICATION_AND_REBUILD.md)

## 15. Makefile 不要破坏原回归

### 15.1 保留根目录行为

当前根 Makefile：

```bash
make check
```

用于验证原 APU。接入 PicoRV32 后仍必须保持它通过。

### 15.2 SoC 使用独立目标

可以在根 Makefile 后续增加转发目标：

```make
.PHONY: soc-firmware soc-sim soc-check

soc-firmware:
	$(MAKE) -C soc firmware

soc-sim:
	$(MAKE) -C soc sim

soc-check:
	$(MAKE) -C soc check
```

但实际编译规则放在 `soc/Makefile`，避免原 APU Verilator top、CPP main 和 SoC top
混在同一次编译中。

### 15.3 建议目标

```text
make check               原 APU 六点回归
make soc-toolchain       检查 RISC-V GCC 和 multilib
make soc-firmware        生成 ELF/BIN/HEX/DIS/MAP
make soc-cpu             CPU + BRAM + console
make soc-bridge          APU bridge 单元测试
make soc-smoke           RISC-V APU RAM/寄存器测试
make soc-layer1          RISC-V 执行一层卷积
make soc-check           完整 RISC-V + APU 回归
```

## 16. 你的实际学习顺序

### 第 1 天：只看接口

阅读：

```text
README.md
testbench_ez.v
picorv32.v 的 module 参数和端口声明
```

输出：手画一张 native read/write 时序图，并解释 `mem_wstrb`。

### 第 2 天：运行官方测试

执行：

```bash
make test_ez
make test TOOLCHAIN_PREFIX=<你的前缀>
```

输出：测试日志、commit ID、工具版本。

### 第 3 天：读 PicoSoC 软件链

阅读：

```text
picosoc/picosoc.v
picosoc/start.s
picosoc/sections.lds
picosoc/firmware.c
```

输出：画出 `C store -> mem_* -> UART` 路径。

### 第 4 至 5 天：自己的 CPU + BRAM

实现：

```text
picorv32_wrapper
boot_ram
sim_console
最小 interconnect
start.S/link.ld/main.c
```

输出：`HELLO RISCV`，并保存波形。

### 第 6 至 7 天：interconnect 自检

实现：

- default slave；
- UART 地址；
- timer 或 cycle counter；
- bus fault；
- timeout。

输出：RAM、console、非法地址三个测试都能结束。

### 第 2 周：bridge 单元测试

不接 CPU，先验证 `native_to_apu_ahb`。

输出：寄存器和所有 RAM 类型读写通过。

### 第 3 周：CPU 控制 APU

先寄存器，再 SRAM，再单层卷积。

输出：layer1.0 第一条指令 0 mismatch。

## 17. 每阶段退出检查表

### 官方仓库阶段

- [ ] 记录 PicoRV32 commit。
- [ ] 阅读 ISC `COPYING`。
- [ ] `make test_ez` 能结束。
- [ ] 工具链存在时 `make test` 通过。
- [ ] clone 保持 clean。

### CPU 最小系统阶段

- [ ] 第一笔取指地址为 `PROGADDR_RESET`。
- [ ] `mem_valid` 等待期间请求稳定。
- [ ] Boot RAM 支持 byte write。
- [ ] 非法地址不会让 CPU死锁。
- [ ] `HELLO RISCV` 从 C 程序输出。
- [ ] `trap=0`。

### APU bridge 阶段

- [ ] 全局地址正确转换为 APU 局部地址。
- [ ] 写地址相位和写数据相位分开。
- [ ] RAM 读响应等待同步延迟。
- [ ] partial/unaligned access 被检测。
- [ ] 每笔请求恰好一个 ready。
- [ ] 有 timeout。

### APU 软件阶段

- [ ] `RAM_CTRL/RAM_SEL` 可读写。
- [ ] 64-bit 数据 low32 后 high32。
- [ ] 切换 `RAM_SEL` 不发生在 half-word 中间。
- [ ] WorkSheet 从地址 0 连续写。
- [ ] 运行前 `RAM_CTRL=0`。
- [ ] 完成等待有超时。
- [ ] 单层结果 0 mismatch 后才做完整网络。

## 18. 常见问题与直接判断

### 18.1 CPU 第一拍后不动

检查：

- `resetn` 是否真正拉高；
- `mem_valid` 是否为 1；
- `mem_addr` 是否等于 reset vector；
- BRAM 是否在该地址有 firmware；
- `mem_ready` 是否永远为 0；
- linker entry 是否为 0；
- hex word byte order 是否正确。

### 18.2 `trap` 很快拉高

检查：

- ISA 是否匹配；
- RV32I CPU 是否运行了 `rv32imc` 固件；
- 是否产生未对齐访问；
- startup 是否返回到无效地址；
- 固件是否超过 RAM；
- reset vector 处是否装入数据而非指令。

### 18.3 能取指但不打印

检查：

- `main` 是否被调用；
- console 地址是否与 C 宏一致；
- 编译器是否生成 byte store，而 console 只接受 word；
- interconnect 是否选中 console；
- console 是否产生 ready；
- `volatile` 是否存在。

### 18.4 一接 APU CPU 就卡死

检查：

- APU 地址是否命中；
- bridge 是否接受请求；
- FSM 是否进入 RESP；
- CPU `mem_ready` 是否最终出现；
- 读等待拍是否足够；
- APU `haddr` 是局部地址还是错误全局地址；
- `htrans` 是否为 `NONSEQ=2'b10`；
- 写数据是否在后一拍存在。

### 18.5 APU 寄存器正确，SRAM 读回错误

优先检查：

- 同步 RAM 读延迟；
- low/high half 地址；
- `ram_raddr_d[0]`；
- 是否中途切换 `RAM_SEL`；
- bridge 是否过早给 CPU ready。

### 18.6 APU 可以完成但推理 mismatch

先证明 CPU 产生的 AHB 事务与 `tb/tb_top_student.sv` 一致，再检查：

- bank/output group 循环顺序；
- weight 起始地址；
- BN channel 和 entry；
- worksheet 指令字段；
- 最新结果位于 Act 还是 Out；
- 128/256 channel group reverse。

不要先修改 Ctrl。

## 19. 现在立刻执行的任务

按顺序完成，不要跳步：

```bash
cd <PICORV32_DIR>
git remote -v
git rev-parse HEAD
git status --short
sed -n '1,220p' README.md
```

然后在 README 中搜索：

```bash
rg -n "Native Memory Interface|COMPRESSED_ISA|ENABLE_MUL|PROGADDR_RESET|STACKADDR" README.md
```

再读最小 TB：

```bash
sed -n '1,180p' testbench_ez.v
```

运行：

```bash
make test_ez
```

接着检查工具链：

```bash
command -v riscv64-unknown-elf-gcc
riscv64-unknown-elf-gcc --version
riscv64-unknown-elf-gcc -print-multi-lib
```

如果你的命令前缀是 `riscv32-unknown-elf-`，替换上述前缀。

最后阅读：

```bash
sed -n '1,260p' picosoc/picosoc.v
sed -n '1,220p' picosoc/start.s
sed -n '1,220p' picosoc/sections.lds
sed -n '1,260p' picosoc/firmware.c
```

完成后你应输出四份笔记：

1. PicoRV32 commit 和许可证；
2. native memory interface 信号表；
3. `testbench_ez.v` 的 CPU-memory 数据流图；
4. PicoSoC 的 memory map、startup 和 linker 对应关系。

下一项实际 RTL 任务才是建立：

```text
PicoRV32 + 64 KiB Boot RAM + simulation console
```

在它打印出自己编译的 `HELLO RISCV` 前，不接 APU。

## 20. 官方资料

- PicoRV32 官方仓库：<https://github.com/YosysHQ/picorv32>
- `picorv32.v`：<https://github.com/YosysHQ/picorv32/blob/main/picorv32.v>
- PicoSoC 示例：<https://github.com/YosysHQ/picorv32/tree/main/picosoc>
- PicoRV32 firmware 示例：<https://github.com/YosysHQ/picorv32/tree/main/firmware>
- 上一份整体路线：[RISC-V 全自主 SoC + APU 实施指南](RISCV_SOC_APU_PROJECT_GUIDE.md)

