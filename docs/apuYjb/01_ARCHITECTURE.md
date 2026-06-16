# 系统架构与职责划分

## 1. 方案定位

`apuYjb` 不是“整个 ResNet 都在 FPGA 中运行”，而是混合推理：

```text
CIFAR-10 图像
  -> ARM/PyTorch: conv1 + bn1 + Hardtanh + 二值化
  -> PL/APU: layer1、layer2、layer3，共 12 条硬件指令
  -> ARM/PyTorch: 8x8 AvgPool + FC + BN + LogSoftmax
  -> Top-1 / Top-5
```

ARM 负责文件系统、模型加载、图像预处理、参数搬运、启动 APU、读取结果和最终分类。
PL 中的 APU 只负责网络中间的二值卷积与残差计算。

## 2. 硬件控制路径

`myDesign.tcl` 描述的 Block Design 为：

```text
Zynq-7000 Processing System
  M_AXI_GP0
    -> SmartConnect
    -> AXI4-to-AHB-Lite Bridge
    -> APU_0
```

PS 输出 `FCLK_CLK0=100 MHz`，同时驱动 SmartConnect、bridge 和 APU。`proc_sys_reset`
根据 PS 的复位产生低有效外设复位，连接 bridge 和 `APU_0.nRst`。

## 3. 软件调用层次

```text
inference_ps.py / evaluate_cifar10_ps.py
  -> resnet_binary_ps.py
       -> ARM 前处理
       -> apu_driver.APUDriver.execute_apu_network()
            -> PYNQ Overlay 下载 myDesign.bit
            -> 根据 myDesign.hwh 找到 APU_0 基址
            -> MMIO 写参数、指令和输入
            -> 拉高 APU_READY，轮询 CPL
            -> MMIO 读最终特征图
       -> ARM 后处理与分类
```

`apu_driver_full.py` 继承基础驱动，但当前入口没有导入它。不能因为文件存在，就认为运行时
已经具备其 timeout 和 `CPL` 清零检查。

## 4. 张量边界

| 边界 | Shape | 数值语义 | 执行端 |
|---|---:|---|---|
| 原始输入 | `1x3x32x32` | 归一化 float | ARM |
| APU 输入 | `1x64x32x32` | 0/1，`0 -> +1`，`1 -> -1` | ARM 写 PL |
| APU 输出 | `1x256x8x8` | 0/1 | PL 写，ARM 读 |
| FC 输入 | `1x256` | APU bit 转回 -1/+1 后全局平均 | ARM |
| 分类输出 | `1x10` | LogSoftmax | ARM |

对应代码中，APU 输入为 65536 bit，即 2048 个 32-bit MMIO word；APU 输出为 16384 bit，
即 512 个 32-bit word。

## 5. 模型参数的两种来源

系统同时依赖两套不同形式的参数：

1. `model_best.pth.tar`：由 PyTorch 加载，主要给 ARM 前端 `conv1/bn1` 和后端 `fc/bn3`。
2. `param/*.txt`：驱动逐层写入 APU 的 weight RAM 和 BN RAM。

这两套文件必须来自同一个训练/导出版本。仅替换 checkpoint 或仅替换硬件参数，都可能让
程序正常完成但准确率显著降低。

## 6. 为什么不能关闭 ARM

该方案的以下动作全部由 ARM 完成：

- 运行 Python 和 PyTorch；
- 下载 Overlay、解析 HWH、建立 MMIO；
- 从 SD 卡读取权重和数据集；
- 每张图重新搬运硬件参数并轮询 APU；
- 执行模型首层、池化、全连接和分类统计。

因此 ARM 一旦 reset 或 clock-stop，推理链会中断。若验收条件是 ARM 完全禁用，应切换到
[`docs/archive/fpga/`](../archive/fpga/README.md) 描述的纯 PL 探索方案，而不是修改本方案的启动步骤。
