# APU ASIC 架构与 dev1 普通卷积阶段设计总结

## 1. 文档范围

本文记录当前 `dev1` 工作树中的 APU RTL 架构、普通卷积数据流和实际流水时序，并重点比较当前版本与 `main` 分支在以下三个差异文件上的实现：

```text
rtl/Ctrl.sv
rtl/InBuf.sv
rtl/Top_student.sv
```

比较基线：

```text
main HEAD: 47a816b
dev1 HEAD: ee9bd92
比较对象: 当前 dev1 工作树相对 main，即 git diff main -- rtl
```

当前阶段只确认普通卷积路径。残差卷积 `opcode=01` 虽然已有 RTL 框架，但不属于本文的正确性结论。

## 2. 当前阶段结论

当前 `dev1` 已证明 layer1.0 普通卷积的计算链可以得到正确结果：

```text
ActSRAM
-> FeatureProcessor 窗口读取和 padding
-> InBuf
-> WeightSRAM + WeightBuffer
-> 64 路 XOR/popcount
-> 64 路 Accumulator
-> SIMD 阈值比较
-> OutSRAM
```

单条 `layer1.0.conv1` 聚焦验证曾得到：

| 检查项 | 结果 |
| --- | ---: |
| OutSRAM 写事务 | 1024 次 |
| OutSRAM 写地址 | `0..1023` 连续、无遗漏 |
| 64 路累加值与 `layer1.0_conv1_output` 对比 | `65536/65536` 一致 |
| SIMD 写入值与 `layer1.0_tanh1_output` 对比 | `65536/65536 bit` 一致 |
| 修复 TB 读回后的最终 dump | `0/65536 bit` 不一致 |

因此，当前 layer1.0 已验证问题不在计算核、SIMD 或 SRAM 写入，而此前剩余的部分 mismatch 来自 TB 的 AHB 读回相位和 64/32-bit 排列。

该结论的边界是：

- 已确认 `32x32x64 -> 32x32x64`、`3x3`、stride 1 普通卷积。
- 当前普通卷积连续指令和乒乓切换机制已经具备。
- 128/256 通道的多输入组、多输出组以及 stride 2 普通卷积仍应分别做 bit-perfect 回归。
- 残差卷积不在当前通过范围内。
- 当前 RTL 仍有 latch、位宽和编码风格告警，不能把功能仿真通过等同于 ASIC signoff。

## 3. 系统架构

### 3.1 顶层结构

```text
                              +------------------+
AHB 32-bit <-> ahb_slave_top <-> RAM/寄存器窗口 |
                              +--------+---------+
                                       |
             +-------------------------+-------------------------+
             |                         |                         |
         WorkSheet                  参数装载                 数据装载
        16 x 32-bit          WeightSRAM / SIMD RAM      ActSRAM / OutSRAM
             |
             v
            Ctrl
             |
             v
ActSRAM/OutSRAM -> InBuf -> ComputeCoreGroup -> SIMD -> OutSRAM/ActSRAM
                    64b       64 cores          64b
```

顶层 `Top` 负责模块实例化和控制权复用，不执行卷积算法本身。

### 3.2 主要参数

| 参数 | 当前值 | 架构含义 |
| --- | ---: | --- |
| `P_BINDWIDTH` | 64 | 每拍处理一个 64 输入通道组 |
| `P_GROUP` | 64 | 64 个输出通道并行计算 |
| `P_FEATURE_MEMORY_SIZE` | 65536 bit | 每块 Feature SRAM 为 `1024 x 64 bit` |
| `P_WORDS_WE` | 256 | 每个 WeightSRAM slice 深度 |
| `P_BITWIDTH_WE` | 64 | 每个权重 word 覆盖 64 个输入通道 |
| `P_OUTBITWIDTH_ACC` | 12 | 每个输出通道的累加位宽 |
| `P_COMPAREWIDTH` | 13 | SIMD/BN 等效参数位宽 |
| `P_TOTAL64BN` | 32 | 每个输出通道的参数深度 |

