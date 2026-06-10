# 06 RTL 模块合同

## 1. Top

### 1.1 定位

`Top` 只负责模块连接、owner mux 和参数传播，不拥有网络循环状态。顶层实例名和
默认参数应保持与现有 TB 兼容。

### 1.2 外部端口

| 信号 | 方向 | 宽度 | 作用 |
| --- | --- | ---: | --- |
| `clk` | in | 1 | 唯一功能时钟 |
| `nRst` | in | 1 | 低有效异步复位 |
| `hsel` | in | 1 | AHB slave select |
| `haddr` | in | 32 | AHB byte address |
| `htrans` | in | 2 | bit1 表示有效传输 |
| `hwrite` | in | 1 | 读写方向 |
| `hsize` | in | 3 | 透传但内部不校验 |
| `hburst` | in | 3 | 透传但内部不维护 burst 状态 |
| `hwdata` | in | 32 | 写数据相位 |
| `hready` | in | 1 | 当前实现未使用 |
| `hlock/hprot` | in | 1/4 | 当前实现未使用 |
| `hrdata` | out | 32 | 读数据 |
| `hresp` | out | 2 | 固定 OKAY |
| `hreadyout` | out | 1 | 固定 ready |
| `int_cal` | out | 1 | sticky 计算完成 |

### 1.3 Owner mux

Feature SRAM 地址和写数据由 `data_ram_ctrl` 选择 AHB 或 Ctrl。当前 enable 是
AHB 请求和 Ctrl 请求 OR 后取反：

```text
nCe = !(ahb_read_en | ctrl_read_en)
nWe = !(ahb_write_en | ctrl_write_en)
```

因此软件必须保证两端不并发。若只 mux 地址而允许另一个 owner 的 enable 到达，
会形成“AHB enable + Ctrl address”或相反的混合事务。

## 2. ahb_slave_top

组合 `ahb_slave + addr_map + ram_mux`，不引入额外状态。它把外部总线翻译成：

- worksheet 32-bit 端口；
- Act/Out 64-bit AHB 端口；
- Weight 64-bit bank 端口；
- SIMD 13-bit channel 端口；
- RAM owner、启动和完成信号。

重新实现可合并三个子模块，但必须保持相同地址/数据相位。

## 3. ahb_slave

### 3.1 行为

```text
ready_en = hsel && htrans[1]
wr_en    = ready_en && hwrite
rd_en    = ready_en && !hwrite
```

- `t_raddr` 组合等于有效读地址，否则为 0。
- `t_rden` 组合等于 `rd_en`。
- `t_waddr` 在任意 `hsel` 时钟沿锁存 `haddr[13:0]`。
- `t_wren` 将 `wr_en` 寄存一拍。
- `t_wdata=hwdata`，利用 AHB 写数据后一拍到达。
- `hrdata=t_rdata`。

如果把 `t_wren` 改成组合信号而不重做写数据相位，地址和 `hwdata` 将错一拍。

## 4. addr_map

### 4.1 寄存器

| 寄存器 | 复位 | 更新 |
| --- | --- | --- |
| `ram_sel_reg[7:0]` | 0 | 写 `0x2004` |
| `ram_ctrl_reg[1:0]` | 0 | 写 `0x2000` |
| `apu_ready` | 0 | 写 `0x2008` 的 bit0；无写事务下一拍清零 |
| `cal_cpl_r` | 0 | `cal_cpl` 置位；读 `0x200C` 清零 |
| `t_raddr_d` | 0 | 有效读时锁存，用于返回 mux |

`CPL` 返回的是 `cal_cpl_r` 的一拍延迟副本，TB 通过 `int_cal` 等待后再读。

### 4.2 RAM 地址

```text
ram_waddr = t_waddr[12:2]
ram_raddr = t_raddr[12:2]
ram_wdata = t_wdata
```

当前 `ram_space` 由 `t_waddr < 0x2000` 生成，并同时门控读写。由于 `t_waddr` 在
有效读地址相位也会被锁存，现有 TB 流程可用，但该耦合不适合作为通用总线设计。
重构时应分别用读地址和写地址判断，同时保持标准回归。

## 5. ram_mux

### 5.1 片选和地址变换

