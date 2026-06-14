# DMA 文件清单和实际操作流程

## 1. 当前保留的路径

```text
dma/
  rtl/
    apu_dma_*.sv
    axis_job_decoder.sv
    apu_stream_loader.sv
    apu_job_ctrl.sv
    axis_result_streamer.sv
  vivado/
    package_apu_dma_ip.tcl
    create_apu_dma_project.tcl
    build_apu_dma_bitstream.tcl
    export_apu_dma_overlay.tcl
    report_apu_dma_design.tcl
  overlay/
    apu_dma.bit
    apu_dma.hwh
  pynq/
    apu_dma_driver.py
    dma_job.py
    dma_network_job.py
    test_apu_dma_smoke.py
    inference_dma.py
    apu_driver_dma.py
  benchmark/
    benchmark_apu_dma_transport.py
    benchmark_mmio.py
  tools/
    pynq_jupyter_exec.ps1
  reports/
    raw/
```

不再维护独立 loopback overlay。当前 `dma/overlay/` 只要求存在：

```text
apu_dma.bit
apu_dma.hwh
```

## 2. Vivado 侧流程

从空目录重建：

```tcl
cd {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU}

set ::env(APU_DMA_IP_BUILD_DIR) {E:/apu_dma_ip_pack}
source dma/vivado/package_apu_dma_ip.tcl

set ::env(APU_DMA_PROJECT_DIR) {E:/apu_dma_bd}
source dma/vivado/create_apu_dma_project.tcl
```

生成 bitstream：

```tcl
set ::env(APU_DMA_PROJECT_DIR) {E:/apu_dma_bd}
source dma/vivado/build_apu_dma_bitstream.tcl
```

导出 overlay：

```tcl
source {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU/dma/vivado/export_apu_dma_overlay.tcl}
```

导出报告：

```tcl
source {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU/dma/vivado/report_apu_dma_design.tcl}
```

详见 [Vivado Tcl 工程生成和 bit/hwh 导出指南](06_VIVADO_GUI_BUILD_AND_EXPORT.md)。

## 3. PYNQ 侧流程

板上路径：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
```

功能 smoke：

```bash
python3 dma/pynq/test_apu_dma_smoke.py --require-interrupts
```

真实 loader benchmark：

```bash
python3 dma/benchmark/benchmark_apu_dma_transport.py \
  --clock-mhz 25 \
  --repeats 256 \
  --warmup 1 \
  --iterations 5
```

完整网络 wrapper：

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

旧 MMIO 基线：

```bash
python3 dma/benchmark/benchmark_mmio.py --warmup 1 --iterations 5
```

详见 [PYNQ 上板、远程操作和测试命令](07_PYNQ_BRINGUP_AND_TEST.md)。

## 4. PC 侧检查

协议和 job 构造测试：

```powershell
C:\Users\JiabingYu\AppData\Local\Programs\Python\Python311\python.exe `
  -m unittest discover -s dma\tests -p "test_*.py" -v
```

已通过：

```text
Ran 9 tests in 0.332s
OK
```

Python 语法检查：

```powershell
C:\Users\JiabingYu\AppData\Local\Programs\Python\Python311\python.exe `
  -m py_compile `
  dma\pynq\apu_dma_driver.py `
  dma\pynq\dma_job.py `
  dma\pynq\dma_network_job.py `
  dma\pynq\test_apu_dma_smoke.py `
  dma\pynq\inference_dma.py `
  dma\benchmark\benchmark_apu_dma_transport.py
```

## 5. 当前未完成项

- 25 MHz bit 下真实 loader 未达到 `wall_mbps_mean >= 200`；
- CPU 尚未低于 10%；
- 完整网络同输入重复输出不稳定；
- 旧 MMIO 基线完整 JSON 尚未跑完。
