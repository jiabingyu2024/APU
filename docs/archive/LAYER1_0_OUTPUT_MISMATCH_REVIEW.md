# Layer1.0 输出不一致审查记录

## 1. 记录信息

- 日期：2026-06-08
- 范围：`docs/design/APU_DESIGN.md`、`tb/tb_top_student.sv`、普通卷积相关 RTL、`data/data_flow/layer1.0_*`
- 当前阶段：只做静态审查和已有输出文件分析，不修改 RTL/tb/data
- 目标问题：tb 跑到 layer1.0 后输出与 `data/data_flow` 中 golden 不一致

## 2. 项目与 layer1.0 预期

根据 `docs/design/APU_DESIGN.md`，APU 的普通卷积链路是：

```text
ActSRAM/OutSRAM -> InBuf -> ComputeCoreGroup -> SIMD -> OutSRAM/ActSRAM
```

`layer1.0.conv1` 指令应为：

```text
opcode=00
32x32x64 -> 32x32x64
kernel=3x3
stride=1
wAddr=0
bnAddr=0
```

当前 tb 写入的是 `layer1.0.conv1.txt` 和 `layer1.0.bn1_combined.txt`，因此 APU SRAM 中可直接对比的结果应优先看融合后 0/1 输出，也就是 `data/data_flow/layer1.0_tanh1_output.txt` 或同格式的 `layer1.0_bn1_output.txt`。`data/data_flow/layer1.0_conv1_output.txt` 是十进制卷积累加值，不是当前 `build/data_out.txt` 的 32-bit 二进制 dump 格式。

## 3. 主要发现

### FINDING-001：当前 tb 没有启动 APU，直接读回 SRAM

证据：

- `tb/tb_top_student.sv:90-94` 只装载了 `layer1.0.conv1` 的权重、BN 和 worksheet 指令。
- `tb/tb_top_student.sv:141-143` 的 `run_apu()` 处于注释状态。
- `tb/tb_top_student.sv:168-171` 随后直接把 `RAM_CTRL=3`、`RAM_SEL=128` 并读回 ActSRAM。

影响：

```text
输入写入 ActSRAM
-> 只配置权重/BN/worksheet
-> 未写 APU_READY，Ctrl/WorkSheet 不运行
-> 读回 ActSRAM
```

所以当前 `build/data_out.txt` 不应被解释为 layer1.0 卷积结果。它本质上是在读输入 SRAM。

量化证据：

```text
out[i] == input[i+1] : 2047 / 2047
out[0] == input[1]   : true
out[2046] == input[2047] : true
```

这说明已有 `build/data_out.txt` 基本是 `input_binary.txt` 左移一行后的读回，而不是卷积输出。

### FINDING-002：AHB burst 读保存逻辑存在一拍错位现象

证据：

- `tb/tb_top_student.sv:487-502` 在给出第 0 个读地址后，循环里先推进到 `addr+(i+1)*4`，再写当前 `hrdata`。
- 已有输出表现为 `build/data_out.txt` 第 1 行等于 `input_binary.txt` 第 2 行。

影响：

即使只是验证 SRAM 写入/读回，当前 dump 也会漏掉第 1 个 32-bit word，并把后续读数整体前移。若直接拿这个文件和 golden 对拍，会制造伪 mismatch。

需要注意：

这不是普通卷积算法错误的充分证据。必须先把读回任务修正为可观测的稳定读，再判断计算链路。

### FINDING-003：`addr_map` 的 RAM 读使能由写地址空间决定

证据：

- `rtl/addr_map.sv:122`：`ram_space = (t_waddr < RAM_CTRL_ADDR)`
- `rtl/addr_map.sv:124-125`：`ram_wen` 和 `ram_ren` 都使用同一个 `ram_space`

影响：

在执行 `RAM_SEL_ADDR` 或 `RAM_CTRL_ADDR` 控制寄存器写之后，下一笔 RAM 读请求可能因为 `t_waddr` 仍停留在控制空间而得不到 `ram_ren`。这会让 `FeatureProcessor` 读口不更新，读回值可能保持上一拍或错位。

这和 FINDING-002 一起解释了为什么当前 `build/data_out.txt` 呈现输入数据错位，而不是干净的输入回读。

### FINDING-004：第一次普通卷积后的读回 SRAM 选择需要按 ping-pong 确认

证据：

- `rtl/Ctrl.sv:224` reset 后 `pingpong=0`。
- `rtl/Ctrl.sv:205-206` 当 `writeSelect=0` 时写 OutSRAM。
- `rtl/Ctrl.sv:289-318` ActSRAM/OutSRAM 由 Ctrl 的 `ActWriteEn`/`OutWriteEn` 写入。
- `tb/tb_top_student.sv:170` 当前读的是 `RAM_SEL=128`，即 ActSRAM。

