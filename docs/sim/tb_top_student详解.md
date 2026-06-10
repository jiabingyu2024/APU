# `tb_top_student.sv` 测试平台详解

## 1. 概述

`tb_top_student.sv` 是 APU（Accelerated Processing Unit，加速处理单元）芯片项目的顶层仿真测试平台（testbench）。该 TB 通过 **AHB 总线协议**与 DUT (Device Under Test) 通信，模拟 CPU 或 DMA 控制器的行为，完成以下任务：

1. **配置寄存器** —— 设置 RAM 控制模式、选择输入/输出的 SRAM bank
2. **加载输入数据** —— 将图像/特征图数据写入输入 SRAM
3. **加载权重和 BN（Batch Normalization）参数** —— 将卷积核权重和 BN 组合参数写入权重 SRAM 和 SIMD 参数寄存器
4. **下发指令** —— 将卷积层的配置（`opcode`, `kernelSize`, `stride` 等）写入 WorkSheet
5. **启动计算** —— 通知 APU 开始执行，等待 `int_cal` 完成信号
6. **读出结果** —— 从输出 SRAM 读取计算结果并保存到文件

整个 TB 仿真的是一个 **3 层卷积神经网络（CNN）的逐层计算流程**。

---

## 2. 整体运行流程 (数据流)

### 2.1 流程图解

```
 ┌─────────────────────────────────────────────────────────┐
 │                    初始化和复位                          │
 │  时钟生成 → 复位释放 → 等待 20 时钟周期                 │
 └─────────────────────┬───────────────────────────────────┘
                       │
 ┌─────────────────────▼───────────────────────────────────┐
 │                 1. 配置 RAM 控制器                       │
 │                RAM_CTRL_ADDR = 0x3                        │
 └─────────────────────┬───────────────────────────────────┘
                       │
 ┌─────────────────────▼───────────────────────────────────┐
 │             2. 写输入数据到输入 SRAM                      │
 │  从 input_binary.txt 读取 → AHB 突发写入 bank 128        │
 └─────────────────────┬───────────────────────────────────┘
                       │
 ┌─────────────────────▼───────────────────────────────────┐
 │        3. 逐层配置并运行卷积层（Layer1 ~ Layer3）          │
 │                                                          │
 │  for each layer:                                         │
 │    ├─ 读权重文件 → AHB 写权重 SRAM (bank 64~127)         │
 │    ├─ 读 BN 参数文件 → AHB 写 SIMD (bank 0~63)           │
 │    ├─ 写 WorkSheet 指令 (bank 130)                       │
 │    ├─ 启动 APU (APU_READY_ADDR = 1)                      │
 │    ├─ 等待 int_cal 完成信号                              │
 │    └─ (可选) 读结果并保存到文件                            │
 └─────────────────────┬───────────────────────────────────┘
                       │
 ┌─────────────────────▼───────────────────────────────────┐
 │                4. 最终读结果并结束                        │
 │             输出到 data_out.txt                           │
 └─────────────────────┬───────────────────────────────────┘
                       │
                   $finish
```

### 2.2 三层卷积的配置参数

| 层 | 输入 C | 输出 C | H/W | Kernel | Stride | 说明 |
|:--:|:------:|:------:|:---:|:------:|:------:|------|
| layer1.0.conv1 | 64 | 64 | 32 | 3×3 | 1 | 第 1 个卷积 |
| layer1.0.conv2 | 64 | 64 | 32 | 3×3 | 1 | 残差分支 |
| layer1.1.conv1 | 64 | 64 | 32 | 3×3 | 1 | 第 2 个残差块 |
| layer1.1.conv2 | 64 | 64 | 32 | 3×3 | 1 | 残差分支 |
| **layer2.0.conv1** | **64** | **128** | **32** | **3×3** | **2** | **下采样，通道加倍** |
| layer2.0.conv2_res | 128 | 128 | 16 | 3×3 | 1 | 残差（驻留权重） |
| layer2.1.conv1 | 128 | 128 | 16 | 3×3 | 1 | |
| layer2.1.conv2 | 128 | 128 | 16 | 3×3 | 1 | |
| **layer3.0.conv1** | **128** | **256** | **16** | **3×3** | **2** | **再次下采样** |
| layer3.0.conv2_res | 256 | 256 | 8 | 3×3 | 1 | 残差（驻留权重） |
| layer3.1.conv1 | 256 | 256 | 8 | 3×3 | 1 | |
| layer3.1.conv2 | 256 | 256 | 8 | 3×3 | 1 | |

