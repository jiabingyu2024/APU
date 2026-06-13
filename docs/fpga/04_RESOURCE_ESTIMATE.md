# PYNQ-Z2 资源占用初步评估

## 1. 结论

目标器件是 `xc7z020clg400-1`。当前设计在采用“模型/程序/Feature 使用 BRAM，64 组权重
使用 LUTRAM”的前提下，**有机会放入 XC7Z020，但资源并不宽裕**：

- BRAM 预计约 `109 / 140 BRAM36`，约 **77.9%**；
- 权重 LUTRAM 理论最低约 `16,384 LUT`，已经占全部 LUT 的 **30.8%**；
- 全部 LUT 粗估约 **30,000～43,000 / 53,200**，约 **56%～81%**；
- FF 粗估约 **34,000～42,000 / 106,400**，约 **32%～39%**；
- DSP48 预计接近 **0 / 220**；
- 使用 1 个 MMCM，把 125 MHz 输入转换为 25 MHz SoC 时钟。

这个结论不是 Vivado 综合结果。最大的未知量是存储器能否按预期推断，以及 64 路
popcount、变量除法/取模被 Vivado 优化后的 LUT 数量。

## 2. PYNQ-Z2 PL 资源

| 资源 | XC7Z020 数量 | 当前设计压力 |
|---|---:|---|
| Logic Slice | 13,300 | 中高 |
| 6-input LUT | 53,200 | 高，权重 LUTRAM 和计算阵列是主要占用 |
| Flip-Flop | 106,400 | 中，SIMD 参数阵列约占四分之一 |
| BRAM36 等价 | 140 | 高，预计使用约 109 个 |
| Block RAM 容量 | 630 KiB | 预计固定映射约占 435 KiB，但存在宽深度碎片 |
| DSP48 | 220 | 很低，二值计算没有使用常规乘法器 |

板卡数据来源见 [PIN.md](PIN.md)。LUT 和 FF 数量由每个 slice 包含 4 个 LUT、8 个 FF
换算得到。

