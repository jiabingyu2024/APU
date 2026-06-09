# dev1 Layer2 残差卷积修复日志

## 1. 修复信息

- 日期：2026-06-09
- 分支：`dev1`
- 目标：使 layer2 残差卷积及后续 layer2.1 最终输出与 golden 一致
- 关联审查日志：`docs/archive/DEV1_LAYER2_RESIDUAL_MISMATCH_REVIEW.md`
- 关联设计文档：
  - `docs/design/APU_DESIGN.md`
  - `docs/design/AHB_RAM_SEL_128_129.md`
- 涉及文件：
  - `rtl/Ctrl.sv`
  - `tb/tb_top_student.sv`

本日志记录已实施的修复、验证结果，以及后续切换不同 layer 仿真时 TB 需要修改的项目。

## 2. 问题回顾

layer1 普通卷积已经通过；失败集中在 layer2 残差卷积及其传播后的 layer2.1 输出。

前序审查把问题拆成两个层次：

| 问题 | 性质 | 修复位置 |
| --- | --- | --- |
| 128 通道输出组顺序与 golden 不一致 | 外部可见数据布局/导出契约不一致 | TB dump 适配，后续应冻结到设计规范 |
| residual 第一项 `ACC_LOAD` 使用上一条指令遗留输入 | RTL 控制时序 bug | `rtl/Ctrl.sv` |

关键证据：

```text
完整 layer1 + layer2：
  原始 layer2.1_tanh3 mismatch = 17046 bit
  交换每像素相邻两个 64-channel word 后 = 74 bit

隔离 layer2.0：
  原始 layer2.0_tanh3 mismatch = 15868 bit
  交换 64-channel 组后 = 4 bit

整数 accumulator 级别：
  residual 共 512 个 64-bit 输出 word
  仅 word 0 的 64 lane 全部错误
  word 1..511 全部 bit-exact
```

这说明：

1. 大面积 mismatch 不是计算阵列整体错误，而是 128-channel 两个 64-channel 组的导出顺序与 golden 相反。
2. 剩余局部错误来自 residual 指令启动首项，属于连续指令交接时的数据源选择/预取时序问题。

## 3. 架构时序判断

设计中的主要数据路径为：

```text
Feature SRAM 同步读
  -> InBuf 寄存
  -> ComputeCoreGroup 组合计算
  -> Accumulator 寄存
  -> SIMD
  -> 另一块 Feature SRAM 写回
```

`Ctrl.pingpong` 决定当前计算主路径从哪一块 Feature SRAM 读、向哪一块写。根据 `docs/design/AHB_RAM_SEL_128_129.md`：

```text
复位后 pingpong = 0
完成第 1 条指令后结果在 OutSRAM
完成第 2 条指令后结果在 ActSRAM
完成第 N 条指令后：
  N 为奇数 -> 读 OutSRAM/RAM_SEL=129
  N 为偶数 -> 读 ActSRAM/RAM_SEL=128
```

layer2.0 residual 的前一条指令是 `layer2.0.conv1`。该指令输出已经写到 ping-pong 目标 SRAM。residual 启动时，主路径输入必须从当前 `pingpong` 指向的上一层输出 SRAM 读取，而不能固定回到 ActSRAM。

原实现中 `oInputBufSelect` 在 `IDLE` 或 `oInputBufNWe` 期间被压到 0，导致 residual 第一拍预取阶段选择了错误 SRAM。后续运行阶段 `oInputBufSelect` 又跟随 `oOutReadEn`，进入稳态后数据源恢复正确，所以只污染 residual 第一个输出 word。

## 4. 已尝试但未采用的修复

### 4.1 额外插入 residual `ACC_LOAD`

曾尝试通过增加 residual 起始阶段的 `ACC_LOAD`/延迟来规避首项错误。

观察结果：

```text
最终 layer2.1 交换通道组后的 mismatch：
  74 bit -> 约 71 bit
```