### 3.3 计算并行度

`ComputeCoreGroup` 包含 64 个 `ComputeCore`。每个 core 每拍执行：

```text
64-bit activation XOR 64-bit weight
-> 64 项组合加法/popcount
-> 一个 7-bit partial sum
-> 12-bit accumulator
```

整个 group 每个有效计算拍同时产生 64 个 partial sum，因此逻辑并行度为：

```text
64 个输出通道 x 64 个输入通道 bit = 4096 个二值运算/拍
```

当前 `Multiplier.sv` 实际实现 XOR 计数，而不是物理乘法器。BN/SIMD 参数转换必须与这种二值编码和计数语义保持一致。

## 4. 外部控制与存储体系

### 4.1 AHB 地址空间

| 地址 | 功能 |
| --- | --- |
| `0x0000-0x1FFF` | 当前 `RAM_SEL` 选中 RAM 的数据窗口 |
| `0x2000` | `RAM_CTRL_ADDR`，RAM 控制权 |
| `0x2004` | `RAM_SEL_ADDR`，内部 RAM 片选 |
| `0x2008` | `APU_READY_ADDR`，启动 WorkSheet |
| `0x200C` | `CPL_ADDR`，完成状态 |

`RAM_CTRL_ADDR[0]` 控制 ActSRAM/OutSRAM，`RAM_CTRL_ADDR[1]` 控制 Weight/SIMD 参数 RAM：

```text
1: AHB/PS 控制
0: APU 数据通路控制
```

### 4.2 RAM 片选

| `RAM_SEL` | 选中对象 |
| ---: | --- |
| `0..63` | 64 个 SIMD 参数 slice |
| `64..127` | 64 个 WeightSRAM slice |
| `128` | ActSRAM |
| `129` | OutSRAM |
| `130` | WorkSheet 指令 RAM |

ActSRAM 与 OutSRAM 是两块物理存储器。复位后 `pingpong=0`：

```text
第 1 条指令: ActSRAM -> OutSRAM
第 2 条指令: OutSRAM -> ActSRAM
第 3 条指令: ActSRAM -> OutSRAM
```

每条计算指令完成时 `pingpong` 翻转一次；`nCe` 不清零 `pingpong`，只有 `nRst` 才将其恢复为 0。

### 4.3 32-bit AHB 与 64-bit 内部 RAM

特征和权重 RAM 均按 64 bit 工作，AHB 数据宽度为 32 bit。`ram_mux` 将相邻两个 AHB word 合并为一个内部 word：

```text
第一个 32-bit beat  -> 低 32 bit 暂存
第二个 32-bit beat  -> {高 32 bit, 低 32 bit} 写入 64-bit RAM
```

读回时 AHB 地址依次选择低、高 32 bit；TB 输出文件再按 golden 的高、低半字顺序重排。

## 5. 指令与普通卷积映射

32-bit 指令格式为：

| 位域 | 字段 | 普通卷积含义 |
| --- | --- | --- |
| `[31:30]` | `calc_type` | `00` 表示普通卷积 |
| `[29:28]` | `kernel_size` | 当前使用 `1` 或 `3` |
| `[27:25]` | `in_hw` | 输入 H/W 的 log2 |
| `[24:21]` | `in_c` | 输入通道数 log2 |
| `[20:17]` | `out_c` | 输出通道数 log2 |
| `[16:15]` | `stride1` | 普通卷积步长 |
| `[14:13]` | `stride2` | 普通卷积不使用 |
| `[12:5]` | `w1_addr` | 权重基地址 |
| `[4:0]` | `bn_addr` | SIMD 参数基地址 |

dev1 `Ctrl` 将指令转换为：

```text
totalRound1 = C_in / 64
totalRound2 = C_out / 64
totalRound  = totalRound1 * totalRound2
timePerRound = H_out * W_out
cyclePerTime = K_h * K_w
```

当前状态和计数器含义：

