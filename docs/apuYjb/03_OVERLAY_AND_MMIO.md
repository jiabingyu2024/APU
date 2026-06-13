# Overlay、Block Design 与 MMIO 协议

## 1. Overlay 加载

驱动初始化执行：

```python
self.overlay = Overlay("./myDesign.bit")
base = self.overlay.ip_dict["APU_0"]["phys_addr"]
size = self.overlay.ip_dict["APU_0"]["addr_range"]
self.mmio = MMIO(base, size)
```

PYNQ 会寻找与 bit 同名的 `myDesign.hwh`。IP 实例名必须是 `APU_0`，否则会出现
`KeyError`。软件从 HWH 动态取得物理基址，所以基址并非必须固定为 `0x43C00000`；但 HWH、
bit 和实际硬件必须一致。

## 2. 旧 Block Design

| 项目 | 旧设计值 |
|---|---|
| FPGA 器件 | Zynq-7020 / PYNQ-Z2 对应器件 |
| PS master | `processing_system7_0/M_AXI_GP0` |
| 协议转换 | SmartConnect + `axi_ahblite_bridge` |
| APU 实例名 | `APU_0` |
| 地址 | `0x43C00000` |
| 地址范围 | `0x00010000` |
| APU 时钟 | PS `FCLK_CLK0`, 100 MHz |
| APU 复位 | `proc_sys_reset_0/peripheral_aresetn` |

软件访问的是相对偏移；例如 `CPL` 的绝对地址是旧基址 `0x43C00000 + 0x200C`。

## 3. 寄存器表

| 相对偏移 | 名称 | 方向 | 当前软件用法 |
|---:|---|---|---|
| `0x2000` | `RAM_CTRL` | 写 | `0x3` 交给 PS 访问，`0x0` 交给 APU 运行 |
| `0x2004` | `RAM_SEL` | 写 | 选择当前映射到 `0x0000` RAM window 的 bank |
| `0x2008` | `APU_READY` | 写 | 写 1 启动，完成后写 0 |
| `0x200C` | `CPL` | 读 | 0 表示未完成，非 0 表示完成 |

旧 HWH 的寄存器 metadata 存在错误：缺少 `RAM_CTRL`，且 `APU_READY/CPL` 的十进制 offset
记录与 `0x2008/0x200C` 不符。当前驱动直接使用常量偏移，所以不读取这些 register 描述；
重新封装 IP 时仍应修正 metadata。

## 4. RAM 选择编码

| `RAM_SEL` | RAM 类型 |
|---:|---|
| `0..63` | 64 个 BN RAM slice |
| `64..127` | 64 个 Weight RAM slice |
| `128` | Act/Input feature SRAM |
| `129` | Output feature SRAM |
| `130` | Instruction/Worksheet RAM |

选择 bank 后，地址 `0x0000-0x1FFF` 被解释为该 bank 内部地址。驱动始终进行对齐的 32-bit
访问；硬件内部的 64-bit RAM word 由相邻两个 32-bit transaction 拼接。

## 5. 参数地址单位

驱动的指令字段不是统一的 byte address：

- `w_addr` 在软件写 RAM 时乘 8，表示 64-bit weight word 地址；
- `bn_addr` 在软件写 RAM 时乘 4，表示 32-bit BN word 地址；
- worksheet index 乘 4，表示一条 32-bit instruction；
- MMIO API 最终接收的都是 byte offset。

如果把指令字段直接当 byte address，会导致参数写入位置整体偏移。

## 6. 启动握手

当前基础驱动的顺序是：

```text
RAM_CTRL = 3
-> 选择 RAM 并写输入/参数/指令
-> RAM_CTRL = 0
-> APU_READY = 1
-> 反复读取 CPL，直到非 0
-> APU_READY = 0
```

`apu_driver.py` 没有 timeout，也没有在每次启动前确认旧 `CPL` 已清零。硬件接口、复位或
时序一旦异常，Python 可能永久卡住。`apu_driver_full.py` 实现了这两项保护，但当前未接入。

## 7. 当前 RTL 重新打包时的要求

旧 HWH 中 APU AHB 接口没有当前 `Top` 所需的 `HSEL/HREADY/HREADYOUT` 映射，且 HRESP
宽度存在差异。重新生成 Overlay 时不能直接复用旧 IP metadata，至少应有明确 wrapper：

```text
AXI-to-AHB-Lite bridge
  -> AHB wrapper
       HSEL 合法驱动
       HREADY 返回链完整
       Top.hready 明确驱动
       2-bit HRESP 到 AHB-Lite 1-bit HRESP 明确转换
  -> current Top/APU
```

同时必须完成 post-route timing signoff。旧设计的 100 MHz 只是配置事实，不代表当前 RTL
已经在 100 MHz 下满足 `WNS >= 0, TNS = 0`。
