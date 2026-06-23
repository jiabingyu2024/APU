# Final Tests Python Drivers and Metrics

本文解释 `dma/final_tests/` 中最终汇报脚本的 Python 调用关系，以及旧版 MMIO driver 和新版 DMA driver 如何输出带宽、CPU 占用、推理时间等数字。

核心目标：

- 看懂 01 到 06 六个 final tests 分别调用了哪些 Python 文件。
- 看懂旧版 `myDesign.bit` 路线怎样通过 MMIO/AHB driver 访问 APU。
- 看懂新版 `apu_dma.bit` 路线怎样通过 AXI DMA driver 访问 APU。
- 看懂 JSON 里的 `wall_mbps`、`hardware_mbps`、`cpu_percent`、`inference_ms`、`average_inference_ms` 如何计算。

## 1. 六个 Final Tests 的分组

| 编号 | 脚本 | 路线 | 主要目的 | 报告文件 |
| --- | --- | --- | --- | --- |
| 01 | `01_mydesign_benchmark.py` | 旧 MMIO/AHB | 纯传输基线 | `01_mydesign_benchmark.json` |
| 02 | `02_mydesign_inference.py` | 旧 MMIO/AHB | 单图推理 | `02_mmio_inference.json` |
| 03 | `03_mydesign_evaluate.py` | 旧 MMIO/AHB | CIFAR-10 小样本评估 | `03_mmio_evaluate.json` |
| 04 | `04_apu_dma_benchmark.py` | 新 DMA | 纯 DMA transport 验收 | `04_apu_dma_benchmark.json` |
| 05 | `05_apu_dma_inference.py` | 新 DMA | 单图推理 | `05_dma_inference.json` |
| 06 | `06_apu_dma_evaluate.py` | 新 DMA | CIFAR-10 小样本评估 | `06_dma_evaluate.json` |

最重要的口径：

```text
传输带宽 >= 200 MB/s：主要看 04 的 wall_mbps_mean
CPU 占用率 < 10%：主要看 04 的 cpu_percent_mean，并确认 wait_mode=interrupt
功能正确性：看 02 vs 05 的单图输出，以及 03 vs 06 的 Top-1/Top-5
```

01 和 04 是纯传输测试。02/03/05/06 会进入完整 ResNet hybrid 推理流程。

## 2. 02/03/05/06 的共同入口

这四个脚本都进入：

```text
dma/final_tests/common.py
```

入口关系：

```text
02_mydesign_inference.py
  -> single_image_main("mmio")

03_mydesign_evaluate.py
  -> evaluate_main("mmio")

05_apu_dma_inference.py
  -> single_image_main("dma")

06_apu_dma_evaluate.py
  -> evaluate_main("dma")
```

`single_image_main()` 的主流程：

```text
build_model(transport)
  -> load one image
  -> preprocess image
  -> model(input_batch)
  -> capture APU boundary input/output
  -> metrics(model.apu_driver)
  -> save JSON and npy files
```

`evaluate_main()` 的主流程：

```text
build_model(transport)
  -> load CIFAR-10 subset
  -> for each image:
       outputs = model(images)
       update Top-1 / Top-5
       transfer_rows.append(metrics(model.apu_driver))
  -> aggregate transfer_rows
  -> save JSON
```

这里的 `transport` 决定使用哪条硬件路线：

- `"mmio"`：旧版 `apuYjb/apu_driver.py`。
- `"dma"`：新版 `dma/pynq/apu_driver_dma.py`。

## 3. 模型层：`resnet_binary_ps.py`

02/03/05/06 都使用同一个模型文件：

```text
apuYjb/resnet_binary_ps.py
```

`common.build_model()` 调用：

```text
resnet_binary_ps.resnet_binary_cifar10_hybrid(...)
```

模型 `forward()` 可简化为：

