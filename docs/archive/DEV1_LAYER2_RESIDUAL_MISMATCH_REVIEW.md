# dev1 Layer2 残差卷积输出不一致审查日志

## 1. 审查信息

- 审查日期：2026-06-09
- 分支：`dev1`
- HEAD：`8d8a9a8`
- 仿真器：Verilator `5.046`
- 审查目标：定位 layer2 残差卷积失败原因，为后续修复准备证据和验收条件
- 变更约束：本轮不修改 RTL、不修复 TB，仅新增本审查日志
- 工作区说明：`tb/tb_top_student.sv` 在审查开始前已有用户调试修改，本轮只读取，不改动

本日志联动阅读：

- `docs/design/APU_DESIGN.md`
- `docs/design/APU_DESIGN_DEV1_CONV.md`
- `rtl/Ctrl.sv`
- `rtl/InBuf.sv`
- `rtl/FeatureProcessor.sv`
- `rtl/WorkSheet.sv`
- `rtl/Accumulator.sv`
- `tb/tb_top_student.sv`

## 2. 最终结论

当前失败由两个不同层次的问题叠加造成，不能用一个“卷积算法错误”概括。

### 2.1 输出布局契约不一致

硬件最终 SRAM 中每个像素的两个 64-channel word 顺序是：

```text
地址偶数 word：golden 的 channel 64..127 组
地址奇数 word：golden 的 channel 0..63 组
```

golden 文件则按低 64 通道组、高 64 通道组排列。对每个像素交换相邻两个 64-bit word 后：

| 对拍对象 | 原始 bit mismatch | 交换 64-channel 组后 |
| --- | ---: | ---: |
| 最终 `layer2.1_tanh3` | 17046 | 74 |
| 隔离 `layer2.0_tanh3` | 15868 | 4 |

因此大规模整文件 mismatch 主要是存储布局/软件解释契约不一致，不是 17046 个独立计算错误。

### 2.2 剩余 RTL 根因：连续指令交接时首项预取不足

隔离 layer2.0 后，残差指令共有 512 个 64-bit 输出 word：

```text
word 0：64 路 accumulator 全部与 combine golden 不一致
word 1..511：全部 64 路 accumulator 与 combine golden 完全一致
```

首个 residual `ACC_LOAD` 有效时，Feature SRAM -> InBuf 和 Weight SRAM -> WeightBuffer 尚未完成新指令首项填充，Accumulator 装载了上一条普通卷积遗留的 partial sum。后续流水进入稳态，因此其余 511 个 word 正确。

首个 accumulator word 的 64 路整数都错误，但经过 BN/SIMD 阈值比较后只有 4 bit 翻转。这 4 bit 再经过 layer2.1 后续卷积传播，形成最终 74 bit 局部差异。

## 3. 架构与时序契约

根据设计文档，残差指令位于：

```text
WorkSheet
  -> Ctrl 发射 opcode=01
  -> 主路径 Feature SRAM 3x3 读取
  -> InBuf
  -> ComputeCoreGroup / Accumulator
  -> CONV2 shortcut 读取与累加
  -> SIMD
  -> 另一块 Feature SRAM
```

layer2.0 的两条关键指令为：

```text
普通卷积：32x32x64 -> 16x16x128，3x3，stride1=2
残差卷积：16x16x128 -> 16x16x128，主路径 3x3，shortcut stride2=2
```

数据通路固定延迟是：

```text
FeatureProcessor 同步读 1 拍 -> InBuf 1 拍
WeightSRAM 同步读 1 拍       -> WeightBuffer 1 拍
Multiplier/AdderTree 组合     -> Accumulator 时钟沿采样
```

所以新指令发出地址后，至少要等激活和权重都经过各自两级寄存，才能发出该输出 word 的第一个 `ACC_LOAD`。当前 Ctrl 只有 `oAccInstr_notdelay -> oAccInstr` 一拍控制延迟，没有“数据有效 token”证明 LOAD 对应新指令首项。

如果该契约继续靠固定 cycle 猜测，任何 SRAM 宏读延迟、buffer 级数或指令交接方式变化，都可能再次产生首项丢失或跨指令污染。

## 4. 复现与证据

### 4.1 完整 layer1 + layer2 运行

当前 `build/sim/data_out.txt` 有 2048 行 32-bit 数据。layer2.1 有效输出取前 1024 行，与 `data/data_flow/layer2.1_tanh3_output.txt` 对拍。

结果：

