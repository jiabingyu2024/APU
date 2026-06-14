# DMA 赛道：当前状态与工作计划

## 1. 目标与边界

本路线以 `apuYjb` 的 PYNQ-Z2、PS+PL Block Design 和现有 APU 计算核心为基础，
不沿用 `soc/` 的纯 PL 自研 SoC 路线。目标是：

- 数据面由 CPU 主导的 MMIO 搬运升级为 AXI-Stream + AXI DMA；
- PS DDR 与 PL 之间使用 DMA 直接传输，软件不再逐字搬运数据；
- 建立可背压、可连续传输的流水数据通路；
- 实测有效传输带宽不低于 200 MB/s；
- DMA 传输阶段 CPU 占用率低于 10%；
- 给出可复现的 AXI-Lite 与 DMA 性能对比报告。

这里的“零拷贝”定义为：应用直接使用 `pynq.allocate` 分配的 CMA 缓冲区，AXI DMA
通过物理地址访问该缓冲区，数据提交前不再执行 `list -> bytes -> MMIO` 中间复制。
PyTorch 前处理本身是否产生张量转换，必须在报告中单独说明，不能混入 DMA 零拷贝结论。

## 2. 当前方案审查结论

### 2.1 当前硬件路径

旧 `apuYjb/myDesign.tcl` 的实际路径是：

```text
PS M_AXI_GP0
  -> SmartConnect
  -> AXI4-to-AHB-Lite Bridge
  -> APU_0
```

APU 使用 PS `FCLK_CLK0=100 MHz`。当前 BD 没有 AXI DMA，也没有启用 PS 的
`S_AXI_HP0..3` 高性能从端口。所有输入、参数、指令和输出均经过 GP0/MMIO/AHB 路径。

### 2.2 当前软件瓶颈

`apuYjb/apu_driver.py` 每张图都会：

1. 将 `1x64x32x32` 输入打包并写入 8 KiB 特征 RAM；
2. 重复写入约 338 KiB 卷积权重；
3. 写入约 7 KiB BN 参数和 12 条指令；
4. 启动并轮询 5 个计算段；
5. 逐个 32-bit word 读取约 2 KiB 最终输出。

仅主要 payload 已约 355 KiB/图，此外还有大量 `RAM_SEL`、控制寄存器写和 Python
循环开销。当前 `_ahb_read_burst_py()` 实际仍是逐字 `MMIO.read()`，并非总线 burst。
因此本路线首先解决“软件参与每一个数据字”的问题。

### 2.3 可保留与必须改变的部分

可保留：

- `rtl/` 中已经通过现有回归的卷积、BN、残差和 worksheet 计算逻辑；
- 现有指令编码、权重/BN 布局和 bit 顺序；
- PS 上的 PyTorch 前后处理和 CIFAR-10 评估框架；
- 旧 Overlay 作为 AXI-Lite/MMIO 性能基线。

必须改变：

- 数据搬运不能继续经过 `M_AXI_GP0 -> AHB`；
- 必须启用 PS `S_AXI_HP` 端口供 DMA 访问 DDR；
- PL 侧必须增加 AXI-Stream 接收、发送、背压和任务控制；
- 软件必须改用 CMA 连续缓冲区、DMA 中断和批量任务；
- 必须增加硬件周期/字节计数器，不能只用 Python 墙钟时间推断带宽。

## 3. 推荐总体架构

### 3.1 Block Design

```text
                           control/status
PS M_AXI_GP0 -----------------------------------------------+
                                                            |
                                               +------------v---------+
                                               | APU DMA AXI-Lite ctrl |
                                               +----------------------+
                                                            |
PS DDR <- S_AXI_HP0 <- AXI DMA M_AXI_MM2S                    |
                         |                                  start/status
                         v                                   |
                   M_AXIS_MM2S                               |
                         |                                   |
                +--------v-----------------------------------v---+
                | APU DMA wrapper                                |
                | job decoder -> loaders -> existing APU core    |
                |              -> result packetizer              |
                +-------------------------+-----------------------+
                                          |
                                    M_AXIS_RESULT
                                          |
PS DDR <- S_AXI_HP1 <- AXI DMA M_AXI_S2MM v

AXI DMA mm2s_introut/s2mm_introut -> xlconcat -> PS IRQ_F2P
```

