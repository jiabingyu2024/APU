# RISC-V 全自主 SoC + APU 项目实施指南

## 0. 先给结论

对当前项目和大三阶段的时间、知识基础，推荐路线是：

```text
PicoRV32（RV32IMC，裸机）
        |
        | PicoRV32 native valid/ready 总线
        v
单主机 SoC 地址译码与互连
        |------------------ 片上 BRAM：程序、数据、栈
        |------------------ UART：打印、下载模型参数
        |------------------ Timer/GPIO：基本外设与验收
        `------------------ APU 总线桥：转换为 APU 当前 AHB-Lite 接口
                                      |
                                      v
                                  现有 APU
```

第一版不要选择 Rocket。Rocket Chip 是 Chisel/Scala 生成器体系，并通常使用
TileLink 互连，处理器、总线、缓存和生成流程都明显复杂于本项目需要。它适合后续
研究型升级，不适合作为第一次独立完成的 FPGA SoC 集成目标。

第一版也不要上 Linux、cache、DDR、多主机仲裁、DMA 或虚拟内存。验收只要求
RISC-V 执行 C 程序并通过总线驱动 APU，裸机 SoC 已经完整覆盖处理器、总线、存储、
外设、驱动、编译链接、启动和硬件验证流程。

建议采用以下基线：

| 项目 | 第一版选择 |
| --- | --- |
| CPU | PicoRV32 |
| ISA | RV32IMC，ABI 为 ILP32 |
| 软件 | 裸机 C，无操作系统 |
| CPU 总线 | PicoRV32 native memory interface |
| SoC 拓扑 | 单主机、地址译码、一问一答、无 outstanding |
| APU 接口 | 保留现有 AHB 从设备，增加 CPU-to-AHB 适配器 |
| 片上存储 | 64 KiB 起步，资源允许时使用 128 KiB BRAM |
| 时钟 | 单时钟域，建议先从 25 MHz 或 50 MHz 开始 |
| 调试 | UART 日志 + LED 心跳 + 仿真波形 |
| 固件装载 | 初期 BRAM 初始化，最终增加 UART 参数下载 |
| FPGA 配置 | JTAG 直接配置 PL，不使用 ARM 软件运行时 |

本文是实施路线和架构草案。目标 FPGA 型号、开发板、板载独立 PL 时钟、UART 引脚
和可用 BRAM 数量仍需根据实际开发板手册确认。

## 1. 你现在已经具备什么

当前仓库不是从零开始，已经有一个经过固定网络 bit-exact 回归的 APU：

```text
AHB Slave
   |
   +-- WorkSheet：存储并发射 32-bit APU 指令
   +-- Ctrl：卷积、残差、地址和时序控制
   +-- ActSRAM / OutSRAM：特征图乒乓缓存
   +-- WeightSRAM：64 路权重存储
   +-- ComputeCoreGroup：64 路并行二值卷积
   `-- SIMD：BN 等效比较和二值激活
```

现有 testbench 实际扮演了“软件处理器”的角色：

1. 通过 AHB 写初始输入。
2. 通过 AHB 写权重和 BN 参数。
3. 通过 AHB 写 WorkSheet 指令。
4. 写启动寄存器。
5. 等待完成。
6. 读回结果并与 golden 比较。

RISC-V SoC 集成的核心工作，就是把这套 testbench 行为迁移成真实的裸机 C 驱动，
再让 PicoRV32 通过硬件总线执行这些读写。

这意味着你不需要重新设计卷积阵列。新工作的重点是：

- CPU 如何取指和访问数据；
- CPU 地址如何选择 BRAM、UART、Timer 或 APU；
- PicoRV32 请求如何转换成 APU 接受的 AHB 时序；
- C 程序如何被编译、链接并放入 BRAM；
- 模型参数如何进入没有 ARM、没有 DDR 的 PL SoC；
- 如何在 FPGA 上证明执行者确实是 RISC-V，而不是 ARM PS。

## 2. 验收目标拆解

不要把“做出完整 SoC”当成一个不可分割的大任务。它应拆成四条可以分别证明的
验收链。

### 2.1 RISC-V 核运行正常

最低证据：

- PicoRV32 从复位地址取到第一条指令；
- 能正确执行启动代码并建立栈；
- 进入 `main()`；
- UART 打印固定字符串、整数和循环计数；
- 能通过 C 程序读写片上 RAM；
- 非法地址访问能返回确定值或进入 trap，不能永久死锁。

### 2.2 APU 挂载成功

最低证据：

- C 程序能够读写 APU 的 `RAM_CTRL`、`RAM_SEL`；
- 能写入 ActSRAM、WeightSRAM、SIMD 参数和 WorkSheet；
- 写 `APU_READY` 后 APU 开始工作；
- CPU 轮询或中断检测到完成；
- CPU 能读回输出 SRAM；
- 至少一个完整检查点与软件 golden 完全一致。

### 2.3 推理功能完整

最低证据不是“APU 完成信号出现”，而是：

- layer1、layer2、layer3 按正确批次执行；
- 权重可按阶段重新装载；
- residual 指令执行正确；
- 最终输出顺序完成物理组到 canonical 组的转换；
- 与当前 `make check` 的六个检查点一致，或至少最终分类结果一致且中间检查点可追溯。

### 2.4 ARM PS 完全不参与运行

需要提供可审查证据：

- Vivado block design 或 RTL 顶层中没有 Zynq PS IP 数据通路；
- SoC 时钟来自板载 PL 时钟引脚，而不是 PS `FCLK_CLK`；
- UART、定时器、程序 RAM、模型搬运均位于 PL；
- FPGA 通过 JTAG 配置，运行时不需要 PYNQ/Linux/ARM 程序；
- ARM CPU 保持复位或停止状态；
- 断开 PS 软件后，RISC-V SoC 仍可独立运行。

注意：Zynq 芯片物理上始终包含 ARM PS。所谓“完全脱离”应解释为 ARM 不执行应用、
不提供运行时总线服务、不提供时钟、不搬运数据。如果开发板没有独立接入 PL 的时钟，
就不能在报告中声称完全不依赖 PS 时钟，必须改板级方案或明确限制。

## 3. 为什么推荐 PicoRV32

### 3.1 PicoRV32 与 Rocket 对比