**关键特点：**
- **Layer1** 的 4 个操作作为一个批次（worksheet batch）连续配置，最后统一调用一次 `run_apu()`。
- **Layer2** 与 Layer1 类似，也是 4 个操作一起下发。
- **Layer3** 的权重集过大（outC=256），无法一次性放入 Weight SRAM（256 条目），因此每个子操作**单独加载并立即运行**，并在每个子操作完成后读取中间结果保存到文件。

---

## 3. 各模块详解

### 3.1 时钟与复位生成 (第 5-17 行)

```systemverilog
parameter period = 10;
reg hclk = 1'b1;
reg hresetn = 1'b1;

always #(period/2) hclk = ~hclk;    // 周期为 10ns 的时钟

initial begin
    hresetn = 1'b0;
    #(100 * period)                  // 复位保持 1000ns = 1μs
    hresetn = 1'b1;                  // 释放复位
end
```

- **时钟**: 周期 10ns，频率 100MHz
- **复位**: 低电平有效，保持 1μs 后拉高释放

### 3.2 信号声明 (第 19-56 行)

#### AHB 主接口信号

| 信号 | 方向 | 位宽 | 说明 |
|:----|:----:|:----:|------|
| `hbusreq` | output | 1 | 总线请求 |
| `hgrant` | input | 1 | 总线授权（回环到 hbusreq，无仲裁） |
| `haddr` | output | 32 | 地址总线 |
| `htrans` | output | 2 | 传输类型：`2'b10`=NONSEQ, `2'b11`=SEQ |
| `hwrite` | output | 1 | 写使能：1=写，0=读 |
| `hsize` | output | 3 | 传输大小：`3'b010`=word(4B) |
| `hburst` | output | 3 | 突发类型：SINGLE/INCR/INCR4/INCR8/INCR16 |
| `hwdata` | output | 32 | 写数据 |
| `hrdata` | input | 32 | 读数据 |
| `hresp` | input | 2 | 响应：`2'b00`=OKAY |
| `hready` | input | 1 | 从设备就绪 |
| `hsel` | input | 1 | 从设备选择 |

#### 数据存储数组

```systemverilog
reg [31:0] data_burst_wr[32767:0];       // 权重/输入数据写入缓冲区
reg [31:0] data_burst_SIMD_wr[32767:0];  // BN 参数写入缓冲区
reg [31:0] data_burst_rd[2047:0];        // 读数据缓冲区
```

#### 层配置参数

```systemverilog
parameter saddr = 32'h0000_0000;          // 起始地址
parameter RAM_CTRL_ADDR = 14'h2000;       // RAM 控制寄存器地址
parameter RAM_SEL_ADDR  = 14'h2004;       // RAM 选择寄存器地址
parameter APU_READY_ADDR = 14'h2008;      // APU 启动寄存器地址
parameter CPL_ADDR      = 14'h200c;       // 完成状态寄存器地址
```

这些地址映射到 AHB 从设备内部的寄存器空间（通过 `addr_map.sv` 解码），用于控制数据 RAM 的读写模式和选择目标 SRAM bank。

#### 通道数配置

```systemverilog
integer IN_C = 64;   // 输入通道数
integer OUT_C = 64;  // 输出通道数
integer IN_H = 8;    // 输入高度
integer IN_W = 8;    // 输入宽度
integer inst = 0;    // 指令编号
```

#### 控制与状态信号

```systemverilog
wire int_cal;       // APU 计算完成中断信号（DUT 输出）
assign cal_cpl = 2'b10;  // 计算完成状态编码
```

### 3.3 DUT 例化 (第 200-217 行)

```systemverilog
Top dut_apu_inst (
    .nRst       ( hresetn ),
    .clk        ( hclk    ),
    .hsel       ( htrans[1] ),   // 片选 = htrans[1]
    .haddr      ( haddr   ),
    .htrans     ( htrans  ),
    .hwrite     ( hwrite  ),
    .hsize      ( hsize   ),
    .hburst     ( hburst  ),
    .hwdata     ( hwdata  ),
    .hrdata     ( hrdata  ),
    .hresp      ( hresp   ),
    .hready     ( 1'b1    ),
    .hreadyout  ( hready  ),
    .int_cal    ( int_cal ),
    .hlock      ( 1'b0    ),
    .hprot      ( 4'b0    )
);
```

**特别说明：**
- `hsel` 直接连到 `htrans[1]`，即只要有有效传输就选中该从设备，省去了地址译码器
- `hready` 输入固定为 1，表示主机始终就绪
- `hgrant = hbusreq` 总线授权直接回环，无仲裁器——TB 是唯一的主设备