推导：

第一次普通卷积从 ActSRAM 读，结果应写入 OutSRAM。若后续真的调用 `run_apu()`，读回应选择 `RAM_SEL=129`，不是 128。

影响：

修复启动后如果仍读 128，会读到 layer1.0.conv1 的输入，而不是输出。这个问题会继续表现为 layer1.0 输出不一致。

## 4. 当前最可能根因排序

| 优先级 | 问题 | 判断 |
|---:|---|---|
| P0 | tb 未调用 `run_apu()` | 已确认，是当前 dump 不是卷积结果的直接原因 |
| P0 | 读回 SRAM 选错 | 第一次 conv 输出应在 OutSRAM，当前读 ActSRAM |
| P1 | AHB burst read/dump 一拍错位 | 已由 `out[i] == input[i+1]` 支持 |
| P1 | `addr_map.ram_ren` 使用写地址空间 | 已有静态证据，会污染读回可观测性 |
| P2 | Ctrl 写回延迟是否与 SRAM/InBuf/Accumulator 对齐 | 需要在启动和读回修好后用波形验证 |
| P2 | 权重/BN 装载 bit/通道顺序 | 当前尚不能定性，因为计算尚未有效运行并被可靠读回 |

## 5. 建议验证计划

### Step 1：先做 SRAM 回读自检

目标：证明 tb 的 AHB 写入和读出本身可靠。

检查点：

- 写 `input_binary.txt` 到 ActSRAM。
- 不启动 APU。
- 读回 ActSRAM。
- 期望 `data_out.txt` 与 `input_binary.txt` 完全一致，不能有一行 offset。

若该步骤失败，先不要看卷积。

### Step 2：单条 layer1.0.conv1 启动测试

目标：证明 WorkSheet/Ctrl 真正运行。

必要条件：

- `conv_layer(...)` 后调用 `run_apu()`。
- 等待 `int_cal` 或读 `CPL_ADDR` 确认完成。
- 第一次普通卷积完成后读 `RAM_SEL=129`。
- 对比对象使用 `data/data_flow/layer1.0_tanh1_output.txt`，不是 `layer1.0_conv1_output.txt`。

### Step 3：格式转换后对拍

目标：排除文本格式误判。

规则：

- tb dump：每行 32 bit，两个 32-bit word 组成一个 64-bit feature word。
- `tanh1_output.txt`：每行 32 个 0/1 token。
- 对拍时要明确 32-bit word 内 bit 顺序，以及两个 half-word 拼接顺序。

建议先对前 4 个空间点手工展开：

```text
(h=0,w=0,c=0..63)
(h=0,w=1,c=0..63)
(h=0,w=2,c=0..63)
(h=0,w=3,c=0..63)
```

### Step 4：若仍 mismatch，再看普通卷积 RTL

优先抓波形：

```text
Ctrl: state, round, t, cycle, WeightAddr, BNAddr, writeAddr, writeEn
FeatureProcessor: iReadCenterAddr, countConvCycles, countDepthCycles, zeroMask, oFeatureData
InBuf: nWe, iSelect, oInData
WeightSRAM/WeightBuffer: readAddr, oDataa, weightBufData
Accumulator: inst, iData, oData
SIMD: iAddr, iAccData, oSIMDData
OutSRAM: nWe, iWriteAddr, iWriteData
```

第一条普通卷积的关键预期：

```text
round=0,t=0,cycle=0..8
readCenterAddr=0
WeightAddr=0..8
BNAddr=0
最终 writeAddr=0，写 OutSRAM
```

## 6. 暂不建议立刻修改的点

- 暂不优先查残差卷积。当前问题在 layer1.0 普通卷积启动/读回阶段已经不成立。
- 暂不直接用 `layer1.0_conv1_output.txt` 对比 `build/data_out.txt`，两者语义不同。
- 暂不根据当前 `build/data_out.txt` 判断 ComputeCore、SIMD 阈值或权重顺序错误，因为现有 dump 没有证明 APU 已运行。

## 7. 结论

当前 layer1.0 输出不一致的首要原因不是残差卷积，也暂时不能归因到普通卷积计算核。基于现有 tb，`layer1.0.conv1` 被装载但没有启动执行，随后又读回 ActSRAM；已有 `build/data_out.txt` 与 `input_binary.txt` 呈现 1 行错位关系，说明读回链路本身也存在相位/使能问题。

下一步应按“SRAM 回读自检 -> 单条 conv1 启动并读 OutSRAM -> 格式转换对拍 -> 波形定位普通卷积 RTL”的顺序推进。
