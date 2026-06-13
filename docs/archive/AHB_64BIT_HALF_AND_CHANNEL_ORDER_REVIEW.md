# AHB 32/64 位传输与通道顺序审查

## 1. 审查目的

本次根据助教提供的原始 `tb_top` 模板，重新审查以下问题：

1. 内部 64-bit RAM 通过 32-bit AHB 分两次传输时，先传哪一半；
2. 参数文件和输出文件每两行分别对应哪 32 个通道；
3. 当前 TB 是否在读回后进行了额外重排；
4. `Ctrl`、`InBuf` 等计算 RTL 是否为了错误的高低半字理解而被改写；
5. 当前“全部回归通过”是否真实证明接口符合助教模板。

结论先行：**此前确实把 golden 文本第一行错误解释成了 high32，并在验证端加入了不属于助教模板的半字交换和通道组逆序。当前回归因此只能证明“经过适配器后匹配”，不能证明 AHB 原始输出顺序正确。**

## 2. 助教模板实际规定了什么

助教模板的写入任务按数组下标顺序发送数据：

```systemverilog
hwdata <= data_burst_wr[start_addr+i];
haddr  <= addr+(i+1)*4;
```

因此文本第 `0` 行写 AHB 地址 `0x0`，第 `1` 行写地址 `0x4`，没有进行两行交换。

助教模板的输出任务也按 AHB 返回顺序直接写文件：

```systemverilog
$fwrite(fp_datao_w, "%32b\n", hrdata);
```

模板没有以下行为：

- 不交换同一个 64-bit word 的两次 32-bit 返回；
- 不缓存一个像素后逆转 64-channel group；
- 不把输出转换成另一个“canonical”顺序。

所以课程接口的基准应是：**TB 文件顺序、AHB 地址递增顺序和原始读回文件顺序一致。**

## 3. 原始 RTL 的 32 -> 64 位合并规则

`rtl/ram_mux.sv` 自初始提交以来没有修改。写入逻辑为：

```systemverilog
if (ram_wen & (!ram_waddr[0]))
    ram_wdata_r <= ram_wdata;

assign in_ram_wen   = ram_wen & ram_waddr[0];
assign in_ram_wdata = {ram_wdata, ram_wdata_r};
```

地址和数据关系如下：

| AHB 字地址 | 字节地址 | 行为 | 内部 64-bit 位置 |
| ---: | ---: | --- | --- |
| 偶数 `2N` | `8N+0` | 暂存当前 `hwdata` | `[31:0]` |
| 奇数 `2N+1` | `8N+4` | 提交 `{当前数据, 暂存数据}` | `[63:32]` |

即：

```text
internal_word[31:0]  = file_line[2N]
internal_word[63:32] = file_line[2N+1]
```

读回逻辑与之对称：偶数 AHB 字地址返回 `[31:0]`，奇数地址返回 `[63:32]`。

这部分是原始 APU 总线接口，不是后续为了测试而添加的错误适配，也不应修改成“高 32 位先写”。

## 4. 原始软件驱动对文件行的解释

`apuYjb/apu_driver.py` 的输入打包按 NHWC 通道顺序每 32 个 bit 形成一个整数。其结果是：

```text
第 0 个 32-bit word：channel 0..31
第 1 个 32-bit word：channel 32..63
```

由于整数以二进制字符串打印时 bit31 在左、bit0 在右，所以一行文本虽然视觉上是
MSB-first，但它仍然是第一个 AHB 32-bit word，不等于“64-bit 数据的高半字”。

原始板端驱动的读回也只是连续读取 `+0, +4, +8...`，随后按同一通道流解包，没有交换相邻两个 word，也没有逆转通道组。

因此此前的关键误解是混淆了：

1. **一行 32-bit 字符串内部的 MSB-first 显示顺序**；
2. **一个 64-bit RAM word 的 low32/high32 地址顺序**。

二者不是同一件事。课程文件第一行应是低地址 32-bit word，也就是内部 `[31:0]`。

## 5. 已删除的 TB 私有适配

此前 `tb/tb_top_student.sv` 的 `ahb_read_burst_save_named` 做了两级额外转换：

```systemverilog
for (group_idx = channel_groups - 1; group_idx >= 0; group_idx--) begin
    $fwrite(..., pixel_words[2*group_idx+1]);
    $fwrite(..., pixel_words[2*group_idx]);
end
```

### 5.1 半字交换

AHB 原始返回顺序是：

```text
pixel_words[2*g]   = internal_word[31:0]
pixel_words[2*g+1] = internal_word[63:32]
```