```text
直接对拍：
  mismatch bits  = 17046
  mismatch lines = 1024 / 1024

每像素交换相邻两个 64-bit word 后：
  mismatch bits  = 74
  mismatch lines = 49 / 1024
  mismatch 64-bit words = 35 / 512
```

交换后差异只位于输出左上区域，不再是全图均匀分布。这说明 74 bit 是前级局部错误经后续空间卷积传播后的结果。

### 4.2 layer2.0 隔离测试

隔离环境使用 `layer1.1_tanh3` 作为输入，仅执行：

```text
layer2.0.conv1
layer2.0.conv2_combined / residual
```

隔离输出与 `layer2.0_tanh3_output.txt` 对拍：

```text
直接对拍：15868 bit mismatch
交换相邻 64-channel 组：4 bit mismatch
```

进一步在每次 SRAM 写回时记录 64 路 12-bit accumulator，并与
`layer2.0.conv2_combine_output.txt` 的整数结果逐 lane 对拍：

```text
residual 输出 word 数：512
错误 word：仅地址 0
地址 0：64 / 64 lanes mismatch
地址 1..511：32704 / 32704 lanes match
```

这是当前根因最强的定界证据：

- 若权重布局、shortcut 地址或 InBuf replay 全程错误，不可能后续 511 个 word 全部整数级一致。
- 若只是 SIMD 阈值或输出读回错误，不会出现地址 0 的 64 路 accumulator 已经全部错误。
- 错误发生在第一个 residual 累加窗口，且进入稳态后消失，符合启动填充不足。

## 5. 指令边界逐拍定位

以下为隔离波形在普通卷积切换到 residual 指令时的关键快照。时间为 VCD 时间，信号值为时钟上升沿后的可见值。

| 时间 | Instruction | Ctrl state/cycle | `InputBufNWe` | `AccInstr` | InBuf | 关键含义 |
| ---: | --- | --- | ---: | --- | --- | --- |
| 188620000 | conv1 | IDLE/8 | 0 | ADD | conv1 尾部数据 | `ComputeDone=1`，普通卷积进入排空 |
| 188630000 | residual | IDLE/0 | 1 | ADD | `2cd44d3d1c24db4e` | WorkSheet 已换指令，但 InBuf 仍是上一指令数据 |
| 188640000 | residual | CONV/0 | 1 | RESET | 同上 | Ctrl 只初始化地址和控制，尚未预取 |
| 188650000 | residual | CONV/1 | 0 | RESET | 同上 | 开始 SRAM/Buffer 流水，`AccInstr_notdelay=LOAD` |
| 188660000 | residual | CONV/2 | 0 | LOAD | 同上 | LOAD 已到 Accumulator，新指令首项数据仍未到齐 |
| 188670000 | residual | CONV/3 | 0 | ADD | 首批新数据开始进入 | 错误 partial sum 已作为首项装入 |
| 188850000 | residual | CONV/2 | 0 | LOAD | 后续数据 | 首个 residual 结果写地址 0，64 路累加全错 |
| 189040000 | residual | CONV/2 | 0 | LOAD | 稳态数据 | 地址 1 的 64 路累加全部正确 |

注意：188640000 附近仍有普通卷积最后一个结果写回，但 `Instruction` 已经显示 residual。这是自然排空与 WorkSheet 提前换指令重叠造成的观测现象。仅按“当前 Instruction”给写事务归属会把上一条指令的尾写误记为下一条指令。

## 6. RTL 责任链

### 6.1 WorkSheet：无 ready/accept 握手地直接换指令

`rtl/WorkSheet.sv:98-103` 在 `iComputeDone` 时直接更新 `oInstruction`，并保持 `oCtrlnCe=0`：

```systemverilog
if (iComputeDone==1'b1) begin
    oInstruction<=r_Instruction[currentInstrAddress+1'b1];
    currentInstrAddress<=currentInstrAddress+1'b1;
    oCtrlnCe<=0;
end
```

这意味着上一条指令尾部写回尚在流水中时，解码字段已经切换为下一条指令。该策略可以工作，但要求 Ctrl 明确区分：

```text
上一指令 drain
下一指令 accept/init
下一指令 prefill
下一指令 first valid MAC
```

当前接口没有 `instruction_valid/instruction_ready` 或独立 accept 脉冲。

如果后续只在 WorkSheet 侧随意加/减一拍，可能把最后写回、pingpong 翻转和下一指令首读再次错开。

### 6.2 Ctrl：CONV 启动与 ACC_LOAD 由逻辑 cycle 直接推进

