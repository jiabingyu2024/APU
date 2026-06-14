# 完整网络DMA Job迁移

## 1. 已实现内容

`dma/pynq/dma_network_job.py`按旧`apu_driver_full.py`的参数顺序构造完整12层网络：

```text
LOAD input
LOAD layer1+layer2 parameters -> RUN 8 instructions
LOAD layer3.0 conv1          -> RUN 1
LOAD layer3.0 residual       -> RUN 1
LOAD layer3.1 conv1          -> RUN 1
LOAD layer3.1 conv2          -> RUN 1
READ ACT 256x64-bit
END_JOB
```

使用当前`apuYjb/param`离线构建结果：

```text
input job bytes: 386528
packet count: 781
maximum response bytes: 2112
```

离线测试已确认RUN指令数为`[8,1,1,1,1]`、最终读取ACT 256个64-bit word，且job能被
协议解析器完整解码。

## 2. 与旧AHB布局的等价关系

旧`ram_mux.sv`把相邻两个32-bit写组合为：

```systemverilog
{second_word, first_word}
```

新构包器将同一对`uint32`按little-endian直接视为一个`uint64`，因此RAM中的64-bit值不变。
weight地址从旧byte地址转换为64-bit原生word地址；BN和instruction仍使用32-bit原生word
地址。旧驱动故意保留的BN地址空洞也被保留，只合并真正连续的区域。

## 3. 输入与输出bit顺序

- 输入仍按NCHW转NHWC后，以通道为最快维；
- 每组bit按RAM word的bit0到bit63排列；
- 输出ACT的256个64-bit word按同样顺序解包为`1x256x8x8` NCHW；
- 未改变量化、符号或阈值语义。

## 4. 板上使用

Python脚本中：

```python
from dma.pynq.inference_dma import ApuDmaNetwork

with ApuDmaNetwork(
    "dma/overlay/apu_dma.bit",
    "apuYjb/param",
) as apu:
    output = apu.execute(input_tensor_01)
```

在Jupyter已有event loop时使用：

```python
output = await apu.execute_async(input_tensor_01)
```

初始化时参数只解析并写入CMA job模板一次；每张图仅原位覆盖模板中的1024个输入
`uint64` word，然后提交同一聚合job。

## 5. 尚未完成的验收

当前仅证明软件布局可构建和解析，尚未证明硬件结果正确。bitstream生成后必须依次比较：

1. DMA结果与旧`apu_driver_full.py`的512个`uint32`输出逐字一致；
2. 关键阶段中间ACT结果一致；
3. 完整CIFAR-10 Top-1/Top-5不低于旧MMIO基线；
4. 连续1000张图无timeout、DMA error或packet错位。

