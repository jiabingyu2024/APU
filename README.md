# APU Binary Neural Network Accelerator

本项目实现并验证了一个面向 CIFAR-10 二值 ResNet 中间卷积层的 APU。基础计算核心位于 `rtl/`，原始 PYNQ MMIO/AHB 上板验证位于 `apuYjb/`，最终完成的 AXI-Stream + AXI-DMA 扩展位于 `dma/`。

当前最终交付路线是 `dma` 支线。`soc/`、`fpga/`、`third_party/` 保留为历史探索和复查材料，但不再作为最终验收路径。

## Project Layout

```text
APU/
|-- rtl/                 基础 APU ASIC RTL
|-- tb/                  基础 RTL 仿真 testbench
|-- data/                参数、输入和 golden data flow
|-- apuYjb/              旧版 PYNQ MMIO/AHB 上板验证基线
|-- dma/                 最终 DMA 扩展支线
|   |-- rtl/             APU DMA wrapper、AXIS loader/streamer、寄存器
|   |-- vivado/          IP 封装、BD 创建、bit/hwh 导出的 Tcl
|   |-- pynq/            PYNQ driver、job 构造、smoke/inference 支撑
|   |-- final_tests/     最终六个汇报测试脚本
|   |-- overlay/         当前 apu_dma.bit / apu_dma.hwh
|   `-- reports/         板上测试导出的 JSON/CSV 结果
|-- docs/                设计说明、上板指南、测试报告和归档
|-- soc/                 已弃用的 PicoRV32 + APU SoC 尝试源码，保留不删
|-- fpga/                已弃用的早期 FPGA/PL-only 尝试源码，保留不删
|-- third_party/         SoC 探索依赖的第三方代码，保留不删
`-- build/               自动生成目录，不作为源码交付
```

## Current Reading Path

建议按下面顺序阅读：

1. [docs/README.md](docs/README.md)：完整文档索引。
2. [docs/design/final/README.md](docs/design/final/README.md)：基础 APU RTL 设计基线。
3. [docs/apuYjb/README.md](docs/apuYjb/README.md)：旧版 PYNQ MMIO/AHB 基线。
4. [docs/dma/README.md](docs/dma/README.md)：最终 DMA 支线入口。
5. [docs/dma/11_FINAL_SIX_TESTS.md](docs/dma/11_FINAL_SIX_TESTS.md)：六个最终测试脚本。
6. [docs/dma/08_PERFORMANCE_ACCEPTANCE.md](docs/dma/08_PERFORMANCE_ACCEPTANCE.md)：性能验收口径。

历史探索文档已经归档到 `docs/archive/`，其中 `docs/archive/soc/`、`docs/archive/fpga/`、`docs/archive/explore/` 只用于复查，不作为当前运行指南。

## Basic RTL Simulation

基础 APU RTL 的本地仿真入口仍然保留：

```bash
make
make run
CCACHE_DISABLE=1 make check
```

`make check` 会运行标准回归，并调用 `scripts/compare_outputs.py` 与 `data/data_flow/` 中的 golden 输出逐 bit 对比。修改 `rtl/`、`tb/` 或基础数据布局后，应先跑这一组回归。

## PYNQ MMIO Baseline

`apuYjb/` 是旧版 `myDesign.bit/.hwh` 的 PYNQ MMIO/AHB 验证路线。它用于证明基础 APU 能在板上运行，也用于和 DMA 支线做性能对比。

最终汇报中对应的三个基线测试位于：

```bash
python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 100
```

## Final DMA Tests

DMA 支线使用 `dma/overlay/apu_dma.bit` 和 `dma/overlay/apu_dma.hwh`。最终汇报中的 DMA 三个测试为：

```bash
python3 dma/final_tests/04_apu_dma_benchmark.py --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

性能验收主要看测试 4：

- `wall_mbps_mean` / `hardware_mbps_mean` 用于判断 DMA 传输带宽。
- CPU 占用率应以 DMA 传输 benchmark 和中断等待口径为主。
- 测试 6 是应用级端到端评估，会包含 Python 数据集、预处理、循环调度和结果解析，吞吐低于测试 4 是正常现象。

## Vivado DMA Build

DMA overlay 的真实构建流程是：

1. 先把 APU DMA RTL 封装为 IP。
2. 再通过 Tcl 创建 block design。
3. 综合、实现、生成 bitstream。
4. 导出 `apu_dma.bit` 和 `apu_dma.hwh` 到 `dma/overlay/`。

PL 频率通过一个参数控制：

```powershell
$env:APU_DMA_PL_FREQ_MHZ = "50"
```

具体步骤见 [docs/dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md](docs/dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md)。修改 RTL 或 Vivado Tcl 后需要重新综合/实现；只修改 Python driver、benchmark 或文档不需要重新综合。

## Deprecated Branches

以下内容保留但不作为最终验收路线：

- `soc/`：PicoRV32 + APU 的 PL-only SoC 尝试，已弃用。
- `fpga/`：早期 FPGA/PL-only 上板尝试，已弃用。
- `third_party/picorv32/`：SoC 探索依赖。
- `docs/archive/soc/`、`docs/archive/fpga/`、`docs/archive/explore/`：对应历史文档归档。

不要按这些支线重新验收当前项目；最终运行和报告以 `dma/final_tests/` 与 `docs/dma/` 为准。
