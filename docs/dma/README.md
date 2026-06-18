# APU DMA Documentation

`docs/dma/` 是最终 DMA 支线的文档入口。当前只维护真实 `apu_dma.bit/.hwh` 路线，不再维护独立 DMA loopback overlay。

旧版 `apuYjb/myDesign.bit/.hwh` 只作为 AXI-Lite/AHB MMIO 基线，用于和 DMA 方案对比。

## Read First

| 目标 | 文档 |
| --- | --- |
| 系统学习 DMA 支线设计 | [design/README.md](design/README.md) |
| 分清 job/packet/header/payload 等概念 | [design/00_TERMS_JOB_PACKET_HEADER.md](design/00_TERMS_JOB_PACKET_HEADER.md) |
| 从硬件和软件两边理解 DMA 支线 | [design/00A_HARDWARE_SOFTWARE_CO_VIEW.md](design/00A_HARDWARE_SOFTWARE_CO_VIEW.md) |
| 从 AHB/MMIO 过渡理解 AXI/DMA | [design/01_AXI_DMA_FOUNDATION.md](design/01_AXI_DMA_FOUNDATION.md) |
| 看完整 job 数据流 | [design/02_SYSTEM_DATA_FLOW.md](design/02_SYSTEM_DATA_FLOW.md) |
| 学习 DMA RTL 结构 | [design/03_RTL_ARCHITECTURE.md](design/03_RTL_ARCHITECTURE.md) |
| 学习 Vivado Block Design | [design/04_BLOCK_DESIGN.md](design/04_BLOCK_DESIGN.md) |
| 查看硬件框图和模块归属 | [design/06_HARDWARE_BLOCK_DIAGRAM.md](design/06_HARDWARE_BLOCK_DIAGRAM.md) |
| 了解当前 DMA 支线状态 | [00_CURRENT_STATE_AND_WORK_PLAN.md](00_CURRENT_STATE_AND_WORK_PLAN.md) |
| 看文件入口和操作路径 | [01_IMPLEMENTATION_FILE_AND_FLOW_GUIDE.md](01_IMPLEMENTATION_FILE_AND_FLOW_GUIDE.md) |
| 理解旧 MMIO/AHB 基线 | [02_STAGE_A_BASELINE.md](02_STAGE_A_BASELINE.md) |
| 理解 AXI-Stream packet 格式 | [04_STREAM_PACKET_PROTOCOL.md](04_STREAM_PACKET_PROTOCOL.md) |
| 审查 DMA RTL wrapper | [05_RTL_IMPLEMENTATION_REVIEW.md](05_RTL_IMPLEMENTATION_REVIEW.md) |
| 用 Vivado 生成 bit/hwh | [06_VIVADO_GUI_BUILD_AND_EXPORT.md](06_VIVADO_GUI_BUILD_AND_EXPORT.md) |
| 在 PYNQ 上运行和导出报告 | [07_PYNQ_BRINGUP_AND_TEST.md](07_PYNQ_BRINGUP_AND_TEST.md) |
| 判断性能指标 | [08_PERFORMANCE_ACCEPTANCE.md](08_PERFORMANCE_ACCEPTANCE.md) |
| 理解完整网络 DMA job | [09_FULL_NETWORK_DMA_JOB.md](09_FULL_NETWORK_DMA_JOB.md) |
| 查看板上结果汇总 | [10_BOARD_RUN_SUMMARY.md](10_BOARD_RUN_SUMMARY.md) |
| 跑最终六个测试 | [11_FINAL_SIX_TESTS.md](11_FINAL_SIX_TESTS.md) |
| 查看软件 golden 和 InBuf 修复记录 | [sw/README.md](sw/README.md) |

## Final Commands

板上目录：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma
```

旧 MMIO/AHB 基线：

```bash
python3 dma/final_tests/01_mydesign_benchmark.py --warmup 1 --iterations 5
python3 dma/final_tests/02_mydesign_inference.py
python3 dma/final_tests/03_mydesign_evaluate.py --samples 100
```

DMA 扩展：

```bash
python3 dma/final_tests/04_apu_dma_benchmark.py --clock-mhz 50 --repeats 256 --warmup 1 --iterations 5
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/final_tests/06_apu_dma_evaluate.py --samples 100
```

## Acceptance Focus

- 传输带宽 `>= 200 MB/s`：主要看 04 的 `wall_mbps_mean`。
- CPU `<10%`：主要看 04 的 `cpu_percent_mean`，并确认 `wait_mode` 是 `interrupt`。
- 功能正确性：看 02 vs 05、03 vs 06，并结合 `dma/sw/` 下的 golden 对齐脚本。
- 06 的应用级吞吐低于 04 是正常现象，不能用 06 替代纯 DMA transport 验收。

## Build Notes

Vivado 真实流程是先封装 APU DMA IP，再用 Tcl 创建 BD、综合实现并导出 bit/hwh。

频率由环境变量控制：

```powershell
$env:APU_DMA_PL_FREQ_MHZ = "50"
```

修改 RTL 或 Vivado Tcl 后需要重新生成 `dma/overlay/apu_dma.bit` 和 `dma/overlay/apu_dma.hwh`。只修改 Python driver、benchmark、final tests 或文档，不需要重新综合。
