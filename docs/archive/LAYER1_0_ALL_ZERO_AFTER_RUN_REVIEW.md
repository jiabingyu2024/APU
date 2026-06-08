# Layer1.0 启动后输出近似全 0 审查记录

## 1. 记录信息

- 日期：2026-06-08
- 范围：`tb/tb_top_student.sv`、`rtl/Ctrl.sv`、`rtl/SIMD.sv`、`rtl/Accumulator.sv`、`build/top.vcd`、`build/data_out.txt`
- 当前阶段：只审查，不修改 RTL/tb/data
- 问题：已加入 `run_apu()` 且读回 `RAM_SEL=129` 后，输出几乎全 0

## 2. 当前现象确认

当前 tb 已满足两个前置条件：

- `tb/tb_top_student.sv:94-95`：`conv_layer(...)` 后调用 `run_apu()`。
- `tb/tb_top_student.sv:171-173`：运行后读回 `RAM_SEL=129`，即第一次普通卷积的 OutSRAM。

已有 `build/data_out.txt` 统计：

```text
总行数        : 2048
全 0 行       : 2045
总 1 bit 数   : 39
非 0 行       : 2046, 2047, 2048
```

这不是 `layer1.0_tanh1_output.txt` 的合理分布。golden 中 0/1 基本接近各半：

```text
expected ones  : 32904
expected zeros : 32632
```

## 3. 关键波形证据

从 `build/top.vcd` 抽取到：

```text
OutWriteEn rising count : 1024
U_OutSRAMnWe low count  : 1024
ComputeDone rising      : 1
```

说明：

- Ctrl 确实跑完了 `32x32x64 -> 32x32x64` 的 1024 个输出点。
- OutSRAM 确实发生了 1024 次写。
- 问题不是“APU 没启动”或“OutSRAM 完全没写”。

但每次写回时的 `SIMDData`/`ComputeCoreData` 异常：

```text
write[0]    : SIMDData ones = 0,  Acc min/max = 47 / 75
write[1]    : SIMDData ones = 0,  Acc min/max = 47 / 75
write[2]    : SIMDData ones = 0,  Acc min/max = 46 / 75
write[100]  : SIMDData ones = 0,  Acc min/max = 49 / 85
write[500]  : SIMDData ones = 0,  Acc min/max = 43 / 88
write[1020] : SIMDData ones = 0,  Acc min/max = 52 / 76
write[1021] : SIMDData ones = 0,  Acc min/max = 52 / 76
write[1022] : SIMDData ones = 0,  Acc min/max = 52 / 76
write[1023] : SIMDData ones = 26, Acc min/max = 253 / 332
```

只有最后一个 64-bit 输出 word 的累加值落在正确量级，前面 1023 个写回点基本只有一个 64-channel partial sum 的量级。

## 4. BN/SIMD 参数不是全 0

`data/param_files/layer1.0.bn1_combined.txt` 前 64 个参数均为有效 13-bit 参数：

```text
sign bit : 1
threshold range : 260..303
```

`rtl/SIMD.sv` 的当前逻辑为：

```systemverilog
SIMD_Temp[gv_i] = (iAccData[gv_i] > SIMD_Reg[iAddr][gv_i][P_COMPAREWIDTH-2:0]) ? 1 : 0;
oSIMDData[gv_i] = (SIMD_Reg[iAddr][gv_i][P_COMPAREWIDTH-1] == 1'b1)
                ? SIMD_Temp[gv_i]
                : (~SIMD_Temp[gv_i]);
```

因此当 sign bit 为 1 时，输出等于：

```text
acc > threshold
```

前 1023 次写回时 `acc ~= 50..80`，阈值约 `260..303`，所以 SIMD 输出全 0 是符合当前波形的。真正异常点在于写回时 `acc` 不是完整 3x3 累加结果。

## 5. 最可能根因：写回控制延迟了，但 SIMDData/Accumulator 结果没有同步保持

`rtl/Ctrl.sv` 中写控制路径：