```text
input image
  -> PS/PyTorch conv1 + bn1 + hardtanh
  -> convert to 0/1 binary tensor
  -> apu_driver.execute_apu_network(input_tensor_ps_01)
  -> APU returns 0/1 tensor
  -> convert 0/1 back to -1/+1
  -> PS/PyTorch avgpool + fc + bn3 + logsoftmax
  -> class prediction
```

因此：

- `inference_ms` 测的是一次 `model(input_batch)` 的耗时，不只是 DMA 传输，也不只是 APU RTL 计算。
- `transfer` 字段来自 `model.apu_driver.last_transfer_metrics`，只描述 APU driver 这一段的传输统计。

## 4. 新旧 Driver 如何切换

切换发生在 `common.select_driver()`：

```python
def select_driver(transport, apu_dir, dma_dir):
    for name in ("resnet_binary_ps", "apu_driver"):
        sys.modules.pop(name, None)
    sys.path.insert(0, apu_dir)
    if transport == "dma":
        pynq_dir = os.path.join(dma_dir, "pynq")
        sys.path.insert(0, pynq_dir)
        sys.modules["apu_driver"] = importlib.import_module("apu_driver_dma")
    return importlib.import_module("resnet_binary_ps").resnet_binary_cifar10_hybrid
```

这段代码的含义：

1. 清掉 `resnet_binary_ps` 和 `apu_driver` 的模块缓存，避免上一轮测试污染当前路线。
2. 把 `apuYjb` 加到 `sys.path`，使模型文件可导入。
3. 如果是 DMA 路线，就先把模块名 `apu_driver` 指向 `dma/pynq/apu_driver_dma.py`。

所以 `resnet_binary_ps.py` 中虽然写的是：

```python
from apu_driver import APUDriver
```

但实际导入结果取决于 `transport`：

```text
transport="mmio"
  apu_driver -> apuYjb/apu_driver.py

transport="dma"
  apu_driver -> dma/pynq/apu_driver_dma.py
```

这是一种兼容适配。模型层仍然调用同一个 `execute_apu_network()`，底层 driver 被替换。

## 5. 旧版 MMIO Driver 调用链

旧版 driver：

```text
apuYjb/apu_driver.py
```

调用链：

```text
common.py
  -> resnet_binary_ps.py
     -> self.apu_driver.execute_apu_network(...)
        -> apuYjb/apu_driver.py::APUDriver.execute_apu_network
           -> PYNQ Overlay(myDesign.bit)
           -> MMIO write/read
```

旧版初始化：

```text
APUDriver.__init__
  -> Overlay(bitstream_file)
  -> overlay.ip_dict[axi_apu_ip_name]
  -> MMIO(phys_addr, addr_range)
```

旧版访问硬件的基本函数：

| 函数 | 作用 | 方向 |
| --- | --- | --- |
| `_ahb_write_single_reg_py(addr, data)` | 写一个 32-bit 控制寄存器或 RAM word | PS -> PL |
| `_ahb_write_burst_py(addr, data_list)` | 通过 MMIO 写一段 uint32 数据 | PS -> PL |
| `_ahb_read_single_reg_py(addr)` | 读一个 32-bit 寄存器 | PL -> PS |
| `_ahb_read_burst_py(addr, count)` | 循环读 `count` 个 32-bit word | PL -> PS |

旧版 `execute_apu_network()` 做的事情：

```text
1. 将 APU 输入 tensor 打包成 32-bit word list
2. RAM_CTRL=0x3，允许 PS 写 APU RAM
3. RAM_SEL=IN_RAM_SEL，选择输入 feature RAM
4. _ahb_write_burst_py 写入输入 feature
5. 分阶段加载 weight、BN、instruction
6. RAM_CTRL=0x0，交给 APU 运行
7. APU_READY=1 启动
8. while CPL_ADDR == 0: sleep(0.00001)，轮询等待完成
9. 读取输出 RAM
10. 解包成 NCHW 0/1 tensor 返回给 PyTorch 后处理
```