| 状态/计数器 | 作用 |
| --- | --- |
| `IDLE` | 等待有效指令，初始化控制输出 |
| `CONV` | 普通卷积主状态 |
| `CONV2` | 残差分支状态，普通卷积不进入 |
| `cycle` | 当前 kernel 位置，3x3 时为 `0..8` |
| `t` | 当前空间位置计数 |
| `round` | 输入/输出通道组组合轮次 |
| `cut_num` | 已完成 kernel block 的全局展开计数，同时驱动读写地址 |

对于已验证的 layer1.0：

```text
totalRound1 = 1
totalRound2 = 1
totalRound  = 1
timePerRound = 1024
cyclePerTime = 9
```

所以每个输出点连续发出 9 个 kernel 位置，完成后 `cut_num` 加 1，目标地址依次为 `0..1023`。

## 6. 普通卷积模块职责

### 6.1 WorkSheet

- 最多保存 16 条 32-bit 指令。
- `apu_ready` 后发出当前指令并拉低 `oCtrlnCe`。
- 收到 `ComputeDone` 后发出下一条指令。
- 最后一条完成后产生 `WorkSheetDone/int_cal`。

### 6.2 Ctrl

Ctrl 是普通卷积的时序所有者，负责：

- 解码指令和生成循环边界。
- 选择 ActSRAM 或 OutSRAM 为输入源。
- 生成 FeatureProcessor 中心地址、形状和 kernel size。
- 顺序生成 WeightSRAM 地址。
- 产生 Accumulator 的 reset/load/add 控制。
- 维护 BN 地址。
- 产生目标 SRAM 的写地址、写使能。
- 在指令结束时翻转 `pingpong` 并产生 `ComputeDone`。

### 6.3 FeatureProcessor

FeatureProcessor 同时承担特征 SRAM 和卷积窗口地址生成：

- 内部存储为 `1024 x 64 bit`。
- RAM 读为寄存输出，延迟 1 拍。
- `countConvCycles` 遍历 3x3 的 9 个位置。
- `countDepthCycles` 遍历输入通道组。
- 根据 `inHW`、`iDepth` 和中心地址生成上下左右偏移。
- 边界位置通过同步后的 `zeroMaskReg` 输出 0，实现 padding。
- 写入在 `posedge clk` 完成。

### 6.4 InBuf

普通卷积下 `calc_type=00`，InBuf 中的残差计数器保持为 0，功能退化为单级输入寄存器：

```systemverilog
data = iSelect ? iWriteDataB : iWriteDataA;

if (!nWe)
    rBuf <= data;
```

因此普通卷积的有效时序是：

```text
FeatureProcessor 寄存读 1 拍
-> InBuf 寄存 1 拍
```

### 6.5 WeightSRAM 与 WeightBuffer

每个输出通道具有独立的 `256 x 64 bit` WeightSRAM：

```text
WeightSRAM 同步读 1 拍
-> WeightBuffer 寄存 1 拍
```

WeightBuffer 的 `enable` 接 `!InputBufNWe`，使激活和权重在进入组合计算前保持同样的两级时序深度。

### 6.6 ComputeCoreGroup

64 个 core 共用同一份 64-bit 激活，但读取各自 slice 中的 64-bit 权重：

```text
InBufData[63:0]
XOR WeightData[channel][63:0]
-> 64 项组合求和
-> 该输出通道的 partial sum
```

Multiplier 和 AdderTree 均为组合逻辑，不增加寄存延迟。

### 6.7 Accumulator 与 SIMD

Accumulator 是时序逻辑：

| `AccInstr` | 行为 |
| --- | --- |
| `00` | 清零 |
| `01` | 装载第一个 partial sum |
| `10` | 累加后续 partial sum |
| `11` | 保持 |

SIMD 是组合比较：

```text
64 x 12-bit accumulator
-> 与 64 x 12-bit threshold 比较
-> 按参数 bit[12] 选择比较结果或反相结果
-> 64-bit SIMDData
```

