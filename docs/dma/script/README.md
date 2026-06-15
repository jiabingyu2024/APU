# DMA 子项目 Python 脚本文档

## 目录结构概览

```
dma/
├── pynq/                          # 板级运行脚本 (需要 PYNQ 环境)
│   ├── __init__.py
│   ├── dma_job.py                 # [核心] DMA Job 协议构建器与解码器
│   ├── dma_network_job.py         # [核心] 全网络聚合 Job 构建器
│   ├── apu_dma_driver.py          # [驱动] DMA Overlay 底层驱动
│   ├── apu_driver_dma.py          # [适配器] 兼容旧版 APUDriver 接口的封装
│   ├── inference_dma.py           # [推理] DMA 推理包装器
│   └── test_apu_dma_smoke.py      # [冒烟测试] 板级 DMA 冒烟测试
├── benchmark/                     # 性能基准测试脚本
│   ├── benchmark_mmio.py          # 旧版 MMIO 传输带宽基准测试
│   ├── benchmark_mmio_e2e.py      # 旧版 MMIO 端到端推理基准测试
│   ├── benchmark_apu_dma_transport.py  # 新版 DMA 传输带宽基准测试
│   └── snapshot_baseline.py       # 基线资产快照记录
├── tests/                         # 离线单元测试 (无需 PYNQ)
│   ├── test_dma_job.py            # DMA Job 协议单元测试
│   └── test_dma_network_job.py    # 全网络 Job 离线单元测试
└── tools/                         # 开发调试工具
    ├── build_job_image.py         # 生成演示 Job 二进制文件
    └── decode_job_image.py        # 解码 Job 二进制文件
```

---

## 1. 核心协议层 (pynq/)

### 1.1 `dma_job.py` — DMA Job 协议构建器与解码器

| 属性 | 说明 |
|------|------|
| **职责** | 定义 APU DMA 主机端与设备端之间的通信协议格式，提供 Job 构建 (`JobBuilder`) 和响应解析 (`iter_job_packets` / `iter_response_packets`) 功能 |
| **依赖** | 仅依赖 NumPy，**无 PYNQ 依赖**。可在 PC 端离线使用。 |
| **关键数据结构** | `PacketHeader` (数据包头部)、`Opcode` / `Target` / `ResponseType` / `Status` 枚举 |
| **核心类** | `JobBuilder` — 将 LOAD / RUN / READ_RESULT / END_JOB 指令序列打包进 uint64 缓冲区 |
| **输入** | `uint64_buffer` (连续一维可写 NumPy 数组)、sequence_id、指令参数 |
| **输出** | 写入 buffer 的 Job 二进制数据 + `used_bytes` (实际使用字节数) |
| **测试内容** | 不直接测试硬件，是 DMA 协议的数据平面 — 所有上层脚本都依赖此模块定义的数据格式 |

**关键设计点**：
- 每条指令 = 4 beats (32 字节) 固定头部 + 变长负载 (8字节对齐填充)
- `LOAD` 指令支持 64 位 (ACT/OUT/WEIGHT) 和 32 位 (BN/INSTRUCTION) 两种负载
- `RUN` 指令携带 instruction_count + timeout_cycles
- `READ_RESULT` 从指定目标 RAM 读取结果
- `END_JOB` 必须为 Job 的最后一条指令
- 响应解析器 (`iter_response_packets`) 处理从 DMA 返回的 DATA / FINAL / ERROR 包

---

### 1.2 `dma_network_job.py` — 全网络聚合 Job 构建器

| 属性 | 说明 |
|------|------|
| **职责** | 将完整的 12 层 ResNet 二值卷积网络打包为单个聚合 DMA Job，包含所有权重、BN 参数和指令 |
| **依赖** | `dma_job.py` (JobBuilder, Target)；参数文件位于 `apuYjb/param/` |
| **关键数据** | `LayerSpec` — 描述每层的参数文件、形状、地址映射；`STAGES` — 5 个执行阶段 |
| **核心函数** | `build_full_network_job()` — 将全网络构建到缓冲区中 |
| **输入** | uint64 buffer、param_dir、1024 个 uint64 输入字、sequence_id、timeout_cycles |
| **输出** | 填充完成的 `JobBuilder` + `used_bytes` |
| **辅助函数** | `pack_input_nchw()` — 将 NCHW (1,64,32,32) 张量打包为 1024 个 uint64 字；`unpack_output_payload()` — 将输出 256 个 uint64 解包为 (1,256,8,8) |