旧版路线的本质：

```text
控制、参数、输入、输出都通过 MMIO/AHB 小粒度访问完成。
```

所以它带宽低，CPU 占用高。

## 6. 旧版 02/03 的带宽如何统计

旧版原 driver 没有性能统计。`common.py` 增加了：

```text
LegacyTransferMonitor
```

它在 `build_model("mmio")` 后包装旧 driver：

```python
LegacyTransferMonitor(model.apu_driver)
```

### 6.1 字节数统计

`LegacyTransferMonitor` 替换四个 MMIO 函数：

```text
_ahb_write_single_reg_py
_ahb_write_burst_py
_ahb_read_single_reg_py
_ahb_read_burst_py
```

统计规则：

```text
write_single: ps_to_pl_bytes += 4
write_burst : ps_to_pl_bytes += 4 * len(data)
read_single : pl_to_ps_bytes += 4
read_burst  : pl_to_ps_bytes += 4 * count
```

所以旧版的 `ps_to_pl_bytes` 和 `pl_to_ps_bytes` 是按 driver 发起的 MMIO 读写数量数出来的。

### 6.2 时间和 CPU 统计

它还包装 `execute_apu_network()`：

```python
wall_start = time.perf_counter()
cpu_start = time.process_time()
result = execute(*args, **kwargs)
cpu_seconds = time.process_time() - cpu_start
wall_seconds = time.perf_counter() - wall_start
total = ps_to_pl_bytes + pl_to_ps_bytes
```

输出字段：

```text
transport      = "legacy_mmio_ahb"
wait_mode      = "polling"
ps_to_pl_bytes = 写入 APU 的字节数
pl_to_ps_bytes = 从 APU 读回的字节数
total_bytes    = ps_to_pl_bytes + pl_to_ps_bytes
wall_seconds   = execute_apu_network 的真实耗时
cpu_seconds    = Python 进程消耗的 CPU 时间
cpu_percent    = 100 * cpu_seconds / wall_seconds
wall_mbps      = total_bytes / wall_seconds / 1e6
```

`time.perf_counter()` 是墙钟时间，包含等待硬件、sleep、MMIO 调用开销。`time.process_time()` 是 Python 进程实际消耗的 CPU 时间。

旧版 `wait_mode` 固定为 `polling`，因为它通过读 `CPL_ADDR` 轮询 APU 完成。

## 7. 新版 DMA Driver 调用链

DMA 兼容 driver：

```text
dma/pynq/apu_driver_dma.py
```

它故意暴露和旧版同名的类：

```text
class APUDriver
```

以及同名方法：

```text
execute_apu_network(...)
```

这样 `resnet_binary_ps.py` 不需要改。

DMA 路线调用链：

```text
common.py
  -> sys.modules["apu_driver"] = apu_driver_dma
  -> resnet_binary_ps.py
     -> self.apu_driver.execute_apu_network(...)
        -> dma/pynq/apu_driver_dma.py::APUDriver.execute_apu_network
           -> ApuDmaNetwork.execute(...)
              -> ApuDmaOverlay.execute(...)
                 -> PYNQ AXI DMA send/recv channels
                 -> apu_dma_0 custom IP
```

对应文件：

| 层级 | 文件 | 作用 |
| --- | --- | --- |
| 兼容层 | `dma/pynq/apu_driver_dma.py` | 模拟旧 `APUDriver` 接口 |
| 网络 job 层 | `dma/pynq/inference_dma.py` | 复用 TX buffer，执行完整网络 job |
| job 构造层 | `dma/pynq/dma_network_job.py` | 把输入、权重、BN、instruction 打包成 job |
| packet 协议层 | `dma/pynq/dma_job.py` | 定义 JobBuilder、header、response parser |
| PYNQ DMA 层 | `dma/pynq/apu_dma_driver.py` | Overlay、AXI DMA、MMIO 状态寄存器、中断等待 |

## 8. DMA 单图/评估执行过程

