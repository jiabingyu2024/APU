---
document_type: daughtercard_reference
board: EES_363DP
compatible_baseboard: PYNQ-Z2
interface: Arduino shield connector
manual_version: 1.0
manual_date: 2018-12
vendor: 依元素科技有限公司
source_pdf: 数字子卡用户手册.pdf
source_pages: 8
conversion_purpose: AI-readable reference for RTL, Vivado, and XDC constraints
language: zh-CN
---

# EES_363DP 数字子卡 AI 可读参考手册

本文档根据《数字子卡用户手册》整理，用于辅助 AI 理解 EES_363DP 数字子卡、
编写 RTL/XDC 文件，以及在 Vivado 中完成 PYNQ-Z2 实验。

## 1. 最重要的硬件规则

1. EES_363DP 是安装在 PYNQ-Z2 Arduino 扩展接口上的数字实验子卡。
2. 子卡由 PYNQ-Z2 提供 3.3 V 电源。使用前将子卡电源开关 `SW7` 拨到
   `ON`，上电后绿色指示灯 `D3` 常亮。
3. 四位八段数码管为**共阳极**结构。
4. 数码管的 8 路段选和 4 路位选均为**低电平有效**：
   - 段线输出低电平时，对应笔段点亮。
   - 位选输出低电平时，对应数码位使能。
5. `LED1-LED8` 与数码管的 8 路段选物理共用 FPGA 引脚，不能作为两组
   相互独立的输出使用。
6. 板上 6 个拨码开关通过电阻网络向 FPGA 提供明确的高、低电平。
7. 所有表格中的 `FPGA IO 约束` 均为 Zynq PL 封装引脚，可写入 XDC 的
   `PACKAGE_PIN` 属性。
8. 这些接口来自 PYNQ-Z2 Arduino 连接器，通常使用 `LVCMOS33`。最终设计
   仍应通过原理图和 Vivado DRC 复核电压标准。

## 2. 子卡功能概览

| 模块 | 数量 | FPGA 信号数 | 方向 |
|---|---:|---:|---|
| 四位八段数码管 | 1 组 | 8 段选 + 4 位选 | FPGA 输出 |
| 拨码开关 | 6 个 | 6 | FPGA 输入 |
| 用户 LED | 8 个 | 8，与段选共用 | FPGA 输出 |
| 子卡电源开关 | SW7 | 不连接 FPGA | 人工控制 |
| 电源指示灯 | D3，绿色 | 不连接 FPGA | 上电指示 |

## 3. 供电

- 子卡安装到 PYNQ-Z2 Arduino 扩展连接器后，由 PYNQ-Z2 供电。
- 将 `SW7` 拨向 `ON` 端，向子卡接通 `AR_3V3/VCC_3V3`。
- 绿色 `D3` 通过 330 欧姆限流电阻连接到 3.3 V，供电正常时常亮。
- 子卡没有需要写入 XDC 的独立时钟源。

## 4. 四位八段数码管

### 4.1 电气结构

数码管由两部分控制：

- **段选**：8 路信号分别控制 `A、B、C、D、E、F、G、DP` 笔段。
- **位选**：4 路信号选择 `K1-K4` 中的一位。

数码管为共阳极器件。位选端通过 PNP 三极管 `2N5401` 接到 3.3 V，FPGA
向三极管基极输出低电平时，该位阳极被接通。因此，位选为低有效。段线连接
数码管阴极，FPGA 输出低电平时形成电流通路，因此段选也为低有效。

建议采用动态扫描：先关闭全部位选，更新段码，再只打开一位。快速轮询四位，
利用视觉暂留获得稳定显示。

### 4.2 原手册段选引脚表

原手册没有直接标出 `A-G/DP` 名称，而是以数码管器件管脚编号表示。若需要
确认每一行对应的实际笔段字母，应结合器件原理图或点亮测试确认，不应仅凭
常见数码管管脚顺序猜测。