| 目标 | write enable | internal addr |
| --- | --- | --- |
| SIMD | `ram_sel[7:6]==00 && ram_wen` | `ram_waddr[4:0]` |
| Weight | `ram_sel[7:6]==01 && ram_wen && ram_waddr[0]` | `ram_waddr[8:1]` |
| Act | `ram_sel==128 && ram_wen && ram_waddr[0]` | `ram_waddr[10:1]` |
| Out | `ram_sel==129 && ram_wen && ram_waddr[0]` | `ram_waddr[10:1]` |
| WorkSheet | `ram_sel==130 && ram_wen` | `ram_waddr[3:0]` |

Weight/Feature 读地址同样右移一位。`ram_raddr_d[0]` 决定返回 64-bit word 的低/高
半字。删除该延迟会用下一拍地址选择当前 RAM 返回值。

### 5.2 写合并寄存器

`ram_wdata_r` 在任意 RAM 窗口偶数 word 写时保存 32 bit；目标 64-bit RAM 在奇数
word 写时接收 `{ram_wdata,ram_wdata_r}`。该寄存器是跨 bank 共享的，所以主机
协议必须保证一对 half-word 连续写同一个目标。

## 6. WorkSheet

### 6.1 接口

| 信号 | 方向 | 语义 |
| --- | --- | --- |
| `nWe` | in | 低有效写 instruction RAM |
| `iWriteAddr/Data` | in | AHB 写端 |
| `iReadAddr` | in | AHB 同步读地址 |
| `iAPUReady` | in | 启动单拍 |
| `iComputeDone` | in | 当前指令结束 |
| `oCtrlnCe` | out | Ctrl 低有效使能 |
| `oInstruction` | out | 当前执行指令 |
| `oWorkSheetDone` | out | 全批完成单拍源 |
| `oWorkSheetData` | out | AHB 同步读数据 |

### 6.2 状态行为

内部 `IDEL=1` 表示空闲：收到 `iAPUReady` 后输出地址 0 指令，`oCtrlnCe=0`。
运行中每次 `iComputeDone`：

- 若当前是最后指令，产生 `oWorkSheetDone=1`，回地址 0、清计数、关闭 Ctrl。
- 否则在同一沿切换到下一地址指令。

指令数按每次写事务 `totalInstrCount++`。必须遵守第三章限制。

## 7. Ctrl

完整行为见 [05_CONTROL_AND_TIMING.md](05_CONTROL_AND_TIMING.md) 和
[07_RESIDUAL_PATH.md](07_RESIDUAL_PATH.md)。接口按所有权分组：

| 输出组 | 信号 |
| --- | --- |
| Act read | center address、read enable、kernel size、HW、logCin |
| Act write | address、enable |
| Out read/write | 与 Act 对称 |
| InBuf | active-low write enable、source select |
| Compute | WeightAddr、WeightReadEn、AccInstr |
| SIMD | BNAddr |
| WorkSheet | ComputeDone |

关键寄存延迟：写使能/写地址 1 拍；AccInstr 1 拍；InputBufSelect 为时序输出。

## 8. FeatureProcessor

### 8.1 存储端口

| 信号 | 语义 |
| --- | --- |
| `nWe` | 低有效同步写 |
| `iWriteAddr/Data` | 64-bit 写端 |
| `nCe` | 低有效同步读和窗口计数使能 |
| `iReadCenterAddr` | 当前卷积中心的组 0 物理地址 |
| `iKernelSize` | 3 时生成 3x3，否则中心读取 |
| `inHW` | 空间宽高 |
| `iDepth` | 64-channel 组数 |
| `oFeatureData` | 一拍 RAM 输出，经延迟 zero mask 选择 |

### 8.2 内部计数

`countDepthCycles` 为最内层，遍历 `0..iDepth-1`；到末组后推进
`countConvCycles`。3x3 后者遍历 0..8，否则保持 0。`nCe=1` 时二者清零。

### 8.3 读时序

在 `nCe=0` 的时钟沿：

1. `featureMemory[safeReadAddr]` 进入读数据寄存器。
2. `zeroMask` 和 `kernel3x3` 同时进入对齐寄存器。
3. 组合输出在 3x3 越界时为 0，否则为读数据寄存器。