**网络结构**：
- **Stage 1** (8 层)：layer1.0~2.1 — 每层加载独立权重 + BN，含一个 resident 层
- **Stage 2** (1 层)：layer3.0.conv1 — 单独执行
- **Stage 3** (1 层)：layer3.0.conv2_combined — resident 层
- **Stage 4** (1 层)：layer3.1.conv1
- **Stage 5** (1 层)：layer3.1.conv2
- 最后发送 `READ_RESULT` 读取 256 个输出字

**地址映射**：每个执行阶段内，各层的权重和 BN 参数分布在 64 个 bank 上。`_append_stage()` 负责将同 bank 内的连续地址区域合并为较少的 LOAD 指令，提高传输效率。

---

## 2. 底层驱动层 (pynq/)

### 2.1 `apu_dma_driver.py` — DMA Overlay 底层驱动

| 属性 | 说明 |
|------|------|
| **职责** | 封装 PYNQ DMA Overlay 的初始化和控制，提供零拷贝 (zero-copy) 的 Job 提交与响应接收能力 |
| **依赖** | PYNQ 库 (`pynq.Overlay`, `pynq.MMIO`, `pynq.allocate`)；**只能在 PYNQ 板端运行** |
| **核心类** | `ApuDmaOverlay` |
| **关键寄存器** | 状态/控制寄存器映射 (REG_ID=0x00 到 REG_CONTROL=0x58) |
| **输入** | `tx_buffer` (PYNQ allocate 分配的 CMA 缓冲区)、`used_bytes`、`expected_response_bytes` |
| **输出** | `DmaResponse` (含响应数据包列表、已用字节数) |

**关键功能**：
- `allocate_job_buffer(size)` — 分配 DMA 可访问的连续缓冲区
- `execute_async()` — 异步 DMA 传输 (使用 `asyncio` + 中断等待)
- `execute()` — 同步包装，对 polling 模式直接 run，对 interrupt 模式管理 event loop
- `read_status()` — 读取硬件计数器 (job 周期、传输字节、stall 周期、完成/错误计数等)
- `clear_counters()` / `enable_irqs()` / `clear_irqs()` — 控制接口

**传输流程**：
1. 分配 RX 缓冲区 → 清零 → flush cache
2. 配置 DMA 接收通道 (预置 RX 缓冲区)
3. 启动 DMA 发送通道 (发送 Job 数据)
4. 等待发送/接收完成 (中断模式 `wait_async()`，轮询模式 `wait()`)
5. Invalidate RX cache → 解析响应包 → 检查错误状态 → 返回 `DmaResponse`

**错误处理**：`ApuDmaError` 封装了 DMA 控制器的错误状态码 (`Status` 枚举)，包含 sequence_id 和 command_id，便于定位出错指令。

---

### 2.2 `apu_driver_dma.py` — 旧版接口兼容适配器

| 属性 | 说明 |
|------|------|
| **职责** | 提供与 `apuYjb/apu_driver.py` 中 `APUDriver` 类相同的 `execute_apu_network()` API，内部委托给 DMA 实现 |
| **定位** | **桥接层** — 使 `apuYjb/resnet_binary_ps.py` 等旧上层代码无需修改即可切换到 DMA 传输 |
| **核心类** | `APUDriver` (同名，同接口) |
| **输入** | `input_tensor_ps_01` — NCHW (1,64,32,32) 0/1 张量 |
| **输出** | 与旧版驱动完全相同的输出格式 — (1,256,8,8) 0/1 张量 |
| **内部实现** | 创建 `ApuDmaNetwork` (inference_dma.py) 并调用其 `execute()` 方法 |