### 3.4 波形导出 (第 220-230 行)

```systemverilog
`ifdef VERILATOR
initial begin
    $dumpfile("build/sim/top.vcd");
    $dumpvars(0, tb_top);
end
`elsif FSDB
initial begin
    $fsdbDumpfile("top.fsdb");
    $fsdbDumpvars(0, "+mda");
end
`endif
```

支持两种波形格式：
- **Verilator**: 导出 VCD 格式波形到 `build/sim/top.vcd`
- **FSDB**: 导出 FSDB 格式波形（Synopsys VCS/NC-Verilog 常用）

---

## 4. 任务 (Task) 详解

### 4.1 `conv_layer` (第 235-284 行) —— 标准卷积层配置

**功能**: 将卷积层的权重、BN 参数和指令写入相应的 SRAM 和寄存器。

**输入参数**:

| 参数 | 位宽 | 说明 |
|:----|:----:|------|
| `opcode` | 2 | 操作码（`2'b00`=标准卷积） |
| `kernalSize` | 2 | 卷积核大小（`2'd3`=3×3） |
| `logInHW` | 3 | 输入特征图尺寸的 log2 值（如 5→32） |
| `logInC` | 4 | 输入通道数的 log2 值（如 6→64） |
| `logOutC` | 4 | 输出通道数的 log2 值 |
| `stride1` | 2 | 步长参数 1 |
| `stride2` | 2 | 步长参数 2 |
| `wAddr` | 8 | 权重在 Weight SRAM 中的起始地址 |
| `bnAddr` | 5 | BN 参数在 SIMD 寄存器中的起始地址 |
| `worksheet_waddr` | 4 | 指令写入 WorkSheet 的地址 |

**运行流程**:

```
1. 计算 output_groups = (1 << logOutC) / 64   // 输出通道组数
2. 计算 words_per_bank = 2 * k * k * ((1<<logInC)/64)  // 每 bank 权重字数
3. 检查 wAddr + ... > 256 → $fatal (权重 SRAM 溢出)
4. 检查 bnAddr + output_groups > 32 → $fatal (SIMD 寄存器溢出)
5. 设置 RAM_CTRL_ADDR = 3  (ram_mux 写模式)
6. 双重循环：for output_group × for 64 PE
   ├─ 选择 bank (i + 64) → bank 64~127 为权重 SRAM
   └─ AHB 突发写入权重数据
7. 双重循环：for output_group × for 64 PE
   ├─ 选择 bank (i) → bank 0~63 为 SIMD 寄存器
   └─ AHB 突发写入 BN 组合参数
8. 选择 bank 130 (WorkSheet)
9. 写入指令字：
   {opcode, kernelSize, logInHW, logInC, logOutC, stride1, stride2, wAddr, bnAddr}
```

#### 指令字编码

```
31:30   29:28   27:25   24:21   20:17   16:15   14:13   12:5    4:0
┌──────┬──────┬───────┬───────┬───────┬───────┬───────┬───────┬──────┐
│opcode│kSize │logInHW│logInC │logOutC│strd1  │strd2  │ wAddr │bnAddr│
└──────┴──────┴───────┴───────┴───────┴───────┴───────┴───────┴──────┘
```

### 4.2 `conv_resident_layer` (第 286-337 行) —— 驻留权重卷积层

**与 `conv_layer` 的区别**:

```systemverilog
// 标准层: words_per_bank = 2 * k * k * (inC / 64)
// 驻留层: words_per_bank = (2 * k * k + 1) * (inC / 64)
```

多出来的 `+1` 是残差连接所需的额外数据宽度。

此外增加了奇偶检查：

```systemverilog
if ((words_per_bank % 2) != 0)
    $fatal(1, "resident weight count must be even");
```

因为 `ram_mux` 将相邻的两个 32-bit 写操作合并为一个 64-bit 权重字，所以总字数必须为偶数。

### 4.3 `run_apu` (第 339-356 行) —— 启动 APU 并等待完成

**功能**: 通知 APU 开始执行已配置的指令，并等待计算完成。

**流程**:

```
1. RAM_CTRL_ADDR = 0    (切换为计算模式)
2. APU_READY_ADDR = 1   (启动 APU)
3. 循环等待 int_cal 信号变为 1
   ├─ 每时钟周期检查一次
   └─ 超时 10,000,000 周期后报 $fatal
4. 读取 CPL_ADDR 获取完成的指令数 (cpl_data)
5. 打印完成信息
```