该方案没有消除根因。它只改变了局部时序，不能保证第一项 partial sum 来自正确 SRAM，也可能破坏后续 `ADD`、`CONV2` shortcut 和写回对齐关系。

结论：放弃。

### 4.2 保持首个权重地址不推进

曾尝试让 residual 启动时首个 weight address 多保持一拍。

观察结果：

```text
combined 权重访问序列被破坏
residual 输出从局部首项错误扩大为整层不一致
```

原因是 layer2 residual 的 `conv2_combined` 文件把主路径权重、shortcut 权重和 BN/SIMD 参数按当前硬件执行顺序打包。单独移动首个权重地址会破坏整体权重项序列。

结论：放弃。

## 5. 最终 RTL 修复

### 5.1 修改点

文件：`rtl/Ctrl.sv`

原逻辑等价于：

```systemverilog
if ((!nRst) || nCe || oInputBufNWe) begin
    oInputBufSelect <= 0;
end else if (state == IDLE) begin
    oInputBufSelect <= 0;
end else begin
    oInputBufSelect <= oOutReadEn;
end
```

问题是：`oInputBufNWe=1` 表示 InBuf 写禁用/准备阶段，但这段时间恰好需要提前把 Feature SRAM 读源切到当前主路径输入。把 select 强制为 0 会使 residual 紧接 OutSRAM 生产者时错误读取 ActSRAM。

修复后：

```systemverilog
always_ff @( posedge clk )
begin
    if((!nRst)||(nCe))
    begin
        oInputBufSelect<=0;
    end
    else if((state==IDLE)||(oInputBufNWe))
    begin
        // Prepare the main ping-pong source before the first InBuf write.
        // This avoids selecting stale ActSRAM data when a residual
        // instruction starts immediately after an OutSRAM-producing layer.
        oInputBufSelect<=pingpong;
    end
    else
    begin
        oInputBufSelect<=oOutReadEn;
    end
end
```

### 5.2 为什么这个修复正确

该修复只改变 InBuf 预取阶段的数据源选择，不改变：

- WorkSheet 指令顺序；
- weight address 序列；
- `ACC_LOAD/ADD/HOLD` 时序；
- Accumulator 数据位宽和计算逻辑；
- residual `CONV -> CONV2` 状态转换；
- Feature SRAM 写回地址和写使能。

它满足 residual 启动的必要条件：

```text
IDLE / InBuf 禁写准备阶段：
  oInputBufSelect = pingpong
  先把主路径输入源切到上一条指令输出所在 SRAM

正式运行阶段：
  oInputBufSelect = oOutReadEn
  继续保留原有 CONV2 shortcut/replay 所需的数据源切换行为
```

如果删掉该修复或把 `oInputBufSelect` 在 `oInputBufNWe` 期间重新固定为 0，会复现 residual 首个输出 word 错误；对于 `conv -> residual` 且上一层输出位于 OutSRAM 的场景，首个 `ACC_LOAD` 会读取旧 ActSRAM 数据。

### 5.3 修复边界

这是一个定点修复，不是对 Ctrl 全部 valid/token 时序的重构。

仍然保留的历史风险：

- `Ctrl.sv` 中部分读地址组合逻辑仍有 latch warning 风险；
- `InBuf.sv` replay 逻辑仍依赖组合 latch 和 magic cycle；
- layer3 的 256-channel 四组顺序尚未完成同等强度验证；
- 当前架构仍缺少显式 `instruction_ready/accept` 与随数据传播的 valid token。

这些风险没有阻止 layer2 修复通过，但不应视为 signoff 级实现。

## 6. TB 输出布局修复

### 6.1 问题

硬件在 128-channel 输出时，每个像素的两个 64-channel word 顺序为：

```text
硬件 SRAM dump 顺序：
  word 0 = channel 64..127
  word 1 = channel 0..63

golden 文件顺序：
  word 0 = channel 0..63
  word 1 = channel 64..127
```

因此直接把 SRAM 顺序写成 `data_out.txt` 会产生整文件 mismatch。这个问题是导出/解释契约问题，不是 Accumulator 算错。

