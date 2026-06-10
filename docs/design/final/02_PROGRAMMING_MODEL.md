# 02 编程模型与外部接口

## 1. AHB 接口约束

顶层端口提供 32-bit AHB-Lite 风格 slave：`hsel/haddr/htrans/hwrite/hsize/
hburst/hwdata` 输入，`hrdata/hresp/hreadyout` 输出。

当前实现约束：

- `hreadyout` 永远为 1，不插入 wait state。
- `hresp` 永远为 OKAY。
- 只验证 32-bit word 访问；`hsize/hburst` 不参与内部合法性检查。
- 不支持 byte enable、unaligned access、错误响应或并发 master 仲裁。
- 写地址在地址相位寄存，`hwdata` 在后一拍作为数据相位使用。
- RAM 读为同步路径，主机必须按 TB 所示相位采样返回数据。

## 2. 地址空间

| Byte 地址 | 权限 | 名称 | 语义 |
| --- | --- | --- | --- |
| `0x0000-0x1FFF` | RW | RAM window | 访问 `RAM_SEL` 当前选中对象 |
| `0x2000` | RW | `RAM_CTRL` | bit0 数据 RAM owner；bit1 权重读 owner |
| `0x2004` | RW | `RAM_SEL` | RAM slice/bank 选择 |
| `0x2008` | WO | `APU_READY` | 写 bit0=1 产生单拍启动请求 |
| `0x200C` | RO | `CPL` | sticky 完成状态；读取会清除 |

内部 `T_ADDR_WID=14`，只解码 `haddr[13:0]`。

### 2.1 `RAM_CTRL`

| 位 | 0 | 1 |
| --- | --- | --- |
| bit0 `data_ram_ctrl` | Ctrl 地址/数据 | AHB 地址/数据 |
| bit1 `conv_ram_ctrl` | Ctrl 权重读地址 | AHB 权重读地址 |

软件必须在装载和读回阶段写 `3`，启动前写 `0`。当前顶层并未把所有 enable
都严格按 owner 隔离，所以禁止 AHB 与 APU 同时访问内部 RAM。

### 2.2 `RAM_SEL`

| 值 | 对象 | RAM 窗口地址含义 |
| ---: | --- | --- |
| `0..63` | SIMD 参数 channel 0..63 | entry index `addr[6:2]` |
| `64..127` | WeightSRAM bank 0..63 | 32-bit half-word 地址 |
| `128` | ActSRAM | 32-bit half-word 地址 |
| `129` | OutSRAM | 32-bit half-word 地址 |
| `130` | WorkSheet | 32-bit instruction index |

## 3. 32/64-bit 适配

WeightSRAM、ActSRAM、OutSRAM 的内部 word 为 64 bit。`ram_mux` 使用相邻两个
32-bit 写事务组成一个 word：

```text
window word address even: 保存为 low32
window word address odd:  写 {current_data, saved_low32}
internal_addr = window_word_addr >> 1
```

主机写入顺序必须是低 32 bit 后高 32 bit。若从奇地址开始，或中间插入另一个
64-bit RAM 的低半字，`ram_wdata_r` 会把不相关数据拼入当前 word。

读回时：

```text
even AHB word address -> internal word[31:0]
odd  AHB word address -> internal word[63:32]
```

Golden 文本通常按高 32 bit、低 32 bit 两行显示，TB dump 会执行半字重排。

SIMD 参数只使用每个 32-bit 写数据的低 13 bit，不执行 64-bit 合并。WorkSheet
直接存完整 32-bit word。

## 4. 启动和完成协议

推荐软件序列：

1. 写 `RAM_CTRL=3`。
2. 选择 `RAM_SEL=128`，装载初始输入。
3. 逐 bank 装载权重，逐 channel 装载 SIMD 参数。
4. 选择 `RAM_SEL=130`，从 worksheet 地址 0 连续写指令。
5. 写 `RAM_CTRL=0`，停止 AHB RAM 访问。
6. 写 `APU_READY=1`；该寄存器在无写事务的下一拍自动清零。
7. 等待 `int_cal=1` 或轮询 `CPL`。
8. 读取 `CPL` 清 sticky 完成位。
9. 写 `RAM_CTRL=3`，选择最新结果所在 Feature SRAM 并读回。

`int_cal` 是完成 sticky 位，而不是单拍脉冲。`cal_cpl` 来自
`WorkSheetDone`；读取 `CPL` 后清除。

## 5. WorkSheet 编程限制

WorkSheet 当前采用“写事务计数”而不是“最高地址+1”作为指令数：

- 必须从地址 0 开始连续写入。
- 不允许稀疏写、重复覆盖后直接启动或运行期间写入。
- 一批完成后 `totalInstrCount` 清零，下一批必须重新从地址 0 写。
- 物理深度是 16，但 4-bit `totalInstrCount` 写满 16 条会回卷；当前安全上限
  应视为 15 条，已验证批次最多 8 条。

Layer3 每个 op 都覆盖 worksheet 地址 0 并单独启动，这是容量策略，不会重置
Ctrl 的 ping-pong。

## 6. Feature SRAM 读回选择

按硬复位以来累计完成的计算指令数，而不是 `run_apu()` 次数判断：

| 累计指令数 | 最新结果 | `RAM_SEL` |
| ---: | --- | ---: |
| 0 | 初始输入 | 128 |
| 奇数 | OutSRAM | 129 |
| 偶数 | ActSRAM | 128 |

一条 residual 指令虽然进入两个状态，仍只计一条指令。

## 7. 主机侧容量检查

普通卷积每个 PE bank、每个输出组需要：

```text
weight_words64 = K*K*(Cin/64)
weight_words32 = 2*weight_words64
```

Residual combined 每个 PE bank、每个输出组需要：

```text
weight_words32 = (2*K*K + 1)*(Cin/64)
weight_words64 = weight_words32/2
```

后式只适用于当前 combined 文件协议，并要求 32-bit 行数为偶数。装载器必须检查：

```text
wAddr + weight_words64*output_groups <= 256
bnAddr + output_groups <= 32
```

Layer1+2 的权重可共同驻留在地址 0..163；完整 layer3 不能共同驻留，因此四个
layer3 op 分别装载并重用地址 0。

## 8. 接口级禁止事项

- 禁止运行中写 `RAM_SEL/RAM_CTRL` 并同时发 RAM 事务。
- 禁止把 `RAM_SEL=128` 简化理解为“输入”，它只是物理 ActSRAM。
- 禁止按 worksheet 批次数重置 ping-pong 推导。
- 禁止改变 WeightSRAM/FeatureSRAM 同步读延迟而不同时重做 Ctrl 对齐。
- 禁止把 AHB dump 原始顺序直接与 canonical golden 比较。