| 序号 | 器件引脚 | 原理图网络名 | FPGA 封装引脚 | 方向 | 有效电平 |
|---:|---|---|---|---|---|
| 1 | K(0/1/2/3)_11 | FPGA_H13 | H15 | OUTPUT | 低有效 |
| 2 | K(0/1/2/3)_7 | FPGA_K4 | F16 | OUTPUT | 低有效 |
| 3 | K(0/1/2/3)_4 | FPGA_B5 | T15 | OUTPUT | 低有效 |
| 4 | K(0/1/2/3)_2 | FPGA_B3 | V17 | OUTPUT | 低有效 |
| 5 | K(0/1/2/3)_1 | FPGA_A3 | U17 | OUTPUT | 低有效 |
| 6 | K(0/1/2/3)_10 | FPGA_M5 | T12 | OUTPUT | 低有效 |
| 7 | K(0/1/2/3)_5 | FPGA_A5 | V15 | OUTPUT | 低有效 |
| 8 | K(0/1/2/3)_3 | FPGA_A4 | R16 | OUTPUT | 低有效 |

### 4.3 位选引脚表

| 数码位 | 器件引脚 | 原理图网络名 | FPGA 封装引脚 | 方向 | 有效电平 |
|---|---|---|---|---|---|
| K1 | K1_12 | FPGA_B6 | V13 | OUTPUT | 低有效 |
| K2 | K2_9 | FPGA_A10 | U13 | OUTPUT | 低有效 |
| K3 | K3_8 | FPGA_C12 | U12 | OUTPUT | 低有效 |
| K4 | K4_6 | FPGA_A12 | T14 | OUTPUT | 低有效 |

### 4.4 建议的 RTL 接口

```systemverilog
// 全部为低有效。
output logic [7:0] seg_n;
output logic [3:0] digit_n;
```

推荐的安全扫描顺序：

1. 将 `digit_n` 设为 `4'b1111`，关闭所有位。
2. 更新 `seg_n`。
3. 将目标位对应的 `digit_n` 位清零。
4. 保持约 0.5-2 ms 后切换到下一位。

四位完整刷新率建议高于约 100 Hz。避免同时使能多个位，否则可能出现重影，
也会增加瞬时电流。

## 5. 拨码开关

子卡包含 `SW1-SW6` 六个拨码开关。每个 FPGA 输入通过 100 欧姆串联电阻连接
开关公共端；开关可选择 3.3 V 或经 1 kOhm 电阻连接地，因此输入不会悬空。
板面照片标出了 `LOW` 和 `HIGH` 方向。

| 开关 | 器件引脚 | 原理图网络名 | FPGA 封装引脚 | 方向 |
|---|---|---|---|---|
| SW1 | SW1_2 | FPGA_P12 | P15 | INPUT |
| SW2 | SW2_2 | FPGA_P13 | P16 | INPUT |
| SW3 | SW3_2 | FPGA_H2 | N17 | INPUT |
| SW4 | SW4_2 | FPGA_H1 | P18 | INPUT |
| SW5 | SW5_2 | FPGA_B1 | R17 | INPUT |
| SW6 | SW6_2 | FPGA_B2 | T16 | INPUT |

建议 RTL 接口：

```systemverilog
input logic [5:0] dip_sw;
```

这些是机械开关。若开关变化直接控制状态机、计数器或单周期脉冲，应在 RTL 中
加入同步器和消抖逻辑。若只作为静态模式配置输入，通常经过两级同步即可。

## 6. LED1-LED8

8 个 LED 由 PNP 三极管 `2N5401` 进行高侧驱动。FPGA 将三极管基极拉低时，
对应 LED 获得供电，因此按原理图判断为**低电平点亮**。