### 6.2 修改点

文件：`tb/tb_top_student.sv`

`ahb_read_burst_save` 增加参数：

```systemverilog
task ahb_read_burst_save;
    input [31:0] addr;
    input [31:0] leng;
    input        swap_channel_groups;
```

当 `swap_channel_groups=0` 时，保持原始 64-bit word dump 顺序。

当 `swap_channel_groups=1` 时，以两个 64-bit word 为一组缓存并交换输出，使 128-channel 的低 64 通道组先写入 `data_out.txt`，高 64 通道组后写入，从而匹配 golden 文件。

### 6.3 注意事项

该 TB 修改只是把当前硬件 SRAM 布局转换成 golden 布局，便于对拍。长期应该在设计文档中冻结唯一规范：

1. RTL 侧改为低 64-channel 组先写；或
2. 软件/TB/golden adapter 明确按高组、低组解释 SRAM。

两边不能同时交换，否则会出现“双重交换”：仿真可能局部通过，但软件或上板读取会错。

## 7. 验证结果

### 7.1 隔离 layer2.0

配置：

```text
输入：layer1.1_tanh3 作为 ActSRAM 初始输入
指令：
  layer2.0.conv1
  layer2.0.conv2_combined / residual
输出：16x16x128
读取：RAM_SEL=128
dump：2*512 个 32-bit word
通道组：swap_channel_groups=1
golden：data/data_flow/layer2.0_tanh3_output.txt
```

结果：

```text
直接 SRAM 顺序：仍体现 128-channel 组顺序差异
交换通道组后：
  bit mismatch  = 0
  line mismatch = 0
```

### 7.2 完整 layer1 + layer2

配置：

```text
指令：
  layer1.0.conv1
  layer1.0.conv2
  layer1.1.conv1
  layer1.1.conv2
  layer2.0.conv1
  layer2.0.conv2_combined / residual
  layer2.1.conv1
  layer2.1.conv2

run_apu()：8 条指令装入后执行一次
输出：layer2.1_tanh3，16x16x128
读取：RAM_SEL=128
dump：2*512 个 32-bit word
通道组：swap_channel_groups=1
golden：data/data_flow/layer2.1_tanh3_output.txt
```

仿真命令：

```bash
CCACHE_DISABLE=1 make run
```

结果：

```text
build/sim/data_out.txt vs data/data_flow/layer2.1_tanh3_output.txt
got_lines     = 1024
expected_lines= 1024
bit mismatch  = 0
line mismatch = 0
```

说明：`make run` 首次曾受 ccache 只读缓存影响失败；关闭 ccache 后仿真通过。这不是 RTL 功能问题。

## 8. 不同 layer 仿真时是否需要修改 TB

需要。当前 `tb/tb_top_student.sv` 不是完全参数化 testbench，而是通过手动打开/注释不同配置块来决定：

- 写入哪些权重/BN 文件；
- 写入哪些 WorkSheet 指令；
- `run_apu()` 在哪里调用；
- 最终读取 ActSRAM 还是 OutSRAM；
- 读取多少 32-bit word；
- dump 时是否交换 64-channel 组；
- 使用哪个输入文件和哪个 golden 文件对拍。

切换 layer 时原则上不应修改 RTL；需要修改的是 TB 的配置和 dump 参数。

### 8.1 必须同步修改的 TB 项

| 项目 | 必须修改的原因 |
| --- | --- |
| 指令配置块 | 只应装入本次要跑的 layer/op；多装或少装都会改变最终输出位置和内容 |
| `run_apu()` 位置 | 一次 `run_apu()` 会执行 WorkSheet 中已装入的全部指令，不等于只跑一层 |
| `RAM_SEL_ADDR` | 取决于复位以来累计完成的计算指令数 N，奇数读 129，偶数读 128 |
| `ahb_read_burst_save` 的 `leng` | 取决于输出 feature map 尺寸和通道数 |
| `swap_channel_groups` | 取决于输出通道数和 golden 的 channel group 顺序 |
| 初始输入写入 | 全网络从 `input_binary.txt` 开始；隔离某层时要写入上一层 golden 输出转换后的输入 |
| golden 文件 | 必须与当前最后一条执行指令的输出对应 |

