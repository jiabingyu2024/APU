# dev1 layer1.0 部分输出不一致定位报告

- 日期：2026-06-08
- 分支：`dev1`
- 范围：普通卷积 `layer1.0`
- 结论状态：已定位并修复 testbench，RTL 计算路径未修改
- 仿真命令：`CCACHE_DISABLE=1 make run`
- 波形：`build/sim/top.vcd`
- dump：`build/sim/data_out.txt`

## 1. 最终结论

当前 layer1.0 的普通卷积计算结果本身已经正确。

`data_out.txt` 中看起来仍有部分错误，直接根因位于 testbench 的
`ahb_read_burst_save` 读回任务，不在 `Ctrl`、`InBuf`、`FeatureProcessor`、
`ComputeCore` 或 `SIMD` 计算路径。

具体错误是：

1. task 发出首个地址后，没有保存首个返回数据；
2. 循环中先推进到下一个 AHB 地址，再等待时钟并保存 `hrdata`；
3. SRAM 为 64 bit，AHB 为 32 bit，`ram_mux` 又按地址最低位选择上下半字；
4. 最终 dump 的两个 32-bit 行不再来自同一个 64-bit SRAM word。

因此这是 **AHB dump 采样相位和 64/32-bit 拆分顺序错误**，不是 APU 输出错误。

## 2. 修复前输出对拍结果

直接将 `build/sim/data_out.txt` 与
`data/data_flow/layer1.0_tanh1_output.txt` 对比：

```text
总 bit 数：       65536
不一致 bit 数：   5752
错误率：          8.7769%
完全正确像素：    108 / 1024
```

错误具有非常固定的通道分布：

```text
输出通道 0..31：  32768 bit 全部正确
输出通道 32..63： 所有 5752 个错误均集中在这里
```

这不是卷积读地址、padding 或统一写回时序错误的典型表现。上述问题通常会同时
影响 64 个输出通道，不会严格以 32 通道为边界切开。

## 3. OutSRAM 实际写入结果

从 VCD 按 `OutWriteEn` 上升沿重新抽取真实写事务：

```text
OutSRAM 写事务：       1024 次
写地址：               0..1023，连续且无重复/遗漏
Accumulator 对拍：     65536 / 65536 个数值完全一致
SIMD 对拍：            65536 / 65536 bit 完全一致
```

Accumulator 使用 `ComputeCoreData[767:0]`。考虑 packed-array 展平方向后，
每个输出点的 64 个累加值与
`data/data_flow/layer1.0_conv1_output.txt` 完全相同。

同时，写入 OutSRAM 的 `SIMDData[63:0]` 与
`data/data_flow/layer1.0_tanh1_output.txt` 完全相同。

这证明当前 layer1.0 的以下路径已经通过：

```text
ActSRAM
-> FeatureProcessor 3x3/padding
-> InBuf
-> WeightSRAM/WeightBuffer
-> XOR + AdderTree
-> Accumulator
-> SIMD
-> OutSRAM 写入
```

## 4. dump 的精确错位关系

设 golden 的每个像素由两行 32 bit 组成：

```text
golden[2*p]     = 当前像素的第一个 32-bit 半字
golden[2*p + 1] = 当前像素的第二个 32-bit 半字
```

实际 `data_out.txt` 满足：

```text
data_out[2*p]     == golden[2*p]         ：1024 / 1024
data_out[2*p + 1] == golden[2*(p+1) + 1] ：1023 / 1023
```

也就是：

```text
当前像素第一个半字 + 下一个像素第二个半字
```

除最后一行外，前 2047 行全部严格符合这个错误模型。最后一行是 burst 结束后
额外采到的尾部/保持数据。

## 5. 具体错误位置

问题代码位于：

```text
tb/tb_top_student.sv:477  ahb_read_burst_save
```

关键流程是：

```systemverilog
haddr <= addr;
...
@ (posedge hclk);

for (i=0; i<leng-1; i=i+1) begin
    haddr <= addr+(i+1)*4;
    @ (posedge hclk);
    $fwrite(fp_datao_w,"%32b\n",hrdata);
end
```

首地址 `addr` 的返回值没有被保存。循环第一次保存数据时，AHB 地址已经推进到
`addr + 4`。

与此同时，`rtl/ram_mux.sv:83-89` 延迟了 `ram_raddr`，并在
`rtl/ram_mux.sv:141-146` 根据延迟地址最低位选择 64-bit SRAM 的上下 32 bit。
testbench 的提前推进使 SRAM 数据和 dump 行号错开一个 32-bit beat。

## 6. 为什么看起来只是“部分错误”

OutSRAM 内部每个地址保存 64 bit，而 dump 每行保存 32 bit。

当前 task 恰好让其中一个半字仍对应当前 SRAM word，因此通道 0..31 全部正确；
另一个半字来自下一 SRAM word，因此通道 32..63 只有数据偶然相同时才表现正确。

所以 8.78% 的 bit mismatch 是读回错位后的表象，不能据此继续修改卷积 RTL。

## 7. 排除项

本次 layer1.0 问题可排除：

- `Ctrl` 普通卷积循环边界错误；
- `Ctrl` 写地址或写使能漏写；
- `FeatureProcessor` 普通卷积 padding 错误；
- `InBuf` 普通卷积数据源错误；
- WeightSRAM 地址顺序错误；
- Accumulator 累加次数错误；
- SIMD 阈值、符号位或比较方向错误；
- OutSRAM 实际写入内容错误。

`Ctrl` 和 `InBuf` 当前仍有 Verilator latch/位宽警告，但它们不是本次
layer1.0 dump mismatch 的直接根因，后续残差卷积审查仍需单独处理。

## 8. 修复方案

本次只修复 testbench 的 `ahb_read_burst_save`，未修改 RTL 计算路径：

1. 每个地址在 `posedge hclk` 进入同步 SRAM 读路径；
2. 等到 `negedge hclk`，在 `ram_mux` 和 `hrdata` 已稳定后采样返回数据；
3. 从 `i=0` 开始保存，避免丢失首地址的 read response；
4. 每两个 32-bit AHB beat 重组一个 64-bit OutSRAM word；
5. AHB 依次返回低 32 bit、高 32 bit，文件按 data_flow 所需的高 32 bit、
   低 32 bit 顺序输出；
6. 要求 `leng` 为偶数，防止产生不完整的 64-bit dump 数据。

修改文件：

```text
tb/tb_top_student.sv
```

## 9. 修复验证记录

验证命令：

```text
CCACHE_DISABLE=1 make run
```

将修复后的 `build/sim/data_out.txt` 与
`data/data_flow/layer1.0_tanh1_output.txt` 全量对拍：

```text
输出行数：        2048 / 2048
一致行数：        2048 / 2048
一致像素：        1024 / 1024
不一致 bit 数：   0 / 65536
前四行顺序检查：  通过
```

最终结论：

```text
layer1.0 普通卷积 RTL 输出正确；
此前的部分 mismatch 由 testbench AHB 读回采样相位和 64/32-bit 排列顺序导致；
修复 TB 后已达到 bit-perfect。
```

本次没有根据错误的 `data_out.txt` 表象继续修改 `Ctrl`、`InBuf`、
`ComputeCore`、`SIMD` 或 OutSRAM 写回逻辑。