| LED | 原理图网络名 | FPGA 封装引脚 | 方向 | 有效电平 | 共用的段选序号 |
|---|---|---|---|---|---:|
| LED1 | FPGA_K4 | F16 | OUTPUT | 低有效 | 2 |
| LED2 | FPGA_M5 | T12 | OUTPUT | 低有效 | 6 |
| LED3 | FPGA_H13 | H15 | OUTPUT | 低有效 | 1 |
| LED4 | FPGA_A5 | V15 | OUTPUT | 低有效 | 7 |
| LED5 | FPGA_B5 | T15 | OUTPUT | 低有效 | 3 |
| LED6 | FPGA_A4 | R16 | OUTPUT | 低有效 | 8 |
| LED7 | FPGA_A3 | U17 | OUTPUT | 低有效 | 5 |
| LED8 | FPGA_B3 | V17 | OUTPUT | 低有效 | 4 |

重要：LED 和数码管段选不是仅仅“碰巧使用相同的 XDC 引脚”，而是连接在相同
的 FPGA 网络上。驱动数码管时，LED 会随段扫描信号变化；驱动 LED 时，相应
数码管笔段也会受到影响。设计顶层中应只保留一组 8 位物理输出，例如
`seg_led_n[7:0]`，不要创建独立的 `seg_n` 和 `led_n` 后再约束到同一引脚。

## 7. 与 PYNQ-Z2 Arduino 引脚的对应关系

以下别名来自 PYNQ-Z2 Arduino 连接器，可用于理解子卡如何连接到基板。

### 7.1 段选/LED 共用输出

| 子卡网络 | FPGA 引脚 | PYNQ-Z2 Arduino 信号 |
|---|---|---|
| FPGA_H13 | H15 | AR_SCK |
| FPGA_K4 | F16 | AR_SS |
| FPGA_B5 | T15 | AR5 |
| FPGA_B3 | V17 | AR8 |
| FPGA_A3 | U17 | AR7 |
| FPGA_M5 | T12 | AR_MOSI |
| FPGA_A5 | V15 | AR4 |
| FPGA_A4 | R16 | AR6 |

### 7.2 数码管位选输出

| 子卡网络 | FPGA 引脚 | PYNQ-Z2 Arduino 信号 |
|---|---|---|
| FPGA_B6 | V13 | AR3 |
| FPGA_A10 | U13 | AR2 |
| FPGA_C12 | U12 | AR1 |
| FPGA_A12 | T14 | AR0 |

### 7.3 拨码开关输入

| 子卡网络 | FPGA 引脚 | PYNQ-Z2 Arduino 信号 |
|---|---|---|
| FPGA_P12 | P15 | AR_SCL |
| FPGA_P13 | P16 | AR_SDA |
| FPGA_H2 | N17 | AR13 |
| FPGA_H1 | P18 | AR12 |
| FPGA_B1 | R17 | AR11 |
| FPGA_B2 | T16 | AR10 |

## 8. 推荐 XDC 模板

下面使用三组清晰的顶层端口名：

- `seg_led_n[7:0]`：段选和 LED 共用的低有效输出。
- `digit_n[3:0]`：四位数码管低有效位选。
- `dip_sw[5:0]`：六个拨码开关输入。

```tcl
## EES_363DP segment/LED shared outputs, active low
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {seg_led_n[0]}]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {seg_led_n[1]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {seg_led_n[2]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {seg_led_n[3]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {seg_led_n[4]}]
set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVCMOS33} [get_ports {seg_led_n[5]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {seg_led_n[6]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {seg_led_n[7]}]

## EES_363DP digit enables, active low: K1, K2, K3, K4
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {digit_n[0]}]
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVCMOS33} [get_ports {digit_n[1]}]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports {digit_n[2]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {digit_n[3]}]

## EES_363DP DIP switches: SW1 through SW6
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports {dip_sw[0]}]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports {dip_sw[1]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {dip_sw[2]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {dip_sw[3]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {dip_sw[4]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {dip_sw[5]}]
```

注意：`seg_led_n` 的下标严格按原手册表格序号排列，不代表标准的
`{DP,G,F,E,D,C,B,A}` 或 `{A,B,C,D,E,F,G,DP}` 顺序。编写字形查找表前应通过
逐段点亮测试建立“数组下标到 A-G/DP”的准确映射。