建议数据宽度为 64 bit、时钟先保持 100 MHz，与 APU 当前时钟一致。理论单向上限为
800 MB/s，达到 200 MB/s 只需 25% 有效利用率，同时避免首版引入 CDC。时序通过后再评估
提高到 125/150 MHz，不把超频作为满足指标的前提。

### 3.2 接口取舍

“AXI-Lite 升级为 AXI-Stream + AXI-DMA”不等于完全删除 AXI-Lite：

- 大块输入、权重、BN、指令和输出必须走 AXI-Stream/DMA；
- 版本、状态、错误码、任务计数和性能计数器保留 AXI-Lite；
- AXI-Lite 只承担低频控制，不能再承担 tensor/weight payload。

### 3.3 推荐的 PL 模块边界

| 模块 | 职责 | 关键约束 |
|---|---|---|
| `apu_dma_top` | DMA 版本顶层和接口汇聚 | 不放具体解析/存储细节 |
| `axis_job_decoder` | 解析任务头和 payload 类型 | 必须支持 `TREADY` 背压和长度检查 |
| `apu_stream_loader` | 64-bit 流写入 feature/weight/BN/worksheet | 负责 bank、地址和 32/64-bit 拼接 |
| `apu_job_ctrl` | 分段装载、启动、等待完成、错误恢复 | 一次任务只产生一次完成事件 |
| `apu_core` | 从当前 `Top` 抽出的计算与 SRAM 主体 | 不感知 AXI 协议 |
| `axis_result_packetizer` | 读取结果 SRAM并产生 `TVALID/TLAST` | `TVALID` 在停顿期间必须保持 |
| `axi_lite_ctrl` | 版本、状态、中断、计数器 | 不承载大块数据 |
| `axis_fifo/skid` | 解耦 DMA 与 loader/packetizer | 防止组合 ready 链和数据丢失 |

为保证公平对比，推荐把现有 `Top` 拆成“协议无关的 `apu_core` + 旧 AHB wrapper + 新 DMA
wrapper”。这样 AXI-Lite 与 DMA 对比使用同一计算核心和同一参数格式。直接在当前 `Top`
外增加 AXIS-to-AHB master 可作为早期 bring-up，但 32-bit AHB 路径在 100 MHz 下余量有限，
不应作为最终 200 MB/s 架构。

## 4. 流式任务协议建议

单次 MM2S DMA 发送一个连续 job buffer，PL 根据短 header 将后续 payload 路由到目标 RAM。
建议最小 header 至少包含：

```text
magic | version | opcode | target/bank | destination address
payload_bytes | flags | sequence_id | header_crc/reserved
```

建议 opcode：

- `LOAD_INPUT`
- `LOAD_WEIGHT`
- `LOAD_BN`
- `LOAD_INSTRUCTION`
- `RUN_SEGMENT`
- `READ_RESULT`
- `END_JOB`

DMA 可以在 APU 计算期间因 `TREADY=0` 暂停，CPU 只提交一次聚合任务，不再参与每层
参数写和完成轮询。S2MM 结果包携带 `sequence_id`、状态、有效字节数和结果数据，便于检测
错帧、短帧和软件/硬件版本不匹配。

## 5. 分阶段工作计划

### 阶段 0：冻结基线与测量口径

产物：

- 固定旧 `bit+hwh+driver+param+checkpoint` 校验值；
- 记录单图正确性、Top-1/Top-5、MMIO 搬运时间、计算时间和总时间；
- 明确 CPU<10% 指标分别报告“纯 DMA 窗口”和“端到端推理”。

通过门槛：同一图片重复运行结果一致，旧方案性能数据可复现。

### 阶段 1：冻结 DMA 架构与协议

产物：

