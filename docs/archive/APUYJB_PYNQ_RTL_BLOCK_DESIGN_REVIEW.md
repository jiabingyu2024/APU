# apuYjb 对接当前 RTL/PYNQ Block Design 审查

审查日期：2026-06-13  
审查范围：`apuYjb/` 板端 Python、旧 `myDesign.{tcl,hwh,bit}` 元数据、当前 `rtl/*.sv`、
现有设计/验证文档及 testbench。未修改 RTL、软件、参数或 Vivado 工程。

## 1. 结论

**当前组合不能判定为可正确运行，不建议直接上板。** 即使 Vivado 能生成 bitstream，也有
两类高概率结果：

1. BD 的 AHB glue、时钟或 HWH 不满足条件时，MMIO 不生效，Python 永久卡在等待 `CPL`；
2. APU 完成计算时，最终 256 通道输出仍会因 group 顺序错误，或因参数版本不一致，导致
   PS 端全连接分类结果错误。

其中“最终输出 group 未逆序”是已确认的软件/RTL合同冲突；“旧 BD 使用 100 MHz”是未完成
时序签核的实现阻断项；“27 个共同参数文件全部不同”使当前 RTL 与 `apuYjb/param` 的数值
兼容性没有证据。

## 2. 审查边界

仓库没有当前 PS-overlay 版本的 `.bd/.xpr/component.xml`、综合报告、实现后时序报告和板上
读写日志。现有 `fpga/` 是另一条“纯 PL PicoRV32 + 25 MHz”构建路线，不是 `apuYjb` 所需的
ARM PS MMIO overlay。因此本报告是静态接口和实现风险审查，不是 Vivado/板级 signoff。

## 3. 关键发现

### B1 - 最终输出通道 group 顺序不兼容（Blocker，已确认）

当前 RTL 的物理 feature SRAM 布局要求：128 通道按 group `1,0` 解释，256 通道按
`3,2,1,0` 解释。标准 TB 先缓存一个像素的全部 word，再倒序遍历 group，并在组内输出
`high32, low32`：

- `docs/design/final/04_DATA_AND_MEMORY_LAYOUT.md:177-193`
- `docs/design/final/08_VERIFICATION_AND_REBUILD.md:68-80`
- `tb/tb_top_student.sv:513-560`

`apuYjb/apu_driver.py:79-94` 仅按 MMIO 地址递增顺序展开 bit，未对每个像素的 4 个
64-bit group 做 `3,2,1,0` 重排。最终张量 shape 仍是 `(1,256,8,8)`，但通道块顺序错误，
后续 `avgpool/fc/bn3` 会把特征送入错误权重通道。

**预期现象：** APU 能完成、`CPL` 能返回 1，但分类 logits/类别错误；仅看“完成”会误判成功。

### B2 - 当前 Top 不能原样复用旧 AHB IP 元数据（Blocker，条件性）

当前 `Top` 端口包含 `hsel`、`hready` 输入和 `hreadyout` 输出，且事务接受条件实际依赖
`hsel & htrans[1]`：

- `rtl/Top_student.sv:33-51`
- `rtl/ahb_slave.sv:31-42`

旧 `myDesign.hwh` 的 `APU_0/ahb` 接口没有映射 `HSEL/HREADY/HREADYOUT`，并把 RTL 的
2-bit `hresp` 接到了 AHB-Lite bridge 的 1-bit `m_ahb_hresp`。旧 Tcl 只做整包 interface
连接，没有额外常量或 glue：`apuYjb/myDesign.tcl:747-766`。

新的自定义 IP/BD 必须明确做到：

- 单 slave 直连时把 `Top.hsel` 置 1，或由地址译码产生；
- 把 `Top.hreadyout` 接到 AHB master/bridge 的 `HREADY` 返回；
- `Top.hready` 当前未使用，可明确绑 1；
- 对 AHB-Lite 标准的 1-bit `HRESP` 做合法 wrapper，不能依赖 2-bit 自动截断；
- 不能只照抄旧 `component.xml` 或旧 HWH 的 bus mapping。

**预期现象：** 若 `hsel` 悬空/为 0，所有写入都被忽略，`CPL` 永远为 0，Python 无限等待。

### B3 - 旧 overlay 的 100 MHz 对当前 RTL 没有时序签核（Blocker）