## 9. Vivado 与上板检查

### 9.1 约束检查

```tcl
report_io
report_drc
report_methodology
```

确认以下事项：

- 顶层端口名称与 XDC 中 `get_ports` 名称完全一致。
- 8 路段选/LED 共用信号只约束一次。
- 所有输出在复位时默认为高电平，避免上电瞬间全亮。
- 数码管扫描时任意时刻最多只使能一位。
- 未使用数码管时，`digit_n = 4'b1111`。
- 未使用 LED/段选时，`seg_led_n = 8'hFF`。
- 拨码输入已经进入 FPGA 时钟域同步。

### 9.2 建议的首次上板顺序

1. 关闭全部数码位：`digit_n = 4'b1111`。
2. 逐个将 `seg_led_n` 的某一位拉低，确认 LED 与数码管段线对应关系。
3. 记录每个数组下标对应的 `A-G/DP` 笔段。
4. 令所有段线为低，逐个拉低 `digit_n`，确认 K1-K4 的物理左右顺序。
5. 读取 `dip_sw` 并通过 ILA 或串口观察，确认 `LOW/HIGH` 方向。
6. 最后实现动态扫描和数字译码。

## 10. 机器可读引脚清单

```yaml
daughtercard: EES_363DP
voltage: 3.3V
baseboard: PYNQ-Z2
signals:
  segment_led_shared:
    active_low: true
    mapping:
      - {index: 0, package_pin: H15, schematic_net: FPGA_H13, led: LED3}
      - {index: 1, package_pin: F16, schematic_net: FPGA_K4,  led: LED1}
      - {index: 2, package_pin: T15, schematic_net: FPGA_B5,  led: LED5}
      - {index: 3, package_pin: V17, schematic_net: FPGA_B3,  led: LED8}
      - {index: 4, package_pin: U17, schematic_net: FPGA_A3,  led: LED7}
      - {index: 5, package_pin: T12, schematic_net: FPGA_M5,  led: LED2}
      - {index: 6, package_pin: V15, schematic_net: FPGA_A5,  led: LED4}
      - {index: 7, package_pin: R16, schematic_net: FPGA_A4,  led: LED6}
  digit_select:
    active_low: true
    mapping:
      - {index: 0, digit: K1, package_pin: V13}
      - {index: 1, digit: K2, package_pin: U13}
      - {index: 2, digit: K3, package_pin: U12}
      - {index: 3, digit: K4, package_pin: T14}
  dip_switch:
    mapping:
      - {index: 0, switch: SW1, package_pin: P15}
      - {index: 1, switch: SW2, package_pin: P16}
      - {index: 2, switch: SW3, package_pin: N17}
      - {index: 3, switch: SW4, package_pin: P18}
      - {index: 4, switch: SW5, package_pin: R17}
      - {index: 5, switch: SW6, package_pin: T16}
```

## 11. 已确认信息与推断信息

| 信息 | 可信度 | 依据 |
|---|---|---|
| 所有封装引脚 | 手册明确给出 | 第 4-6 页约束表 |
| 数码管为共阳极 | 手册明确给出 | 第 4 页正文 |
| 段选和 LED 共用引脚 | 手册明确给出 | 第 4 页备注及第 6 页表格 |
| 位选低有效 | 电路明确推断 | PNP 2N5401 高侧驱动原理图 |
| 段选低有效 | 共阳极结构和电路明确推断 | 第 4 页原理图 |
| LED 低有效 | PNP 高侧驱动电路明确推断 | 第 6 页原理图 |
| 段序号到 A-G/DP 的映射 | 手册未明确 | 需要逐段点亮或查器件资料 |

## 12. 原 PDF 页码索引

| 内容 | PDF 页码 |
|---|---:|
| 封面 | 1 |
| 目录 | 2 |
| 概述、供电 | 3 |
| 四位八段数码管及约束表 | 4 |
| 拨码开关及约束表 | 5 |
| LED 原理图及约束表 | 6 |
| 联系信息 | 7-8 |