- `01_DMA_ARCHITECTURE.md`；
- `02_STREAM_PACKET_PROTOCOL.md`；
- 寄存器表、header 格式、错误码、复位和超时语义；
- 明确首版单时钟 100 MHz，禁止边写某 RAM 边由 APU 读取同一 RAM。

通过门槛：每类 payload 的目标 RAM、地址单位、bit/word 顺序均有唯一解释。

### 阶段 2：RTL 数据通路与单元验证

实施顺序：

1. AXIS FIFO/skid 和协议断言；
2. job decoder 与错误处理；
3. feature RAM 64-bit loader；
4. weight/BN/instruction loader；
5. result packetizer；
6. job controller；
7. 抽取 `apu_core` 并接入完整网络。

验证至少覆盖：连续无停顿、随机 backpressure、短包、超长包、错误 magic、复位中断、
`TLAST` 错位、APU timeout，以及 DMA 路径输出与现有 golden 的逐字一致。

通过门槛：随机背压下零丢字/零重字，完整网络结果与旧路径 bit-exact 一致。

### 阶段 3：Vivado Block Design

产物放入 `dma/vivado/`：

- 可重建工程的 Tcl；
- APU DMA IP 打包脚本；
- AXI DMA、PS7、HP0/HP1、IRQ、时钟复位的连接说明；
- 地址表和 bit/hwh 生成检查清单。

配置重点：

- AXI DMA 开启 MM2S、S2MM 和中断；
- stream/data mover 宽度使用 64 bit；
- MM2S 与 S2MM 分别连接 HP0/HP1，避免数据面走 GP0；
- 所有首版数据通路使用同一 100 MHz 时钟；
- AXI-Lite 控制仍由 GP0 访问；
- 实现后要求 `WNS >= 0`、`TNS = 0`，并检查 BRAM/LUTRAM 推断。

通过门槛：Vivado address validation、BD validation、DRC、时序全部通过。

### 阶段 4：PYNQ 零拷贝驱动

产物放入 `dma/pynq/`：

- Overlay 加载和 IP 发现；
- `pynq.allocate(dtype=np.uint64)` 的发送/接收缓冲区；
- 原位向 DMA buffer 打包输入和任务，禁止 `.tobytes()` 后再 MMIO；
- cache flush/invalidate；
- 基于 DMA 中断的等待，禁止忙轮询 CPL；
- timeout、DMA error、PL error code 和 buffer 生命周期管理。

启动顺序必须先提交 S2MM 接收缓冲区，再启动 MM2S，防止 PL 输出端因无接收者而堵塞。

通过门槛：连续至少 1000 次传输，无 hang、DMA error、长度漂移或结果错位。

### 阶段 5：功能与正确性验收

分三级进行：

1. DMA loopback：验证 DDR -> MM2S -> FIFO -> S2MM -> DDR；
2. APU 最小任务：单层/零权重/已知输入；
3. 完整网络：与旧 MMIO 路径和 golden 中间结果对比。

准确率问题与传输问题分开：DMA 路径必须先做到与旧驱动 bit-exact；若两者都只有
Top-1 约 20%，则继续沿模型参数/量化合同排查，不能把准确率提升作为 DMA 接口正确性的
替代证据。

### 阶段 6：性能优化

先完成基础 DMA，再按收益实施：

1. 聚合多个 payload 为一次 MM2S job，降低提交次数；
2. 中断等待替代 Python polling；
3. 发送/接收 ping-pong buffer；
4. 输入装载、APU 计算、结果发送按不同 buffer 重叠；
5. 批处理按计算段调度，权重装载一次后处理 N 张图，摊薄约 338 KiB/图的权重搬运；
6. 只有在 100 MHz 时序和功能稳定后才评估更高频率。

第 5 项是高分关键优化。当前 weight RAM 无法同时常驻完整网络参数，若仍按“每张图重载
全部层参数”，DMA 虽可降低 CPU 占用，但端到端吞吐仍会被权重流量限制。

### 阶段 7：性能测试与报告

必须同时给出以下指标：

