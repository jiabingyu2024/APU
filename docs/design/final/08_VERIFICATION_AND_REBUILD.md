# 08 验证规范与回归

## 1. 验证目标

最终验收不是“仿真结束”或“波形看起来合理”，而是 canonical 输出与仓库 golden
逐 bit 一致，并保证早期层不因后续修复回归。

## 2. 标准回归

```bash
CCACHE_DISABLE=1 make check
```

该命令执行：

1. 编译 Verilator 模型。
2. 运行完整 layer1+layer2+layer3 流程。
3. 再运行一次 `+LAYER1_ONLY`。
4. 使用 `scripts/compare_outputs.py` 对六个检查点比较。

期望输出：

```text
PASS layer1.1_tanh3     bits=    0 lines=   0/2048
PASS layer2.1_tanh3     bits=    0 lines=   0/1024
PASS layer3.0_tanh1     bits=    0 lines=   0/512
PASS layer3.0_tanh3     bits=    0 lines=   0/512
PASS layer3.1_tanh1     bits=    0 lines=   0/512
PASS layer3.1_bn3       bits=    0 lines=   0/512
```

## 3. Testbench 执行流程

### 3.1 初始化

- 10 ns 时钟周期。
- `hresetn` 低 100 个周期。
- 复位释放后等待 20 个周期。
- 写 `RAM_CTRL=3`。
- 把 `input_binary.txt` 的 2048 个 32-bit word 写入 ActSRAM。

### 3.2 Layer1/2

调用 `conv_layer/conv_resident_layer` 时同时：

1. 按 output group、PE bank 装载权重。
2. 按 output group、PE lane 装载 SIMD 参数。
3. 写一条 worksheet 指令。

前 8 条全部装载后只调用一次 `run_apu()`。随后从 ActSRAM dump layer2.1。

### 3.3 Layer3

每个 op 覆盖 weight/BN/worksheet 地址 0，单独调用 `run_apu()`。结果 SRAM 依次：

```text
op9  OutSRAM
op10 ActSRAM
op11 OutSRAM
op12 ActSRAM
```

### 3.4 完成等待

`run_apu` 写 `RAM_CTRL=0` 和 `APU_READY=1`，最多等待 10,000,000 个周期的
`int_cal`，随后读取 `CPL` 清 sticky 状态。

## 4. 输出 adapter

`ahb_read_burst_save_named(addr,leng,channel_groups,path)` 的规范：

- `channel_groups` 仅允许 1/2/4。
- `leng` 必须是 `2*channel_groups` 的整数倍。
- 每个 AHB 地址在 posedge 发出，negedge 采样稳定 `hrdata`。
- 先缓存一个像素的全部 32-bit word。
- group 从物理末组到首组输出。
- 每个 64-bit group 先输出 high32，再输出 low32。

该 adapter 是验证边界，不参与真实 APU 计算。若 adapter 错误，可能出现大面积
mismatch 并误导 RTL 调试。

## 5. Golden 文件语义

| 文件后缀 | 内容 |
| --- | --- |
| `_conv*_output` | 每通道整数卷积/Hamming 域参考，空格分隔十进制 token |
| `_bn*_output` | 部分文件是 0/1 token，部分是打包 32-bit 二进制 |
| `_tanh*_output` | canonical 通道顺序的 0/1 token |
| `*_combine_output` | residual 主路径加 shortcut 的整数参考 |

比较脚本会删除每行空白并要求最终二值文件每行正好 32 bit。

## 6. 分层定位策略

发生 mismatch 时按以下顺序，不要直接修改 Ctrl：

1. 检查实际执行的 worksheet 条数、地址是否从 0 连续。
2. 检查最终 RAM_SEL 是否符合累计指令奇偶。
3. 检查 dump 的 low/high half 和 group reverse。
4. 检查 output line count 与 shape。
5. 比较 accumulator 整数与 conv/combine golden。
6. 若整数一致，再检查 BN entry、direction 和 strict compare。
7. 若只有首 word 错，检查指令边界预取和 InBufSelect。
8. 若只在边缘错，检查 zeroMask 与同步读对齐。
9. 若整层周期性错，检查 WeightAddr span、IG/OG 次序和写地址压缩。

## 7. 建议断言

重新生成 RTL 应加入以下 SVA 或等价检查：

```text
A1 运行时 AHB owner 与 Ctrl owner 不并发请求同一 RAM。
A2 每条指令恰好产生一次 ComputeDone 和一次 pingpong 翻转。
A3 normal 每个输出 word 的 LOAD 次数为 1，ADD 次数为 9*IG-1。
A4 residual 每个输出 word 的总采样次数为 9*IG+IG/2。
A5 write_en 时 accumulator 已完成当前输出 word 的最后一项。
A6 write_addr、BNAddr 和 SIMDData 属于同一 output word。
A7 WeightAddr 始终位于当前指令合法 span。
A8 FeatureProcessor kernel/depth counters 在 nCe 时清零。
A9 最后一个 output word 在 ComputeDone 前或同一尾部窗口被写入。
A10 WorkSheet count=0 时禁止启动。
A11 SIMD acc==threshold 时输出 0。
A12 residual replay 后续输出组使用首输出组捕获的 shortcut 数据。
```

## 8. 单元测试矩阵

| 模块 | 最小测试 |
| --- | --- |
| `ram_mux` | 32->64 合并、64->32 拆分、所有 RAM_SEL |
| `WorkSheet` | 0/1/8/15 条、连续批次、完成清计数 |
| `FeatureProcessor` | 中心/四角/四边、depth 1/2/4、kernel 1/3 |
| `ComputeCore` | 全同、全反、随机 XOR popcount、acc 控制 |
| `SIMD` | >、<、== 阈值，两种 direction |
| `Ctrl normal` | 64->64、64->128 s2、128->128、128->256、256->256 |
| `Ctrl residual` | layer2 19 拍/组、layer3 38 拍/组、尾部完成 |
| `InBuf` | normal 1 拍、layer2 单组 replay、layer3 双组 replay |

## 9. 波形观测信号

最小必要集合：

```text
Instruction, CtrlnCe, state, pingpong
cycle, cut_num, round, t, res_flag
Act/Out read enable and center address
InputBufNWe, InputBufSelect, ActData, OutData, InBufData
WeightAddr, WeightSRAMReadData, WeightBuffer data
AccInstr, ComputeCoreData[representative lanes]
BNAddr, SIMDData
Act/Out write enable and address
ComputeDone, WorkSheetDone, int_cal
```

## 10. 回归通过不等于 signoff

标准回归只证明固定网络映射功能等价。它不覆盖：

- 任意参数组合；
- 运行中 AHB 并发；
- 完整 16 条 worksheet；
- 目标 SRAM macro 的 read-during-write 行为；
- 时序收敛、面积、功耗、DFT、CDC/RDC；
- latch/width warning 的 signoff 清理。