SIMDData 不单独寄存，直接连接到 ActSRAM/OutSRAM 写数据口。因此写使能到达 FeatureProcessor 写端时，Accumulator 必须仍保持对应输出点的最终值。

## 7. dev1 普通卷积实际流水时序

### 7.1 延迟组成

| 数据阶段 | 延迟 |
| --- | ---: |
| FeatureProcessor 同步读 | 1 cycle |
| InBuf | 1 cycle |
| WeightSRAM 同步读 | 1 cycle |
| WeightBuffer | 1 cycle |
| XOR + AdderTree | 0 cycle |
| Accumulator | 1 cycle |
| SIMD | 0 cycle |
| FeatureProcessor 写入 | 1 edge |

激活和权重从地址发出到组合 partial sum 前均经过两级寄存，因此二者在 ComputeCore 输入处对齐。

### 7.2 Ctrl 的对齐策略

dev1 没有在每个输出点后插入独立 `WRITEBACK` 状态，而是使用连续流水：

1. `oAccInstr_notdelay` 先由 CONV 状态产生。
2. `oAccInstr` 再寄存 1 拍，使 load/add 控制追随已进入 InBuf/WeightBuffer 的数据。
3. 当前输出点的 kernel 地址在 9 拍内连续发出。
4. `cycle` 回到 0、`cut_num` 进入下一输出点时，前一输出点最后几项仍在后级流水中排空。
5. 前一输出点最终累加值形成后，`oOutWriteEn` 有效。
6. 下一时钟沿，FeatureProcessor 使用沿前稳定的 SIMDData 和写地址完成写入。
7. 同一个沿 Accumulator 可以开始装载下一输出点的第一个 partial sum，不破坏刚完成的 SRAM 写入。

这是一种“下一输出点前导周期兼作上一输出点写回窗口”的重叠调度。

### 7.3 layer1.0 首个输出点实测时序

以下 `E0` 表示进入 `CONV` 且逻辑 `cycle=0` 后的第一个时钟沿。表中 Acc 结果来自当前波形的量级观察。

| 时钟沿 | Ctrl 逻辑位置 | 数据和控制行为 |
| --- | --- | --- |
| `E0` | point 0, kernel 0 | 发出 Act/Weight 地址 0；InBuf 保持；Accumulator 清零 |
| `E1` | point 0, kernel 1 | Feature/Weight SRAM 得到 kernel 0；打开 InBuf/WeightBuffer |
| `E2` | point 0, kernel 2 | InBuf 和 WeightBuffer 锁存 kernel 0；`AccInstr` 进入 LOAD |
| `E3` | point 0, kernel 3 | Accumulator 装载 kernel 0，64 路约为 `22..42` |
| `E4-E8` | point 0, kernel 4..8 | 连续累加 kernel 1..5 |
| `E9` | point 1, kernel 0 | 流水仍在累加 point 0 的 kernel 6；新中心地址开始切换 |
| `E10` | point 1, kernel 1 | 累加 point 0 的 kernel 7；产生上一点写回请求 |
| `E11` | point 1, kernel 2 | 累加 point 0 的 kernel 8，最终约为 `247..337`；`OutWriteEn=1`，地址 0 |
| `E12` | point 1, kernel 3 | OutSRAM 在时钟沿写入 point 0 的最终 SIMDData；Accumulator同时装载 point 1 的 kernel 0 |

对应的实测时间为：

```text
E0  = 378960 ns
E11 = 379070 ns，首点最终累加值形成
E12 = 379080 ns，地址 0 实际写入
```

因此 layer1.0 的时序特征为：

```text
首点地址发出到实际写入约 12 拍
稳态每 9 拍完成并写回一个 64-channel 输出 word
```

理论主体计算周期仍为：

```text
1024 output pixels x 9 kernel positions = 9216 cycles
```

另外存在启动填充、末尾排空和指令切换开销。

### 7.4 写地址和 BN 地址