`ApuDmaNetwork.__init__()` 在模型初始化时执行一次：

```text
1. ApuDmaOverlay(bitstream)
2. allocate TX job buffer
3. 使用全 0 input 构建完整网络 job
4. 记录 input_slice
5. 保存 used_bytes 和 expected_response_bytes
```

重点是：

```text
权重、BN、instruction 的 packet 结构在初始化时已经放进 TX buffer。
每次推理只替换输入 feature 所在的 input_slice。
```

每次 `execute(input_tensor)`：

```text
1. pack_input_nchw(input_tensor)
2. self.tx[input_slice] = packed input
3. ApuDmaOverlay.execute(tx, used_bytes, expected_response_bytes)
4. parse response DATA packet
5. unpack_output_payload(...)
6. 返回 NCHW 0/1 tensor
```

`ApuDmaOverlay.execute_async()` 的实际 DMA 流程：

```text
1. 检查 tx_buffer 是 pynq.allocate 得到的 uint64 buffer
2. 如果没有传入 rx_buffer，则 allocate RX buffer
3. RX buffer 清零
4. tx_buffer.flush()
5. rx_buffer.flush()
6. recvchannel.transfer(rx_buffer, nbytes=expected_response_bytes)
7. sendchannel.transfer(tx_buffer, nbytes=used_bytes)
8. wait_async 或 wait 等待 DMA 完成
9. rx_buffer.invalidate()
10. find_response_used_bytes()
11. iter_response_packets()
12. 若 terminal response 是 ERROR，则抛出 ApuDmaError
13. 返回 DmaResponse
```

`wait_mode` 的来源：

```text
sendchannel 有 interrupt 且 recvchannel 有 interrupt -> interrupt
否则 -> polling
```

验收 CPU `<10%` 必须是：

```text
wait_mode = interrupt
```

## 9. DMA 05/06 的带宽如何统计

`dma/pynq/apu_driver_dma.py` 的 `execute_apu_network()` 记录 `last_transfer_metrics`。

简化逻辑：

```python
self.network.driver.clear_counters()
wall_start = time.perf_counter()
cpu_start = time.process_time()
output = self.network.execute(input_tensor_ps_01)
cpu_seconds = time.process_time() - cpu_start
wall_seconds = time.perf_counter() - wall_start
status = self.network.driver.read_status()
total_bytes = status["rx_bytes"] + status["tx_bytes"]
hardware_seconds = status["busy_cycles"] / (self.clock_mhz * 1_000_000.0)
```

输出字段：

```text
transport      = "apu_dma"
wait_mode      = "interrupt" 或 "polling"
ps_to_pl_bytes = status["rx_bytes"]
pl_to_ps_bytes = status["tx_bytes"]
total_bytes    = rx_bytes + tx_bytes
wall_seconds   = network.execute 的真实耗时
cpu_seconds    = Python 进程消耗的 CPU 时间
cpu_percent    = 100 * cpu_seconds / wall_seconds
wall_mbps      = total_bytes / wall_seconds / 1e6
hardware_mbps  = total_bytes / hardware_seconds / 1e6
busy_cycles    = status["busy_cycles"]
clock_mhz      = self.clock_mhz
```

这里 `status` 来自 `apu_dma_0` 的 AXI-Lite 性能计数器：

```text
rx_bytes    : apu_dma_0 从 S_AXIS_JOB 接收的字节数
tx_bytes    : apu_dma_0 从 M_AXIS_RESULT 发出的字节数
busy_cycles : apu_dma_0 job busy 的周期数
```

注意：05/06 的 `wall_mbps` 是应用侧单图/多图 driver 调用口径，不是纯 DMA 通道峰值。它包含输入打包、TX buffer 更新、DMA、APU 运行、response 解析等开销，所以通常远低于 04。

还有一个细节：

```text
apu_driver_dma.py 当前 clock_mhz 默认是 25.0。
```

