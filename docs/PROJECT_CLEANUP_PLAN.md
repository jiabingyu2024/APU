# APU 项目整理计划

本文只规划整理动作，不直接删除或迁移源码。当前项目已经形成一个基础 APU ASIC 实现和两条上板/扩展支线：`apuYjb` 是已验证的原始 PYNQ MMIO/AHB 路线，`dma` 是最终完成的 AXI-Stream + AXI-DMA 路线，`soc`/`fpga`/`third_party` 是曾经尝试但当前不作为最终交付路线的保留内容。

## 1. 整理目标

1. 让首次阅读项目的人能快速判断“最终该看什么、跑什么、不要跑什么”。
2. 保留失败探索的工程价值，但明确标注 `soc` 支线已弃用，避免误用。
3. 把 DMA 支线收敛为最终汇报入口，突出六个最终测试、Vivado 生成流程、PYNQ 运行命令和性能报告。
4. 不删除 `soc`、`fpga`、`third_party`，只通过文档、归档标识和 README 降低干扰。
5. 清理明显过时、重复、无真实产物支撑的脚本和文档；执行清理前先列清单确认。
6. 统一文档编码、路径命名和入口说明，避免 Windows/Vivado 长路径和中文编码问题继续干扰。

## 2. 当前项目定位

| 路径 | 定位 | 后续处理原则 |
| --- | --- | --- |
| `rtl/` | 基础 APU ASIC RTL，实现卷积、BN/激活、residual、AHB/MMIO 访问等核心功能 | 作为底层设计基线保留，文档说明它被 `apuYjb` 与 `dma` 复用 |
| `tb/` | 基础 APU 仿真入口和关键回归 testbench | 保留，补充与 `rtl/` 的对应关系 |
| `data/` | APU 参数、输入和 golden data flow | 保留，标注为基础 RTL 与软件 golden 的数据源 |
| `apuYjb/` | 原始 PYNQ 上板验证路线，使用 `myDesign.bit/.hwh` 和 Python MMIO 驱动 | 保留为旧版 MMIO/AHB 基线，用于 DMA 对比 |
| `dma/` | 最终完成路线，包含 DMA RTL wrapper、Vivado Tcl、PYNQ driver、benchmark、final tests、reports | 作为最终交付主线重点整理 |
| `docs/dma/` | DMA 支线设计、构建、上板、测试和报告文档 | 重点更新为最终可读文档 |
| `soc/` | PicoRV32 + APU 的 SoC 尝试，当前决定弃用 | 不删除，移动文档定位为“弃用探索记录” |
| `fpga/` | 早期 PL-only/PYNQ-Z2 尝试和脚本 | 不删除，标注非最终路线 |
| `third_party/` | PicoRV32 上游代码 | 不删除，标注仅为 SoC 探索依赖 |
| `docs/archive/soc/`、`docs/archive/fpga/`、`docs/archive/explore/` | SoC/FPGA 探索文档 | 已移动到探索归档，不作为当前主线 |
| `build/`、Vivado 临时输出 | 自动生成产物 | 不作为源码交付，加入清理/忽略说明 |

## 3. 建议的最终阅读入口

整理完成后，建议把顶层入口压缩为以下路径：

1. `README.md`：只讲项目总览、最终路线、快速运行入口。
2. `docs/README.md`：文档导航，明确当前有效文档与归档文档。
3. `docs/design/final/README.md`：基础 APU ASIC 的最终 RTL 设计说明。
4. `docs/apuYjb/README.md`：旧版 PYNQ MMIO/AHB 基线说明。
5. `docs/dma/README.md`：DMA 最终支线文档入口。
6. `docs/dma/11_FINAL_SIX_TESTS.md`：最终六个测试脚本和汇报口径。
7. `docs/dma/07_PYNQ_BRINGUP_AND_TEST.md`：PYNQ 连接、上传、运行、导出报告命令。
8. `docs/dma/08_PERFORMANCE_ACCEPTANCE.md`：性能指标解释，说明带宽和 CPU 占用率以测试 4 为验收主口径。