对于 `C_in=64`：

```text
write_addr = cut_num
```

对于代码中计划支持的多输入组：

```text
C_in=128: write_addr = cut_num / 2
C_in=256: write_addr = cut_num / 4
```

写使能只在一个输出 word 的所有输入通道组完成后产生。BN 地址在实际注册写使能出现时推进，并在 `bn_addr + totalRound2 - 1` 处回绕。

## 8. dev1 与 main 的三个差异文件

## 8.1 Ctrl.sv：决定普通卷积能否通过的核心差异

### main 的控制模型

main 使用：

```text
round = output pixel
t     = output channel group
cycle = kernel position x input channel group
```

并设置多级控制延迟：

```text
write enable: 2 拍
write address: 3 拍
InputBuf 控制: 1 拍
AccInstr: 由状态机直接驱动，没有与数据路径组成统一 valid 管线
```

main 后续又增加 `writebackPending/writebackCount`，试图在每个输出点结束后暂停读取并保持 Accumulator，等待延迟写控制完成。

### main 普通卷积时序的问题

main 的根本问题是控制信号分别按经验延迟，但没有一个统一的“该拍数据属于哪个 kernel/输出点”的有效标记：

1. Feature 和 Weight 数据到组合计算前实际需要两级寄存。
2. `ACC_LOAD/ACC_ADD` 直接根据当前逻辑 `cycle` 产生，没有同步经过等价的数据延迟。
3. 指令启动时 Accumulator 可能先看到 LOAD，而 InBuf/WeightBuffer 仍未得到首项有效数据。
4. 写使能和写地址采用不同延迟深度，而 SIMDData 没有对应的数据寄存管线。
5. `writebackPending` 可以避免最严重的“下一点 partial sum 覆盖最终值”，但只是在尾部增加保持窗口，没有消除前端 load/add 与数据的相位差。

历史波形曾表现为：前 1023 个输出主要写入下一点的早期 partial sum，输出几乎全 0；增加 `writebackPending` 后累加量级恢复，但仍不能 bit-perfect。

### dev1 的控制模型

dev1 改为：

```text
cycle     = 纯 kernel 位置
cut_num   = 连续输出进度和地址基准
totalRound1/2 = 输入/输出 64-channel 组数
AccInstr  = notdelay 控制再寄存 1 拍
write enable/address = 同级寄存后送到 FeatureProcessor
```

普通卷积不再进入单独写回暂停阶段，而是让流水自然排空，并在下一点的前导周期写回上一点。这使得：

```text
SRAM read -> buffer -> accumulator -> SIMD -> SRAM write
```

形成了当前已通过波形验证的固定相位关系。

### Ctrl 差异总结

| 项目 | main | 当前 dev1 |
| --- | --- | --- |
| 循环表达 | pixel/group/cycle 三层索引 | `round/t/cycle + cut_num` 连续展开 |
| Acc 控制 | 直接按逻辑 cycle | `oAccInstr_notdelay` 后再延迟 1 拍 |
| 写回方式 | `writebackPending` 停顿 | 与下一点启动重叠 |
| 写控制延迟 | enable 2 拍、address 3 拍 | enable/address 同为 1 拍 |
| 数据保持 | 依赖 pending/hold | 利用最终累加值到下一次 LOAD 之间的自然窗口 |
| layer1.0 结果 | 不能 bit-perfect | bit-perfect |

普通卷积 pass/fail 的决定性差异位于 `Ctrl.sv`。

## 8.2 InBuf.sv：普通卷积固定为单拍缓冲

### main

main InBuf 包含：

```text
rBuf
rBufReg[0:1]
regWe/regSelect 及其延迟
```

其优先级为 resident replay 数据优先，其次才是 Act/Out 当前读数据。该结构主要服务残差场景。

### dev1

dev1 删除 `regWe/regSelect` 接口，增加 `iInstruction`，由 `calc_type` 决定是否启用残差保存逻辑。

普通卷积时：

