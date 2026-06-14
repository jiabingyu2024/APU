# 无 USB-TTL 的板级调试与验收

## 1. 适用边界

本方案不读取 PL UART，不需要外置 USB-TTL。普通 USB 线只承担 PYNQ-Z2 的供电、
USB-JTAG 下载和 XSCT 访问；SoC 是否正常由板载按钮、拨码开关、4 个普通 LED 和
2 个 RGB LED判断。

PL 顶层不实例化 PS7。需要注意：`H16` 的 125 MHz 来自以太网 PHY，冷启动时 PHY
初始化仍可能依赖 PS MIO。最终要求应表述为“Cortex-A9 双核保持 reset 且停止时钟”，
不能复位整个 PS 外设域，否则 H16 可能消失。

## 2. 板载资源

| 资源 | 作用 |
| --- | --- |
| BTN0 | 复位纯 PL SoC，松开后重新执行固件 |
| BTN1 | 普通 LED 灯检；按住时 LED0..3 必须全亮，不依赖 SoC 时钟 |
| SW0=0 | 普通 LED 显示运行状态 |
| SW0=1 | 普通 LED 显示 8 位固件阶段码的一个半字节 |
| SW1=0 | 显示阶段码低 4 位 |
| SW1=1 | 显示阶段码高 4 位 |

SW0=0 时：

| LED | 含义 | 正常最终状态 |
| --- | --- | --- |
| LED0 | 全部固件检查通过 | 亮 |
| LED1 | 固件失败或 PicoRV32 trap | 灭 |
| LED2 | APU 至少完成过一次 | 亮 |
| LED3 | 25 MHz 心跳 | 持续闪烁 |

RGB LED 为低有效，RTL 统一使用 25% PWM：

| 指示 | 含义 |
| --- | --- |
| LD4 红 | FAIL/trap |
| LD4 绿 | 最终 PASS |
| LD4 蓝 | 固件正在运行 |
| LD5 红 | PicoRV32 trap |
| LD5 绿 | CPU 已执行到第一条阶段码写入 |
| LD5 蓝 | APU 曾完成一次计算 |

## 3. 固件阶段码

| 阶段码 | 含义 |
| --- | --- |
| `01` | 已进入 `main`，Boot RAM 和 CPU 基本可工作 |
| `10` | RAM byte/half/word 检查通过 |
| `20` | RV32IM 乘除检查通过 |
| `30` | timer 检查通过 |
| `40` | default slave 检查通过 |
| `50` | 开始完整网络 |
| `51` | 前 8 条 WorkSheet 指令完成 |
| `52`..`55` | 四个 layer3 batch 依次完成 |
| `5F` | 完整网络最终 golden 比较通过 |
| `60` | 开始 zero-conv 闭环 |
| `6F` | zero-conv 全部输出通过 |
| `70` | 开始 APU MMIO smoke test |
| `7E` | APU MMIO smoke test 通过 |
| `7F` | 所有检查通过，即将写 EXIT=0 |

失败码为 `0x80 | 原 fail code`。例如 LED 高/低半字节组合为 `B6`，则原始失败码是
`0x36`，表示完整网络最终输出与 golden 不一致。

## 4. 下载后的判断顺序

1. 下载 bit 后按住 BTN1。若 LED0..3 不能全亮，先检查 bit、顶层和 XDC，不查 CPU/APU。
2. 松开 BTN1，令 SW0=0。LED3 应闪烁；不闪表示 H16/MMCM/复位链未工作。
3. LD5 绿色应很快出现；没有则 CPU 未从 Boot RAM 正常执行。
4. LED2/LD5 蓝应出现；没有则将 SW0=1，分别读取阶段码高低半字节。
5. 正常运行约 0.2 秒内结束，最终 LED0、LED2 亮，LED1 灭，LED3闪烁，LD4 绿。
6. 若 LD4 红或 LED1 亮，读取阶段码；若阶段码高位为 8..B，按上一节还原 fail code。

## 5. LED0 不亮的定位表

| 现象 | 优先结论 |
| --- | --- |
| BTN1 灯检失败 | 顶层/XDC/bit 下载错误 |
| 灯检通过但 LED3 不闪 | H16 无时钟、PHY 未释放、MMCM 未锁定或 BTN0 被按住 |
| LED3 闪但 LD5 绿不亮 | firmware.hex 未进 Boot RAM、CPU reset/trap 或工程使用旧初始化文件 |
| 阶段码停在 `50` | 模型搬运或前 8 条计算未完成 |
| 阶段码停在 `51`..`54` | 对应 layer3 batch 未完成 |
| 阶段码为 `B0`..`B4` | APU completion timeout |
| 阶段码为 `B6` | 最终网络结果与 golden 不一致 |
| LED2 亮但 LED0 不亮 | APU 至少运行过，但后续 zero-conv/MMIO/golden 检查失败 |

## 6. 不使用 USB-TTL 时仍可使用的 USB 功能

- Vivado Hardware Manager 通过 J8 USB-JTAG 下载 bit。
- XSCT 通过同一 JTAG 链写 `A9_CPU_RST_CTRL`，不需要串口。
- 可选 ILA 也走 USB-JTAG，不属于 USB-TTL；资源紧张时不建议默认加入 bitstream。

普通 USB 数据线不能把任意 PL UART 引脚自动变成串口。当前 `uart_tx_o` 位于 PMODB，
没有外置电平适配/USB-UART 时不要把 UART 日志作为验收条件。
