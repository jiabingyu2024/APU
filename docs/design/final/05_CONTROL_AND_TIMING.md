# 05 控制微架构与周期时序

## 1. Ctrl 职责

Ctrl 是全设计唯一的计算时序所有者。它负责：

- 组合解码当前 instruction。
- 维护 `pingpong`、状态、kernel 计数和全局线性进度。
- 产生两块 Feature SRAM 的读源、shape、中心地址和写回。
- 产生 WeightSRAM 地址、读使能和 InBuf 控制。
- 产生 Accumulator `CLEAR/LOAD/ADD/HOLD`。
- 维护 SIMD 参数 entry。
- 在最后结果进入写回窗口时向 WorkSheet 返回 `ComputeDone`。

当前控制器不是 valid-ready 流水，而是依赖固定读延迟和固定相位。重建时可以
改成 token 化控制，但外部地址序列、数值结果和最终时序关系必须等价。

## 2. 状态机

| 状态 | 编码 | 作用 |
| --- | --- | --- |
| `IDLE` | `00` | 等待/接收当前 WorkSheet 指令，初始化新指令 |
| `CONV` | `01` | 3x3 主路径的连续 kernel 运算 |
| `CONV2` | `11` | residual shortcut 的附加 1 或 2 个累加拍 |

状态转换：

```text
IDLE --nCe=0 and valid instruction--> CONV
CONV --normal final item-----------> IDLE + ComputeDone + pingpong toggle
CONV --residual group main end-----> CONV2
CONV2 --shortcut words complete----> CONV
CONV2 --last output complete-------> IDLE + ComputeDone + pingpong toggle
```

`nCe=1` 强制 Ctrl 回 IDLE 并清大部分运行计数，但不清 `pingpong`。

## 3. 核心状态和计数器

| 名称 | 宽度 | 实际用途 |
| --- | ---: | --- |
| `pingpong` | 1 | 当前主路径 SRAM 方向 |
| `cycle` | 4 | 当前 9-cycle chunk 内相位；IG=1 时才等同 kernel |
| `cut_num` | 默认 15 | 每完成一个 9-cycle chunk 加 1；驱动像素/组/地址 |
| `round` | 5 | 总循环结束辅助计数，范围 `IG*OG` |
| `t` | 11 | 总循环结束辅助计数，范围 `Hout*Wout` |
| `res_flag` | 4 | CONV2 内 shortcut word 计数 |
| `CONV2_done` | 1 | 抑制同一 main block 重复跳入 CONV2 |
| `oWeightAddr` | 8 | 当前每个 bank 共用的读地址 |
| `oBNAddr` | 5 | 当前物理输出组的 SIMD entry |

注意：`round` 的注释称输出组，`t` 称输出位置，但当前数据地址并不直接使用二者。
`cut_num` 的展开顺序才是规范行为。按变量名重写循环会改变参数文件和物理布局。

## 4. 线性索引解释

令：

```text
IG = Cin/64
OG = Cout/64
TR = IG*OG
p  = floor(cut_num/TR)       // 输出像素
c  = cut_num % TR
chunk = c % IG               // 当前输出 word 内的 9-cycle chunk
og = floor(c/IG)             // 当前物理输出组
```

每个 `cut_num` 对应当前输出 word 主路径扁平项序列中的连续 9 拍。FeatureProcessor
内部实际顺序是 kernel 外层、input-group/depth 内层。定义：

```text
term = chunk*9 + cycle
kernel_position = floor(term/IG)
input_group     = term % IG
```

因此一个 normal 输出 word 在 IG 个 chunk、共 `9*IG` 拍后完成：

```text
ACC_LOAD: cycle==0 and chunk==0
ACC_ADD:  其余有效主路径项
write:    下一输出 word 开始的流水窗口
```

写地址按 `cut_num/IG` 压缩：

```text
IG=1 -> cut_num
IG=2 -> cut_num >> 1
IG=4 -> cut_num >> 2
```

语义上等价于 `p*OG+og`。

RTL 实现不使用通用 `/` 或 `%` 计算这些结果。因为 IG、OG 都是 1/2/4：

```text
total_group_shift = log2(IG) + log2(OG)
p = cut_num >> total_group_shift
```