**兼容性保证**：
- 构造函数签名相同 (`bitstream_file`, `axi_apu_ip_name`(忽略), `param_file_dir`, `output_debug_dir`)
- `execute_apu_network()` 参数签名与旧版完全一致
- `cleanup()` 释放 DMA 缓冲区

---

### 2.3 `inference_dma.py` — DMA 推理包装器

| 属性 | 说明 |
|------|------|
| **职责** | 封装一次完整 DMA 推理的生命周期：构建 Job → 提交执行 → 解析响应 → 返回输出张量 |
| **核心类** | `ApuDmaNetwork` |
| **依赖** | `apu_dma_driver.ApuDmaOverlay` + `dma_job` + `dma_network_job` |
| **输入** | `input_tensor` — PyTorch 或 NumPy 的 (1,64,32,32) 张量 |
| **输出** | 同形状 (1,64,32,32)... 实际上是 (1,256,8,8) 解包输出 |

**执行流程**：
1. 构造阶段：分配 TX 缓冲区 → 预构建完整网络 Job (占位输入) → 记录 input_slice 位置
2. 每次推理：将输入张量打包后填入 TX 缓冲区的 input_slice → 提交 DMA 执行
3. 响应解析：过滤 DATA 包 → `unpack_output_payload()` → 返回 PyTorch 张量或 NumPy 数组

**异步支持**：`execute_async()` 方法支持 Python `asyncio` 异步调用。

---

## 3. 板级冒烟测试 (pynq/)

### 3.1 `test_apu_dma_smoke.py` — DMA 板级冒烟测试

| 属性 | 说明 |
|------|------|
| **职责** | **硬件验证** — 在 PYNQ 板上运行，验证 DMA Overlay 能否正常加载、Job 能否正确传输、数据能否正确回读 |
| **依赖** | PYNQ 环境，DMA 比特流 (`apu_dma.bit`) |
| **测试方法** | 构建一个 LOAD + READ_RESULT 的简单 Job，将已知模式的 256~1024 个 uint64 写入 ACT RAM 再读回，逐字比较 |
| **输入** | `--words` (测试数据量)、`--sequence-id`、`--require-interrupts` (是否要求中断模式) |
| **输出** | PASS / 具体的 mismatch 错误信息 + 驱动状态 |
| **测试内容** | ① DMA Overlay 加载与初始化 ② DMA 发送通道 (MM2S) ③ DMA 接收通道 (S2MM) ④ APU DMA 控制器的状态寄存器 ⑤ 数据完整性的 round-trip 验证 |

**判断标准**：
- PASS：所有写入的数据能完全正确读回
- 中断模式：如果 `--require-interrupts` 设置但不可用则报错
- 轮询模式：可用于功能验证，但 CPU 占用率可能 >10% 不符合性能验收标准

---

## 4. 性能基准测试 (benchmark/)

### 4.1 `benchmark_mmio.py` — 旧版 MMIO 传输带宽基准测试

| 属性 | 说明 |
|------|------|
| **职责** | 测量旧版 MMIO/AHB 传输路径 (PS M_AXI_GP0 → AXI-to-AHB-Lite Bridge → APU_0) 的读/写带宽 |
| **依赖** | PYNQ 环境 + `apuYjb/apu_driver.APUDriver` (旧版) |
| **输入** | `--sizes` (传输大小列表)、`--warmup`、`--iterations` |
| **输出** | CSV 样本文件 + JSON 汇总报告 (`mmio_transfer_samples.csv`, `mmio_transfer_summary.json`) |
| **测试内容** | ① PS→PL (写) 方向带宽 ② PL→PS (读) 方向带宽 ③ CPU 占用率 (cpu_percent) |

**评估指标**：
- 按不同传输大小 (默认 256/1024/4096/8192 字节) 分别统计
- 统计：mean / min / p50 / p95 / max MB/s + CPU%

### 4.2 `benchmark_mmio_e2e.py` — 旧版 MMIO 端到端推理基准测试

