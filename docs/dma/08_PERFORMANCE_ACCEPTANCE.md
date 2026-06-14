# DMA性能验收与报告口径

## 1. 必须分别报告三组数据

1. 旧AXI-Lite/AHB MMIO基线：`benchmark_mmio.py`；
2. 纯DMA loopback：`test_dma_loopback.py`；
3. 真实APU loader通路：`benchmark_apu_dma_transport.py`。

完整网络端到端推理数据必须在bit-exact功能通过后补充，不能用纯DMA带宽替代推理性能。

## 2. 带宽定义

```text
MB/s = 有效payload字节 / 墙钟秒 / 1e6
```

同时报告硬件计数器口径：

```text
hardware MB/s = RX_BYTES / (BUSY_CYCLES / 100 MHz) / 1e6
```

墙钟带宽包含Python、DMA提交和中断返回开销；硬件带宽用于定位PL数据通路本身。

## 3. CPU占用率

```text
CPU% = process_time / wall_time * 100
```

只接受DMA中断等待数据。使用busy polling、循环读状态寄存器或`--allow-polling`的结果只能
用于诊断，不能证明CPU占用率小于10%。

## 4. 最终通过条件

- loopback与真实loader平均带宽均至少200 MB/s；
- DMA等待窗口平均CPU占用率小于10%；
- 连续1000次job无hang、DMA error、短包或错序；
- DMA输出与旧MMIO路径逐字bit-exact；
- 完整网络Top-1/Top-5不因接口替换而下降；
- Vivado实现后`WNS >= 0`、`TNS = 0`且DRC无error。