## 4. 第一阶段：文档入口修正

优先处理文档可读性，不动设计源码。

1. 重写顶层 `README.md`，删除或弱化已弃用 SoC 主流程，突出当前项目三层结构：
   - 基础 APU ASIC：`rtl/`、`tb/`、`data/`
   - 旧版 MMIO 上板基线：`apuYjb/`
   - 最终 DMA 扩展：`dma/`
2. 重写 `docs/README.md`，修复当前乱码问题，按“最终主线 / 基线 / 归档探索 / 历史问题”组织。
3. 在 `docs/archive/soc/README.md` 和 `docs/archive/fpga/README.md` 顶部增加醒目标记：
   - 当前不作为最终交付路线
   - 保留原因是探索记录和可复查证据
   - 不建议按这些文档重新验收项目
4. 检查所有 Markdown 编码，统一为 UTF-8。
5. 所有文档中的命令路径尽量使用短路径写法，避免 Vivado 工程路径过长。

## 5. 第二阶段：DMA 最终支线收敛

DMA 是最终完成支线，需要把文档和脚本入口收敛成稳定交付形态。

1. 更新 `dma/README.md`：
   - 说明 `dma/rtl`、`dma/vivado`、`dma/pynq`、`dma/final_tests`、`dma/reports` 分别是什么。
   - 明确 `dma/overlay/apu_dma.bit` 和 `apu_dma.hwh` 是当前上板 overlay。
   - 明确旧版 `myDesign.bit/.hwh` 不属于 `dma/overlay`，只作为 MMIO 对比基线。
2. 更新 `dma/final_tests/README.md`：
   - 只保留六个最终脚本。
   - 每个脚本写清楚使用哪个 bit/hwh、跑什么输入、输出哪个报告文件。
   - 写清楚测试 4 是 DMA 传输带宽和 CPU 占用率验收主口径，测试 6 是应用级端到端口径。
3. 更新 `docs/dma/11_FINAL_SIX_TESTS.md`：
   - 固化六个命令：
     - `01_mydesign_benchmark.py`
     - `02_mydesign_inference.py`
     - `03_mydesign_evaluate.py`
     - `04_apu_dma_benchmark.py`
     - `05_apu_dma_inference.py`
     - `06_apu_dma_evaluate.py`
   - 固化报告输出位置和字段解释。
4. 更新 `docs/dma/08_PERFORMANCE_ACCEPTANCE.md`：
   - 区分 `hardware_mbps_mean`、`wall_mbps_mean`、应用端到端吞吐。
   - 说明 CPU 占用率应优先看 DMA wait/benchmark 口径，避免把 Python 数据集加载、CMA 分配、推理后处理计入硬件 DMA 传输验收。
5. 更新 `docs/dma/06_VIVADO_GUI_BUILD_AND_EXPORT.md`：
   - 保留 APU 先封装为 IP，再由 Tcl 创建 BD 的真实流程。
   - 写清楚 `APU_DMA_PL_FREQ_MHZ` 一个参数控制 PL 频率。
   - 写清楚修改 RTL 或 Vivado Tcl 后需要重新综合/实现/导出 bit/hwh，单纯 Python driver 修改不需要重新综合。
6. 更新 `docs/dma/07_PYNQ_BRINGUP_AND_TEST.md`：
   - 固化 Jupyter HTTP 方式操纵 PYNQ 的方法。
   - 固化 MobaXterm/SSH 手动方式。
   - 固化上传代码、运行六个测试、打包导出 `dma/reports` 的命令。

## 6. 第三阶段：弃用支线降噪

不删除 `soc`、`fpga`、`third_party`，但让它们不再干扰最终交付。

