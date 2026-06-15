# APU / APU_DMA 50MHz 时序审查与优化规划

日期：2026-06-15

## 1. 结论摘要

本次只做静态 RTL 审查，没有修改 RTL，也没有 Vivado post-route timing report 可读。因此以下是按 RTL 结构推断的高风险路径和优化计划，最终优先级必须用 `report_timing_summary` / `report_timing -max_paths` 确认。

APU 和 APU_DMA 的核心计算路径基本相同：`apu_dma_core` 直接实例化 `WorkSheet + Ctrl + InBuf + FeatureProcessor x2 + ComputeCoreGroup + SIMD`。所以两个版本难以达到 50MHz 的主因应优先从共用计算核查起，DMA wrapper 主要增加 AXIS/AXIL 控制路径，不是第一嫌疑。

最高风险路径排序：

1. `ComputeCore`: `WeightBuffer/InBuf Q -> Multiplier XOR -> AdderTree 64-input popcount -> Accumulator D`
2. `FeatureProcessor`: `iReadCenterAddr/inHW/iDepth/count* -> /、%、*、加减 -> featureMemory read address`
3. `SIMD`: `Accumulator Q[64 lanes] -> 64 路 threshold RAM 读 mux -> compare -> FeatureProcessor write data`
4. `ComputeCoreGroup`: `weightWriteSelect` 到 64 个 `nWeightWe` 比较门，以及 `coreWeightData[weightWriteSelect]` 64:1 读 mux
5. `Ctrl`: `cut_num/state/instruction -> address/read-enable/weight/acc/write 控制`，目前已经做过位宽收缩和移位化，风险低于前两项但仍需报告确认

## 2. 当前频率与工程约束观察

- `dma/vivado/create_apu_dma_project.tcl` 当前把 PS FCLK0 设置为 `25.000000 MHz`，同一个 FCLK 驱动 SmartConnect、AXI DMA、FIFO 和 `apu_dma/aclk`。
- `dma/overlay/apu_dma.hwh` 中导出的 `apu_dma_0/aclk` 也是 `25MHz`。
- 如果目标是 50MHz，应先把工程脚本参数改为 50MHz 并生成 post-route report，再看真实 worst paths。仅在 HWH 或 Tcl 里改频率不会改善 RTL 时序。

建议新增固定报告项：

```tcl
report_timing_summary -delay_type max -max_paths 50 -report_unconstrained
report_timing -delay_type max -max_paths 30 -sort_by group
report_utilization -hierarchical
report_high_fanout_nets -fanout_greater_than 100
```

## 3. 高风险路径审查

### 3.1 ComputeCore popcount 路径

代码位置：

- `rtl/ComputeCore.sv`: `Multiplier -> AdderTree -> Accumulator`
- `rtl/AdderTree.sv`: `always_comb` 中 for-loop 累加 64 个 1-bit

当前 `AdderTree` 写法：

```systemverilog
oData = '0;
for (i = 0; i < P_INNUM; i = i + 1) begin
  oData = oData + extend(iData[i]);
end
```

综合器可能把它实现成 64 级或重平衡后的宽加法网络。即使工具会优化，路径仍包含 64-bit XOR/popcount 加法树到 accumulator 的一整个组合级，而且复制 64 个 core。

不影响功能结果的优化方向：

- P0：把 `AdderTree` 改成显式平衡 popcount 树，例如 64 -> 32 -> 16 -> 8 -> 4 -> 2 -> 1，保持组合输出 `addData` 的同拍语义。这不改变流水拍数，功能风险低。
- P1：使用 FPGA 友好的分组 popcount：8 组 8-bit popcount，再求和。仍保持组合同拍语义，但能更好约束每层位宽和 LUT 结构。
- P2：插入一级或两级 pipeline 到 popcount 中间。这会显著改善 50MHz 余量，但会改变 `WeightBuffer/InBuf -> Accumulator` 延迟，必须同步调整 `Ctrl.oAccInstr`、写回使能和 residual replay 相位，验证成本高。

建议先做 P0/P1，不先做 P2。

### 3.2 FeatureProcessor 地址生成路径

代码位置：`rtl/FeatureProcessor.sv`

组合逻辑中存在：

- `rowOffset = inHW * iDepth`
- `centerPixel = iReadCenterAddr / colOffset`
- `centerRow = centerPixel / inHW`
- `centerCol = centerPixel % inHW`
- 多路 `readAddr = center + depth +/- rowOffset +/- colOffset`

这里的 `/`、`%`、`*` 在综合中非常危险。虽然实际 shape 只用 `inHW=8/16/32`、`iDepth=1/2/4`，但 RTL 写成动态除法/取模，Vivado 可能构造很重的组合网络。这个路径还直接驱动同步 RAM 地址，属于典型 50MHz 卡点。