### 8.2 RAM_SEL 规则

不要按 `run_apu()` 调用次数判断。应按本次硬件复位以来累计完成的计算指令数 `N` 判断：

```text
N = 0：初始输入在 ActSRAM，RAM_SEL=128
N 为奇数：最终结果在 OutSRAM，RAM_SEL=129
N 为偶数：最终结果在 ActSRAM，RAM_SEL=128
```

示例：

| 场景 | 完成指令数 N | 最终 RAM_SEL |
| --- | ---: | ---: |
| 只跑 `layer1.0.conv1` | 1 | 129 |
| 跑 `layer1.0.conv1 + layer1.0.conv2` | 2 | 128 |
| 跑完整 layer1.0 + layer1.1 | 4 | 128 |
| 跑完整 layer1 + layer2 | 8 | 128 |
| 复位后隔离跑 `layer2.0.conv1 + residual` | 2 | 128 |

`WorkSheet.totalInstrCount` 会在一批完成后清零，但 `Ctrl.pingpong` 不会被 `nCe` 清零。因此分多次 `run_apu()` 时，仍要累计复位以来完成的指令数；只有硬复位 `nRst` 会把 ping-pong 起点恢复到 ActSRAM。

### 8.3 读取长度规则

`ahb_read_burst_save` 的 `leng` 是 32-bit AHB word 数。

| 输出尺寸 | bit 数 | 32-bit word 数 | 建议 `leng` |
| --- | ---: | ---: | --- |
| `32x32x64` | 65536 | 2048 | `2*1024` |
| `16x16x128` | 32768 | 1024 | `2*512` |
| `8x8x256` | 16384 | 512 | `2*256` |

注意：dump 文件每行写 32 bit，且任务内部按两个 32-bit AHB 读数拼成一个 64-bit SRAM word 后输出。

### 8.4 `swap_channel_groups` 规则

| 输出通道 | 当前建议 | 原因 |
| ---: | --- | --- |
| 64 | `swap_channel_groups=0` | 只有一个 64-channel 组，不存在组间交换 |
| 128 | `swap_channel_groups=1` | 当前硬件 SRAM 顺序与 golden 的低/高 64-channel 组顺序相反 |
| 256 | 当前不能只靠 `swap_channel_groups` 修正 | 2026-06-09 实测 layer3 第一条 `layer3.0.conv1` 已经 mismatch，枚举四个 64-channel 组排列后仍不通过 |

因此 layer3 输出如果是 `8x8x256`，不能简单认为 `swap_channel_groups=1` 就一定正确。当前验证表明，layer3 不只是最终 dump 顺序问题；第一条 `layer3.0.conv1` 的输出已经与 golden 不符。详见 `docs/archive/DEV1_LAYER3_OUTPUT_MISMATCH_REVIEW.md`。

### 8.5 常见场景配置表

| 场景 | 指令 | `run_apu()` | `RAM_SEL` | `leng` | `swap` | golden |
| --- | --- | --- | ---: | --- | ---: | --- |
| `layer1.0.conv1` 单独验证 | 1 条 | 装 1 条后跑 | 129 | `2*1024` | 0 | `layer1.0_tanh1_output.txt` |
| `layer1.0` 完整验证 | 2 条 | 装 2 条后跑 | 128 | `2*1024` | 0 | `layer1.0_tanh3_output.txt` |
| `layer1.0 + layer1.1` | 4 条 | 装 4 条后跑 | 128 | `2*1024` | 0 | `layer1.1_tanh3_output.txt` |
| 隔离 `layer2.0` | 2 条，从复位开始 | 装 2 条后跑 | 128 | `2*512` | 1 | `layer2.0_tanh3_output.txt` |
| 完整 layer1 + layer2 | 8 条 | 装 8 条后跑 | 128 | `2*512` | 1 | `layer2.1_tanh3_output.txt` |
| `layer3.0.conv1` | 第 9 条 | 先跑前 8 条，再单独跑本 op | 129 | `2*256` | 0；四组重排仍失败 | `layer3.0_tanh1_output.txt` |
| `layer3.0.residual` | 第 10 条 | 单独跑本 op | 128 | `2*256` | 0；当前失败 | `layer3.0_tanh3_output.txt` |
| `layer3.1.conv1` | 第 11 条 | 单独跑本 op | 129 | `2*256` | 0；当前失败 | `layer3.1_tanh1_output.txt` |
| `layer3.1.conv2` | 第 12 条 | 单独跑本 op | 128 | `2*256` | 0；当前失败 | `layer3.1_bn3_output.txt` |