| 指标 | 测量方法 |
|---|---|
| 原始 DMA 带宽 | 4/16/64 MiB buffer，多轮预热后统计 payload/time |
| APU 实际输入带宽 | 实际 job payload / PL 计数器周期 |
| 输出带宽 | result payload / S2MM active cycles |
| 端到端延迟 | pack + DMA + compute + DMA + unpack |
| CPU 占用率 | `process_time / perf_counter`，并用系统监控交叉检查 |
| 稳定性 | 1000 次以上传输的 min/avg/P95/P99/max |
| 正确性 | checksum、逐字 golden、Top-1/Top-5 |

小至 8 KiB 的单帧会被启动开销主导，因此 200 MB/s 指标必须用大 buffer 和连续 job 两种
方式报告，不能只挑选理论峰值。带宽统一使用十进制 `MB/s = bytes / seconds / 1e6`。

### 阶段 8：AXI-Lite 与 DMA 对比报告

同一板卡、同一频率、同一 payload、同一 APU 核心下报告：

- H2PL、PL2H 和双向带宽；
- 每次提交延迟；
- CPU 占用率；
- 不同块大小下的吞吐曲线；
- 单图与 batch 模式端到端延迟/吞吐；
- 资源增量：LUT、FF、BRAM、时序；
- 结果一致性与已知限制。

禁止拿旧方案 32-bit 小块 MMIO 的最差值与 DMA 理论峰值比较。所有报告数据必须来自脚本
原始 CSV/JSON，保留 Vivado utilization/timing 报告和测试环境版本。

## 6. 量化验收门槛

| 项目 | 最低通过标准 |
|---|---|
| 功能 | DMA loopback 和 APU 完整任务均正确，连续 1000 次无错误 |
| 一致性 | DMA 与旧 MMIO 路径输出逐字一致 |
| 带宽 | 大块单向有效带宽 >= 200 MB/s |
| CPU | 纯 DMA 传输窗口平均 CPU 占用率 < 10% |
| 流协议 | 随机 backpressure 下无丢字、重字、死锁 |
| 时序 | post-route `WNS >= 0`, `TNS = 0` |
| 可复现 | Tcl 可重建工程，脚本可生成原始性能数据和最终表格 |
| 对比 | AXI-Lite 与 DMA 使用统一口径并报告加速比 |

建议内部目标设为 >= 250 MB/s，为测量波动和系统负载保留余量。

## 7. 主要风险与决策点

1. **准确率基线尚低**：DMA 首先保证 bit-exact，不应同时修改数值语义。
2. **权重无法完整常驻**：最终吞吐需要聚合任务或 batch 分段调度。
3. **“零拷贝”口径易被夸大**：必须区分 DMA buffer 零拷贝与 PyTorch 张量转换。
4. **CPU<10%依赖中断**：使用 polling 即使带宽达标也可能验收失败。
5. **现有 APU RAM 为计算核心私有存储**：装载与计算并发前必须确认端口冲突，不能仅靠仲裁信号猜测。
6. **AXIS 停顿语义**：`TVALID=1 && TREADY=0` 时所有 payload 和 sideband 必须稳定。
7. **复位/错误恢复**：DMA error、短包或 APU timeout 后必须能软复位并开始下一任务。
8. **资源压力**：AXI DMA、FIFO、双缓冲会增加 BRAM，实施前需以当前实现报告为基线。

## 8. 推荐执行顺序

当前项目处于“架构与协议冻结前”，下一步不是直接改 `apu_driver.py`，也不是先在 GUI 中拖
AXI DMA。应依次完成：

```text
旧方案基线测量
  -> DMA 架构/packet/寄存器冻结
  -> AXIS loader/result RTL 与随机背压验证
  -> 接入 APU core 并做 bit-exact 回归
  -> Tcl 重建 Block Design
  -> PYNQ 零拷贝中断驱动
  -> 板上功能验收
  -> 带宽/CPU/稳定性测试
  -> AXI-Lite vs DMA 最终报告
```

首个可交付里程碑应是“DMA loopback >=200 MB/s 且 CPU<10%”，第二个里程碑是“APU
DMA 输出与旧 MMIO 输出 bit-exact”，第三个里程碑才是 batch/ping-pong 的端到端性能优化。