### 4.4 `ahb_write` (第 398-440 行) —— AHB 单次写操作

**AHB 写时序**：

```
时钟:  __  ┌─┐  ┌─┐  ┌─┐  ┌─┐  ┌─┐  ┌─┐  ┌─┐  ┌─┐  ┌─┐  ┌─┐
         ─┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘
hbusreq:  _____________⎺⎺⎺⎺⎺⎺⎺⎺⎺______________________
haddr:   XXXXXXXXXXXXX[_addr_]XXXXXXXXXXXXXXX
htrans:  XX[_NONSEQ_]XX[_IDLE_ ]XXXXXXXXXXXXXX
hwdata:  XXXXXXXXXXXXXXXXXXXX[_data_]XXXXXXXXXX
hresp:   XX[_OKAY_]XXXXXXXXXXXXXXXXXXXXXXXXXXX
hready:  ⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺
```

1. 拉高 `hbusreq` 请求总线
2. 等待 `hgrant` 和 `hready` 同时为高
3. 拉低 `hbusreq`，发出地址和控制信号（NONSEQ 传输）
4. 发出数据（`hwdata`）
5. 等待传输完成
6. 清空控制信号

### 4.5 `ahb_read` (第 358-396 行) —— AHB 单次读操作

与写操作类似，但：
- `hwrite = 0`
- 数据从 `hrdata` 读取
- 检查 `hresp != 2'b00` 报错

### 4.6 `ahb_write_burst` (第 568-616 行) —— AHB 突发写操作

**功能**: 连续写入多个 32-bit 数据。

**时序特点**：
- 第一个传输使用 `NONSEQ (2'b10)`
- 后续传输使用 `SEQ (2'b11)`
- 突发类型自动选择：4→INCR4, 8→INCR8, 16→INCR16, 其他→INCR

**数据来源**: 从 `data_burst_wr[start_addr + i]` 读取。

### 4.7 `ahb_write_SIMD_burst` (第 617-664 行) —— SIMD 参数突发写

与 `ahb_write_burst` 完全相同，但数据来源为 `data_burst_SIMD_wr`。

两个独立缓冲区的原因：一次完整的层配置需要先写入权重（`data_burst_wr` 从权重文件读取），再写入 BN 参数（`data_burst_SIMD_wr` 从 BN 文件读取），互不干扰。

### 4.8 `ahb_read_burst` (第 443-487 行) —— AHB 突发读操作

**功能**: 连续读取多个 32-bit 数据到 `data_burst_rd` 数组。

### 4.9 `ahb_read_burst_save` / `ahb_read_burst_save_named` (第 489-565 行) —— 读结果并保存到文件

**功能**: 从输出 SRAM 读取计算结果，保存到文本文件。

**保存格式**：按 64-bit 对齐（偶数个 32-bit 字），每个 32-bit 字以二进制格式写入文件。

**`swap_channel_groups` 参数**：
- `0`: 正常顺序写入
- `1`: 用于 128 通道输出的情况，按通道组交错排列（每组 4 个 32-bit 字：{high2, low2, high1, low1}）

---

## 5. SRAM Bank 地址映射

| Bank 范围 | 用途 | 说明 |
|:---------:|:----|------|
| 0 ~ 63 | SIMD 参数寄存器 | 存储 BN 组合参数（threshold, scale, shift 等） |
| 64 ~ 127 | 权重 SRAM | 存储卷积核权重 |
| 128 | 输入 SRAM | 存储输入特征图 |
| 129 | 输出 SRAM | 存储输出特征图 |
| 130 | WorkSheet | 存储指令序列 |

**控制寄存器地址映射** (通过 AHB 访问):

| 地址 | 名称 | 功能 |
|:---:|:----|------|
| `14'h2000` | RAM_CTRL_ADDR | RAM 控制：`0`=计算模式, `3`=写模式 |
| `14'h2004` | RAM_SEL_ADDR | RAM 选择：选择要操作的 bank |
| `14'h2008` | APU_READY_ADDR | 写 1 启动 APU 计算 |
| `14'h200c` | CPL_ADDR | 读完成状态（已完成的指令数） |

---

## 6. 数据流详解

### 6.1 Layer1 运行流程示例

以 layer1.0 为例，看一条指令的完整数据流：