`rtl/Ctrl.sv:447-470` 在 IDLE 中初始化状态、权重地址、Accumulator 和 InBuf 写使能：

```systemverilog
state <= oComputeDone ? IDLE : CONV;
cycle <= 0;
oWeightAddr <= oComputeDone ? 0 : w1_addr;
oAccInstr_notdelay <= 2'b00;
oInputBufNWe <= 1;
```

下一次进入 CONV 后，`rtl/Ctrl.sv:522-523` 立即打开 Weight/InBuf 流水：

```systemverilog
oWeightReadEn <= 1;
oInputBufNWe <= 0;
```

同时 `rtl/Ctrl.sv:547-571` 依据当前 `cycle/cut_num` 产生 LOAD/ADD：

```systemverilog
if (cycle==0) begin
    ...
    oAccInstr_notdelay <= 2'b01;
end else begin
    oAccInstr_notdelay <= 2'b10;
end
```

`rtl/Ctrl.sv:928-936` 只把该控制延迟一拍：

```systemverilog
oAccInstr <= oAccInstr_notdelay;
```

问题不在“少写了一个 ADD”，而在于 Ctrl 没有证明当前 partial sum 已属于新指令。cycle 已经进入计算语义时，数据路径还处于填充语义。

如果只把 `ACC_LOAD` 全局再延迟一拍，而不同时处理后续 ADD、CONV2 和写回，可能修好首项却破坏稳态 511 个正确 word。

### 6.3 数据路径：激活和权重各需要两级时序

激活路径：

```text
FeatureProcessor.sv:67-74  SRAM 同步读寄存
InBuf.sv:145-175          rBuf 再寄存
```

权重路径：

```text
WeightSRAM.sv:23-26       SRAM 同步读寄存
WeightBuffer.sv:13-18     weightBufData 再寄存
```

而 `Multiplier + AdderTree` 是组合逻辑，Accumulator 在 `rtl/Accumulator.sv:21-25` 按 `inst` 直接采样当前 partial sum。

如果删掉任一 buffer 或替换为不同延迟 SRAM，而 Ctrl 仍使用固定 cycle 编码，普通卷积和 residual 的 LOAD/ADD 对齐都会变化。

## 7. 通道组顺序问题的定性

隔离 residual 地址 0 的 accumulator 应对应 golden 的 channel 64..127，而地址 1 对应 channel 0..63。对全部 512 个地址采用：

```text
addr = 2*pixel + 0 -> golden group 1
addr = 2*pixel + 1 -> golden group 0
```

后，除地址 0 外，所有整数累加值完全一致。

因此该问题应归类为“外部可见布局契约未冻结”，而不是直接判为 ComputeCore 算错。后续修复前必须先决定唯一规范：

1. RTL 改为低组先写、高组后写；或
2. 软件/TB/golden adapter 明确按高组、低组解释 SRAM。

两种方案只能选一种并写入 `docs/design`。若双方各自局部交换，会产生双重交换，layer2 表面通过但软件上板仍错误。

## 8. CONV2 与 InBuf replay 审查

### 8.1 当前 layer2 配置下不是主要失败点

对 layer2.0 的稳态证据是：

```text
地址 1..511 的 residual combine accumulator 全部 bit-exact
```

这覆盖了：

- 主路径 3x3、两个输入通道组的累计；
- `CONV -> CONV2 -> CONV` 切换；
- shortcut 权重地址；
- 第二输出通道组对原始 residual 数据的 replay；
- BN/SIMD 写回。

因此不能把当前 layer2 失败继续笼统归因于“CONV2 肯定错”或“InBuf replay 全错”。

### 8.2 实现仍有综合和扩展风险

`rtl/InBuf.sv` 当前用组合 latch 保存 replay 状态：

```systemverilog
always_comb begin
    if(count==1)
        fromram = ...;
end

always_comb begin
    if (calc_type==2'b01 && fromram!=iSelect) begin
        if (count==18) temp1=data;
        ...
    end
end
```

Verilator 明确报告：

```text
LATCH: fromram
LATCH: temp1
LATCH: temp2
```

同时存在以下风险：

- `fromram` 为 2 bit，`iSelect` 为 1 bit，比较发生隐式位宽扩展；
- `count_top` 只按 `in_hw==16 ? 38 : 152` 硬编码，绑定 layer2/layer3 特例；
- replay 触发点使用 `18/20/36/37/40/38` 等 magic number；
- `temp1/temp2/fromram` 没有显式 reset 和统一时钟更新条件；
- `stride2` 在 Ctrl 中被解码但未直接使用，当前 downsample 映射依赖硬编码地址公式；
- Ctrl 的读地址组合块也被 lint 报告 latch，接口时序依赖历史值。