`safeReadAddr` 当前直接等于可能回卷的 `readAddr`，安全性来自 mask，不是地址钳位。

### 8.4 复位

当前仿真模型在异步复位中循环清 1024 个 word。ASIC 重建应换 memory wrapper，
但软件装载前不可读取未初始化内容。

## 9. InBuf

接口：两个 64-bit SRAM 数据输入、`iSelect`、低有效 `nWe`、instruction 和低有效
chip enable。`oInData` 在 `nCe=1` 时强制 0。

Normal：`nWe=0` 的时钟沿把选择的数据锁存到 `rBuf`，延迟 1 拍。

Residual：额外保存 shortcut 数据并在后续输出组 replay。精确周期见第七章。
当前 latch 写法可以等价改成寄存器，但不能删除 replay 功能。

## 10. WeightSRAM

单 bank 端口：

| 端口 | 行为 |
| --- | --- |
| `iAddrb/iData/nWe` | `nWe=0` 时同步写 |
| `iAddra/nCe/oDataa` | `nCe=0` 时同步读，延迟 1 拍 |

无复位。读写同地址行为由 RTL nonblocking 语义和目标 memory 决定，当前软件避免
计算期间写权重。

## 11. WeightBuffer

64-bit 单级寄存器，低有效复位；`enable=1` 时采样 WeightSRAM 输出。顶层连接
`enable=!InputBufNWe`，使权重和激活在进入组合计算前具有相同的两级延迟。

如果删除 WeightBuffer 而不调整 Ctrl，权重会比激活早一拍，所有 popcount 属于
不同 kernel 项。

## 12. Multiplier

64 路纯组合 XOR：

```systemverilog
oData[i] = iDataA[i] ^ iDataB[i];
```

模块名是历史命名，不代表算术乘法。

## 13. AdderTree

纯组合 64 项无符号求和，默认输出 7 bit，可表示 0..64。当前用 for-loop 累加，
综合器自行平衡加法网络。若插入流水寄存器，必须把 token/AccInstr 同步延迟。

## 14. Accumulator

输入 7 bit，输出 12 bit，零扩展后执行 clear/load/add/hold。无饱和、无符号、
自然模 4096 溢出；当前最大 residual Hamming 项数 `36*64+2*64=2432`，不会溢出。

复位异步清零。`inst=11` 和 default 均保持。

## 15. ComputeCore

一个 core 拥有一个 WeightSRAM bank、WeightBuffer、XOR64、popcount 和 accumulator。
激活由 64 个 core 共享，权重和 accumulator 私有。`oWeightData` 只用于 AHB 读回。

关键路径：

```text
InBuf Q + WeightBuffer Q -> XOR -> 64-input popcount -> Accumulator D
```

## 16. ComputeCoreGroup

生成 64 个 ComputeCore。写权重时只有：

```text
weightWriteSelect == core_index
```

的 bank 得到有效低 `nWeightWe`。读计算时所有 bank 使用同一 `weightReadAddr`，
并行返回 64 个输出通道的权重。

AHB 读回通过 `weightWriteSelect` 复用选择某 bank 的 `oWeightData`。

## 17. SIMD

### 17.1 参数 RAM

写端：`nWe=0` 时把 `iWriteData[12:0]` 写到
`SIMD_Reg[iWriteAddr][iChannel]`。当前异步复位清空整个二维阵列。

读回端：每拍把 `SIMD_Reg[iAddr][iChannel]` 寄存到 `oReadData`。

### 17.2 计算端

64 lane 纯组合比较：

```text
dir=1 -> acc > threshold
dir=0 -> acc < threshold
equal -> 0
```

`iAccData` 只有 12 bit，参数低 12 bit。输出 64 bit 直接连接两块 Feature SRAM
写数据端，不再寄存。

## 18. 重建接口检查表

1. 所有 active-low 信号极性与本章一致。
2. Feature/Weight RAM 都是一拍同步读。
3. InBuf/WeightBuffer 各再增加一拍。
4. XOR/AdderTree/SIMD 不增加寄存级。
5. Accumulator 和 Feature 写入发生在时钟沿。
6. Weight bank、SIMD lane、输出 bit 索引一致。
7. WorkSheet 完成和 Ctrl ping-pong 的所有权没有混入 Top。