旧 HWH 标明 `APU_0.clk=100 MHz`，旧 BD 将 PS `FCLK_CLK0` 同时送给 AXI bridge 和 APU：

- `apuYjb/myDesign.hwh:225-229`
- `apuYjb/myDesign.tcl:760-763`

当前仓库的板级方案特意把 APU 降到 25 MHz，且文档要求只在 post-route
`WNS >= 0, TNS = 0` 后生成可验收 bitstream：

- `docs/archive/fpga/01_VIVADO_PROJECT_AND_BITSTREAM.md:125-136`
- `docs/archive/fpga/01_VIVADO_PROJECT_AND_BITSTREAM.md:315-326`

RTL 中存在未流水的 `XOR64 -> 64 项 popcount -> accumulator` 路径，以及 Ctrl/feature
地址组合路径：`rtl/Multiplier.sv:13-17`、`rtl/AdderTree.sv:33-40`。当前没有 100 MHz
post-route timing report，因此不能把旧 FCLK 配置视为可用。

**预期现象：** 实现可能出现负裕量；即使 Vivado 仍生成 bit，板上会出现数据相关、温压相关
的随机错误或完成异常。建议评估基线先把 PS FCLK 配成 25 MHz，再以报告逐级提频。

### B4 - `apuYjb/param` 不是当前 RTL 回归使用的参数集（Blocker）

对共同文件逐一去除 CRLF 影响后比较：

```text
共同参数文件：27
完全相同：0
内容不同：27
```

例如 `layer1.0.conv1.txt` 的 1152 行全部不同，`input_binary.txt` 的 2048 行全部不同。
与此同时，两边共同的 37 个 `data_flow` golden 文件全部相同。这说明参数很可能经历过
编码、方向/阈值或模型导出版本变更，不能用“文件长度相同”推断数值合同相同。

当前 bit-exact 回归只覆盖 `data/param_files/`，没有覆盖 `apuYjb/param/`。在没有用旧参数跑
当前 RTL 并与相匹配 golden 比较前，正确性不能签核。

**预期现象：** APU 正常完成，但中间层或最终输出产生系统性 mismatch。

### H1 - 实际运行的驱动没有超时保护（High）

`resnet_binary_ps.py:125-136` 导入的是 `apu_driver.APUDriver`，不是带 10 秒 timeout 的
`apu_driver_full.APUDriver`。实际驱动在五个执行批次中均使用无上限轮询，例如
`apuYjb/apu_driver.py:275-278`、`:293-309`。

因此 B2/B3 或任意硬件故障不会返回明确错误，而会表现为 Jupyter/Python 永久卡死。
`apu_driver_full.py` 虽有 timeout 和启动前清残留 `CPL`，但当前入口没有使用它。

### H2 - bit/HWH/IP 名称必须来自同一次构建（High）

驱动固定查询 `overlay.ip_dict["APU_0"]`，再从 HWH 获取 base/range：
`apuYjb/apu_driver.py:28-38`。因此新 BD 必须保持实例名 `APU_0`，或者同步修改软件配置。

`.bit` 与 `.hwh` 必须同名且来自同一次构建。若只替换 `myDesign.bit` 而保留旧 HWH，软件
可能使用错误地址或旧接口元数据。地址基址可以不是 `0x43C00000`，因为驱动动态读取基址；
但窗口必须覆盖至少 `0x0000-0x200C`。

旧 HWH 的寄存器描述本身也不可信：其中 `APU_READY_ADDR/CPL_ADDR` 记录为十进制
8120/8124，且缺少 `RAM_CTRL`，与 RTL/驱动的 `0x2008/0x200C/0x2000` 不一致。当前驱动
使用直接 MMIO offset，暂不受 register metadata 影响，但新 IP 打包时应修正。

### M1 - AHB slave 只适配受控的 32-bit MMIO（Medium）

当前 slave 永远 `HREADY=1/HRESP=OKAY`，不检查 `HSIZE/HBURST`，不支持 byte/halfword、
unaligned 或错误响应：`rtl/ahb_slave.sv:31-42`。`apuYjb` 当前使用对齐 32-bit word，基本
符合该限制；但 BD 中 AXI-to-AHB bridge 必须配置为 32-bit，并禁止软件做窄访问。

64-bit RAM 由两个相邻 32-bit 写合并，必须严格 low32 后 high32，不能跨 bank 交错：
`rtl/ram_mux.sv:73-120`。当前驱动按 bank 顺序连续写，静态上符合该合同。

