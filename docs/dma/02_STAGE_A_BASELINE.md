# 阶段 A：旧 MMIO 基线

本页只记录旧 `apuYjb/myDesign.bit/.hwh` 的 AXI-Lite/AHB MMIO 基线。它用于和
`dma/overlay/apu_dma.bit/.hwh` 做 A/B 对比，不属于新的 DMA overlay。

## 1. 当前状态

已确认旧 baseline 文件在板上存在：

```text
apuYjb/myDesign.bit
SHA256 6DC85F3FE828147FA9ABF2E45C822A1CEE0F81A7F35CA4CD6F654BA7AE93A323

apuYjb/myDesign.hwh
SHA256 597925900453597BE79ACFD59C9F56E35CDD8E45A845583C3839320B142A3799
```

`dma/benchmark/benchmark_mmio.py` 已上传到板上。默认长测曾被中断，因此当前还没有可信的
`dma/reports/raw/mmio_transfer_summary.json`。先跑短测，确认旧路径可用后再扩大迭代数。

## 2. 相关文件

| 文件 | 用途 | 运行位置 |
|---|---|---|
| `dma/benchmark/snapshot_baseline.py` | 生成资产 SHA-256 清单 | PC 或 PYNQ |
| `dma/benchmark/benchmark_mmio.py` | 测量旧 RAM window 双向传输 | PYNQ |
| `dma/benchmark/benchmark_mmio_e2e.py` | 测量旧完整推理 | PYNQ |
| `dma/reports/raw/baseline_asset_manifest.json` | 当前基线资产清单 | 脚本生成 |

## 3. 板上运行

当前板上工程目录：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
```

先跑短测：

```bash
python3 dma/benchmark/benchmark_mmio.py --warmup 1 --iterations 5
```

短测通过后再跑较长版本：

```bash
python3 dma/benchmark/benchmark_mmio.py \
  --warmup 5 \
  --iterations 50 \
  --sizes 256,1024,4096,8192
```

输出：

```text
dma/reports/raw/mmio_transfer_samples.csv
dma/reports/raw/mmio_transfer_summary.json
```

这里测得的是旧 RAM window 的软件可见吞吐，不是 AXI 总线理论峰值。

## 4. 完整推理基线

先用少量样本：

```bash
python3 dma/benchmark/benchmark_mmio_e2e.py \
  --start-index 0 \
  --samples 10 \
  --warmup 1
```

确认无卡死后再扩大样本：

```bash
python3 dma/benchmark/benchmark_mmio_e2e.py \
  --start-index 0 \
  --samples 1000 \
  --warmup 2
```

输出：

```text
dma/reports/raw/mmio_e2e_samples.csv
dma/reports/raw/mmio_e2e_summary.json
dma/reports/raw/mmio_debug/sample_00000_*.txt
```

DMA 完整网络版本最终必须和旧 MMIO 基线对齐同一样本的 raw APU 输出哈希；当前 DMA
完整网络重复运行还不稳定，不能作为 bit-exact 通过证据。

## 5. 通过条件

旧 MMIO 基线通过必须同时具备：

- `baseline_asset_manifest.json`；
- `mmio_transfer_samples.csv` 与 summary；
- `mmio_e2e_samples.csv` 与 summary；
- 至少一个固定样本的 raw APU 输出哈希；
- 测试命令、板卡 PYNQ 版本和异常记录。