`common.build_model("dma")` 通过 `resnet_binary_ps.py` 构造 driver 时没有传入 `clock_mhz`，所以如果你使用 50 MHz bitstream，05/06 报告里的 `hardware_mbps` 只能作为应用侧参考。严格的硬件计数器带宽以 04 中显式传入 `--clock-mhz 50` 的结果为准。

## 10. 01 旧版纯 MMIO Benchmark

01 包装：

```text
dma/benchmark/benchmark_mmio.py
```

调用关系：

```text
01_mydesign_benchmark.py
  -> runpy.run_path("dma/benchmark/benchmark_mmio.py")
  -> 生成 dma/reports/raw/mmio_transfer_summary.json
  -> 复制为 dma/reports/final/01_mydesign_benchmark.json
```

测试过程：

```text
1. 初始化 APUDriver(myDesign.bit, APU_0)
2. RAM_CTRL=0x3，允许 PS 访问 RAM
3. RAM_SEL=IN_RAM_SEL
4. 对每个 size_bytes 构造 pattern
5. warmup 若干次
6. 测 _ahb_write_burst_py 的耗时，记为 ps_to_pl
7. 测 _ahb_read_burst_py 的耗时，记为 pl_to_ps
8. 检查 readback 是否等于 pattern
9. 写 CSV 和 summary JSON
```

单条样本公式：

```text
wall_seconds = perf_counter 结束值 - 开始值
cpu_seconds  = process_time 结束值 - 开始值
cpu_percent  = 100 * cpu_seconds / wall_seconds
mb_per_second = size_bytes / wall_seconds / 1e6
```

summary 公式：

```text
mbps_mean = mean(mb_per_second)
mbps_min  = min(mb_per_second)
mbps_p50  = percentile(mb_per_second, 50)
mbps_p95  = percentile(mb_per_second, 95)
mbps_max  = max(mb_per_second)
cpu_percent_mean = mean(cpu_percent)
```

01 的意义是建立旧 MMIO/AHB 的纯传输基线，不涉及完整神经网络推理。

## 11. 04 新版纯 DMA Transport Benchmark

04 包装：

```text
dma/benchmark/benchmark_apu_dma_transport.py
```

调用关系：

```text
04_apu_dma_benchmark.py
  -> runpy.run_path("dma/benchmark/benchmark_apu_dma_transport.py")
  -> 生成 dma/reports/raw/apu_dma_transport_summary.json
  -> 复制为 dma/reports/final/04_apu_dma_benchmark.json
```

04 不经过 ResNet，也不经过 `apu_driver_dma.py`，而是直接使用：

```text
ApuDmaOverlay
JobBuilder
```

测试 job：

```text
payload = 256 个 uint64
for repeat in repeats:
    for bank in 0..63:
        LOAD WEIGHT bank, payload
END_JOB
```

也就是说 04 主要压测：

```text
AXI DMA MM2S -> AXIS FIFO -> apu_dma loader -> response -> AXI DMA S2MM
```

它不是 CIFAR-10 推理，不输出分类结果。

04 的计时范围：

```python
driver.clear_counters()
wall_start = time.perf_counter()
cpu_start = time.process_time()
with driver.execute(tx, used_bytes, expected_response_bytes, rx_buffer=rx):
    pass
cpu_seconds = time.process_time() - cpu_start
wall_seconds = time.perf_counter() - wall_start
status = driver.read_status()
```

单条样本公式：

```text
job_bytes = used_bytes
wall_mb_per_second = used_bytes / wall_seconds / 1e6
cpu_percent = 100 * cpu_seconds / wall_seconds

hardware_seconds = busy_cycles / (clock_mhz * 1_000_000)
hardware_mb_per_second = used_bytes / hardware_seconds / 1e6
```

summary 公式：