| 对比项 | PicoRV32 | Rocket |
| --- | --- | --- |
| RTL/生成方式 | 单个 Verilog 源文件即可集成 | Chisel/Scala 生成体系 |
| 典型定位 | MCU、控制核、FPGA 辅助处理器 | 更完整的处理器/SoC 研究平台 |
| 总线 | native、AXI4-Lite、Wishbone 版本 | 主要围绕 TileLink 生态 |
| cache/MMU | 可不使用 | 通常涉及更复杂层次 |
| 软件目标 | 裸机 C 很合适 | 可支持更复杂软件栈 |
| 学习重点 | 地址译码、握手、启动、驱动 | 还要先掌握 Chisel 和生成器配置 |
| 与当前 APU 匹配度 | 高，单请求、32-bit、易桥接 | 需要 TileLink/AHB 或 AXI/AHB 适配 |
| 首次成功风险 | 较低 | 较高 |

PicoRV32 官方提供三种核心形式：

- `picorv32`：简单的 native valid/ready memory interface；
- `picorv32_axi`：AXI4-Lite master；
- `picorv32_wb`：Wishbone master。

本项目建议使用原始 `picorv32`。原因是它一次只发一个请求，信号少，很适合你亲自
设计地址译码和 APU 桥；这样能真正理解 SoC，而不是把问题全部交给 Vivado IP。

### 3.2 推荐 CPU 参数

第一版建议：

```systemverilog
picorv32 #(
    .PROGADDR_RESET    (32'h0000_0000),
    .STACKADDR         (32'h0001_0000), // 64 KiB RAM 顶部；实际按 RAM 容量修改
    .COMPRESSED_ISA    (1),
    .ENABLE_MUL        (1),
    .ENABLE_DIV        (1),
    .ENABLE_IRQ        (0),             // 轮询版先关闭
    .ENABLE_COUNTERS   (1),
    .ENABLE_COUNTERS64 (0),
    .CATCH_MISALIGN    (1),
    .CATCH_ILLINSN     (1)
) u_cpu (...);
```

对应编译选项：

```text
-march=rv32imc -mabi=ilp32
```

不能出现以下不一致：

- RTL 没开 `M`，软件却使用 `-march=rv32imc`；
- RTL 开了 compressed，链接地址或启动代码却错误处理 16-bit 指令；
- 使用 `ilp32d` ABI，但硬件没有浮点扩展；
- 栈顶超出 BRAM 实际范围。

## 4. 推荐 SoC 总体架构

```text
                          外部 25/50/100 MHz PL 时钟
                                      |
                                  Clock/Reset
                                      |
       +------------------------------+----------------------------+
       |                                                           |
       v                                                           v
+---------------+       native valid/ready       +------------------------+
|   PicoRV32    |-------------------------------->| SoC Interconnect       |
| RV32IMC CPU   |<--------------------------------| 地址译码 + 返回复用    |
+---------------+                                 +--+-----+-----+--------+
                                                       |     |     |
                  +------------------------------------+     |     +----------------+
                  |                                          |                      |
                  v                                          v                      v
         +----------------+                          +--------------+       +----------------+
         | Boot/Data BRAM |                          | UART/Timer   |       | CPU-to-AHB     |
         | 64/128 KiB     |                          | GPIO         |       | Bridge         |
         +----------------+                          +--------------+       +-------+--------+
                                                                                  |
                                                                          AHB-Lite-like
                                                                                  |
                                                                                  v
                                                                         +----------------+
                                                                         | Existing APU   |
                                                                         | Top            |
                                                                         +----------------+
```

### 4.1 为什么采用单主机

第一版只有 PicoRV32 一个 bus master。所有 BRAM、UART、Timer 和 APU 都是 slave。
因此不需要仲裁器，也不会出现两个 master 同时控制 APU RAM 的问题。

如果未来增加 UART DMA 或 SPI DMA，它们会成为第二个 master；那时必须增加仲裁、
总线 ownership 和一致性规则。不要在第一版提前引入。

### 4.2 为什么先用单时钟域

CPU、互连、BRAM、UART 寄存器和 APU 先全部使用同一个 `soc_clk`。这样不需要解决
CDC，完成信号也可直接同步使用。目标频率先设 25 MHz 或 50 MHz，功能通过后再提高。

如果 APU 最终只能在更低或更高频率工作，再增加异步桥。过早引入两个时钟域会同时
增加握手、复位、约束和调试难度。

## 5. 先掌握五个必要概念

### 5.1 Memory-mapped I/O

CPU 看见的是统一 32-bit 地址空间。访问不同地址，互连选择不同硬件：

```c
*(volatile unsigned int *)0x10000000 = 'A';  // UART
*(volatile unsigned int *)0x20002008 = 1;    // APU start
```

这两句在 CPU 看来都是 store，区别只在地址译码。

### 5.2 Master 与 slave

PicoRV32 是 master，因为它主动产生地址和读写请求。BRAM、UART、APU 是 slave，
因为它们只能被访问并返回响应。

### 5.3 valid/ready 握手

PicoRV32 发请求时保持：

```text
mem_valid = 1
mem_addr / mem_wdata / mem_wstrb 保持稳定
```

slave 或互连完成请求时拉高 `mem_ready`。只有 `mem_valid && mem_ready` 同拍为 1，
该次事务才算结束。若从设备需要等待，CPU 会停住，不会丢失请求。

### 5.4 地址相位与数据相位

AHB 写事务中，地址和控制先出现，写数据在后一拍出现。现有 APU 的 `ahb_slave.sv`
正是把写地址锁存，并把写使能延迟一拍后使用 `hwdata`。

如果桥接器把地址、写使能和写数据当成完全同拍信号，APU 会把数据写到错误地址。

### 5.5 启动代码、链接脚本与 C 程序

CPU 复位后不会自动理解 C。你需要：

```text
reset vector
 -> startup.S 设置栈指针、清零 .bss、初始化 .data
 -> main()
 -> UART/APU 驱动
```

链接脚本决定 `.text/.rodata/.data/.bss/stack` 放在哪些地址；硬件 BRAM 地址和链接脚本
必须完全一致。

## 6. 建议内存映射

第一版建议使用以下全局地址：