```
第1步: 读权重文件
  $readmemb("data/param_files/layer1.0.conv1.txt", data_burst_wr)
  → 将权重二进制数据读到 data_burst_wr 数组

第2步: 读 BN 参数文件
  $readmemb("data/param_files/layer1.0.bn1_combined.txt", data_burst_SIMD_wr)
  → 将 BN 参数读到 data_burst_SIMD_wr 数组

第3步: 调用 conv_layer 任务
  conv_layer(2'b00, 2'd3, 3'd5, 4'd6, 4'd6, 2'd1, 2'd0, 8'd0, 5'd0, 0);
  ├─ 计算 output_groups = 64/64 = 1
  ├─ 计算 words_per_bank = 2 × 3 × 3 × (64/64) = 18
  ├─ 写入 18×64 = 1152 个权重字到 bank 64~127
  ├─ 写入 1×64 = 64 个 BN 参数到 bank 0~63
  └─ 写入指令到 bank 130 地址 0

第4步: (Layer1 4 个操作都配置完后)
  run_apu();
  ├─ 切换 RAM 为计算模式
  ├─ 设置 APU_READY = 1
  ├─ 等待 int_cal 高电平
  └─ 读取完成状态
```

### 6.2 Layer3 的特殊处理

Layer3 的 outC=256，意味着 `output_groups = 256/64 = 4`，每个 bank 的权重字数大幅增加。所有子操作（conv1, conv2_res, conv1, conv2）的权重总量超过了 Weight SRAM 的 256 条目上限。

因此 Layer3 采用**单指令运行**模式：

```
for each sub-operation in layer3:
    ├─ 加载权重（地址从 0 开始，复用 SRAM 空间）
    ├─ 加载 BN 参数（地址从 0 开始，复用寄存器空间）
    ├─ 写入指令（地址 0）
    ├─ run_apu()
    ├─ 切换 RAM 为读模式
    ├─ 选择 bank 129 (输入/输出交替)
    └─ ahb_read_burst_save_named() 保存中间结果到文件
```

---

## 7. 仿真文件输出来

| 输出文件 | 内容 |
|:--------|:-----|
| `build/sim/layer3.0_tanh1_hw.txt` | layer3.0.conv1 输出（tanh1 之后） |
| `build/sim/layer3.0_tanh3_hw.txt` | layer3.0.conv2 残差输出（tanh3 之后） |
| `build/sim/layer3.1_tanh1_hw.txt` | layer3.1.conv1 输出（tanh1 之后） |
| `build/sim/data_out.txt` | 最终计算结果 |

---

## 8. 如何运行仿真

该项目支持多种仿真器，典型命令：

```bash
# 使用 Verilator 仿真
make run 或 make verilator

# 使用 VCS 仿真
make vcs

# 查看波形
make wave        # 打开 VCD 波形
make fsdb_wave   # 打开 FSDB 波形
```

详见 `docs/sim/` 目录下的其他文档或项目的 Makefile。

---

## 9. 总线互联说明

TB 中的 AHB 总线做了简化，适合功能验证：

```systemverilog
assign hgrant = hbusreq;   // 无仲裁，请求即授权
assign hsel   = htrans[1]; // 无地址译码，有传输即选中
```

这意味着这个 TB 只在单主设备场景下有效，实际 SoC 集成时需要真实的仲裁器和地址译码器。

---

## 10. 关键设计要点总结

1. **无符号数 vs 有符号数**：权重和输入以二进制补码格式存储在 `data_burst_wr` 中，由 `$readmemb` 读取。

2. **ram_mux 的字合并**：`conv_resident_layer` 要求偶数个权重字，因为 `ram_mux` 会将连续两个 32-bit 写合并为一个 64-bit 权重字。

3. **输出通道组（output_groups）**：APU 一次处理 64 个输出通道，超过 64 通道时按组循环。这决定了权重写入的循环方式和 SRAM 地址计算。

4. **指令地址 vs 数据地址**：权重和 BN 参数的地址是 SRAM 内部地址（相对值），而 AHB 地址是 32-bit 系统地址空间中的绝对值。`ahb_write_burst` 的 `addr` 参数是 AHB 地址，`start_addr` 是 `data_burst_wr` 数组中的索引。

5. **工作模式切换**：
   - `RAM_CTRL_ADDR = 3`：写模式，允许通过 AHB 写入 SRAM
   - `RAM_CTRL_ADDR = 0`：计算模式，SRAM 由 APU 内部逻辑控制

6. **Layer3 的权重地址复用**：因为 Weight SRAM 容量有限（256 个 64-bit 字），当 outC=256 时每个子操作的权重都需要 192+ 字，无法同时容纳 4 个子操作的权重，所以 Layer3 每个子操作独立加载、运行、读出结果。