```text
wall_mbps_mean = mean(wall_mb_per_second)
wall_mbps_p50 = percentile(wall_mb_per_second, 50)
hardware_mbps_mean = mean(hardware_mb_per_second)
cpu_percent_mean = mean(cpu_percent)
passes_200mbps_wall = wall_mbps_mean >= 200
passes_cpu_10percent = cpu_percent_mean < 10
```

04 是验收主口径，因为它专门测 DMA transport，并且 `--clock-mhz` 由命令行显式给出。

## 12. 03/06 Evaluate 的聚合统计

每张图执行：

```python
start = time.time()
outputs = model(images)
inference_times.append(time.time() - start)
transfer_rows.append(metrics(model.apu_driver))
```

准确率：

```text
Top-1: argmax(outputs) == label
Top-5: label in outputs.topk(5)
```

平均单图推理时间：

```text
average_inference_ms = 1000 * sum(inference_times) / samples
```

传输统计聚合：

```text
ps_to_pl_bytes = sum(row["ps_to_pl_bytes"])
pl_to_ps_bytes = sum(row["pl_to_ps_bytes"])
total_bytes    = sum(row["total_bytes"])
wall_seconds   = sum(row["wall_seconds"])
cpu_seconds    = sum(row["cpu_seconds"])
wall_mbps      = total_bytes / wall_seconds / 1e6
cpu_percent    = 100 * cpu_seconds / wall_seconds
```

如果是 DMA 路线，还会记录：

```text
hardware_mbps = mean(row["hardware_mbps"])
```

注意这里的 `wall_seconds` 是每张图 driver 层 transfer metric 的 wall_seconds 之和，不是整个 Python 脚本从开始到结束的总耗时。

## 13. 02/05 Single Image 的 SHA 输出

02 和 05 会临时包装 `execute_apu_network()`，捕获 APU 边界输入/输出：

```python
apu_input = kwargs.get("input_tensor_ps_01", args[0] if args else None)
result = execute(*args, **kwargs)
captured["input"] = apu_input.detach().cpu().to(torch.uint8).clone()
captured["output"] = result.detach().cpu().to(torch.uint8).clone()
```

保存文件：

```text
dma/reports/final/02_mmio_inference_apu_input.npy
dma/reports/final/02_mmio_inference_apu_output.npy
dma/reports/final/05_dma_inference_apu_input.npy
dma/reports/final/05_dma_inference_apu_output.npy
```

JSON 中的 hash：

```text
apu_input_sha256
apu_output_sha256
```

计算方式：

```python
array = np.ascontiguousarray(tensor.detach().cpu().numpy())
sha256(array.tobytes())
```

如果 02 和 05 的 `apu_output_sha256` 一致，说明 DMA wrapper 没有改变 APU 输出结果。

## 14. 输出字段速查

| 字段 | 来源 | 含义 |
| --- | --- | --- |
| `transport` | driver 填入 | `legacy_mmio_ahb` 或 `apu_dma` |
| `wait_mode` | driver 填入 | 旧版为 `polling`，DMA 为 `interrupt` 或 `polling` |
| `ps_to_pl_bytes` | 旧版包装函数或 DMA 硬件计数器 | PS 到 PL 的数据量 |
| `pl_to_ps_bytes` | 旧版包装函数或 DMA 硬件计数器 | PL 到 PS 的数据量 |
| `total_bytes` | 两方向相加 | 总传输字节数 |
| `wall_seconds` | `time.perf_counter()` | 真实墙钟耗时 |
| `cpu_seconds` | `time.process_time()` | Python 进程 CPU time |
| `cpu_percent` | 公式计算 | `100 * cpu_seconds / wall_seconds` |
| `wall_mbps` | 公式计算 | `total_bytes / wall_seconds / 1e6` |
| `hardware_mbps` | DMA 硬件计数器 | `bytes / (busy_cycles / clock)` |
| `inference_ms` | 02/05 | 单次 `model(input_batch)` 墙钟耗时 |
| `average_inference_ms` | 03/06 | 多张图片平均 `model(images)` 墙钟耗时 |
| `prediction` | 02/05 | `argmax(logsoftmax)` |
| `top1_percent` | 03/06 | Top-1 正确率 |
| `top5_percent` | 03/06 | Top-5 正确率 |