```text
calc_type = 00
count = 0
temp/fromram 逻辑不参与输出选择
rBuf 每个有效周期只锁存当前 ping-pong 源 SRAM 数据
```

因此普通卷积的数据契约更明确：InBuf 就是一拍寄存器。

main 的额外 replay 端口在普通卷积中理论上应保持无效，所以 InBuf 不是 main 普通卷积失败的主要根因；dev1 的价值是去掉普通路径上的额外优先级和隐式状态，使 Ctrl 与 InBuf 的时序边界更清晰。

## 8.3 Top_student.sv：接口收敛，不新增普通卷积延迟

main 顶层声明并连接：

```text
Ctrl.oInputBufRegWe     -> InBuf.regWe
Ctrl.oInputBufRegSelect -> InBuf.regSelect
```

dev1 删除这两条 sideband，改为：

```text
Instruction[31:0] -> InBuf.iInstruction
```

普通卷积下顶层数据通路仍是：

```text
ActData/OutData -> InBuf -> ComputeCoreGroup
```

Top_student 本身没有增加或删除寄存级；它的作用是配合 InBuf 接口重构，明确让 InBuf 自己根据指令类型管理残差状态。对普通卷积而言，这一变化保持一拍 InBuf 时序，并减少 main 中 Ctrl 对 InBuf 内部 replay 机制的跨模块控制。

## 8.4 三文件协同关系

```text
Top_student
  传递当前 Instruction，不再传递 regWe/regSelect
        |
        v
InBuf
  普通卷积固定为一拍数据寄存
        |
        v
Ctrl
  按该固定延迟生成 AccInstr 和写回时刻
```

三个文件共同把普通卷积的模块契约收敛为：

```text
源 SRAM 读 1 拍 + InBuf 1 拍
权重 SRAM 读 1 拍 + WeightBuffer 1 拍
AccInstr 与上述数据对齐
最终 SIMDData 在目标 SRAM 写沿前保持稳定
```

其中 Ctrl 是功能正确性的主要修复点，InBuf 和 Top_student 是接口与职责边界的配套变化。

## 9. 普通卷积控制时序不变量

后续修改 RTL 时，至少应保持以下不变量：

1. 激活与权重必须属于同一个 kernel 位置和输入通道组。
2. `ACC_LOAD` 只能作用于当前输出 word 的第一个有效 partial sum。
3. `ACC_ADD` 的次数必须等于 `K*K*C_in/64 - 1`。
4. SIMD 阈值地址必须对应当前输出通道组。
5. 写使能有效前，64 路 Accumulator 必须已经包含全部 partial sum。
6. FeatureProcessor 写沿采样的 SIMDData、写地址和 ping-pong 目标必须属于同一个输出 word。
7. 最后一个输出 word 必须有独立的排空机会，不能依赖下一点启动来触发而丢失。
8. 每条指令只能翻转一次 `pingpong`。
9. `ComputeDone` 只能在最后一个结果已经进入写回窗口后产生。

建议未来将这些不变量转化为 SystemVerilog assertions，而不是继续依赖人工波形判断。

## 10. ASIC 实现视角

### 10.1 时钟与复位

- 当前顶层只有一个 `clk`，不存在功能 CDC。
- 大部分控制和数据寄存器使用低有效异步复位 `nRst`。
- WeightSRAM 读写逻辑未显式复位，符合存储阵列常见建模方式。
- 当前不同模块的复位风格并不完全统一，ASIC 集成前需要确定复位树、同步释放和 STA 约束。

### 10.2 SRAM 宏替换

当前 `FeatureProcessor` 在复位时循环清零整个 memory，`SIMD` 也对二维数组整体清零。该写法适合功能仿真，但通常不直接对应 ASIC SRAM macro：

- Feature SRAM 应替换为双口或伪双口 SRAM macro，并明确读延迟为 1 拍。
- 64 个 WeightSRAM slice 应映射为 64 个独立 bank 或等价多 bank 宏。
- 参数 RAM 可根据面积选择 SRAM、寄存器文件或 latch-based memory。
- SRAM 内容初始化应由软件写入，不应依赖大规模异步复位。

