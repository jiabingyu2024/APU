# 10 RTL 重建蓝图

## 1. 目标文件

兼容实现应提供以下模块名：

```text
Top
ahb_slave_top
ahb_slave
addr_map
ram_mux
WorkSheet
Ctrl
FeatureProcessor
InBuf
ComputeCoreGroup
ComputeCore
WeightSRAM
WeightBuffer
Multiplier
AdderTree
Accumulator
SIMD
```

可改变文件拆分，但 `Top` 端口、默认参数和 TB 可见层次必须兼容，除非同步修改 TB。
当前源文件中顶层模块 `Top` 位于 `rtl/Top_student.sv`；其余模块原则上与
`rtl/<ModuleName>.sv` 同名。`rtl/ahb_slave_top.sv` 的后半部分包含历史注释代码，
重建时只需保留活动的 `ahb_slave_top` 实现。

## 2. 推荐实现顺序

1. `Multiplier/AdderTree/Accumulator`：建立 Hamming 算术语义。
2. `WeightSRAM/WeightBuffer/ComputeCore/Group`：锁定权重 bank 和两拍输入延迟。
3. `SIMD`：实现参数 RAM和严格比较。
4. `FeatureProcessor`：实现 1024x64 RAM、3x3 地址、depth 和 padding。
5. `ram_mux/addr_map/ahb_slave`：完成装载、读回和控制寄存器。
6. `WorkSheet`：完成顺序指令发射。
7. `InBuf`：先 normal，再显式 residual capture/replay。
8. `Ctrl`：先 64->64 normal，再扩展 IG/OG、stride2、residual 和 drain。
9. `Top`：连接 owner mux、ping-pong 数据路径和完成中断。

## 3. 建议的数据 token

即使最终 RTL 不声明 struct，设计时也应把以下字段视为同一 token：

```text
valid
pixel
physical_output_group
input_group
kernel_position
is_first_acc_term
is_last_acc_term
is_shortcut
feature_write_addr
bn_addr
```

地址发出后 token 必须经过与 SRAM+buffer 等长的延迟，才能产生 AccInstr；最后项
token 再经过 accumulator 延迟产生写回。这样可替代当前分散的固定延迟猜测。

## 4. Normal 控制伪代码

```text
for p in 0 .. Hout*Wout-1:
  for pog in 0 .. OG-1:              // physical output group
    accumulator_clear_before_first_term
    for k in 0 .. 8:
      for ig in 0 .. IG-1:
        issue feature address(p, ig, k)
        issue weight address(wbase + pog*(9*IG) + k*IG + ig)
        delayed acc control = LOAD only for ig=0,k=0, otherwise ADD
    after final accumulator update:
      compare with SIMD[bnbase+pog]
      write physical address p*OG+pog
```

为了匹配当前物理/canonical 关系，参数装载必须使 `pog=0` 对应 canonical
`OG-1`。若选择重新定义 `pog`，同时修改权重、BN 和输出 adapter。

## 5. Residual 控制伪代码

```text
for p in 0 .. H*W-1:
  capture shortcut groups SG=IG/2 from larger feature when first needed
  for pog in 0 .. OG-1:
    for k in 0 .. 8:
      for ig in 0 .. IG-1:
        accumulate main 3x3 term
    for sg in 0 .. SG-1:
      if pog==0: use SRAM shortcut data and save it
      else:      replay saved shortcut data
      accumulate shortcut 1x1 term
    SIMD compare and write p*OG+pog
```

当前 combined WeightSRAM 地址等价于每 `pog` 存 `9*IG+SG` 个 64-bit word。

## 6. FeatureProcessor 伪代码

```text
on each enabled read edge:
  addr = center + depth_idx + kernel_offset[k]
  ram_q <= memory[addr]
  mask_q <= kernel position crosses image boundary

output = mask_q ? 0 : ram_q

advance depth_idx
if depth_idx wraps:
  advance k, wrapping after 8
```

Kernel offset：

```text
{-W*G-G, -W*G, -W*G+G,
 -G,      0,    +G,
 +W*G-G, +W*G, +W*G+G}
```

## 7. 总线与装载伪代码

```text
write64(target, addr, value):
  write32(window + 8*addr + 0, value[31:0])
  write32(window + 8*addr + 4, value[63:32])

read64(target, addr):
  lo = read32(window + 8*addr + 0)
  hi = read32(window + 8*addr + 4)
  return {hi,lo}
```

`RAM_SEL` 在调用前选择目标 bank。SIMD 和 worksheet 使用单个 32-bit 写。

## 8. Reset 合同

兼容仿真版：

- 控制和数据寄存器异步清零。
- Feature/SIMD 数组可按现有模型清零。
- WeightSRAM 内容不复位。

ASIC 版：

- 只复位控制状态和输出寄存器。
- 所有 memory 内容由软件初始化。
- 复位释放后在 `APU_READY` 前不得使用未初始化参数。

两版必须在软件完成装载后得到相同结果。

## 9. 完成条件

重新实现完成的必要条件：

1. 所有模块编译且无功能性 latch/width 问题。
2. `make check` 六个 checkpoint 全为 0 mismatch。
3. layer2/layer3 residual accumulator 整数逐 lane 一致。
4. 断言覆盖 LOAD/ADD 数量、WeightAddr span、尾部写回和 ping-pong。
5. 文档中的地址空间、指令字和数据文件无需修改即可运行。

只通过最终 layer3 输出不足以验收，因为错误可能被后续阈值或网络层偶然抵消。