| 属性 | 说明 |
|------|------|
| **职责** | 使用旧版 MMIO 驱动，在 CIFAR-10 测试集子集上测量端到端推理性能 (延迟 + 准确率) |
| **依赖** | PYNQ 环境 + `apuYjb/resnet_binary_ps.resnet_binary_cifar10_hybrid` + CIFAR-10 数据集 |
| **输入** | `--samples` (样本数)、`--start-index`、`--warmup` |
| **输出** | CSV 样本文件 + JSON 汇总报告 (`mmio_e2e_samples.csv`, `mmio_e2e_summary.json`) |
| **测试内容** | ① Top-1 / Top-5 准确率 ② 每样本推理延迟 (ms) ③ CPU 占用率 ④ 输出数据 checksum (SHA256) 用于跨版本对比 |

### 4.3 `benchmark_apu_dma_transport.py` — 新版 DMA 传输带宽基准测试

| 属性 | 说明 |
|------|------|
| **职责** | 测量新版 DMA 传输路径的 Job 提交带宽 (通过真实的 DMA loader 发送批量 WEIGHT 数据) |
| **依赖** | PYNQ 环境 + `apu_dma_driver.ApuDmaOverlay` + `dma_job.JobBuilder` |
| **输入** | `--repeats` (重复倍数)、`--clock-mhz` (硬件时钟频率)、`--warmup`、`--iterations` |
| **输出** | CSV 样本文件 + JSON 汇总报告 (`apu_dma_transport_samples.csv`, `apu_dma_transport_summary.json`) |
| **测试内容** | ① 墙钟带宽 (wall_mb_per_second) ② 硬件带宽 (hardware_mb_per_second) ③ CPU 占用率 ④ MM2S/S2MM stall 周期 |

**验收标准**：
- `passes_200mbps_wall`：平均墙钟带宽 ≥200 MB/s
- `passes_cpu_10percent`：平均 CPU 占用率 <10%

### 4.4 `snapshot_baseline.py` — 基线资产快照记录

| 属性 | 说明 |
|------|------|
| **职责** | 生成当前代码库基线资产的 SHA256 校验和清单，用于后续对比追踪变更 |
| **依赖** | 无 PYNQ 依赖，可在 PC 端运行 |
| **输入** | `--repo-root` (仓库根目录)、`--output` (输出路径) |
| **输出** | JSON 清单文件 (`baseline_asset_manifest.json`) |
| **记录内容** | 比特流/ .hwh / .tcl 文件 checksum、旧版驱动/模型脚本 checksum、模型权重 checksum、所有参数文件的 checksum、Git commit 信息、Python/平台版本 |

---

## 5. 离线单元测试 (tests/)

### 5.1 `test_dma_job.py` — DMA Job 协议单元测试

| 属性 | 说明 |
|------|------|
| **职责** | 对 `dma_job.py` 的数据包构建/解析功能进行纯软件验证 |
| **依赖** | 无 PYNQ！仅需要 NumPy |
| **测试用例** | ① **round_trip** — 构建含多种指令的 Job，再用解析器读回，验证 opcode/sequence_id/payload 一致 ② **reject_trailing_data** — END_JOB 后的多余数据应报错 ③ **capacity_check** — 缓冲区容量超限应报错 ④ **dtype_contract** — uint64 与 uint32 负载混用应报错 ⑤ **instruction_limit** — 超过 15 条指令应报错 ⑥ **response_parser** — 构造模拟的 DMA 响应数据并验证解析 |

**意义**：这些测试确保 DMA 协议实现符合规范，在部署到硬件前即可捕获协议层 bug。

### 5.2 `test_dma_network_job.py` — 全网络 Job 离线单元测试

| 属性 | 说明 |
|------|------|
| **职责** | 验证 `dma_network_job.py` 构建的全网络 Job 格式正确 |
| **依赖** | 需要参数文件 (`apuYjb/param/`) 读取真实层配置 |
| **测试用例** | ① **pack_round_trip** — pack_input_nchw 打包后解包应与原始数据一致 ② **output_unpack_shape** — unpack_output_payload 输出形状应为 (1,256,8,8) ③ **full_job_layout** — 构建全网络 Job 后验证：RUN 指令数量 (5个阶段)、指令计数 [8,1,1,1,1]、READ_RESULT 目标 = ACT、element_count=256、内存边界、command_id 顺序递增 |