```systemverilog
writeAddrDelay1 <= writeAddr;
writeAddrDelay2 <= writeAddrDelay1;
writeAddrDelay3 <= writeAddrDelay2;
writeEnDelay1   <= writeEn;
writeEnDelay2   <= writeEnDelay1;

oOutWriteEn <= writeEnDelay2 && !writeSelectDelay2;
...
oOutWriteAddr <= writeAddrDelay3;
```

也就是说，写使能延迟 2 拍，写地址延迟 3 拍后才真正写 OutSRAM。

但写数据在顶层直接连接：

```systemverilog
U_OutSRAMWriteData = (data_ram_ctrl == 1) ? out_ram_wdata : SIMDData;
```

没有看到与 `oOutWriteEn/oOutWriteAddr` 同步的 `SIMDData` 延迟寄存器，也没有看到在写回窗口内强制 `Accumulator` 保持最终累加值。

普通卷积控制在 `cycle == cyclePerTime` 时发出 `writeEn`，随后立刻进入下一个输出点：

```text
cycle == 8: 当前点累加完成，writeEn=1
下一拍:    cycle 回 0，下一点开始，AccInstr=ACC_LOAD
再后面:    延迟后的 oOutWriteEn 到达 OutSRAM
```

因此除最后一个输出点外，延迟写回到达时，`ComputeCoreData/SIMDData` 已经被下一输出点的开头 partial sum 覆盖。这个 partial sum 只有约 64 的量级，所以和 260..303 阈值比较后几乎全 0。

最后一个输出点不同：Ctrl 完成后进入 IDLE，默认 `oAccInstr=ACC_HOLD`，Accumulator 没有被下一点覆盖，所以最后一次延迟写回能看到完整累加值。这正好解释了当前现象：

```text
前 1023 个输出 word : 近似全 0
最后 1 个输出 word  : 有非零，acc 量级正确
```

## 6. 与当前 data_out 的关系

`build/data_out.txt` 最后三行非零：

```text
2046: 00001010011111010111000001010000
2047: 00100010110001100110011100001100
2048: 00100010110001100110011100001100
```

这和波形中最后一个 64-bit 写入非零一致。最后一行重复仍可能受 AHB burst read 保存相位影响，但它不是“全 0”主因。主因在运行期写入 OutSRAM 的数据本身已经基本全 0。

## 7. 后续验证计划

建议下一步仍然先不碰残差，专注普通卷积写回时序：

1. 在波形中对齐一个输出点的完整生命周期：

```text
round, cycle
FeatureProcessor.oFeatureData
InBuf.oInData
WeightSRAM.oDataa / WeightBuffer.oData
Accumulator.inst / iData / oData
SIMD.oSIMDData
writeEn/writeEnDelay*
oOutWriteEn/oOutWriteAddr
```

2. 对 `round=0` 手工确认：

```text
cycle 0..8 应累加 9 个 64-bit partial sum
最终 Accumulator 应接近 data_flow/layer1.0_conv1_output 第一个输出点的量级
OutSRAM 写入时 SIMDData 必须仍对应这个最终 Accumulator
```

3. 区分两种修复方向再动手：

```text
方案 A：延迟并锁存 SIMDData，使它与 oOutWriteEn/oOutWriteAddr 同步。
方案 B：在完成当前输出点后插入写回/hold 阶段，等写入完成后再启动下一输出点。
```

4. 修复后重新检查：

```text
OutWriteEn count = 1024
每次写回时 Acc min/max 应大致在 200..400 区间，而不是 50..80
data_out 与 layer1.0_tanh1_output 做格式转换后对拍
```

## 8. 结论

当前“输出全 0”不是因为没有运行，也不是因为 OutSRAM 没写。APU 已经完成 1024 次输出写回，但前 1023 次写回时 `SIMDData` 对应的不是完整卷积累加结果，而是下一输出点开始后的 partial sum。

最可能根因是 Ctrl 只延迟了写使能/写地址，没有同步延迟或保持 SIMD/Accumulator 数据，导致写回数据和写回控制错位。最后一个输出点因为进入 IDLE 后 Accumulator 保持，反而表现出正确量级，这与波形和 `data_out.txt` 的末尾非零完全吻合。