| 起始地址 | 结束地址 | 大小 | 模块 | 访问属性 |
| --- | --- | ---: | --- | --- |
| `0x0000_0000` | `0x0000_FFFF` | 64 KiB | Boot/Data BRAM | RWX |
| `0x1000_0000` | `0x1000_0FFF` | 4 KiB | UART | RW |
| `0x1000_1000` | `0x1000_1FFF` | 4 KiB | Timer | RW |
| `0x1000_2000` | `0x1000_2FFF` | 4 KiB | GPIO/LED | RW |
| `0x2000_0000` | `0x2000_3FFF` | 16 KiB | APU | RW |
| 其他地址 | - | - | Default slave | 返回错误值并完成 |

如果使用 128 KiB BRAM，则程序区结束地址改为 `0x0001_FFFF`，栈顶可设为
`0x0002_0000`。

### 6.1 APU 全局地址与局部地址

现有 APU 内部只解码低 14 bit，因此互连必须做地址平移：

```text
apu_local_addr = cpu_mem_addr - 0x2000_0000
```

于是：

| CPU 全局地址 | APU 局部地址 | 含义 |
| --- | --- | --- |
| `0x2000_0000` | `0x0000` | 当前 `RAM_SEL` 指向对象的数据窗口 |
| `0x2000_2000` | `0x2000` | `RAM_CTRL` |
| `0x2000_2004` | `0x2004` | `RAM_SEL` |
| `0x2000_2008` | `0x2008` | `APU_READY` |
| `0x2000_200C` | `0x200C` | `CPL` |

不能把全局地址 `0x2000_2008` 原样交给只取 `haddr[13:0]` 的 APU，然后假设高位
会被内部正确解码。虽然截低位在这个特定基址下可能碰巧得到 `0x2008`，架构上仍应
由互连明确产生局部地址，避免以后换基址时静默出错。

### 6.2 UART 寄存器建议

| 偏移 | 名称 | 属性 | 作用 |
| ---: | --- | --- | --- |
| `0x00` | `UART_TXDATA` | WO | 写低 8 bit 发送字符 |
| `0x04` | `UART_RXDATA` | RO | 读低 8 bit 接收字符 |
| `0x08` | `UART_STATUS` | RO | bit0 TX ready，bit1 RX valid |
| `0x0C` | `UART_BAUDDIV` | RW | 波特率分频 |

第一阶段可只实现 TX 和 `TX ready`。完整模型下载阶段再实现 RX。

### 6.3 Timer 寄存器建议

| 偏移 | 名称 | 属性 | 作用 |
| ---: | --- | --- | --- |
| `0x00` | `MTIME_LO` | RO | 自由运行周期计数低 32 bit |
| `0x04` | `MTIME_HI` | RO | 周期计数高 32 bit |
| `0x08` | `CMP_LO` | RW | 比较值低 32 bit |
| `0x0C` | `CTRL` | RW | bit0 enable，bit1 irq enable |

第一阶段即使不开中断，也可用 timer 统计 CPU 搬运时间和 APU 计算时间。

## 7. SoC 互连怎么设计

### 7.1 PicoRV32 native 接口

关键接口为：

```systemverilog
output        mem_valid;
output        mem_instr;
input         mem_ready;
output [31:0] mem_addr;
output [31:0] mem_wdata;
output [ 3:0] mem_wstrb;
input  [31:0] mem_rdata;
```

语义：

- `mem_valid=1`：当前有一笔请求；
- `mem_instr=1`：该请求是取指；
- `mem_wstrb=0`：读；
- `mem_wstrb!=0`：写，四个 bit 分别控制四个 byte；
- `mem_ready=1`：返回完成；
- 读数据只需在 `mem_valid && mem_ready` 时有效。

### 7.2 地址译码

组合译码示例：

```text
0x0000_xxxx -> BRAM
0x1000_0xxx -> UART
0x1000_1xxx -> Timer
0x1000_2xxx -> GPIO
0x2000_xxxx -> APU bridge
otherwise   -> default slave
```

返回路径必须保证一拍只选择一个 slave：

```text
mem_ready = ram_ready | uart_ready | timer_ready | gpio_ready | apu_ready;
mem_rdata = 按当前锁存 slave 选择返回数据；
```

建议请求开始时锁存 slave ID。不要一直用正在变化的组合地址选择返回数据，因为
同步 BRAM/APU 的响应可能晚一拍，此时 CPU 地址可能已经准备下一笔事务。

### 7.3 Default slave 必须存在

未映射访问不能让 `mem_ready` 永远为 0，否则 CPU 会永久卡死，而且很难从 UART 看出
原因。第一版 default slave 可以：

```text
读：返回 0xDEAD_BEEF
写：丢弃
响应：下一拍 mem_ready=1
同时置位 bus_fault 寄存器或点亮错误 LED
```

PicoRV32 native 接口没有标准 bus error 输入，因此最简单的方式是完成事务并记录错误。

### 7.4 BRAM 访问

推荐使用同步读 BRAM：

```text
T0：mem_valid，锁存地址
T1：BRAM 输出有效，mem_ready=1，mem_rdata=BRAM 输出
```

写入时根据 `mem_wstrb[3:0]` 更新对应 byte。不能只支持 32-bit 全字写，因为 C 编译器
会生成 `sb`、`sh`，UART 也可能使用 byte access。

### 7.5 APU 访问只允许 32-bit 对齐全字

现有 APU 明确不支持 partial access。APU bridge 必须检查：

```text
mem_addr[1:0] == 2'b00
mem_wstrb == 4'b0000 或 4'b1111
```

若软件对 APU 使用 `uint8_t *` 或未对齐结构体，必须判为软件错误。驱动统一使用
`volatile uint32_t *`。

## 8. CPU-to-AHB Bridge 设计

### 8.1 为什么必须有桥

PicoRV32 native 总线只有 valid/ready；APU 顶层暴露的是 AHB 风格接口：

```text
hsel, haddr, htrans, hwrite, hsize, hburst, hwdata
hrdata, hresp, hreadyout
```

二者不能直接连线。桥接器负责：

- 锁存 CPU 请求；
- 生成 AHB 地址相位；
- 写事务在下一拍提供 `hwdata`；
- 等待读数据真正稳定后再给 CPU `mem_ready`；
- 将 `hrdata` 返回 `mem_rdata`；
- 将 CPU 全局地址转换为 APU 局部地址。

