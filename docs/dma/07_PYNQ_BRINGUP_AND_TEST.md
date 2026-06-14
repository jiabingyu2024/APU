# PYNQ上板：无USB-TTL的Bring-up流程

## 1. 不需要USB-TTL

DMA路线使用PYNQ Linux、PS和PL。调试通过Jupyter、SSH或以太网完成，不需要外置USB-TTL。
普通Micro-USB线可用于供电/JTAG，但它不是本流程的数据传输通道。电脑与PYNQ应通过网线或
可用的网络连接互通。

## 2. 上传文件

把整个`dma/`目录传到板上，例如：

```bash
scp -r dma xilinx@<BOARD_IP>:/home/xilinx/APU/
```

确认板上存在：

```text
/home/xilinx/APU/dma/overlay/apu_dma.bit
/home/xilinx/APU/dma/overlay/apu_dma.hwh
/home/xilinx/APU/dma/pynq/
```

## 3. 首次检查顺序

先进入目录：

```bash
cd /home/xilinx/APU
```

运行ACT RAM往返测试：

```bash
python3 dma/pynq/test_apu_dma_smoke.py
```

该测试执行：

```text
DDR -> DMA MM2S -> LOAD ACT -> READ ACT -> DMA S2MM -> DDR
```

它不运行卷积，因此可先隔离DMA、packet、RAM写入和同步读返回问题。成功标志是：

```text
APU DMA smoke test PASS
```

如果HWH没有中断信息，只允许临时诊断：

```bash
python3 dma/pynq/test_apu_dma_smoke.py --allow-polling
```

polling结果不能用于CPU占用率验收。

## 4. 测试原始DMA上限

先用阶段B loopback bit/hwh执行：

```bash
python3 dma/pynq/test_dma_loopback.py \
  --bitstream dma/overlay/loopback/apu_dma_loopback.bit
```

它回答“PS DDR、HP端口和AXI DMA本身是否达到200 MB/s”。

## 5. 测试真实loader数据通路

```bash
python3 dma/benchmark/benchmark_apu_dma_transport.py
```

默认job约2 MiB，重复覆盖64个weight bank，避免短传输的软件固定开销掩盖带宽。输出：

```text
dma/reports/raw/apu_dma_transport_samples.csv
dma/reports/raw/apu_dma_transport_summary.json
```

验收重点：

- `wall_mbps_mean >= 200`；
- `cpu_percent_mean < 10`；
- `mm2s_stall_cycles`用于判断loader是否成为瓶颈；
- 必须是interrupt模式，不能用polling数据替代。

## 6. 故障定位

| 现象 | 优先检查 |
|---|---|
| Overlay加载失败 | bit/hwh是否同名且同次生成 |
| 找不到`axi_dma_0` | HWH错误或BD实例名改变 |
| ID mismatch | `apu_dma_0`地址/HWH错误，或bit未下载 |
| DMA一直busy | S2MM是否先启动、TLAST是否由FINAL/ERROR产生 |
| smoke数据错位 | AXIS宽度/TKEEP、feature同步读延迟、地址单位 |
| ERROR响应 | `LAST_ERROR`和response status错误码 |
| CPU占用高 | 是否有DMA中断、是否使用`wait_async`、job是否过短 |
| 带宽低但stall高 | loader背压或DMA/FIFO配置问题 |

