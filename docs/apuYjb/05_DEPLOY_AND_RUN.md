# PYNQ 部署与运行

## 1. 适用环境

本流程适用于 PYNQ-Z2 启动 Linux、ARM 正常运行的模式。需要：

- PYNQ Python 库可用；
- Python 能导入 `torch`、`torchvision`、`numpy` 和 `PIL`；
- `apuYjb/` 目录完整复制到板卡；
- bit 与 HWH 同名且成对；
- 有足够的 SD 卡空间和内存运行 PyTorch。

先在板上检查：

```bash
python3 -c "import pynq, torch, torchvision, numpy, PIL; print('dependencies ok')"
```

PyTorch/torchvision 必须与板上 Python 和 ARM 架构匹配。不要直接照搬 PC 的 x86 wheel。

## 2. 文件放置

建议保持原目录结构，例如：

```text
/home/xilinx/apuYjb/
├── apu_driver.py
├── resnet_binary_ps.py
├── inference_ps.py
├── evaluate_cifar10_ps.py
├── myDesign.bit
├── myDesign.hwh
├── model_best.pth.tar
├── param/
├── data_flow/
├── CIFAR10/
└── image/
```

脚本大量使用 `./` 相对路径，必须先进入该目录再运行。仅从其他工作目录执行绝对脚本路径，
会导致 bit、模型和参数文件找不到。

## 3. 单图推理

```bash
cd /home/xilinx/apuYjb
python3 inference_ps.py
```

正常启动应依次看到：

```text
正在PYNQ上运行
初始化混合ResNet模型
加载 Overlay
找到 APU_0 并初始化 MMIO
成功加载模型权重
运行推理
预测类别索引
```

首次运行前确认脚本中：

```python
RUN_ON_PC_FOR_DEBUG = False
BITSTREAM_FILE_CONFIG = "./myDesign.bit"
AXI_APU_IP_NAME_CONFIG = "APU_0"
```

## 4. CIFAR-10 评估

```bash
cd /home/xilinx/apuYjb
python3 evaluate_cifar10_ps.py
```

评估脚本固定 `batch_size=1`，因为驱动和硬件 shape 都固定 batch 1。脚本每 100 张打印当前
Top-1、Top-5 和最近 100 张平均耗时，最终处理 10000 张测试图片。

首次排障不建议直接跑完整测试集。可临时在本地实验副本中限制样本数，先确认：

- 连续多张都能完成，不会卡在 `CPL`；
- 输出不是全零、全一或所有图片完全相同；
- 分类分布不是固定在单一类别；
- 单张 debug 输出能与 golden 对比。

## 5. Debug 文件

将入口中的 debug 开关设为 True 后，驱动可以输出：

| 文件 | 内容 |
|---|---|
| `*_packed_input*.txt` | 写入 APU 前的 32-bit 输入流 |
| `*_apu_raw.txt` | 从 SRAM 原始读出的 32-bit word |
| `*_apu_unpacked.txt` | 解包后重新按调试格式打包的输出 |

全数据集逐图保存 debug 文件会产生大量 I/O，明显拖慢评估并占满 SD 卡。只应针对少量固定
样本开启。

## 6. 常见启动错误

| 现象 | 原因与检查 |
|---|---|
| `No module named pynq` | 不在 PYNQ 环境，或 Python 环境不对 |
| `APU_0` KeyError | HWH 缺失、实例名改变、bit/HWH 不配套 |
| 模型显示成功但结果异常 | `strict=False` 可能隐藏 checkpoint key 不匹配 |
| 永久无输出 | 基础驱动卡在 `while CPL == 0`，优先检查硬件握手 |
| CIFAR 下载失败 | 数据集不完整且板卡无网络 |
| PC debug 导入失败 | 当前目录没有 `apu_driver_mock.py` |

## 7. 配置项陷阱

入口脚本构造 `model_kwargs` 时使用键 `bitstream_path`，但工厂函数读取的是
`bitstream_file`。当前默认路径都是 `./myDesign.bit`，所以通常不暴露问题；如果需要自定义
bit 路径，应同步修正键名或直接使用默认文件名，不能只改一处后假定已经生效。