## 15. 为什么不同带宽数字不同

项目里至少有四种带宽口径：

### 15.1 01 的 MMIO benchmark 带宽

```text
mb_per_second = size_bytes / one MMIO read-or-write wall_seconds / 1e6
```

这是旧 AHB/MMIO RAM window 的纯读写速度。

### 15.2 02/03 的旧版 driver 带宽

```text
wall_mbps = all counted MMIO bytes during execute_apu_network / execute wall_seconds / 1e6
```

这是旧版完整 APU driver 调用期间的数据搬运口径，包含参数加载、输入写入、轮询等待、输出读取。

### 15.3 04 的 DMA transport 带宽

```text
wall_mbps_mean = used_bytes / driver.execute wall_seconds / 1e6
```

这是 DMA 通道验收主口径，使用聚合大 job。

### 15.4 05/06 的 DMA 应用侧带宽

```text
wall_mbps = (rx_bytes + tx_bytes) / network.execute wall_seconds / 1e6
```

它包含完整网络 job 调用、输入替换、DMA、APU 运行和 response 解析，通常远低于 04。

所以汇报时建议这样说：

```text
纯传输验收看 04。
应用端到端效果看 05/06。
旧方案对比看 01/02/03。
```

## 16. 总调用图

```text
01_mydesign_benchmark.py
  -> benchmark_mmio.py
     -> apuYjb/apu_driver.py
        -> PYNQ Overlay(myDesign.bit)
        -> MMIO write/read

02_mydesign_inference.py
03_mydesign_evaluate.py
  -> common.py
     -> resnet_binary_ps.py
        -> apuYjb/apu_driver.py
           -> MMIO/AHB write weights/input/instruction
           -> polling wait CPL
           -> MMIO/AHB read output
     -> LegacyTransferMonitor counts bytes/time

04_apu_dma_benchmark.py
  -> benchmark_apu_dma_transport.py
     -> ApuDmaOverlay
        -> JobBuilder repeated LOAD WEIGHT packets
        -> AXI DMA send/recv
        -> apu_dma_0 hardware counters

05_apu_dma_inference.py
06_apu_dma_evaluate.py
  -> common.py
     -> sys.modules["apu_driver"] = apu_driver_dma
     -> resnet_binary_ps.py
        -> dma/pynq/apu_driver_dma.py
           -> ApuDmaNetwork
              -> dma_network_job.py builds full network job
              -> ApuDmaOverlay
                 -> AXI DMA send/recv
                 -> apu_dma_0 response + counters
```

## 17. 答辩简短说法

如果老师问“Python driver 怎么切换新旧硬件”，可以答：

> 我保留了原 `resnet_binary_ps.py` 的 `execute_apu_network()` 接口。旧路线导入 `apuYjb/apu_driver.py`，通过 MMIO/AHB 写输入、权重、BN、instruction 并轮询完成。DMA 路线在 `common.select_driver()` 中把模块名 `apu_driver` 替换为 `dma/pynq/apu_driver_dma.py`，因此模型层代码不用改，但底层实际变成构造 DMA job、调用 AXI DMA send/recv、解析 response。

如果老师问“带宽怎么测”，可以答：

> 旧版 MMIO 的字节数由 `LegacyTransferMonitor` 包装 MMIO read/write 函数统计，时间用 `perf_counter()`，CPU 用 `process_time()`。DMA 版 04 的带宽用 job `used_bytes` 除以一次 DMA execute 的 wall time；硬件带宽用 `busy_cycles / clock_mhz` 换算；CPU 占用是 `process_time / perf_counter`。最终验收主要看 04 的 `wall_mbps_mean` 和 `cpu_percent_mean`。