这些风险未造成当前 511 个稳态 word 错误，但会影响：

- ASIC latch 推断和 STA；
- 更换 SRAM 宏后的时序；
- layer3 的 256-channel replay；
- 非当前固定尺寸、stride 或通道配置；
- 形式验证和可维护性。

如果后续修首项时顺手重写 replay，但没有保留“第二输出组必须读到覆盖前 residual 输入”的不变量，会把当前局部首项错误扩大为整层错误。

## 9. 问题分级

| ID | 严重度 | 状态 | 问题 | 当前证据 |
| --- | --- | --- | --- | --- |
| L2-001 | Critical | 已定位，待修复 | 连续指令交接没有 prefill/valid，首个 `ACC_LOAD` 装载上一指令 partial sum | residual 地址 0 的 64/64 accumulator 错，其余 511 word 全对 |
| L2-002 | High | 已定位，待定规范 | 128-channel 相邻 64-bit 组顺序与 golden 相反 | 最终 17046 -> 74，隔离 15868 -> 4 |
| L2-R01 | High risk | 待重构评估 | InBuf replay 使用组合 latch 和 magic cycle | lint LATCH，配置硬编码 |
| L2-R02 | Medium risk | 待加固 | Ctrl 读地址组合块不完全赋值，`stride2` 未直接参与控制 | lint LATCH/UNUSEDSIGNAL |
| L2-R03 | Medium risk | 待加观测 | 写回 drain 时 Instruction 已切换，日志按当前指令归属会误判 | 188640000 仍写 conv1 尾结果 |

## 10. 后续修复准备建议

本轮不实施修复。建议后续按以下顺序设计，而不是直接移动一根控制信号：

1. 冻结 Feature SRAM 的 128/256-channel word 顺序，并同步更新设计文档、TB 和软件解释。
2. 为 Ctrl 定义明确的 `INIT/PREFILL/RUN/DRAIN` 阶段，或建立随数据传播的 valid/token 管线。
3. 从有效 token 推导 `ACC_LOAD/ACC_ADD/ACC_HOLD/write_en`，不要只从逻辑 `cycle` 推导。
4. 让 WorkSheet 与 Ctrl 使用 accept/ready 语义，明确下一指令何时可改变解码字段。
5. 将 InBuf replay 改为显式 `always_ff` 状态和索引，保留覆盖前 residual 数据。
6. 将主路径与 shortcut 的地址、stride、权重项数写成独立派生参数，去掉 magic cycle。

## 11. 修复后的最小验收集

### 11.1 首项和指令边界

- 单条普通卷积冷启动。
- 普通卷积 -> 普通卷积。
- 普通卷积 -> residual。
- residual -> 普通卷积。
- 检查每条指令第一个和最后一个 output word 的 64 路 accumulator。

必须满足：

```text
首个 LOAD 对应该指令第一个有效 partial sum
每个 3x3x128 主路径恰好 18 项
layer2 shortcut 恰好再加入 1 项
最后结果写回后才允许切换 pingpong/发出 ComputeDone
```

### 11.2 布局

- 对单个像素写入可识别的 channel 0..63 与 64..127 pattern。
- 明确 SRAM 地址 0/1 分别对应哪个 channel group。
- TB dump、Python driver 和 golden converter 使用同一规范。

### 11.3 replay

- 第一输出组写回覆盖原 residual 地址后，第二输出组仍读取原始 residual 数据。
- layer2 检查 512 个 word；layer3 检查 256-channel 四组场景。
- lint 不再出现 InBuf replay latch。

## 12. 本轮未做事项

- 未修改 `rtl/Ctrl.sv`。
- 未修改 `rtl/InBuf.sv`。
- 未修改 `rtl/Top_student.sv`。
- 未修改用户已有的 `tb/tb_top_student.sv` 调试内容。
- 未决定通道组顺序应由 RTL 还是软件侧调整。
- 未声称当前 replay 实现可用于 ASIC signoff；只确认它不是当前 layer2 稳态 mismatch 的主要来源。

本轮审查结论可以概括为：先消除输出布局解释差异，再修复 Ctrl 的跨指令首项有效性；不要在没有 valid 时序模型的情况下，仅凭波形把 `ACC_LOAD` 机械平移一拍。