### 8.2 推荐状态机

```text
IDLE
  | mem_valid && apu_select
  v
AHB_ADDR
  | 发 hsel=1, htrans=NONSEQ, haddr, hwrite, hsize=WORD
  +--------------------------+
  | read                     | write
  v                          v
READ_WAIT                  WRITE_DATA
  | 等 APU 数据稳定           | 输出 hwdata
  v                          v
RESP                       RESP
  | mem_ready=1              | mem_ready=1
  v                          v
IDLE                       IDLE
```

锁存寄存器至少包括：

```text
req_addr
req_write
req_wdata
req_wstrb
```

CPU 在 `mem_ready` 前会保持输出，但桥自身锁存请求更容易保证 AHB 后续拍稳定，也方便
未来插入 wait state。

### 8.3 当前 APU AHB 接口的特殊风险

当前 `rtl/ahb_slave.sv` 声明：

- 只支持 word access；
- 没有 wait process；
- `hready` 固定为 1；
- 写地址锁存一拍，写使能延迟一拍后使用 `hwdata`。

更关键的是，内部 RAM 为同步读，而 `hready` 没有反映真实读延迟。现有 testbench 在
AHB 读后额外等待并选择采样边沿，因此能够工作，但这不等价于一个可直接挂标准 AHB
master 的严格零等待从设备。

因此有两条路线：

**推荐路线 A：在 SoC 集成前规范化 APU bus wrapper。**

- APU 内核数据通路保持不变；
- 重写或包裹 `ahb_slave_top`；
- 对寄存器读和 RAM 读给出明确 `HREADYOUT` 延迟；
- 写地址/数据严格遵守 AHB 数据相位；
- 用独立 AHB 单元测试验证 single read/write 和 burst。

**保守路线 B：桥接器复现当前 testbench 节奏。**

- CPU 每次访问 APU都由 bridge 插入固定等待拍；
- 读事务在 APU 内部同步 RAM 输出稳定后才响应 CPU；
- 写事务明确生成地址拍和数据拍；
- 不依赖 APU 固定为 1 的 `hready` 判断读数据何时有效。

路线 B 改动小，但它是“适配当前实现”，不是通用 AHB 互连。报告中必须如实写明。

### 8.4 不要一开始做 burst

CPU C 驱动先使用连续的 single word 访问。APU 参数很多，single transfer 会慢，但
更容易正确。功能通过后，可以在 bridge 或 DMA 中增加 burst。

PicoRV32 自身不会自动把普通 C 循环变成 AHB burst。要得到真正 burst，通常需要
DMA 或带合并能力的 bus master，这属于后续优化。

## 9. 时钟、复位与 ARM 禁用

### 9.1 时钟建议

优先级：

1. 开发板直接连接到 PL 管脚的独立晶振；
2. 外部 PMOD/扩展口输入时钟；
3. 最后才考虑 PS FCLK，但这不能满足“运行时完全不依赖 PS 时钟”的严格表述。

推荐：

```text
board_clk -> MMCM/Clock Wizard -> soc_clk 25/50 MHz
```

第一版只有一个 `soc_clk`。UART 分频、timer 和 APU 都从它派生使能，不要用逻辑
门直接与时钟相与产生新时钟。

### 9.2 SoC 复位

外部按钮/JTAG reset 通常是异步输入。内部采用：

```text
异步拉低复位 + 每个时钟域同步释放
```

复位释放顺序建议：

1. 外部复位有效；
2. MMCM 锁定；
3. reset synchronizer 再等待 2 至 4 拍；
4. 释放 BRAM、互连、UART、APU；
5. 最后释放 PicoRV32。

CPU 最后释放可以避免它在 BRAM 或外设仍处于复位时发出第一笔取指。

### 9.3 如何证明 ARM 未参与

报告和演示至少提供：

- Vivado utilization hierarchy，显示 `picorv32` 和 APU 位于 PL；
- 顶层原理图，数据通路中不存在 PS AXI GP/HP port；
- PL 时钟约束来源是外部 PL clock pin；
- 通过 JTAG 下载 bitstream 后，不启动 PYNQ Linux 应用；
- UART 上电日志由 PicoRV32 固件输出；
- CPU 软件读取 `cycle` 计数器，输出 RISC-V 专属运行证据；
- 保持 ARM 核复位/停止的 XSCT 或板级配置记录。

严格的 ARM reset/clock gate 操作与开发板 boot mode、Zynq 器件和下载方式相关，必须
查对应板卡和 AMD Zynq TRM。不要仅凭“我没有调用 ARM 程序”就写成“ARM 时钟已关闭”。

## 10. 裸机软件工具链

### 10.1 软件目录建议

```text
soc/
|-- firmware/
|   |-- startup.S          # 复位入口、栈、.data/.bss 初始化
|   |-- link.ld            # 内存布局
|   |-- main.c             # 主程序
|   |-- uart.c/.h          # UART 驱动
|   |-- timer.c/.h         # 计时驱动
|   |-- apu.c/.h           # APU 驱动
|   |-- model_manifest.h   # 模型层描述
|   `-- Makefile
|-- tools/
|   |-- elf_to_mem.py      # ELF/bin 转 BRAM 初始化文件
|   |-- pack_model.py      # 文本参数转二进制包
|   `-- uart_loader.py     # PC 向 RISC-V 发送模型包
`-- rtl/
```

### 10.2 工具链选择

需要 bare-metal RISC-V GCC：

```text
riscv32-unknown-elf-gcc
```

部分 Linux 发行版只提供：

```text
riscv64-unknown-elf-gcc
```

它通常也可通过 `-march=rv32imc -mabi=ilp32` 生成 RV32 程序。必须用
`readelf -h` 和 `objdump` 检查实际 ELF，而不是只看编译器名字。

### 10.3 编译流程

```text
startup.S + main.c + drivers
        |
        v
riscv*-unknown-elf-gcc
        |
        v
firmware.elf
   |          |
   |          +--> objdump -> firmware.dis
   |
   +--> objcopy -> firmware.bin
                    |
                    +--> elf_to_mem.py -> firmware.mem/.hex
                                             |
                                             v
                                      FPGA BRAM 初始化
