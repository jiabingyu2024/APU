# 目录资产说明

## 1. 顶层文件

| 文件 | 用途 | 当前是否直接使用 |
|---|---|---|
| `inference_ps.py` | 单张 JPEG 推理入口 | 是 |
| `evaluate_cifar10_ps.py` | CIFAR-10 测试集 Top-1/Top-5 评估 | 是 |
| `resnet_binary_ps.py` | PS 前后处理和 APU 调用封装 | 是 |
| `apu_driver.py` | 当前真实 PYNQ MMIO 驱动 | 是 |
| `apu_driver_full.py` | 增强驱动，增加 timeout 和 `CPL` 状态检查 | 否，未接入入口 |
| `myDesign.bit` | 配置 PL 的 Overlay bitstream | 是 |
| `myDesign.hwh` | PYNQ Overlay 的 IP、地址和时钟元数据 | 是 |
| `myDesign.tcl` | 旧 Vivado Block Design 重建脚本 | 参考/重建 |
| `model_best.pth.tar` | PyTorch checkpoint | 是 |

当前目录没有 `apu_driver_mock.py`。所以把入口脚本中的 `RUN_ON_PC_FOR_DEBUG=True` 后，
会在构造模型时因缺少 mock driver 失败；该模式不是开箱可用的 PC 仿真环境。

## 2. 参数目录 `param/`

目录包含 39 个文本文件，主要分为：

| 类型 | 代表文件 | 用途 |
|---|---|---|
| 普通卷积权重 | `layer1.0.conv1.txt` | 写 weight RAM |
| 残差组合权重 | `layer2.0.conv2_combined.txt` | resident/residual 指令使用 |
| 合并 BN 参数 | `layer3.1.bn3_combined.txt` | 写 BN RAM，每通道一个 32-bit word |
| 早期/附加导出物 | `conv1.txt`、`convavgpool.txt` 等 | 当前硬件执行流程未全部引用 |

当前 `apu_driver.py` 实际引用 24 个 layer 参数文件。不要按文件名猜测并删除其余文件，
它们可能属于模型导出、历史验证或其他运行路径。

参数文本每个 token 是二进制字符串，驱动通过 `int(token, 2)` 转为无符号整数，再写成
`uint32`。文件不是普通浮点权重，不能用文本浮点解析器读取。

## 3. Golden 目录 `data_flow/`

目录包含 37 个中间层输出，覆盖 `conv`、`bn`、`tanh` 和 residual combine 等节点。用途是：

- 确认错误从哪一层首次出现；
- 区分参数装载、卷积计算、BN/阈值和通道排布问题；
- 对比仿真输出与板上 debug dump。

文件内容以每行 32 bit 二进制为主。部分 layer3 combine 文件长度/格式并不完全规则，比较前
应先确认该文件代表的是原始 SRAM word、逻辑 tensor，还是调试脚本生成的文本流。

## 4. 数据集与图片

| 路径 | 用途 |
|---|---|
| `CIFAR10/test_batch` | CIFAR-10 测试集 |
| `CIFAR10/data_batch_1..5` | 训练集，本评估脚本不使用 |
| `CIFAR10/batches.meta` | 类别元数据 |
| `image/cifar10_test_image.jpg` | 单图推理样例 |

`evaluate_cifar10_ps.py` 设置了 `download=True`。当数据完整时 torchvision 通常直接复用；
若文件不完整，板卡需要联网下载，否则会报错。

## 5. 必须成套保存的文件

以下资产不能随意交叉搭配：

```text
myDesign.bit + myDesign.hwh       同一次 Vivado 构建
model_best.pth.tar + param/       同一次模型训练/硬件导出
param/ + data_flow/               同一套 bit-exact 参考
apu_driver.py + APU RTL/IP        同一寄存器、SRAM 和通道排布合同
```

旧 bundle 当前关键校验值：

```text
myDesign.bit       6dc85f3fe828147fa9abf2e45c822a1cee0f81a7f35ca4cd6f654ba7ae93a323
myDesign.hwh       888723049ca15d93316900179c4a8186383818744e9f763a3bac5c863ec50427
model_best.pth.tar 008a6afb2b7633f8df5e65fc45feefc6811ca79ff41a5090e393830f69314b8e
```

替换任一文件后应重新记录 checksum，避免“bit 已更新但 HWH/参数仍是旧版”的隐性混用。