写地址同样使用固定 bit slice。这里保留除法写法只是为了说明算法含义。

## 5. 主路径中心地址

### 5.1 Stride 1 normal

```text
center_addr = p*IG
```

FeatureProcessor 自己在该中心地址周围生成 3x3 偏移。

### 5.2 Stride 2 normal

当前代码使用固定网络等价式：

```text
row = p / (input_hw/2)
center_addr = p*2*IG + 32*row
```

其中常数 32 同时适配：

- 32x32x64：每跳到下一输出行，需要额外跨过一个输入行 32 words。
- 16x16x128：每跳到下一输出行，需要额外跨过一个输入行 32 words。

这不是通用公式。通用重写应使用：

```text
out_row = p / output_hw
out_col = p % output_hw
center_addr = (out_row*stride*input_hw + out_col*stride)*IG
```

但重写后必须核对当前所有地址序列。

### 5.3 Residual 主路径和 shortcut

Residual 指令中的 `in_hw` 描述主路径较小 feature：

```text
main_center = p*IG
shortcut input shape = (2*in_hw) x (2*in_hw) x (Cin/2)
shortcut groups SG = IG/2
shortcut_center = (out_row*2*(2*in_hw) + out_col*2)*SG
```

当前 Ctrl 的硬编码等价式为：

```text
hang_temp = p/(in_hw/2)
shortcut_center = main_center + 32*(hang_temp/2)
```

仅对 layer2 和 layer3 的固定 shape 成立。

## 6. Feature SRAM 控制

读使能选择：

| `pingpong` | `CONV` | `CONV2` |
| ---: | --- | --- |
| 0 | Act read | Out read |
| 1 | Out read | Act read |

主路径 SRAM 使用 `kernel_size=3` 和 `logInC`；另一块 SRAM在 residual 中使用
`kernel_size=1`、空间尺寸 `2*in_hw`、通道 log2 `logInC-1`。

Normal 指令中非主 SRAM 的 shape 输出为 0，且读使能关闭。

## 7. Weight 地址序列

Normal：

```text
weight_span = 9*IG*OG
address = wAddr ... wAddr+weight_span-1, then wrap
```

对单个 physical output group，顺序等价于：

```text
for kernel in 0..8:
  for input_group in 0..IG-1:
    address = wAddr + output_group*(9*IG) + kernel*IG + input_group
```

Residual：

```text
main words     = 9*IG*OG
shortcut words = (IG/2)*OG
weight_span    = main words + shortcut words
```

每个 CONV 和 CONV2 周期都推进一次地址。地址在全 span 末端回到 `wAddr`，
从而对每个新像素重复同一组卷积权重。

如果只在 CONV 推进权重地址，combined 文件中的 shortcut 权重会错位；如果为
首项额外停一拍，也会破坏整个 combined 序列。

## 8. Accumulator 控制

编码：

| `oAccInstr` | 行为 |
| --- | --- |
| `00` | clear to zero |
| `01` | load current 7-bit popcount |
| `10` | add current popcount |
| `11` | hold |

Ctrl 先产生 `oAccInstr_notdelay`，再寄存一拍得到 `oAccInstr`。该一拍与
FeatureSRAM/InBuf 和 WeightSRAM/WeightBuffer 的固定相位共同构成正确流水。

当前 3x3 normal 的累加项数：

```text
9*IG
```

Residual 的累加项数：

```text
9*IG + IG/2
```

CONV2 没有重新 LOAD；它继承 CONV 末尾的 ADD 语义，把 shortcut popcount 加到
主路径 accumulator。

## 9. 写回控制

SIMD 为组合逻辑，FeatureProcessor 在 `posedge`、`nWe=0` 时写入。Ctrl 的
`*_notdelay` 写使能和地址再寄存一拍后接 SRAM。

稳态写回触发条件：

```text
cycle==0 && cut_num!=0 && cut_num%IG==0
```

这表示“下一物理输出 word 已开始，前一 word 的最终累加值正在写回窗口”。
最后一个 word 没有自然的下一 word，Ctrl 在 `ComputeDone/IDLE` 交接分支补发尾部
写使能，并根据已经翻转的 ping-pong 反向选择上一条指令的目标 SRAM。