```

示例编译参数：

```make
CFLAGS := -march=rv32imc -mabi=ilp32 \
          -Os -ffreestanding -nostdlib -nostartfiles \
          -fno-builtin -Wall -Wextra

LDFLAGS := -T link.ld -nostdlib -Wl,--gc-sections
```

初期不要依赖完整 `printf`，它会显著增大程序。自己实现：

```c
void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_hex(uint32_t value);
void uart_put_dec(uint32_t value);
```

### 10.4 链接脚本最小布局

64 KiB BRAM 示例：

```ld
MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        KEEP(*(.init))
        *(.text*)
        *(.rodata*)
    } > RAM

    .data : {
        *(.data*)
    } > RAM

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
```

最终版本应给栈预留明确空间，并检查 map 文件中 `.text + .data + .bss + stack` 未超过
BRAM。模型权重不要全部链接进 64 KiB 程序 RAM。

## 11. APU C 驱动怎么写

### 11.1 基础 MMIO

```c
#include <stdint.h>

#define APU_BASE       0x20000000u
#define APU_WINDOW     (APU_BASE + 0x0000u)
#define APU_RAM_CTRL   (APU_BASE + 0x2000u)
#define APU_RAM_SEL    (APU_BASE + 0x2004u)
#define APU_READY      (APU_BASE + 0x2008u)
#define APU_CPL        (APU_BASE + 0x200Cu)

static inline void mmio_write32(uint32_t addr, uint32_t value)
{
    *(volatile uint32_t *)addr = value;
}

static inline uint32_t mmio_read32(uint32_t addr)
{
    return *(volatile uint32_t *)addr;
}
```

`volatile` 不能删除。否则编译器可能合并、重排或删除它认为“没有普通内存效果”的
寄存器访问。

### 11.2 APU RAM 选择

现有片选：

| `RAM_SEL` | 对象 |
| ---: | --- |
| `0..63` | 64 个 SIMD/BN channel |
| `64..127` | 64 个 WeightSRAM bank |
| `128` | ActSRAM |
| `129` | OutSRAM |
| `130` | WorkSheet |

### 11.3 64-bit RAM 写入顺序

AHB 是 32 bit，而 Feature/Weight SRAM 是 64 bit。当前 `ram_mux` 规定：

```text
先写偶数 32-bit 地址：保存 low32
再写奇数 32-bit 地址：提交 {high32, low32}
```

C 驱动：

```c
static void apu_write64(uint32_t word64_index, uint64_t value)
{
    volatile uint32_t *window = (volatile uint32_t *)APU_WINDOW;
    window[2u * word64_index + 0u] = (uint32_t)value;
    window[2u * word64_index + 1u] = (uint32_t)(value >> 32);
}
```

这两个写不能颠倒，也不能在中间切换 `RAM_SEL`。`ram_wdata_r` 被所有 64-bit RAM
共享，中途切换 bank 会把不同目标的两个半字拼在一起。

### 11.4 装载顺序

```text
1. RAM_CTRL = 3，CPU 取得数据 RAM 和权重 RAM 控制权
2. RAM_SEL = 128，写初始输入
3. 对每个 output group：
      对每个 Weight bank 0..63：
          RAM_SEL = 64 + bank
          写该 bank 对应权重
4. 对每个 output group：
      对每个 SIMD channel 0..63：
          RAM_SEL = channel
          写阈值/方向参数
5. RAM_SEL = 130，连续写 WorkSheet 地址 0..N-1
6. RAM_CTRL = 0，归还 APU 内部 RAM 控制权
7. APU_READY = 1
8. 等待完成
9. RAM_CTRL = 3
10. RAM_SEL = 128 或 129，读回最新结果
```

必须从 WorkSheet 地址 0 连续写，当前安全上限按 15 条处理。不要在 APU 运行时访问
内部 RAM。

### 11.5 完成等待与超时

轮询版：

```c
int apu_wait_done(uint32_t timeout)
{
    while (timeout-- != 0u) {
        if ((mmio_read32(APU_CPL) & 1u) != 0u)
            return 0;
    }
    return -1;
}
```

但当前 `CPL` 读取会清除 sticky 完成位。更稳妥的方案是：

- bridge/SoC 将顶层 `int_cal` 映射到独立只读状态寄存器；或
- 固件只在确认 `int_cal` 后读取一次 `CPL`；或
- 增加 APU IRQ，完成中断进入 PicoRV32。

第一版可轮询独立 SoC 状态寄存器，第二版再实现中断。任何等待都必须有超时和错误
打印，不能使用无边界死循环。

### 11.6 输出组顺序

当前 128/256 channel 的 SRAM 物理组顺序与 golden canonical 顺序不同。读取每个
像素时需要按组逆序，再对每个 64-bit group 输出 high32、low32，具体规则见：

- `docs/design/final/04_DATA_AND_MEMORY_LAYOUT.md`
- `docs/design/final/08_VERIFICATION_AND_REBUILD.md`

若忽略这一点，APU 内部计算可能完全正确，但 PC 端比较会出现大面积 mismatch。

## 12. 模型参数从哪里来

这是最容易被低估的问题。当前文本参数总计 113,408 个 32-bit word，二进制数据约
443 KiB；文本文件本身更大。64/128 KiB BRAM 无法同时容纳程序和全部模型。

### 12.1 不推荐方案

- 把所有权重直接写成 C 数组并链接进程序；
- 继续依赖 ARM/Linux 从文件系统搬运；
- 假设板载 QSPI/SD 一定能被 PL 直接访问；很多 Zynq 板卡的存储连接在 PS 管脚；
- 为了省事把全部参数固化成大量寄存器。

### 12.2 推荐分阶段方案

**阶段 1：小测试参数固化进 BRAM。**

只放一小组 APU smoke test，验证 CPU-to-APU 总线和结果。

**阶段 2：UART 从 PC 流式下载。**

PC Python 程序读取当前 `data/param_files/`，转换为紧凑二进制协议，通过 USB-UART
发送给 PL UART。RISC-V 接收一层/一条 op 的参数后立即写入 APU，执行完成后继续接收
下一层，不需要同时保存整个模型。

**阶段 3：可选外部 SPI Flash。**

若开发板有连接到 PL 的 SPI Flash，再实现 SPI master 或 XIP。没有确认原理图之前
不要把它写成必选路线。

### 12.3 UART 包协议建议

```text
Header:
  magic       4 bytes  = "APU0"
  packet_type 1 byte   = input/weight/bn/instruction/run/read
  target      1 byte   = RAM_SEL
  flags       2 bytes
  word_count  4 bytes
  checksum    4 bytes