**意义**：确保网络描述 (`STAGES` 配置) 与参数文件一致，地址不越界。

---

## 6. 开发调试工具 (tools/)

### 6.1 `build_job_image.py` — 生成演示 Job 二进制

| 属性 | 说明 |
|------|------|
| **职责** | 构建一个确定性的演示 DMA Job 并保存为二进制文件 + JSON 描述清单 |
| **依赖** | `dma_job.JobBuilder` |
| **输入** | `--output` (二进制文件路径)、`--manifest` (JSON 描述路径) |
| **输出** | `.bin` 文件 + `.json` 描述文件 |
| **用途** | 为 RTL 仿真或硬件调试提供标准测试向量 |

### 6.2 `decode_job_image.py` — 解码 Job 二进制

| 属性 | 说明 |
|------|------|
| **职责** | 读取一个 DMA Job 二进制文件并解码为可读的 JSON 描述 |
| **依赖** | `dma_job.iter_job_packets` |
| **输入** | Job 二进制文件路径 |
| **输出** | 标准输出打印 JSON，包含每个数据包的头部字段和负载 hex |
| **用途** | 调试用 — 检查生成的 Job 是否符合预期 |

---

## 7. 与 `apuYjb/` 下脚本的关系

### 7.1 `apuYjb/` 四个核心脚本

| 脚本 | 职责 | 在项目中的角色 |
|------|------|---------------|
| `apu_driver.py` | 旧版 MMIO/AHB 驱动的 `APUDriver` 类 | **被替代的对象** — 使用 MMIO 逐字读写 APU 内部 RAM |
| `resnet_binary_ps.py` | 混合 ResNet 模型定义 (PyTorch + APU 加速) | **上层用户** — 调用 `apu_driver.execute_apu_network()` |
| `inference_ps.py` | 单张图片推理脚本 | **终端应用样例** — 加载模型并推理一张图片 |
| `evaluate_cifar10_ps.py` | CIFAR-10 全测试集评估脚本 | **终端应用样例** — 遍历测试集计算准确率 |

### 7.2 关系图谱

```
┌────────────────────────────────────────────────────────────────────┐
│                       上层应用层                                    │
│                                                                    │
│  evaluate_cifar10_ps.py    inference_ps.py                         │
│  (CIFAR-10 评估)           (单图推理)                              │
└───────────────────────────┬────────────────────────────────────────┘
                            │ 使用
┌───────────────────────────▼────────────────────────────────────────┐
│                      混合模型层                                     │
│                                                                    │
│  resnet_binary_ps.py (ResNet_cifar10_hybrid)                       │
│  • PS 端: conv1, bn, avgpool, fc — PyTorch CPU                    │
│  • APU 端: 二值卷积层 — execute_apu_network()                      │
└───────────────┬──────────────────────────┬────────────────────────┘
                │ 调用                     │ 调用
     ┌──────────▼──────────┐     ┌─────────▼──────────┐
     │ 旧版 MMIO 驱动      │     │ 新版 DMA 驱动      │
     │                     │     │                    │
     │ apu_driver.py       │     │ apu_driver_dma.py  │
     │ (MMIO/AHB 逐字写入) │     │ (DMA 批量传输)     │
     │                     │     │         │          │
     │ 写: MMIO write      │     │         ▼          │
     │ 读: MMIO read       │     │ inference_dma.py   │
     │ 流程:               │     │         │          │
     │ ① 配置 RAM_SEL      │     │         ▼          │
     │ ② 写权重/BN到BRAM   │     │ apu_dma_driver.py  │
     │ ③ 写指令            │     │ (PYNQ DMA Overlay) │
     │ ④ 触发 APU 执行     │     │         │          │
     │ ⑤ 轮询完成标志      │     │         ▼          │
     │ ⑥ 读输出            │     │ dma_job.py         │
     └─────────────────────┘     │ (协议定义)         │
                                 │         │          │
                                 │         ▼          │
                                 │ dma_network_job.py │
                                 │ (全网络打包)       │
                                 └────────────────────┘
```