此前 TB 却输出 `2*g+1` 再输出 `2*g`，把 high32 放在 low32 前面。这与助教模板直接输出 `hrdata` 的行为不一致。

### 5.2 通道组逆序

此前 TB 还把 group 从 `G-1` 遍历到 `0`。对于 128/256 通道，一个像素分别执行：

```text
128 channel: physical group 1, 0
256 channel: physical group 3, 2, 1, 0
```

助教模板没有这一转换，原始 PYNQ 驱动也没有这一转换。因此该适配不能作为外部接口规范，只能说明当前 RTL、参数文件和 golden 之间存在布局差异。

本次已将保存任务恢复为按 AHB 地址递增直接输出：

```systemverilog
$fwrite(fp_datao_w, "%32b\n", read_data);
```

现在 TB 不再接收 `channel_groups`，也不再缓存、交换或逆转输出数据。

## 6. 恢复模板后实际回归结果

执行 `CCACHE_DISABLE=1 make check`，仿真能够正常完成，APU 完成中断也能够到达，
没有出现无限等待。原始 AHB 输出与 `data/data_flow` 直接比较全部失败：

| 检查点 | bit mismatch | line mismatch |
| --- | ---: | ---: |
| layer1.1 tanh3，64 channel | 36456 | 2048 / 2048 |
| layer2.1 tanh3，128 channel | 16284 | 1024 / 1024 |
| layer3.0 tanh1，256 channel | 8126 | 512 / 512 |
| layer3.0 tanh3，256 channel | 8106 | 512 / 512 |
| layer3.1 tanh1，256 channel | 7708 | 512 / 512 |
| layer3.1 bn3，256 channel | 6424 | 512 / 512 |

但这些结果不是随机数值错误。对每个像素进行固定排列后，六个检查点均逐位一致：

| 输出通道数 | 对原始 AHB 输出执行的排列 | 排列后 bit mismatch |
| ---: | --- | ---: |
| 64 | 每个 64-bit word 交换相邻两个 32-bit word | 0 |
| 128 | 64-channel group 顺序 `1,0`，每组再交换两个 32-bit word | 0 |
| 256 | 64-channel group 顺序 `3,2,1,0`，每组再交换两个 32-bit word | 0 |

为排除“前面层错误传播后偶然形成排列”，还单独执行了第一条 64->64 卷积。第一层
`layer1.0_tanh1` 的原始输出结果为：

| 比较方式 | bit mismatch | line mismatch |
| --- | ---: | ---: |
| 原始 AHB 顺序直接比较 | 33644 | 2048 / 2048 |
| 每个 64-bit word 交换相邻 32-bit word 后比较 | 0 | 0 / 2048 |

因此固定布局差异从第一层就存在。MAC、累加、BN/SIMD 数值和完成控制均能产生正确
结果；错误集中在外部所认为的通道编号与 APU 内部物理 lane/group 编号之间。

此前通过的 `make check` 实际验证的是：

```text
AHB 原始输出 -> TB 私有重排 -> golden
```

而不是助教要求的：

```text
AHB 原始输出 -> golden
```

现在恢复模板后能够正确暴露该接口差异，因此当前 `make check` 应当 FAIL；不能把这个
FAIL 当作仿真卡死，也不能再在比较端补偿成 PASS。

## 7. 问题定位

### 7.1 已排除的 RTL

以下模块不负责 32/64 位拆装：

- `Ctrl.sv`：只生成 64-bit feature word 地址、权重地址、BN 地址和时序控制；
- `InBuf.sv`：整字传递 64-bit 激活；
- `FeatureProcessor.sv`：按 64-bit word 存取；
- `WeightSRAM.sv`：按 64-bit word 存取；
- `ComputeCoreGroup.sv`：64 个 lane 并行计算。

这些模块中不存在“先收 low32 还是 high32”的状态机。不能仅因为输出文本顺序错误，
就直接反向修改这些 RTL。

`ram_mux.sv` 才是 32/64 位边界，而它保持了原始设计的 low-address word -> `[31:0]` 合同。

逐段连接关系也是恒等映射：

```text
Weight/SIMD bank i
  -> ComputeCoreData[i]
  -> SIMDData[i]
  -> Feature SRAM word[i]
```

`Top_student.sv` 直接把 `SIMDData[63:0]` 写入 Feature SRAM，没有半字交换。`Ctrl.sv`
只产生 64-bit word 地址、权重地址和 BN entry；它没有能力交换一个 word 内的两个
32-bit 半字。因此本次结果不能定位成 `Ctrl` 的高低半字 bug。

