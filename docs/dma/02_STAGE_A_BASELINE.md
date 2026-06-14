# 阶段 A：旧 MMIO 基线冻结与测量

## 1. 阶段目标

阶段 A 不修改 `APU_0`、旧驱动或旧 Overlay，只建立后续 DMA A/B 对比的固定基线：

- 固定 bit、HWH、驱动、checkpoint 和参数文件校验值；
- 测量旧 GP0/AHB RAM window 的 PS->PL、PL->PS 吞吐和 CPU 占用率；
- 测量旧完整推理的延迟、CPU占用率、Top-1/Top-5和固定样本APU输出哈希；
- 原始结果保存为 CSV/JSON，不依赖终端截图。

## 2. 已新增文件

| 文件 | 用途 | 运行位置 |
|---|---|---|
| `dma/benchmark/snapshot_baseline.py` | 生成资产SHA-256清单 | PC或PYNQ |
| `dma/benchmark/benchmark_mmio.py` | 测量旧RAM window双向传输 | PYNQ |
| `dma/benchmark/benchmark_mmio_e2e.py` | 测量旧完整推理 | PYNQ |
| `dma/reports/raw/baseline_asset_manifest.json` | 当前基线资产清单 | 脚本生成 |

## 3. PC上先冻结资产

在项目根目录运行：

```bash
python3 dma/benchmark/snapshot_baseline.py
```

该脚本记录：

- Git commit和工作区状态；
- `myDesign.bit/.hwh/.tcl`；
- `apu_driver.py`和`resnet_binary_ps.py`；
- checkpoint；
- `apuYjb/param/`内每个参数文件。

如果之后替换任一资产，应重新生成manifest，并把新旧manifest同时保留在实验记录中。

## 4. PYNQ部署

推荐将整个仓库保持相对目录复制到板卡，例如：

```text
/home/xilinx/APU/
  apuYjb/
  dma/
```

运行前检查：

```bash
cd /home/xilinx/APU
python3 -c "import pynq,numpy,torch,torchvision; print('dependencies ok')"
python3 dma/benchmark/snapshot_baseline.py
```

## 5. 测量旧MMIO传输

```bash
cd /home/xilinx/APU
python3 dma/benchmark/benchmark_mmio.py \
  --warmup 5 \
  --iterations 50 \
  --sizes 256,1024,4096,8192
```

脚本执行：

1. 加载旧 `myDesign.bit`；
2. 选择 `RAM_SEL=128` 的输入特征RAM；
3. 写入确定性测试模式；
4. dummy read后逐字读回并校验；
5. 分别记录PS->PL和PL->PS带宽、墙钟时间与进程CPU时间。

输出：

```text
dma/reports/raw/mmio_transfer_samples.csv
dma/reports/raw/mmio_transfer_summary.json
```

这里测得的是旧RAM window软件可见吞吐，不是AXI总线理论峰值。

## 6. 测量旧完整推理

先用10张样本做快速基线：

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

第一张样本的APU raw输出会计算SHA-256。DMA版本必须对同一样本生成相同哈希，除非已通过
逐字证据确认旧驱动存在数据排布bug，并在报告中明确区分“兼容模式”和“修正模式”。

## 7. 通过条件

阶段 A 的代码准备已完成，但板上测量需要真实 PYNQ-Z2。阶段通过必须同时具备：

- `baseline_asset_manifest.json`；
- `mmio_transfer_samples.csv`与summary；
- `mmio_e2e_samples.csv`与summary；
- 至少一个固定样本的raw APU输出哈希；
- 测试命令、板卡PYNQ版本和异常记录。

在板上原始数据返回前，阶段 A 状态为“代码完成，实测待执行”，不能填写虚构性能数字。

