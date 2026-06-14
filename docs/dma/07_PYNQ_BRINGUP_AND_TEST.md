# PYNQ 上板、远程操作和测试命令

## 1. 当前板子信息

当前使用 Jupyter Notebook 服务操作 PYNQ：

```text
URL: http://192.168.137.2:9090/
password: xilinx
server root: /home/xilinx/jupyter_notebooks
project root: /home/xilinx/jupyter_notebooks/APUdma
```

普通浏览器可访问 `http://192.168.137.2/`，会跳转到 `:9090`。

## 2. 直接从 PC 操作板子

仓库提供了 PowerShell 辅助脚本：

```powershell
powershell -ExecutionPolicy Bypass -File dma/tools/pynq_jupyter_exec.ps1 `
  -Code "import os, subprocess; print(os.getcwd()); print(subprocess.check_output(['hostname']).decode())"
```

该脚本会：

1. 登录 Jupyter；
2. 创建临时 Python kernel；
3. 执行 `-Code` 中的 Python；
4. 打印 stdout/stderr；
5. 删除临时 kernel。

它适合跑检查、测试和短 benchmark。长时间运行时提高 `-TimeoutMinutes`：

```powershell
powershell -ExecutionPolicy Bypass -File dma/tools/pynq_jupyter_exec.ps1 `
  -TimeoutMinutes 60 `
  -Code "print('ready')"
```

## 3. 上传文件

推荐把整个工程放在：

```text
/home/xilinx/jupyter_notebooks/APUdma
```

至少要有：

```text
dma/overlay/apu_dma.bit
dma/overlay/apu_dma.hwh
dma/pynq/
dma/benchmark/
apuYjb/param/
```

只手动操作时可用 Jupyter 网页上传或 `scp`。若使用 Jupyter API 上传，必须保持 bit/hwh
同一轮构建。

## 4. 板上命令顺序

进入工程目录：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
```

确认 overlay 和中断：

```bash
python3 - <<'PY'
from pynq import Overlay
import json
ol = Overlay('dma/overlay/apu_dma.bit', download=False)
print(sorted(ol.ip_dict.keys()))
print(json.dumps(ol.interrupt_pins, indent=2, default=str))
PY
```

期望包含：

```text
axi_dma_0
axi_intc_0
apu_dma_0
axi_dma_0/mm2s_introut -> axi_intc_0 index 0
axi_dma_0/s2mm_introut -> axi_intc_0 index 1
apu_dma_0/irq          -> axi_intc_0 index 2
```

## 5. 必跑功能测试

```bash
python3 dma/pynq/test_apu_dma_smoke.py --require-interrupts
```

通过标志：

```text
APU DMA smoke test PASS
wait_mode: interrupt
```

如果失败并提示 interrupt unavailable，优先检查 HWH 是否包含 `axi_intc_0`，以及 bit/hwh
是否同一轮导出。

## 6. 真实 loader benchmark

25 MHz 当前口径：

```bash
python3 dma/benchmark/benchmark_apu_dma_transport.py \
  --clock-mhz 25 \
  --repeats 256 \
  --warmup 1 \
  --iterations 5
```

100 MHz bit 口径：

```bash
python3 dma/benchmark/benchmark_apu_dma_transport.py \
  --clock-mhz 100 \
  --repeats 256 \
  --warmup 1 \
  --iterations 5
```

输出：

```text
dma/reports/raw/apu_dma_transport_samples.csv
dma/reports/raw/apu_dma_transport_summary.json
```

`--allow-polling` 只能用于诊断，不能用于 CPU<10% 验收。

## 7. 完整网络 DMA wrapper

零输入 smoke：

```bash
python3 - <<'PY'
import sys, numpy as np
sys.path.insert(0, 'dma/pynq')
from inference_dma import ApuDmaNetwork

inp = np.zeros((1, 64, 32, 32), dtype=np.uint8)
with ApuDmaNetwork('dma/overlay/apu_dma.bit', 'apuYjb/param') as net:
    out = net.execute(inp)
    print(out.shape, int(out.sum()))
PY
```

当前状态：入口能运行，但重复零输入输出 SHA 不稳定，不能作为 bit-exact 通过证据。

## 8. 旧 MMIO 基线

旧 baseline 使用 `apuYjb/myDesign.bit/.hwh`：

```bash
python3 dma/benchmark/benchmark_mmio.py --warmup 1 --iterations 5
```

完整默认测试更慢：

```bash
python3 dma/benchmark/benchmark_mmio.py
```

输出：

```text
dma/reports/raw/mmio_transfer_samples.csv
dma/reports/raw/mmio_transfer_summary.json
```

## 9. 当前不维护 loopback

当前仓库没有 `dma/overlay/loopback/apu_dma_loopback.bit`，也不再维护独立 loopback Tcl。
不要再执行旧的 `test_dma_loopback.py` 命令。