不影响功能结果的优化方向：

- P0：把 `iDepth` 从 `4'd1/2/4` 解码成 shift，`rowOffset = inHW << depth_shift`，`colOffset = iDepth`。
- P0：把 `centerPixel / inHW` 和 `% inHW` 改成按 `inHW` 的 case 分支：
  - `inHW=8`: row=`centerPixel >> 3`, col=`centerPixel[2:0]`
  - `inHW=16`: row=`centerPixel >> 4`, col=`centerPixel[3:0]`
  - `inHW=32`: row=`centerPixel >> 5`, col=`centerPixel[4:0]`
- P0：`centerPixel = iReadCenterAddr / iDepth` 也改成 `case(iDepth)` 的右移。
- P1：把边界 mask 预计算寄存一拍，或由 `Ctrl` 输出更直接的 padding mask。若保持 SRAM read data 和 `zeroMaskReg` 对齐，不改变外部结果，但必须重新跑所有 layer 对拍。
- P2：把 `FeatureProcessor` 分成“地址/zeroMask 生成寄存级”和“RAM read 寄存级”。这会给 FeatureSRAM 读取增加一拍，必须同步调整 `Ctrl`、`InBuf`、`WeightBuffer` 和 `AccInstr` 相位，验证成本高。

建议先做 P0：只消除动态除法/取模/乘法，不改变寄存级。

### 3.3 SIMD threshold 比较到 Feature 写回

代码位置：`rtl/SIMD.sv`

当前 `SIMD_Reg[iAddr][gv_i]` 在组合比较中直接读二维 reg array，然后 64 路比较结果同拍作为 `SIMDData` 写入 Act/Out FeatureProcessor。风险点：

- 64 路 `SIMD_Reg[iAddr][channel]` 可能综合成大量分布式 RAM/LUT mux。
- `iAccData > threshold` / `< threshold` 是 64 路 12-bit compare。
- 写回路径为 `Accumulator Q -> SIMD compare -> FeatureProcessor write data -> featureMemory D`，虽然写地址/写使能已打一拍，但数据本身仍是组合比较。

不影响功能结果的优化方向：

- P0：把 BN threshold 读口寄存化，提前一拍读出 64 个 threshold 到 `bn_threshold_q[64]`，当前写回拍只做 compare。需要确认 `Ctrl.oBNAddr` 的推进点，可能需要把 BNAddr 预读地址和写回地址分离。
- P1：把 `SIMDData` 也寄存一拍，同时把 Act/Out 写使能和写地址再延后一拍。这不改变最终写入内容，但改变写回时序，需同步 Ctrl。
- P0/P1 之间的折中：保留 `SIMDData` 组合输出，仅把 `SIMD_Reg` 读结果寄存，减少 mux 级。

如果 timing report 显示 worst path 落在 `SIMD_Reg -> oSIMDData -> featureMemory`，优先做 BN 读寄存化。

### 3.4 Weight SRAM bank 选择和读回 mux

代码位置：`rtl/ComputeCoreGroup.sv`

风险点：

- `nWeightWe | (weightWriteSelect != i)` 被复制 64 路，每路比较 6 bit。
- `assign oWeightData = coreWeightData[weightWriteSelect]` 是 64:1 x 64-bit mux，仅用于 host/loader 读回权重，不参与正常计算。

不影响功能结果的优化方向：

- P0：把 `weightWriteSelect` 解码成 one-hot `weight_bank_we[64]`，减少 64 路重复比较。
- P0：如果 `oWeightData` 只用于外部读回，可将 readback mux 寄存一拍或拆成两级 mux。DMA/host 读回路径不是核心计算吞吐路径，增加一拍 readback latency 通常可通过 host side `valid` 对齐处理；APU AHB 版本则要确认 `ahb_slave_top` 读时序是否允许。
- P1：如果板上不需要权重读回，可在 FPGA 构建中裁剪 `oWeightData` 或约束为 debug-only。但这会改变可观测接口，不建议作为默认功能正确版本。

### 3.5 Ctrl 控制和地址生成

代码位置：`rtl/Ctrl.sv`

`Ctrl` 已经明显做过时序友好化：

- 限制 `CUT_NUM_WIDTH`
- `decode_hw/decode_groups/square_hw` 查表
- `pixel_from_chunk/row_skip_from_pixel/scale_by_groups` 用移位替代除法/乘法

仍需关注：

- `cut_num/state/instruction -> main_center_addr/shortcut_center_addr -> FeatureProcessor read address`
- `final_chunk/final_shortcut_cycle` 比较到 FSM 下一状态
- `oInputBufSelect <= oOutReadEn` 依赖组合 read enable