layer3 的关键点：

- 前 8 条 layer1/layer2 必须先作为一个 batch 执行一次，生成 `layer2.1_tanh3` 作为 layer3 输入。
- layer3 权重超出单次 WeightSRAM 可容纳范围，因此每个 op 覆盖 `wAddr=0/bnAddr=0/worksheet=0` 后单独 `run_apu()`。
- 每次 layer3 op 后，`Ctrl.pingpong` 继续累计翻转；不能因为 WorkSheet 地址重用为 0 就重新按第 1 条指令判断 RAM_SEL。
- 当前实测 layer3 未通过，不应把 layer3 表格当作已验收配置。

## 9. 当前 TB 工作区状态提示

写本日志时，`tb/tb_top_student.sv` 是手动调试型 TB。若要复现实测通过的完整 layer1 + layer2 结果，应确保：

```systemverilog
// layer1.0/layer1.1/layer2.0/layer2.1 八条指令全部装入
// layer3 配置块不要参与本次 layer2 对拍
run_apu(); // 八条指令装完后执行一次

ahb_write(RAM_CTRL_ADDR, 4, 32'h3);
ahb_write(RAM_SEL_ADDR, 4, 128);
ahb_read_burst_save(0, 2*512, 1'b1);
```

如果当前 TB 打开了 layer3 配置块，或者 dump 仍使用：

```systemverilog
ahb_read_burst_save(0, 4*512, 1'b0);
```

那它已经不是 layer2.1 对拍配置；此时 `data_out.txt` 不能直接拿去和 `layer2.1_tanh3_output.txt` 比较。

## 10. 后续建议

1. 把 128/256-channel 的 SRAM channel group 顺序写入 `docs/design`，不要只留在 TB adapter 里。
2. 将 `tb/tb_top_student.sv` 参数化，至少抽出：
   - target layer/op；
   - expected instruction count；
   - expected output shape；
   - expected RAM_SEL；
   - channel group reorder mode；
   - golden path。
3. 为 layer3 单独确认 256-channel 四组输出顺序，再扩展 `ahb_read_burst_save`，不要复用 128-channel 的二组交换假设。
4. 中长期重构 Ctrl 的 `INIT/PREFILL/RUN/DRAIN` 或 valid-token 管线，降低跨指令首项 off-by-one 风险。
5. 中长期重构 `InBuf.sv` replay 逻辑，消除 latch warning 和 magic cycle。

## 11. 结论

本次 layer2 修复闭环如下：

```text
根因 1：128-channel 输出组顺序与 golden 相反
处理：TB dump 增加 swap_channel_groups，用于对拍时转换布局

根因 2：residual 启动预取阶段 oInputBufSelect 固定为 0
处理：IDLE/oInputBufNWe 阶段改为 oInputBufSelect = pingpong

验收：隔离 layer2.0 和完整 layer1+layer2 均达到 0 bit mismatch
```

不同 layer 仿真时需要修改 TB 配置，但不应修改 RTL。TB 的关键不是“跑哪个 `run_apu()`”，而是要同时匹配：装入指令数、累计 ping-pong 位置、输出 shape、读回长度、channel group 顺序和 golden 文件。