## 4. 已匹配的合同

以下部分与当前 RTL 一致，可继续沿用：

| 合同 | `apuYjb` 行为 | 当前 RTL | 结论 |
|---|---|---|---|
| 控制寄存器 | `0x2000/04/08/0C` | `addr_map.sv:44-47` | 匹配 |
| RAM window | `0x0000` 起，最大 8 KiB | `<0x2000` | 匹配 |
| RAM_SEL | BN 0..63、Weight 64..127、Act 128、Out 129、IR 130 | `ram_mux.sv:91-128` | 匹配 |
| 指令格式 | `{op,ks,lihw,lic,loc,s1,s2,wa,bna}` | `Ctrl.sv` 解包 | 匹配 |
| 执行分批 | 前 8 条一次，layer3 四条分别执行 | 当前 worksheet/容量策略 | 匹配 |
| 最终 SRAM | 总计 12 条，最终读 Act/128 | 偶数累计指令结果在 ActSRAM | 匹配 |
| 输入/输出容量 | 2048/512 个 32-bit word | 8 KiB RAM window 内 | 匹配 |
| owner 切换 | 装载/读回写 3，运行前写 0 | `RAM_CTRL[1:0]` | 匹配 |

## 5. 可接受的 Block Design 条件

要把当前 `Top` 做成 PYNQ ARM 可访问 overlay，至少应满足：

```text
Zynq7 PS M_AXI_GP0
  -> AXI SmartConnect/Interconnect
  -> AXI-to-AHB-Lite bridge (32-bit)
  -> AHB wrapper
       HSEL      = 1 或合法地址译码
       HREADY    <- Top.hreadyout
       Top.hready = 1
       HRESP     = Top.hresp[0]（wrapper 内明确转换）
  -> Top
```

- APU、bridge、SmartConnect 使用同一受约束时钟；初次上板建议 25 MHz；
- reset 使用 `proc_sys_reset/peripheral_aresetn`，低有效并同步释放；
- 地址 range 至少 `0x4000`，软件可继续通过 HWH 动态取得 base；
- IP 实例名保持 `APU_0`；
- 重新生成匹配的 `.bit + .hwh`，不能复用旧 HWH；
- post-route 报告必须满足 `WNS >= 0`、`TNS = 0`，且无 unconstrained endpoint；
- 在完整推理前先做寄存器回读、单个 RAM 64-bit 拼接和 `CPL` timeout smoke test。

这些条件只解决“能够可靠访问和执行”，不能解决 B1 的输出重排和 B4 的参数版本问题。

## 6. 预期故障定位

| 板上现象 | 首查项 |
|---|---|
| `APU_0` KeyError | HWH 缺失/陈旧、实例名不是 `APU_0` |
| RAM_SEL/RAM_CTRL 写后读不回 | HSEL、地址段、reset、HREADY/HRESP wrapper |
| 永久等待 CPL | HSEL 未使能、APU 未启动、时序失败、driver 无 timeout |
| CPL 正常但输出全零/固定值 | RAM owner、参数装载、32/64-bit 拼接、reset |
| 中间层开始系统性 mismatch | `apuYjb/param` 与当前验证参数版本不一致 |
| 最终 APU bits 像分块置换 | 256 通道 group reverse 缺失 |
| APU 输出似乎正确但分类错误 | group 顺序、PS 端 FC 通道对应、模型权重版本 |
| 低频正常、高频随机错 | post-route timing 未收敛 |

## 7. 最终评估

| 项目 | 评估 |
|---|---|
| 寄存器和 RAM 编程模型 | 基本兼容 |
| 当前 Python 执行批次 | 与 12 条网络策略兼容 |
| 旧 BD 直接复用 | 不兼容，需 AHB wrapper/端口映射修正 |
| 100 MHz FCLK | 未签核，高风险 |
| `apuYjb/param` 数值兼容 | 未证明，27/27 共同文件不同 |
| 最终 256 通道读回 | 已确认不兼容，缺少 group reverse |
| 故障可诊断性 | 差，实际驱动无 timeout |
| 是否可直接上板宣称正确 | **否** |

静态审查的最终判断是：**硬件可能被访问并完成计算，但当前 `apuYjb` 与当前 RTL 的组合
不能得到可信的最终分类结果；若按旧 BD/100 MHz 原样重建，还存在直接卡死或随机硬件错误
的风险。**
