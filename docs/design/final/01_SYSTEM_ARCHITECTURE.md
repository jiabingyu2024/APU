# 01 系统架构

## 1. 架构范围

APU 是面向 CIFAR-10 二值 ResNet 中间层的专用加速器。CPU/PS 负责装载二值
特征、二值权重、融合 BN 阈值和指令；APU 负责 3x3 二值卷积、跨输入通道组
累加、residual 合并、阈值比较和二值写回。

它不是超标量处理器，也没有动态调度、缓存一致性或虚拟存储。其控制模型是
一个 worksheet 顺序发射器加单发射卷积控制器。

## 2. 顶层层次

```text
Top
|-- ahb_slave_top
|   |-- ahb_slave       AHB-Lite 风格前端
|   |-- addr_map        寄存器和 RAM 窗口解码
|   `-- ram_mux         32/64-bit 适配和 RAM 片选
|-- WorkSheet           16 x 32-bit 指令存储及顺序发射
|-- Ctrl                指令解码、循环、地址、写回、ping-pong
|-- FeatureProcessor    ActSRAM，1024 x 64 bit
|-- FeatureProcessor    OutSRAM，1024 x 64 bit
|-- InBuf               激活寄存及 residual replay
|-- ComputeCoreGroup    64 个并行输出通道 core
|   `-- ComputeCore x64
|       |-- WeightSRAM  256 x 64 bit
|       |-- WeightBuffer
|       |-- Multiplier  64 路 XOR
|       |-- AdderTree   64 项 popcount
|       `-- Accumulator 12 bit
`-- SIMD                64 路阈值比较及参数 RAM
```

## 3. 顶层参数基线

| 参数 | 值 | 含义 |
| --- | ---: | --- |
| `P_INSTRUCTION_NUM` | 16 | worksheet 物理深度 |
| `P_BINDWIDTH` | 64 | 特征数据和输入通道组宽度 |
| `P_FEATURE_MEMORY_SIZE` | 65536 bit | 每块 Feature SRAM 容量 |
| `P_GROUP` | 64 | 并行输出通道数 |
| `P_WORDS_WE` | 256 | 每个权重 bank 深度 |
| `P_BITWIDTH_WE` | 64 | 每个权重 word 宽度 |
| `P_OUTBITWIDTH_ACC` | 12 | Hamming 累加结果宽度 |
| `P_CHANNELS` | 64 | SIMD 并行通道数 |
| `P_COMPAREWIDTH` | 13 | 1 bit 方向加 12 bit 阈值 |
| `P_TOTAL64BN` | 32 | 每个 SIMD channel 的参数深度 |

派生容量：

```text
ActSRAM/OutSRAM: 1024 x 64 bit
WeightSRAM:      64 banks x 256 x 64 bit
SIMD params:     32 entries x 64 channels x 13 bit
WorkSheet:       16 x 32 bit
```

## 4. 运行模式

### 4.1 配置模式

`data_ram_ctrl=1` 时 AHB 控制 ActSRAM/OutSRAM 的地址和数据；
`conv_ram_ctrl=1` 时 AHB 控制 WeightSRAM 的读地址。权重和 SIMD 参数写端由
AHB 请求直接驱动，软件协议必须保证 APU 未运行。

```text
AHB -> ram_mux -> Act/Out/Weight/SIMD/WorkSheet
```

### 4.2 计算模式

软件写 `RAM_CTRL=0` 后由 Ctrl 接管运行路径：

```text
源 Feature SRAM
  -> 同步读
  -> InBuf
  -> 64 x (XOR64 + popcount + accumulator)
  -> SIMD 严格阈值比较
  -> 目标 Feature SRAM
```

每条指令只使用一组 64 个 PE，但可通过时间复用处理 1、2 或 4 个输入组和
1、2 或 4 个输出组。

## 5. Ping-pong 数据流

`Ctrl.pingpong` 是 Feature SRAM 角色的唯一运行期状态：

| `pingpong` | 主路径读源 | 主路径写目标 |
| ---: | --- | --- |
| 0 | ActSRAM | OutSRAM |
| 1 | OutSRAM | ActSRAM |

复位将其置 0。每条完整计算指令结束时翻转一次；`nCe`、worksheet 批次完成或
重新装载 worksheet 均不会将其清零。

因此复位后累计完成 `N` 条指令时：

```text
N 为奇数：最新结果在 OutSRAM
N 为偶数：最新结果在 ActSRAM
```

如果删掉每指令一次的翻转，下一条指令会读旧 SRAM；如果在每批 worksheet
结束时错误清零，分批执行的 layer3 会从错误的数据源开始。

## 6. 计算并行度和数值含义

每拍有效数据包含 64 个输入通道 bit。64 个 ComputeCore 共享该激活 word，
每个 core 从自己的 WeightSRAM bank 读取一个 64-bit 权重 word：

```text
每个 core: XOR64 -> popcount[0..64] -> 12-bit accumulator
全阵列:    64 输出通道 x 64 输入通道 = 4096 bit 运算/有效拍
```

Accumulator 保存的是 XOR/Hamming distance 之和，不是有符号点积。若总二值项数
为 `N`，软件侧 `+1/-1` 点积与硬件累计值 `H` 的关系为：

```text
dot = N - 2*H
```

BN 参数生成必须把浮点 BN/sign 判定变换到 Hamming 域；RTL 不再执行该换算。

## 7. 时钟、复位和 CDC

- 只有一个功能时钟 `clk/hclk`，当前设计无 CDC。
- 外部和多数状态寄存器使用低有效异步复位 `nRst/hresetn`。
- WeightSRAM 数组和读数据没有复位。
- FeatureProcessor 和 SIMD 参数阵列在异步复位分支中逐项清零，这是仿真行为，
  不应直接作为 ASIC SRAM macro 实现。
- 重新实现时若改为同步释放或 memory wrapper，必须保持可见读写延迟不变。

## 8. 关键实现不变量

1. 激活 SRAM 路径和权重 SRAM 路径到组合计算前均为两级寄存延迟。
2. `ACC_LOAD` 只采样一个输出 word 的第一项，之后全部使用 `ACC_ADD`。
3. SIMDData 是组合输出，写回沿到达前 accumulator 和 BN 地址必须稳定。
4. 写回地址按物理输出 word 递增，不按 32-bit AHB beat 递增。
5. 一条 residual 指令内部的 `CONV/CONV2` 只对应一次 ping-pong 翻转。
6. worksheet 一批完成只清指令计数，不改变网络的 ping-pong 历史。
7. 内部多通道组物理顺序与 golden 顺序不同，必须按第四章解释。

违反任一项通常不会导致编译错误，而会表现为整层错位、首个输出 word 错误或
只在阈值附近出现少量 bit mismatch。