不建议优先改 `Ctrl`，除非 timing report 明确 worst path 指向它。若需要优化，优先把 `main_center_addr/shortcut_center_addr` 寄存一拍，但这会直接改变 FeatureSRAM 读相位，必须重新调整流水。

## 4. 优化优先级

### 第一阶段：不改变流水拍数，低功能风险

目标：尽量在不改 `Ctrl` 相位的情况下提升 50MHz 成功率。

1. `AdderTree` 改成显式平衡组合树或 8x8 分组 popcount。
2. `FeatureProcessor` 消除动态 `/`、`%`、`*`，全部改为固定 shape 的 case/shift/add。
3. `ComputeCoreGroup` 权重 bank 写使能改 one-hot 解码。
4. 用 Vivado 属性明确 RAM 风格：
   - Feature memory 期望 BRAM：`(* ram_style = "block" *)`
   - Weight memory 视资源选择 BRAM 或 distributed，但必须看 utilization 和 timing。

验收：

- `CCACHE_DISABLE=1 make check`
- APU_DMA 现有仿真/板级 smoke
- 50MHz post-route `WNS >= 0`，无 unconstrained endpoint

### 第二阶段：轻微时序协议调整，中等功能风险

触发条件：第一阶段后 worst path 仍在 SIMD 或 readback mux。

1. SIMD threshold read 寄存化。
2. Weight readback mux 寄存化。
3. DMA result streamer host read path 增加等待状态，吸收 APU memory readback latency。

验收重点：

- BNAddr 与 writeback 地址/使能保持同一 output group。
- AHB/DMA 读回路径不能采到前一个地址数据。

### 第三阶段：计算流水加深，高收益高风险

触发条件：第一、二阶段后 worst path 仍在 popcount/accumulate，且 50MHz 仍无法收敛。

方案：

1. 在 `Multiplier/AdderTree` 和 `Accumulator` 之间加入 1 级 pipeline。
2. 或把 64-bit popcount 拆成两拍：第一拍 8 组局部 popcount，第二拍总和并送 accumulator。

必须同步修改：

- `Ctrl.oAccInstr` 延迟
- 写回 `act_write_en_d/out_write_en_d` 和地址更新
- `SIMD` 写回窗口
- `InBuf` residual replay 捕获/重放相位

这类修改功能结果可以保持不变，但内部每个 token 延迟改变，必须以全网络六点 golden 和 residual 定向测试重新验收。

## 5. APU 与 APU_DMA 分别建议

### APU 版本

优先处理共用计算核：

- `AdderTree`
- `FeatureProcessor`
- `SIMD`
- `ComputeCoreGroup`

AHB 侧只在配置/读回阶段工作，不应是计算期间 50MHz 的第一瓶颈。若 report 指向 `ahb_slave_top -> ram_mux -> hrdata`，可对 AHB read data 加寄存，但会改变 testbench/软件读取相位，需要单独处理。

### APU_DMA 版本

共用计算核仍是第一优先级。DMA wrapper 侧额外建议：

- 当前工程 FCLK 是 25MHz；做 50MHz 验证前先参数化 `PCW_FPGA0_PERIPHERAL_FREQMHZ`，避免脚本和 HWH 混乱。
- `apu_dma_core` 的 `host_rd_data = host_rd_target_q ? out_data : act_data` 是组合 mux，若 host readback path 成为 worst path，可在 `axis_result_streamer` 增加一拍等待并寄存 `host_rd_data`。
- `apu_stream_loader` 的 range/length 检查包含 32-bit add/shift/compare，但只在装载阶段，不影响核心计算；若 report 指向它，可寄存 `load_*` 命令解码。

## 6. 建议的执行顺序

1. 生成 50MHz baseline timing report，保存 worst 30 paths。
2. 若 worst path 指向 `AdderTree`，先做平衡组合 popcount。
3. 若 worst path 指向 `FeatureProcessor`，先去掉动态除法/取模/乘法。
4. 重新跑仿真和 Vivado implementation。
5. 若 WNS 仍负，再看 SIMD/weight readback。
6. 最后才考虑给计算流水加拍。

## 7. 验收清单

- [ ] `make check` 六个 checkpoint 全部 0 mismatch。
- [ ] `tb/tb_inbuf_replay.sv` 通过。
- [ ] APU_DMA smoke / full network job 通过。
- [ ] 50MHz post-route `WNS >= 0`、`TNS = 0`。
- [ ] `report_unconstrained` 无未约束 endpoint。
- [ ] 保存 utilization，确认 BRAM/LUTRAM 变化符合预期。
- [ ] 若改了流水拍数，逐项复查 `Ctrl`、`InBuf`、`SIMD`、写回地址的相位。