AMD 器件资源的官方参考见
[Zynq-7000 SoC Data Sheet: Overview (DS190)](https://docs.amd.com/v/u/en-US/ds190-Zynq-7000-Overview)。

## 3. 存储资源逐项计算

### 3.1 Model ROM

```text
90,880 word × 32 bit = 2,908,160 bit = 355 KiB
```

RAMB36 在约 32-bit 数据宽度下通常按 `1024 × 36` 组织：

```text
ceil(90,880 / 1,024) = 89 BRAM36
```

预计占全部 BRAM 的 `89 / 140 = 63.6%`，是最大的单项资源。

### 3.2 Boot/Data RAM

```text
16,384 word × 32 bit = 524,288 bit = 64 KiB
```

预计需要：

```text
16 BRAM36
```

### 3.3 ActSRAM 与 OutSRAM

每块 `FeatureProcessor`：

```text
1,024 word × 64 bit = 65,536 bit = 8 KiB
```

由于 64-bit 宽度通常需要两个 36-bit BRAM 并行，每块约 2 个 BRAM36，两块合计：

```text
4 BRAM36，16 KiB
```

### 3.4 固定 BRAM 合计

| 存储 | 预计 BRAM36 |
|---|---:|
| Model ROM | 89 |
| Boot/Data RAM | 16 |
| ActSRAM | 2 |
| OutSRAM | 2 |
| 合计 | **109 / 140** |
| 剩余 | **31 BRAM36** |

虽然有效数据只有 `355 + 64 + 16 = 435 KiB`，但 BRAM 有固定的宽度/深度组合，不能按
纯 bit 容量无损打包，因此实际占用比 `435/630` 更高。

### 3.5 64 组 Weight SRAM

每个计算核：

```text
256 word × 64 bit = 16,384 bit = 2 KiB
```

64 个计算核合计：

```text
1,048,576 bit = 128 KiB
```

如果映射成 BRAM，每个 `256×64` 存储通常至少占一个 BRAM36，总计约 64 个：

```text
109 + 64 = 173 BRAM36 > 140
```

因此当前 FPGA 工程定义 `FPGA_DISTRIBUTED_WEIGHT_RAM`，将权重映射为 LUTRAM。一个
LUT6 可保存约 64 bit 的单端口分布式 RAM；256 深度每个数据 bit 至少需要 4 个 LUT：

```text
64 core × 64 bit × 4 LUT = 16,384 LUT
```

这是理论最低值，双地址读写结构和综合打包可能使实际数量更高。

## 4. 逻辑与寄存器估算

### 4.1 64 路计算阵列

每个计算核包含：

- 64 个二值 XOR；
- 一个 64 输入、7-bit 输出的 popcount；
- 一个 12-bit 累加器；
- 一个 64-bit 权重输出缓冲。

64 个核共处理 `64 × 64 = 4,096` 个二值对。`AdderTree.sv` 当前写成循环累加，Vivado
通常会重构为加法树，但实际 LUT 数量依赖优化结果。计算阵列粗估约 **8,000～14,000
LUT**，FF 主要是 4,096-bit WeightBuffer 和 768-bit accumulator。

### 4.2 SIMD/BN 参数

```text
32 × 64 × 13 bit = 26,624 bit
```

当前 `SIMD_Reg` 在复位时使用 `foreach` 清零整个数组。BRAM/LUTRAM 通常不支持运行时
整体复位，因此它很可能展开成约 **26,624 个 FF**，即全部 FF 的 **25.0%**。另外还有
64 个 12-bit 比较器。

### 4.3 PicoRV32 与 SoC 外围

PicoRV32 启用了 RV32IMC、迭代乘法和除法。当前 `ENABLE_MUL=1` 使用移位加法实现，不是
快速 `*` 乘法器，因此预计不会显著占用 DSP。CPU、互连、AHB bridge、UART、timer 和
控制逻辑合计粗估约 **3,000～8,000 LUT**、**2,000～6,000 FF**。

### 4.4 特征地址计算

`FeatureProcessor` 有两份实例，内部包含：

```systemverilog
centerPixel = iReadCenterAddr / colOffset;
centerRow   = centerPixel / inHW;
centerCol   = centerPixel % inHW;
```

除数是运行时信号，Vivado 可能综合出较大的组合除法/取模网络。这部分既可能增加数千 LUT，
也可能成为关键路径。25 MHz 的 40 ns 周期降低了时序压力，但不会减少其面积。

## 5. 资源区间汇总

| 资源 | 乐观估计 | 保守估计 | 器件上限 | 判断 |
|---|---:|---:|---:|---|
| BRAM36 | 109 | 112 | 140 | 可放入，但余量有限 |
| LUT | 30,000 | 43,000 | 53,200 | 有机会，存在较高风险 |
| FF | 34,000 | 42,000 | 106,400 | 正常情况下充足 |
| DSP48 | 0 | 4 | 220 | 非瓶颈 |
| MMCM | 1 | 1 | 视器件时钟资源 | 正常 |

BRAM 的保守值为小型 RAM 或综合辅助结构额外消耗。LUT 区间不包含“存储推断失败后展开
为逻辑”的灾难情况。

## 6. 三个关键风险

### 风险 1：Feature SRAM 未推断为 BRAM

`FeatureProcessor.featureMemory` 的写进程敏感列表包含 `negedge nRst`，但进程内没有对应
复位分支。这不是标准 BRAM 模板。若两块 65,536-bit memory 展开为 FF，将额外需要
131,072 FF，已经超过器件总 FF 数，工程必然无法实现。

综合后必须在层次报告中确认两块 memory 使用 BRAM，而不是 FF/LUT。

### 风险 2：Weight SRAM 未按属性映射 LUTRAM

如果 `FPGA_DISTRIBUTED_WEIGHT_RAM` 未生效，64 组权重会尝试占约 64 个 BRAM36，使总量
达到约 173/140。必须检查 `LUT as Memory` 增长约 16K，并检查 WeightSRAM 层次下没有
大量 BRAM。

### 风险 3：SIMD_Reg 整体复位

当前预计消耗约 26.6K FF。这个数量本身还能容纳，但会增加复位扇出和布局压力。以后若
需要优化，可改为“写入所有有效 BN 参数后才启动计算”，去掉数组整体复位，使其更适合
分布式 RAM。由于每周期要并行读 64 个通道，不能简单替换成单个窄 BRAM。

## 7. Vivado 中如何确认

生成 bitstream 后重点打开：

```text
fpga/output/reports/post_synth_utilization.rpt
fpga/output/reports/post_route_utilization.rpt
fpga/output/reports/post_route_timing_summary.rpt
```

检查命令：

```tcl
report_utilization -hierarchical
report_ram_utilization
report_timing_summary
```

必须确认：

1. 总 `Block RAM Tile` 不超过 140，建议保留至少 10%；
2. Model ROM 约 89 BRAM36；
3. Boot RAM 约 16 BRAM36；
4. 两块 Feature SRAM 合计约 4 BRAM36；
5. Weight SRAM 主要显示为 `LUT as Memory`；
6. SIMD_Reg 是否使用约 26.6K FF；
7. 25 MHz 生成时钟 WNS 非负、TNS 为 0。

## 8. 当前建议

第一版继续按当前结构综合，不必立即大改，因为 25 MHz 下时序要求较宽松，理论资源也有
放入可能。综合后按以下顺序处理：

1. 若 Feature SRAM 未进 BRAM，先修正其同步读写模板；
2. 若 BRAM 超限，确认 Weight SRAM 的 LUTRAM 宏是否生效；
3. 若 LUT 超限，优先优化变量除法/取模和计算并行度；
4. 若 FF/复位布线压力高，再处理 SIMD_Reg 的整体复位；
5. 不要为节省 PL 资源改用 PS DDR，否则会破坏运行时脱离 ARM/PS 的架构要求。

最终资源结论必须以 Vivado post-synthesis 和 post-route 报告替换本报告中的估算区间。