若删除尾部补写，整层最后一个 64-bit word 丢失；若在 `ComputeDone` 当拍直接按
新 ping-pong 选择目标，最后 word 会写入错误 SRAM。

## 10. BN 地址

首个 output word 将 `oBNAddr=bnAddr`。每出现实际注册写使能后，地址在：

```text
bnAddr ... bnAddr+OG-1
```

循环。它必须与物理写地址中的 output-group 次序一致。当前 physical group 的
canonical 含义是反序，转换由参数布局和 dump adapter共同承担。

## 11. Normal 3x3 首点逐拍示例

以下为 `IG=1` 的已观测相位，E0 是 CONV 中逻辑 kernel0 的首个时钟沿：

| Edge | 地址/数据 | Acc/写回 |
| --- | --- | --- |
| E0 | 发出 feature/weight kernel0 地址 | accumulator clear |
| E1 | SRAM 输出 kernel0；发 kernel1 | 打开 buffer 写 |
| E2 | InBuf/WeightBuffer 锁存 kernel0 | `AccInstr` 对齐为 LOAD |
| E3 | 组合 popcount(kernel0) 被 accumulator 装载 | - |
| E4..E10 | 连续处理后续 kernel | 连续 ADD |
| E11 | kernel8 最终值进入 accumulator，前一点写控制有效 | SIMDData 形成 |
| E12 | 目标 Feature SRAM 采样 SIMDData | accumulator 可 LOAD 下一点 |

首点约 12 拍完成物理写入，稳态每 9 拍写一个 64-channel word。

## 12. 指令交接时序

上一指令完成时：

1. Ctrl 产生 `ComputeDone` 并翻转 ping-pong。
2. WorkSheet 在时钟沿选择下一 instruction。
3. Ctrl 回 IDLE，InBuf 禁写。
4. `oInputBufSelect` 在 IDLE/禁写阶段预先等于新 ping-pong。
5. 新指令进入 CONV，Feature/Weight 两条同步读路径填充。
6. 延迟后的 `ACC_LOAD` 采样新指令首项。

步骤 4 是 layer2 residual 首 word 修复点。删掉后只有首项可能错误，容易被误判为
BN 或边界问题。

## 13. 当前等价时序优化

Vivado 已确认 Ctrl 的关键路径起点为 `cut_num_reg`，终点为
`featureMemory_data_out_reg`。优化前 Ctrl 在一个周期中执行：

```text
64 bit cut_num
-> 动态除以 IG*OG
-> 动态除以 input_hw/2
-> 宽乘法和加法
-> FeatureProcessor 地址计算
-> featureMemory_data_out_reg
```

当前实现利用所有合法参数都是 2 的幂，将 Ctrl 部分改为：

```text
15 bit cut_num
-> 固定右移选择
-> 固定右移选择
-> 固定左移和加法
-> FeatureProcessor 地址计算
-> featureMemory_data_out_reg
```

同时做了以下收窄：

- `groups_per_pixel`：16 bit -> 5 bit；
- `pixels_per_group`：16 bit -> 11 bit；
- `weight_span`：16 bit -> 8 bit；
- `cycle/round/t`：8/16/16 bit -> 4/5/11 bit；
- 地址计算中间量：64 bit -> 默认 15 bit。

没有插入新寄存器，因此计算周期数、SRAM 地址序列、累加控制、写回和
`ComputeDone` 时刻均保持不变。Verilator 全网络回归正常结束，六项参考输出均为
0 mismatch。

FeatureProcessor 内部仍有中心地址到 row/col 的组合运算，因此完成本次 Ctrl 优化后，
需要重新查看 Vivado 最差路径，确认瓶颈是否已经转移到 FeatureProcessor 内部。

## 14. 推荐的后续等价重构

为了可综合性和可维护性，可以把当前控制重构为：

```text
INIT -> PREFILL -> RUN -> DRAIN -> DONE
```

并让 token 携带 `{pixel,og,ig,kernel,first,last,write_addr,bn_addr}` 随数据路径延迟。
但必须满足：

- 两条 SRAM 路径 latency 参数化且一致。
- residual shortcut 插入位置与 combined 权重顺序一致。
- 物理 feature group 顺序保持兼容，或全软件栈同步迁移。
- 最终 `make check` 六项均为 0 mismatch。
