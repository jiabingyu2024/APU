# 使用边界与已知风险

## 1. 当前可以确认的事实

- Overlay 使用 PS `M_AXI_GP0 -> SmartConnect -> AXI-to-AHB -> APU_0`。
- 软件寄存器偏移与当前 RTL 地址表的 `0x2000/04/08/0C` 一致。
- RAM selector、输入/输出容量和 12 条指令的五段执行策略基本匹配。
- 程序当前能依赖 ARM 完成单图和 CIFAR-10 推理流程。
- 实际入口使用无 timeout 的 `apu_driver.py`。

## 2. 已确认的高风险项

### 2.1 输出 group 未重排

当前驱动最终解包没有 256 通道物理 group 逆序，而当前 RTL/TB 明确按 group reverse 恢复
逻辑通道。该问题会让 APU 完成但 FC 通道对应错误。

### 2.2 参数不是当前 RTL 回归参数

`apuYjb/param` 与 `data/param_files` 的共同文件数值不同。现有证据不足以证明当前 RTL、旧 bit、
旧参数和 checkpoint 是同一个 bit-exact 版本。

### 2.3 当前 Overlay 的 100 MHz 未对当前 RTL 签核

旧 HWH/Tcl 中 APU 时钟为 100 MHz。当前仓库没有与该 overlay 对应的 post-route timing
report，不能把“能生成 bit”当作 100 MHz 可可靠运行的证据。

### 2.4 当前 Top 不能原样套用旧 AHB metadata

当前 RTL 增加/依赖 `HSEL/HREADY/HREADYOUT` 等握手，而旧 HWH 的 APU interface 没有完整
映射。重建 IP 和 BD 时需要 wrapper，不能只替换 RTL 源后重新综合。

## 3. 软件健壮性问题

| 问题 | 后果 |
|---|---|
| `CPL` 轮询无 timeout | 硬件异常时 Python 永久卡死 |
| 启动前不确认旧 `CPL=0` | 可能把残留完成状态当成本次完成 |
| checkpoint `strict=False` 且不打印 key 差异 | 模型部分未加载也可能显示成功 |
| 自定义 bit 路径 kwargs 名不一致 | 修改配置可能没有真正生效 |
| PC mock 文件缺失 | `RUN_ON_PC_FOR_DEBUG=True` 不能直接运行 |
| dummy read 作用未验证 | 更换 bridge/RAM 时可能产生首读偏移 |

## 4. 本资料不能证明什么

现有文件中没有与 `myDesign.bit` 对应的完整 Vivado 工程、IP `component.xml`、综合利用率报告、
post-route timing report、DRC 报告和板上 MMIO 日志。因此不能仅根据本目录证明：

- bit 确实由当前 `rtl/` 生成；
- 100 MHz 下无时序违例；
- AHB 接口在所有 transaction 下符合协议；
- `param/` 与 `model_best.pth.tar` 数值配套；
- 完整 CIFAR-10 分类结果 bit-exact。

## 5. 与 ARM 禁用要求的结论

`apuYjb` 的 ARM 不是可选管理核，而是推理数据通路的一部分。禁用 ARM 后：

```text
Python 停止
-> PyTorch 前后处理停止
-> MMIO 参数搬运和 APU 启动停止
-> 分类结果无法产生
```

所以不能用 `apuYjb/myDesign.bit` 完成“ARM 硬核完全禁用后仍独立分类”的验收。该目标必须
使用 PL 内处理器或纯硬件控制器，当前仓库对应路线是
[`docs/fpga/05_BIT_TO_ARM_DISABLED_ACCEPTANCE.md`](../fpga/05_BIT_TO_ARM_DISABLED_ACCEPTANCE.md)。

## 6. 正确使用原则

1. 把 `apuYjb` 当作旧 PYNQ 混合推理参考 bundle，而不是当前 RTL 的自动真值。
2. bit、HWH、驱动、参数、checkpoint 和 golden 按版本成套管理。
3. 修改驱动前先用固定样本确定首个 mismatch，避免用准确率猜问题。
4. 重建 Overlay 时重新封装 AHB wrapper，并重新生成匹配的 bit/HWH。
5. 完整分类前先做 MMIO、RAM 拼接、单条指令、分层 golden 和 timing 验收。
6. ARM 禁用验收与 PYNQ Python 推理分成两套独立流程，不混用 bit 和结论。