Payload:
  word_count 个 little-endian 32-bit word
```

RISC-V 固件流程：

```text
收 header
 -> 检查 magic/长度
 -> 流式接收 payload
 -> 边接收边 MMIO 写 APU
 -> 校验 checksum
 -> UART 返回 ACK/ERROR
```

不要把整包先存入 BRAM。权重文件最大单项远超 64 KiB，应使用几十或几百 word 的
小缓冲流式处理。

## 13. 建议新增的工程结构

不要把 SoC 文件直接混在当前 `rtl/` 根目录。建议：

```text
soc/
|-- rtl/
|   |-- top/
|   |   `-- riscv_apu_soc_top.sv
|   |-- cpu/
|   |   |-- picorv32.v
|   |   `-- picorv32_wrapper.sv
|   |-- bus/
|   |   |-- soc_interconnect.sv
|   |   |-- native_to_apu_ahb.sv
|   |   `-- default_slave.sv
|   |-- memory/
|   |   `-- boot_ram.sv
|   |-- peripheral/
|   |   |-- uart.sv
|   |   |-- timer.sv
|   |   `-- gpio.sv
|   `-- clk_rst/
|       |-- clock_gen.sv
|       `-- reset_sync.sv
|-- firmware/
|-- tb/
|   |-- tb_picorv32_smoke.sv
|   |-- tb_soc_uart.sv
|   |-- tb_soc_apu_mmio.sv
|   `-- tb_soc_inference.sv
|-- fpga/
|   |-- constraints/
|   |-- tcl/
|   `-- README.md
|-- tools/
`-- Makefile
```

现有 `rtl/Top_student.sv` 作为 APU 子系统实例化到 `riscv_apu_soc_top.sv`。在 SoC
集成稳定前，不要把 APU 内部模块和 SoC 互连同时大改，否则问题无法隔离。

## 14. 分阶段实施计划

每个阶段必须有清晰的退出条件。上一阶段未通过，不进入下一阶段。

### 阶段 0：冻结现有 APU 基线

任务：

1. 执行 `CCACHE_DISABLE=1 make check`。
2. 保存六个 PASS 结果。
3. 记录当前 RTL commit、Verilator 版本和仿真时钟。
4. 不修改 golden 文件。

退出条件：当前 APU 独立回归 0 mismatch。

### 阶段 1：只验证 PicoRV32

任务：

1. 引入固定版本的 `picorv32.v`，记录 commit 和许可证。
2. 建立 64 KiB BRAM。
3. 编写 `startup.S`、`link.ld`、`main.c`。
4. 在仿真中执行：RAM 自测、加减乘除、循环、函数调用。
5. 用仿真字符端口打印 `HELLO RISCV`。

退出条件：C 程序进入 `main()`，打印成功，trap 未触发。

### 阶段 2：加入 UART、Timer 和地址译码

任务：

1. 实现 BRAM/UART/Timer/default slave 地址译码。
2. UART 输出十六进制和十进制。
3. Timer 测量一段 C 循环耗时。
4. 访问未映射地址，验证 CPU 不会死锁。

退出条件：固件能打印每个外设的 smoke test 结果。

### 阶段 3：APU MMIO 桥单元测试

任务：

1. 实现 `native_to_apu_ahb.sv`。
2. 不接完整 CPU，先用小 TB 驱动 bridge 的 native 端。
3. 验证 APU 寄存器 single read/write。
4. 验证 64-bit low32/high32 合并。
5. 验证同步 RAM 读等待拍。
6. 验证非法 byte/halfword 写被拒绝或记录错误。

退出条件：bridge 单元测试覆盖寄存器、Act、Out、Weight、BN、WorkSheet。

### 阶段 4：RISC-V 控制 APU smoke test

任务：

1. CPU 写 `RAM_CTRL` 并读回。
2. CPU 向 ActSRAM 写一个 64-bit word，再读回。
3. CPU 向一个 Weight bank 写一个 word，再读回。
4. CPU 向 WorkSheet 写一条最小指令。
5. UART 打印每一步结果。

退出条件：所有读回值一致，APU bridge 无超时。

### 阶段 5：单层卷积

任务：

1. 将 layer1.0 第一条卷积所需参数转换成二进制。
2. 初期可将该最小参数集放入仿真 memory。
3. C 驱动按当前 TB 的循环顺序装载权重和 BN。
4. 写 WorkSheet，启动，等待完成。
5. 读回输出并比较 `layer1.0_tanh1_output`。

退出条件：单层输出 bit mismatch 为 0。

### 阶段 6：完整网络和参数流式下载

任务：

1. 实现 PC `pack_model.py`。
2. 实现 UART RX 和 `uart_loader.py`。
3. layer1+2 可按当前 8 条 worksheet 一批运行。
4. layer3 四个 op 分别重装参数并运行。
5. 每个阶段输出 CRC 和 cycle count。
6. 读回六个检查点并与当前 compare 脚本对齐。

退出条件：六个检查点 0 mismatch，或课程明确要求的最终推理结果完全正确。

### 阶段 7：FPGA 上板

任务：

1. 添加目标板时钟、复位、UART、LED 的 XDC。
2. 先只综合 PicoRV32 + UART。
3. 再加入 APU，检查 BRAM/LUT/FF/DSP 使用率。
4. 25 MHz 通过后提升到 50 MHz。
5. 运行 UART 自检和完整推理。

退出条件：上电/JTAG 配置后，无 ARM 应用参与即可输出推理结果。

### 阶段 8：报告与答辩材料

任务：

1. 固化 block diagram、memory map、时序图。
2. 保存 Vivado utilization/timing 报告。
3. 保存 UART log、波形和对拍结果。
4. 录制从下载 bitstream 到完成推理的视频。
5. 列出限制和未来工作，不能把未实现功能写成已完成。

退出条件：每一条验收标准都有对应文件、日志、截图或波形证据。

## 15. 验证策略

### 15.1 不要只做顶层仿真

建议测试矩阵：

| 层级 | 测试 | 必查内容 |
| --- | --- | --- |
| CPU | PicoRV32 C smoke | 取指、栈、函数、乘除、trap |
| BRAM | byte/half/word | `mem_wstrb`、同步读延迟 |
| UART | TX/RX loopback | 波特率、busy、丢字节 |
| Interconnect | 每个地址区间 | 唯一选中、返回复用、非法地址 |
| APU bridge | single read/write | 地址拍、数据拍、read wait |
| APU bridge | 64-bit RAM | low/high 顺序、切换 RAM_SEL |
| Firmware | APU register smoke | MMIO 地址和 volatile |
| Integration | 单层卷积 | 参数顺序、完成、输出布局 |
| Regression | 完整网络 | 六个 checkpoint |

### 15.2 建议断言

```text
S1 mem_valid && !mem_ready 时，桥锁存请求不变化。
S2 每笔 CPU 请求只能选中一个 slave。
S3 每笔已接受请求最终必须产生 mem_ready。
S4 APU 写仅允许 addr[1:0]==0 且 wstrb==1111。
S5 AHB 写数据拍使用与地址拍相同的锁存请求。
S6 APU 运行时 CPU 不访问 APU 内部 RAM 窗口。
S7 APU_READY 只产生一次启动写。
S8 每次启动必须在有限周期内完成或触发 timeout。
S9 WorkSheet 从地址 0 连续装载。
S10 64-bit RAM 的 high32 写之前必须已有同目标 low32。
```

### 15.3 逐层定位原则

遇到完整推理失败时按以下顺序查：

1. CPU 是否还在运行，PC 是否推进；
2. `mem_valid/mem_ready` 是否死锁；
3. 地址译码是否选择 APU；
4. AHB 地址相位和写数据相位是否正确；
5. `RAM_SEL/RAM_CTRL` 是否符合软件阶段；
6. 权重 low/high half 是否颠倒；
7. WorkSheet 条数和地址是否正确；
8. APU 是否产生 `ComputeDone/WorkSheetDone/int_cal`；
9. 读回 SRAM 是否选对；
10. 物理通道组顺序是否转换。

不要一看到最终 mismatch 就修改 Ctrl。先证明 CPU 发出的 AHB 事务与原 testbench 完全
一致。

## 16. FPGA 综合前必须处理的风险

### 16.1 存储器是否真正推断为 BRAM

当前 `FeatureProcessor` 和 `SIMD` 对数组执行复位清零。很多 FPGA BRAM 不支持整个
memory 的异步逐项复位，综合器可能把它展开成大量 FF/LUT，造成资源溢出。

上板前必须查看：

- Vivado inferred RAM 报告；
- BRAM 数量；
- FF/LUT 是否异常增长；
- memory 是否被实现为 distributed RAM 或 registers。

正确工程做法通常是：memory 内容不复位，由软件装载；只复位地址、valid 和控制
寄存器。改造必须保持现有 APU 回归通过。

### 16.2 AHB wrapper 并非严格通用从设备

现有 AHB wrapper 的固定 ready 与同步 RAM 延迟不完全匹配。先通过 bridge 单元测试
锁定当前行为，再决定规范化 wrapper。不能直接接入一个标准 AXI-to-AHB IP 后假设
时序一定正确。

### 16.3 APU 容量与目标 FPGA

主要存储包括：

- 64 个 WeightSRAM，每个 `256 x 64 bit`，总计约 1 Mbit；
- 两个 Feature SRAM，总计约 128 Kbit；
- Boot/Data BRAM 64/128 KiB；
- SIMD 参数 RAM 和其他控制状态。

此外有 64 路计算核和加法树。必须在选板前确认 BRAM、LUT 和 FF 足够。不要等到
所有 RTL 完成后才第一次综合。

### 16.4 时序关键路径

APU 的 XOR/popcount、加法树、Accumulator 路径可能限制频率。第一版降低 SoC 时钟
比立刻修改 APU 流水更安全。若插入流水，会影响 Ctrl、InBuf、WeightBuffer 和写回
对齐，必须重做完整回归。

## 17. Makefile 应覆盖的完整流程

最终建议提供这些目标：

```text
make toolchain-check    检查 RISC-V GCC、objcopy、objdump
make firmware           生成 ELF、BIN、MEM、反汇编和 map
make sim-cpu            运行 CPU C 程序 smoke test
make sim-bus            运行互连和 APU bridge 单测
make sim-soc            运行 RISC-V + APU 集成仿真
make check-apu          保留现有 APU 六点回归
make check-soc          固件 + SoC + APU 总回归
make model              生成 UART 模型二进制包
make fpga               调 Vivado batch Tcl 生成 bitstream
make program            JTAG 下载 bitstream
make uart-load          PC 发送模型并保存运行日志
make clean              只清生成目录
```

工具链验收不只是“能编译”。应保留：

- `firmware.elf`；
- `firmware.map`；
- `firmware.dis`；
- `firmware.bin`；
- `firmware.mem`；
- 编译器版本；
- 固件 Git commit；
- bitstream 对应的 RTL commit。

## 18. 十周建议进度

| 周次 | 目标 | 可交付物 |
| ---: | --- | --- |
| 1 | 学习 PicoRV32 native 总线和裸机启动 | 架构图、memory map、工具链检查 |
| 2 | CPU + BRAM 仿真运行 C | `HELLO RISCV` 仿真日志、反汇编 |
| 3 | UART/Timer/interconnect | 外设自检日志、地址译码波形 |
| 4 | PicoRV32 + UART 上板 | 板上 UART 输出、LED 心跳 |
| 5 | APU bridge 单元测试 | AHB 读写时序图、自动化测试 |
| 6 | CPU 控制 APU RAM/寄存器 | MMIO smoke test 日志 |
| 7 | 单层卷积 | 单层 0 mismatch |
| 8 | UART 模型流式下载 | pack/load 工具和协议文档 |
| 9 | 完整推理 | 六点回归、cycle count |
| 10 | ARM 禁用证明与报告 | utilization、timing、演示视频、报告 |

如果时间不足，优先级是：

```text
CPU 跑 C
 > 总线访问 APU
 > 单层正确
 > 完整推理
 > UART 参数下载
 > 中断/DMA/性能优化