### 7.3 新旧驱动对比

| 维度 | 旧版 (apu_driver.py) | 新版 (dma/*) |
|------|---------------------|--------------|
| **传输方式** | MMIO/AHB — 每个 32 位字单独读写 | AXI DMA — 整个 Job 批量传输 |
| **驱动 APU 的粒度** | 每层：写权重 → 写BN → 写指令 → 触发 → 等待完成 (重复 12 次) | 全网络：一次构建完整 Job → 一次 DMA 传输 → 一次等待完成 |
| **CPU 占用率** | 高 (逐字轮询等待) | 低 (<10%，中断驱动) |
| **带宽** | 低 (MMIO 瓶颈) | 高 (>200 MB/s 目标) |
| **PYNQ 依赖** | 需要 (MMIO / Overlay) | 需要 (DMA / allocate) |
| **接口兼容性** | — | `apu_driver_dma.py` 提供完全兼容的 `APUDriver` 类 |
| **可测试性** | 只能在板端测试 | `dma_job.py` / `dma_network_job.py` 可离线单元测试 |

### 7.4 迁移路径

1. 原 `apuYjb/resnet_binary_ps.py` 中 `from apu_driver import APUDriver` → 修改为 `from apu_driver_dma import APUDriver` (或通过 `sys.path` 指向 `dma/pynq/`)
2. `apuYjb/` 的比特流 (`myDesign.bit`) 替换为 DMA 版的 `apu_dma.bit`
3. 参数文件 (`param/` 目录) 完全兼容，无需修改
4. 上层推理脚本 (`inference_ps.py`, `evaluate_cifar10_ps.py`) **无需修改**，只需重启 Jupyter 内核

### 7.5 测试覆盖关系

```
离线单元测试 (无需板卡):
  test_dma_job.py           → 测试 dma_job.py 协议实现
  test_dma_network_job.py   → 测试 dma_network_job.py 网络构建

板级冒烟测试 (需要 PYNQ):
  test_apu_dma_smoke.py     → 测试 apu_dma_driver.py 基本功能

性能基准测试 (需要 PYNQ):
  benchmark_mmio.py          → 旧版 MMIO 基准 (对比基线)
  benchmark_mmio_e2e.py      → 旧版端到端基准 (对比基线)
  benchmark_apu_dma_transport.py → 新版 DMA 基准 (验收测试)
  snapshot_baseline.py       → 基线快照 (版本追踪)

旧版应用脚本 (apuYjb/):
  apu_driver.py              → 旧版 MMIO 驱动实现
  resnet_binary_ps.py        → 混合模型定义 (使用旧版或新版驱动)
  inference_ps.py            → 单图推理入口
  evaluate_cifar10_ps.py     → CIFAR-10 评估入口
```

---

## 8. 快速索引

| 想做什么 | 用什么脚本 |
|----------|-----------|
| 了解 DMA 协议格式 | `dma_job.py` |
| 在 PC 上离线验证 Job 构建 | `test_dma_job.py` / `test_dma_network_job.py` |
| 在 PYNQ 板上验证 DMA 功能 | `test_apu_dma_smoke.py` |
| 测量 DDR→APU 传输带宽 | `benchmark_apu_dma_transport.py` |
| 对比旧版 MMIO 与 DMA 性能 | `benchmark_mmio.py` + `benchmark_apu_dma_transport.py` |
| 端到端推理 + 准确率验证 | `benchmark_mmio_e2e.py` (旧版)，后续可做 DMA 版 |
| 生成调试用 Job 二进制 | `build_job_image.py` → `decode_job_image.py` |
| 记录当前基线用于回归 | `snapshot_baseline.py` |
| 在旧脚本中切换到 DMA 驱动 | 将 `from apu_driver import APUDriver` 替换为 `from apu_driver_dma import APUDriver` (需指向 `dma/pynq/`) |

---

*文档生成时间：2026-06-15*
*基于对 `dma/` 和 `apuYjb/` 所有 Python 脚本的代码审查*