### 7.2 实际不一致的边界

虽然计算 RTL没有直接拆分 32/64 位，但当前结果必须依靠以下转换才能通过：

```text
64 channel：交换 32-channel 两半
128/256 channel：额外逆转 64-channel group
```

TB 当前按照以下规则装载参数：

```text
参数文件输出项 (j*64+i) -> Weight bank i
参数文件输出项 (j*64+i) -> SIMD bank i, entry (bnAddr+j)
```

这个装载规则、计算 lane 和 SRAM bit 位置全部保持 `i` 不变，而实测结果相对 dataflow
固定表现为“group 逆序 + 每组两个 32-bit 半字交换”。所以不一致点已收敛到：

1. `data/param_files` 中输出 lane/group 的编号语义；或
2. 助教留空的 `conv_layer`/`conv_resident_layer` 本应对参数索引做相应映射，但当前实现
   直接使用了 `j*64+i`。

仓库中没有找到生成 `data/param_files` 的权威脚本，因此目前不能仅根据文件内容断言
究竟应修改参数生成器还是 TB 参数装载索引。但可以明确排除：这不是 `ram_mux` 的
low32/high32 合并错误，也不是 `Ctrl` 的延迟响应或完成中断错误。

特别需要注意：仓库中的 `data/param_files` 与 `apuYjb/param` 的 27 个同名参数文件全部
不同，而两边共同的 golden 文件内容相同。这进一步说明仓库内存在两套参数布局或模型
版本，不能混用其中一套参数和另一套软件约定。

## 8. 是否会导致上板错误

会。上板后可能出现的现象是：

1. bitstream 能下载，APU 能结束，`int_cal` 也能产生；
2. 从 MMIO 连续地址读出的数值不是随机错误，而是稳定的通道排列错误；
3. 若软件按原始 `apu_driver.py` 连续解包、不做逆变换，则输出通道与后续 FC 权重的
   通道编号不一致，最终分类结果可能错误；
4. 软件加入逆变换可以恢复当前数值，但这会掩盖课程接口不一致，不能替代接口修复。

所以它不是“只影响仿真文件显示”的问题，而是会影响板端软件看到的张量布局。

## 9. 后续正确修复顺序

本次只恢复 TB 原始读回顺序，不修改 RTL。后续应按以下顺序处理，不能先交换
`ram_mux`，也不能直接改 `Ctrl`：

1. 冻结助教接口：地址 `8N+0 -> [31:0]`，地址 `8N+4 -> [63:32]`，读回同序。
2. 增加独立 `ram_mux` 单元测试，用固定值验证 `{high,low}`，避免神经网络数据掩盖问题。
3. TB 已恢复成原始 AHB 顺序，保持该行为作为接口验收基线。
4. 向助教确认参数文件的输出通道顺序，尤其是一个 64-channel group 内两行的语义。
5. 根据权威顺序，只在参数生成端或 `conv_layer` 装载索引端修复一次，禁止输出端补偿。
6. 重新跑第一层 64->64，要求原始输出直接逐位一致。
7. 再跑 64->128 和 128->256，要求 group 0/1/2/3 的原始地址顺序直接一致。
8. 最后使用原始 `apu_driver.py` 的连续读写规则做板端软件兼容性回归。

## 10. 最终结论

用户的怀疑成立：此前对“64 位数据分成两个 32 位传输”的文件语义理解有偏差。

准确地说：

- 原始硬件传输合同一直是 low32 地址在前、high32 地址在后；
- 错误不在 `ram_mux`，而在后续把 golden 第一行认作 high32；
- 此前 TB 又增加了通道组逆序，使错误布局在比较前被修正；
- 本次已恢复助教模板式原始读回，仿真正常结束，但所有 dataflow 直接比较均失败；
- 第一层只需交换相邻 32-bit word 即可零误差，完整网络还需逆转 64-channel group；
- `Ctrl/InBuf` 不包含 32/64 拆装逻辑，不能据此直接判定其半字逻辑被改坏；
- 当前证据把根因收敛到参数文件通道语义与 TB 装载索引的边界，尚无证据支持修改
  `Ctrl`、`ram_mux` 或计算 RTL；
- 该差异会传到板端 MMIO 输出，并可能导致最终 FC/分类错误；
- 在权威参数布局确认并修复前，现有全网络 PASS 只能视为“适配后自洽”，不能视为
  课程接口或上板验收通过。