```

中断、DMA 和高频不是最小验收项。一个低频但结果完全正确、证据完整的 SoC，工程
价值高于一个架构复杂但无法稳定复现的系统。

## 19. 最终报告建议目录

```text
1. 项目背景与目标
2. 原 APU 架构与接口分析
3. RISC-V 核选型：PicoRV32 与 Rocket 对比
4. SoC 总体架构和模块划分
5. 地址空间与总线互连
6. CPU-to-AHB Bridge 设计与时序
7. 时钟、复位和 ARM 禁用方案
8. 片上存储与模型参数流式搬运
9. 裸机软件、链接脚本和 APU 驱动
10. 仿真验证与 FPGA 上板流程
11. 功能结果：C 程序、单层、完整推理
12. 性能、资源和时序分析
13. 问题定位与修复记录
14. 当前限制与后续优化
```

报告中至少放这些图：

- SoC block diagram；
- 全局 memory map；
- PicoRV32 valid/ready 读写时序；
- AHB 写地址/数据相位；
- CPU-to-AHB bridge 状态机；
- APU 软件装载和启动流程；
- 完整推理参数流；
- ARM 不参与的数据通路证明；
- Vivado utilization 和 timing summary。

## 20. 常见失败方式

1. **直接上 Rocket。** 结果大部分时间消耗在 Chisel、TileLink 和生成环境，而不是
   本项目真正要掌握的 SoC 集成。
2. **CPU 第一版就接 APU。** CPU、BRAM、链接脚本、互连、AHB 任一处错误都会表现为
   “CPU 不跑”，无法定位。
3. **没有 default slave。** 一个错误地址就让 PicoRV32 永久等待。
4. **链接地址与 BRAM 不一致。** ELF 能生成，但 CPU 从空地址取指。
5. **ISA/ABI 不一致。** 软件含乘法或 compressed 指令，而 RTL 未开启。
6. **APU 使用 byte store。** 当前 APU 只支持 32-bit 对齐全字。
7. **64-bit half 顺序错误。** 权重和特征被整体破坏。
8. **运行中仍让 CPU 控制 APU RAM。** AHB 与 Ctrl 同时驱动内部 memory。
9. **把全部模型放进程序 BRAM。** 链接溢出或资源爆炸。
10. **继续依赖 PS FCLK，却声称 ARM 完全禁用。** 验收逻辑不成立。
11. **只看完成信号。** 完成不代表推理正确，必须 bit-exact 比较。
12. **忽略 BRAM 推断报告。** 仿真通过但 FPGA 资源无法实现。

## 21. 最终验收清单

### CPU 与软件

- [ ] 固定 PicoRV32 源码版本和许可证。
- [ ] `RV32IMC/ILP32` 软硬件配置一致。
- [ ] `startup.S`、`link.ld`、C 程序均由自己维护。
- [ ] UART 能打印启动、版本、错误和性能数据。
- [ ] ELF、BIN、MEM、反汇编和 map 可一键生成。

### SoC 与总线

- [ ] Memory map 无重叠。
- [ ] BRAM 支持 byte/half/word 写。
- [ ] Default slave 不会死锁。
- [ ] APU bridge 正确处理 AHB 写数据相位。
- [ ] APU 同步读延迟得到正确等待。
- [ ] 所有请求均有 timeout 或断言。

### APU

- [ ] 保留原 `make check` 全通过。
- [ ] C 驱动遵守 `RAM_CTRL/RAM_SEL` 协议。
- [ ] 64-bit 数据按 low32 后 high32 写。
- [ ] WorkSheet 从地址 0 连续写。
- [ ] 完成状态读取和清除行为明确。
- [ ] 输出物理组顺序正确转换。
- [ ] 完整推理检查点通过。

### FPGA 与 ARM 禁用

- [ ] 使用 PL 独立时钟。
- [ ] 数据通路不实例化 PS AXI port。
- [ ] ARM 不执行模型搬运或 APU 驱动。
- [ ] ARM reset/stop 状态有板级证据。
- [ ] JTAG 配置后 SoC 可独立运行。
- [ ] BRAM/LUT/FF 资源和 timing report 达标。

### 文档与复现

- [ ] 一条命令构建固件。
- [ ] 一条命令运行 SoC 仿真。
- [ ] 一条命令生成 bitstream。
- [ ] 参数打包和 UART 下载脚本可复现。
- [ ] README 写清工具版本、板卡、引脚和操作步骤。
- [ ] 所有验收项均有日志、波形或截图。

## 22. 你现在应该先做什么

不要立即写完整 SoC RTL。按以下顺序完成第一周任务：

1. 确定开发板精确型号和 FPGA 器件型号。
2. 查原理图，确认独立 PL 时钟、UART 和复位按键引脚。
3. 在 Vivado 中只综合当前 APU，记录资源和 BRAM 推断结果。
4. 安装或确认 RISC-V bare-metal GCC。
5. 固定 PicoRV32 版本，阅读 native memory interface。
6. 画出本文第 4 节架构图和第 6 节 memory map 的板级版本。
7. 只实现 `PicoRV32 + BRAM + 仿真字符输出`。
8. 让一个自己编译的 C 程序打印 `HELLO RISCV`。

完成这八项之后，再进入 UART 和 APU bridge。第一阶段的成功标准不是“已经能推理”，
而是你能够从 ELF、反汇编和波形证明：PicoRV32 正在从自己的 BRAM 取指并执行自己的
C 程序。

## 23. 官方参考资料

- PicoRV32 官方仓库：<https://github.com/YosysHQ/picorv32>
- Rocket Chip 官方仓库：<https://github.com/chipsalliance/rocket-chip>
- RISC-V GNU Toolchain：<https://github.com/riscv-collab/riscv-gnu-toolchain>
- AMD Zynq-7000 TRM UG585：<https://docs.amd.com/r/en-US/ug585-zynq-7000-SoC-TRM>
- 当前 APU 最终设计基线：[../../design/final/README.md](../../design/final/README.md)
- APU 编程模型：[../../design/final/02_PROGRAMMING_MODEL.md](../../design/final/02_PROGRAMMING_MODEL.md)
- APU 验证规范：[../../design/final/08_VERIFICATION_AND_REBUILD.md](../../design/final/08_VERIFICATION_AND_REBUILD.md)