宏替换时最重要的合同不是 Verilog 数组写法，而是本文记录的读 1 拍、写沿采样和 read-during-write 行为。

### 10.3 组合关键路径

当前潜在关键路径为：

```text
InBuf/WeightBuffer Q
-> 64 路 XOR
-> 64-input AdderTree
-> Accumulator D
```

`AdderTree.sv` 当前使用组合 for-loop 描述求和，综合器会构造加法网络，但树形平衡和时序结果依赖综合工具。若目标频率较高，应显式评估：

- 是否形成平衡树。
- XOR/popcount 到 Accumulator 的最大组合延迟。
- 是否需要在 adder tree 中插入流水级。
- 插入流水后 Ctrl 的 `AccInstr` 和写回 token 如何同步增加延迟。

### 10.4 当前容量

| 存储 | 逻辑容量 |
| --- | ---: |
| ActSRAM | 64 Kbit |
| OutSRAM | 64 Kbit |
| 64 个 WeightSRAM | 1024 Kbit |
| SIMD 参数 | `64 x 32 x 13 = 26624 bit` |
| WorkSheet | `16 x 32 = 512 bit` |

权重存储是主要 SRAM 面积来源，计算阵列则由 4096 个 XOR、64 套 popcount 和 64 个累加器构成。

## 11. 当前风险与后续验证边界

### 11.1 当前仍存在的 RTL 风险

- `Ctrl.sv` 和 `InBuf.sv` 存在 Verilator latch 告警，组合逻辑默认赋值不完整。
- 多处算术存在位宽扩展/截断告警。
- `Ctrl` 同时包含普通卷积与未完成验证的残差状态，后续修改残差时可能回归普通路径。
- `cut_num/totalRound` 包含除法，常数化条件不足时可能产生较大组合逻辑。
- `InBuf` 的 `temp/fromram` 残差保存逻辑使用组合状态保持写法，目前不应视为已验证寄存结构。
- `oComputeDone` 与最后一次物理 SRAM 写入的严格先后关系应继续用 assertion 固化。

### 11.2 尚需补齐的普通卷积回归

| 场景 | 目的 |
| --- | --- |
| `64 -> 64`, 3x3, stride 1 | 当前基准，持续防回归 |
| `64 -> 128`, 3x3, stride 2 | 验证输出组、下采样和写地址 |
| `128 -> 128`, 3x3, stride 1 | 验证两个输入组累加和两个输出组 |
| `128 -> 256`, 3x3, stride 2 | 验证四个 totalRound 组合和 SRAM 容量边界 |
| `256 -> 256`, 3x3, stride 1 | 验证最大输入/输出组和权重覆盖 |
| 1x1 普通卷积 | 验证 `cyclePerTime=1` 的首项/末项特例 |

每项至少检查：

```text
读地址序列
WeightAddr 序列
Accumulator 每个 partial sum
BNAddr
写地址/写次数
最终 bit-perfect 输出
```

## 12. 阶段总结

当前 dev1 已建立一条可工作的普通卷积连续流水。其关键不是单独延迟某一个写使能，而是让源 SRAM、InBuf、WeightSRAM、WeightBuffer、Accumulator 和目标 SRAM 形成一致的周期契约。

相对 main：

- `Ctrl.sv` 从分散的经验延迟和独立 writeback stall，改为与下一输出点重叠的连续调度，并延迟 AccInstr 对齐数据。
- `InBuf.sv` 在普通卷积下明确退化为单拍寄存器。
- `Top_student.sv` 删除跨模块 residual replay sideband，改由 InBuf 接收指令类型。

当前通过结论适用于已验证普通卷积配置；残差卷积和更大通道组仍应作为下一阶段独立验证目标，不能从 layer1.0 的通过结果直接推导其正确性。
