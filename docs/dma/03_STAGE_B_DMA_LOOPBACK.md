# 阶段 B：独立 AXI DMA Loopback

## 1. 为什么先不接APU

阶段 B 只验证以下链路：

```text
PS DDR -> DMA MM2S -> 64-bit AXI-Stream FIFO
       -> DMA S2MM -> PS DDR
```

这可以把 DMA、HP端口、CMA buffer、中断和性能问题与 APU packet/计算问题隔离。只有该
阶段达到带宽和CPU门槛，才进入流式APU接口开发。

## 2. 已确认的Vivado环境

本机Windows Vivado 2023.2已确认存在：

```text
Board part   tul.com.tw:pynq-z2:part0:1.0
AXI DMA      xilinx.com:ip:axi_dma:7.1
AXIS FIFO    xilinx.com:ip:axis_data_fifo:2.0
SmartConnect xilinx.com:ip:smartconnect:1.0
PS7          xilinx.com:ip:processing_system7:5.5
```

首版参数为：Simple DMA、MM2S+S2MM、64-bit memory/stream、64-beat burst、26-bit length。

## 3. Vivado工程文件

| 文件 | 作用 |
|---|---|
| `dma/vivado/query_vivado_env.tcl` | 查询board/IP和DMA属性 |
| `dma/vivado/create_loopback_project.tcl` | 创建并validate独立loopback BD |
| `dma/vivado/build_loopback_bitstream.tcl` | 综合、实现、bitstream和报告 |

Block Design：

```text
PS M_AXI_GP0 -> SmartConnect -> AXI DMA S_AXI_LITE
AXI DMA M_AXI_MM2S -> SmartConnect(AXI4/AXI3转换) -> PS S_AXI_HP0
AXI DMA M_AXI_S2MM -> SmartConnect(AXI4/AXI3转换) -> PS S_AXI_HP1
AXI DMA M_AXIS_MM2S -> AXIS FIFO -> AXI DMA S_AXIS_S2MM
MM2S/S2MM IRQ -> xlconcat -> PS IRQ_F2P
```

全部接口首版使用 `FCLK_CLK0=100 MHz`。

## 4. 在Vivado GUI执行

在Vivado Tcl Console中：

```tcl
cd /home/jiabingyu/prj/26_myprj/APU
source dma/vivado/create_loopback_project.tcl
```

如果Vivado运行在Windows且不能直接访问WSL路径，可将仓库放在Windows可访问路径，或设置：

```tcl
set ::env(APU_DMA_PROJECT_DIR) D:/APU_DMA_BUILD/loopback
source D:/path/to/APU/dma/vivado/create_loopback_project.tcl
```

脚本结束必须打印：

```text
DMA_LOOPBACK_STATUS=BD_VALIDATED
```

然后执行：

```tcl
source dma/vivado/build_loopback_bitstream.tcl
```

输出应位于：

```text
dma/overlay/loopback/apu_dma_loopback.bit
dma/overlay/loopback/apu_dma_loopback.hwh
dma/vivado/reports/loopback/
```

## 5. PYNQ板上测试

将同名bit/hwh和脚本复制到板卡后：

```bash
cd /home/xilinx/APU
python3 dma/pynq/test_dma_loopback.py \
  --warmup 3 \
  --iterations 20 \
  --sizes 4096,65536,1048576,4194304
```

脚本会：

- 使用 `pynq.allocate(dtype=np.uint64)` 分配TX/RX CMA buffer；
- 先启动S2MM，再启动MM2S；
- 默认要求两个DMA通道都具备中断支持并使用 `wait_async()`；
- 校验所有64-bit word；
- 输出带宽、CPU占用率和逐尺寸通过状态。

若中断未被HWH/PYNQ识别，脚本默认直接失败。`--allow-polling` 只能用于功能排障，其CPU
结果不能作为 `<10%` 验收证据。

## 6. 带宽口径

loopback中MM2S与S2MM同时运行。报告中的单向等效带宽定义为：

```text
size_bytes / elapsed_seconds / 1e6
```

同时保留双向总payload速率 `2*size_bytes/time`。最终200 MB/s判定使用单向等效值，避免把
读写流量相加后虚增成绩。

## 7. 通过条件

- 4 MiB测试平均单向等效带宽 `>=200 MB/s`；
- 中断等待窗口平均CPU占用率 `<10%`；
- 每个尺寸至少20次有效测量；
- 连续测试零数据错误、零DMA error、零hang；
- 保存 `dma_loopback_samples.csv` 和 `dma_loopback_summary.json`；
- Vivado post-route `WNS>=0, TNS=0`。

当前状态：工程和测试脚本已准备；Vivado 2023.2已完成BD validation并生成wrapper/HWH，
bitstream与板测结果尚未产生。

首次Vivado校验发现DMA的AXI4 memory master不能直接连接PS7的AXI3 HP端口。工程脚本已
按正确结构在MM2S和S2MM路径各加入一个SmartConnect做协议转换。
