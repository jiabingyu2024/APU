# 04 数据表示与存储布局

## 1. 二值编码

软件网络的二值值与硬件 bit 映射为：

| 数学值 | bit |
| ---: | ---: |
| `+1` | 0 |
| `-1` | 1 |

激活和权重逐 bit XOR：相同符号得到 0，不同符号得到 1。AdderTree 对 64 个
XOR bit 求和，因此 partial sum 是当前 64 输入通道中的不匹配数。

不要把 `Multiplier` 改成 XNOR 或把 accumulator 解释为匹配数；这样会要求全部
BN 阈值重新生成。

## 2. Feature SRAM 基本布局

每块 Feature SRAM 是 1024 x 64 bit。一个内部 word 表示一个空间点的一组
64 通道。对 `G=C/64`：

```text
physical_addr = pixel_index*G + physical_group
pixel_index   = row*W + col
```

FeatureProcessor 将 `iDepth` 解释为 G。3x3 地址偏移为：

```text
rowOffset = W*G
colOffset = G
```

kernel 位置 0..8 对应：

```text
0 (-1,-1)  1 (-1,0)  2 (-1,+1)
3 ( 0,-1)  4 ( 0,0)  5 ( 0,+1)
6 (+1,-1)  7 (+1,0)  8 (+1,+1)
```

每个 kernel 位置内，`countDepthCycles` 从 0 到 `G-1`，即输入组先遍历完再进入
下一个 kernel 位置。

## 3. Canonical 与物理通道组顺序

Golden 文件按 canonical 组 `0,1,...,G-1` 排列；当前参数文件和 RTL 组合在
Feature SRAM 中形成相反的语义组顺序：

```text
physical group p <-> canonical group (G-1-p)
```

| 通道数 | SRAM 地址递增的 canonical 组 | dump 转换 |
| ---: | --- | --- |
| 64 | 0 | 无组交换 |
| 128 | 1,0 | 每像素输出 0,1 |
| 256 | 3,2,1,0 | 每像素输出 0,1,2,3 |

这不是简单的 32-bit 高低半字问题。半字顺序和 64-channel 组顺序是两个独立层次：

1. AHB 内一个 64-bit word：低 32 先传，高 32 后传。
2. Golden 文本内一个 64-bit word：高 32 行先写，低 32 行后写。
3. 一个像素的多个 64-channel 组：TB 再逆转 group 顺序。

`ahb_read_burst_save_named` 因而先缓存 `2*G` 个 32-bit word，再从 group
`G-1` 降到 0，且每组输出 high32、low32。

如果重新生成 RTL 时改成 canonical group 顺序，必须同步修改参数文件装载和 TB
adapter；只改写地址会使层内可能通过、层间输入通道却错位。

## 4. Feature 文件尺寸

| Tensor | internal 64-bit words | AHB 32-bit words/文本行 |
| --- | ---: | ---: |
| 32x32x64 | 1024 | 2048 |
| 16x16x128 | 512 | 1024 |
| 8x8x256 | 256 | 512 |

三个阶段都不超过单块 1024-word Feature SRAM。

## 5. Padding 行为

FeatureProcessor 对 3x3、stride 1/2 使用同尺寸卷积意义下的 zero padding。
边界判断基于中心地址还原出的 `centerRow/centerCol`。越界 kernel 位置仍可产生
地址回卷，但 `zeroMaskReg` 与同步 RAM 读对齐后强制 `oFeatureData=0`。

必须同步寄存 mask；若直接使用组合 `zeroMask`，它会对应下一地址而不是当前
RAM 返回数据，边界像素会错一拍。

## 6. WeightSRAM 组织

共有 64 个 bank，每个 bank 对应当前物理输出组中的一个 PE/lane。每个 bank
存 256 个 64-bit word，一个 word 是一个输出通道在一个 kernel 位置和一个输入
通道组上的 64 个二值权重。

普通权重文件为 32-bit 文本行，逻辑组织：

```text
for output_group j:
  for PE i in 0..63:
    2*K*K*in_groups consecutive 32-bit lines
```

每个 output group 内的 64-bit word 顺序是 kernel 外层、input-group 内层。TB 对
`(j,i)` 选择 `RAM_SEL=64+i`，把对应片段写到：

```text
bank_addr64 = wAddr + j*K*K*in_groups + kernel*in_groups + input_group
```

`ram_mux` 将相邻两行拼成一个 64-bit word。

文件行数校验：

```text
line_count = out_groups*64*2*K*K*in_groups
```

例如 layer3.1 256->256：`4*64*2*9*4 = 18432` 行。

## 7. Residual combined 权重

当前 combined 文件不是“普通 conv2 文件后直接附一个完整普通卷积”。每个
输出组、每个 bank 的 32-bit 行数由已验证装载协议定义：

```text
lines32_per_bank_group = (2*K*K + 1)*in_groups
words64_per_bank_group = lines32_per_bank_group/2
```

| residual | in_groups | lines32/group | words64/group |
| --- | ---: | ---: | ---: |
| layer2.0 | 2 | 38 | 19 |
| layer3.0 | 4 | 76 | 38 |

总文件行数分别是 `2*64*38=4864` 和 `4*64*76=19456`。

Ctrl 在主 3x3 权重序列中穿插 `CONV2` 额外权重拍，InBuf 同步切到 shortcut 或
replay 数据。文件生成顺序必须与该拍序列一致，不能只按数学张量维度重排。

## 8. SIMD/BN 参数布局

SIMD 参数逻辑阵列：

```text
SIMD_Reg[entry 0..31][channel 0..63] : 13 bit
```

每个 output group 占一个 entry；每个 output lane 写入相同 entry 的不同 channel：

```text
RAM_SEL   = lane 0..63
AHB addr  = (bnAddr + output_group)*4
writeData = parameter_file[output_group*64 + lane][12:0]
```

13-bit 字段：

```text
bit[12]   direction
bit[11:0] threshold
```

严格比较语义：

```text
direction==1: output = accumulator > threshold
direction==0: output = accumulator < threshold
accumulator==threshold: output = 0
```

禁止把反向分支写成 `~(acc > threshold)`，因为它等价于 `acc <= threshold`。
该边界错误曾只在两个等值点出现，但经过后续层传播为最终 21 bit mismatch。

## 9. 位序和 lane 对应

`ComputeCoreGroup.outData[i]`、`SIMD_Reg[][i]` 和 `oSIMDData[i]` 使用同一个 PE
索引。WeightSRAM bank `i` 也驱动该 PE。重建时必须保持四者一一对应。

参数文件和 golden 的文本 bit 顺序受 `$readmemb` 与 `%32b` 的 MSB-first 显示
影响。已验证合同是按现有 32-bit 字符串原样读取，不应在 RTL 内增加 bit reverse。

## 10. 数据布局自检

重新实现装载或 dump 时至少验证：

1. 写入两个 32-bit 已知值，内部 64-bit 是否为 `{second,first}`。
2. 读回是否依次得到 low32、high32。
3. 128 通道每像素物理组是否解释为 canonical `1,0`。
4. 256 通道每像素物理组是否解释为 canonical `3,2,1,0`。
5. Weight bank 0/63 是否只影响对应 SIMD lane。
6. `acc==threshold` 在两种 direction 下均输出 0。