1. 给 `soc/README.md` 或新增 `soc/STATUS.md`：
   - 标注“已弃用，不作为最终验收路线”。
   - 说明失败原因只保留概要，详细证据跳转到 `docs/archive/soc/`。
2. 给 `fpga/README.md` 或新增 `fpga/STATUS.md`：
   - 标注早期 FPGA/PL-only 尝试，不是最终 DMA overlay 构建入口。
3. 在 `third_party/README` 或顶层文档中说明：
   - `third_party/picorv32` 仅为 SoC 探索依赖。
   - 当前 DMA 最终路线不依赖重新阅读或运行 PicoRV32。
4. `docs/archive/explore/`、`docs/archive/soc/`、`docs/archive/fpga/` 在导航中统一归为“探索归档”，不要放在推荐阅读主线。

## 7. 第四阶段：脚本和产物清理清单

这一阶段需要先列清单，再确认是否删除。原则是：能证明当前最终结果的保留，过时且容易误导的删除或归档。

建议检查以下类别：

1. DMA loopback 相关脚本和文档：
   - 如果没有对应真实 bit/hwh，不再作为可运行入口。
   - 文档中只保留一句历史说明，不保留命令。
2. 过时 benchmark/inference wrapper：
   - 如果功能已被 `dma/final_tests/` 覆盖，改为内部辅助或移入归档说明。
3. 板上导出的报告：
   - `dma/reports/final/` 保留最终六测 JSON 和必要 `.npy` 证据。
   - `dma/reports/raw/` 保留可复查 CSV/summary。
   - 临时 debug 文件只保留定位价值明确的样本。
4. 自动生成目录：
   - `build/`
   - Vivado `.jou`/`.log`/`.runs`/`.cache`/`.gen`
   - Python `__pycache__`
   - 这些应进入 `.gitignore` 或清理说明。

## 8. 第五阶段：最终报告材料组织

整理完成后，建议形成一套可直接用于答辩/汇报的证据链。

1. 基础 APU ASIC：
   - RTL 模块说明。
   - 仿真/bit-exact 对齐说明。
   - `apuYjb` 上板 MMIO 推理结果。
2. DMA 扩展：
   - AXI-Lite/AHB 到 AXI-Stream + AXI-DMA 的改造说明。
   - 零拷贝/预分配 buffer/interrupt wait 的软件配合说明。
   - Vivado BD 架构和频率参数说明。
3. 性能对比：
   - 测试 1 vs 测试 4：传输带宽对比。
   - 测试 2 vs 测试 5：单图推理功能对齐。
   - 测试 3 vs 测试 6：CIFAR-10 小样本评估对齐。
   - 对验收指标明确写：`>=200 MB/s` 以测试 4 的 DMA 传输 benchmark 为主，CPU `<10%` 以中断等待和复用 buffer 后的传输 benchmark 为主。
4. 已知限制：
   - 频率极限需要修改 `APU_DMA_PL_FREQ_MHZ` 后重新 Vivado 生成 bit/hwh。
   - `soc` 支线保留但弃用。
   - 应用级 evaluate 带宽低于纯传输 benchmark 是正常的，因为包含 Python 数据集、预处理、循环调度和结果解析。

## 9. 建议执行顺序

1. 先修正文档编码和顶层导航。
2. 再收敛 DMA 六个最终测试和 PYNQ 操作指南。
3. 然后给 `soc`/`fpga`/`third_party` 加弃用/探索标识。
4. 接着列出可删除脚本和文档清单，由人工确认后再删。
5. 最后根据最新板上报告更新性能验收文档和最终汇总。

## 10. 暂不执行的动作

本计划阶段暂不做以下事情：

1. 不删除 `soc`、`fpga`、`third_party`。
2. 不修改 RTL。
3. 不重新生成 Vivado 工程。
4. 不覆盖 `dma/overlay/apu_dma.bit` 或 `apu_dma.hwh`。
5. 不清空 `dma/reports`。
6. 不把历史探索文档直接删除；删除前先给清单。
