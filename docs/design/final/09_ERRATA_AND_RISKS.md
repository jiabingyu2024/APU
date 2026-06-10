# 09 历史勘误、已修问题与剩余风险

## 1. 文档勘误原则

`docs/archive` 保留了定位过程，其中“当前结论”只对当时工作区成立。以下条目是
最终判定，生成 RTL 或继续调试时不得重新采用被推翻的结论。

## 2. 已关闭问题

### 2.1 Layer1 部分 mismatch

最终根因是 TB AHB 同步读采样相位和 64/32-bit 输出顺序，不是普通卷积 RTL。
修复后 layer1.0 首层输出 0 mismatch。

错误做法：根据错位 dump 修改 Ctrl、SIMD 或卷积计算。

### 2.2 Layer2 大面积 mismatch

大部分差异来自 128-channel 物理组顺序 `1,0` 与 golden `0,1` 不同。剩余首
word 错误来自 residual 指令启动时 InBuf 源未预置为 ping-pong。

最终修复：IDLE/InBuf 禁写准备阶段 `oInputBufSelect=pingpong`；dump adapter 执行
group reverse。

### 2.3 Layer3 全图 mismatch 的旧结论

`DEV1_LAYER3_OUTPUT_MISMATCH_REVIEW.md` 中“第一条 layer3 conv 已全图计算错误”
是基于无效 TB 序列和未转换的 256-channel dump 得出的阶段性结论。

无效序列包括：前 4 条 layer1 提前完成后，下一批仍把 layer2 指令写在 worksheet
4..7；WorkSheet 实际从地址 0 开始，执行内容与预期不一致。

修正批次和 4-group reverse 后，layer3.0 两个 op 已 0 mismatch，说明 Ctrl 的
128->256 普通卷积、WeightAddr 和 residual replay 在当前固定网络上可工作。

### 2.4 Layer3 最后少量 bit mismatch

Accumulator 16384 个整数全部正确。错误只发生在 `acc==threshold` 且 direction=0。
旧逻辑 `~(acc>threshold)` 实际是 `acc<=threshold`。

最终规范：direction 1 严格 `>`，direction 0 严格 `<`，相等输出 0。

## 3. 历史静态审查条目的当前状态

| 旧条目 | 最终状态 |
| --- | --- |
| residual depth 使用 log 右移 | 当前代码使用 `in_c_num-1`，固定 layer2/3 已通过 |
| shortcut 地址未用独立 stride | 当前硬编码地址等价于固定 layer2/3 stride2=2，非通用 |
| combined 权重跨度错误 | 当前 `9*IG+IG/2`/组与文件匹配，固定网络已通过 |
| addr_map 读空间由写地址判断 | 代码仍耦合，但 AHB 地址相位会更新 t_waddr；标准 TB 可用，建议重构 |
| WorkSheet 满 16 条回卷 | 仍存在，标准流最多 8 条一批，不得宣称关闭 |
| owner enable 未完全隔离 | 仍存在，由软件互斥规避 |

## 4. 当前功能风险

### 4.1 Ctrl 组合 latch

读中心地址组合块只在 `state==CONV` 下完整赋值，其他路径可能保持旧值。当前读
使能会关闭，固定回归不受影响；综合实现仍可能推断 latch。

建议：给所有组合输出默认值或把地址注册化，并用 token 对齐。

### 4.2 InBuf latch 和 magic cycle

`fromram/temp1/temp2` 依赖不完整 `always_comb` 保存状态；`18/36/37/40/38/152`
等常量编码固定网络时序。当前 layer2/3 已通过，但任何 pipeline latency 或 shape
变化都会失效。

建议：显式寄存 capture/replay，有语义计数器替代绝对周期常量。

### 4.3 WorkSheet 计数协议

16 条回卷、重复写虚增、稀疏写执行旧值、count=0 启动未保护。应增加显式提交
长度或把计数器扩为 `$clog2(N+1)`。

### 4.4 RAM owner

地址/数据 owner mux 与 enable OR 分离。只要软件严格遵守 `RAM_CTRL` 阶段协议，
当前可用；加入 DMA、多 master 或错误软件后可能破坏 RAM。

### 4.5 地址公式硬编码

Ctrl 的 stride2/residual 行偏移依赖常数 32，只对 32x64、16x128 等 word-row
宽度恰为 32 的配置成立。参数化重建应使用 row/col 公式并做等价回归。

## 5. ASIC 实现风险

### 5.1 存储器复位

FeatureProcessor 和 SIMD 对整个数组异步清零，通常无法映射 SRAM macro。应改为
无复位 memory wrapper，由软件初始化；控制寄存器仍复位。

### 5.2 组合关键路径

64 路 XOR 加 64 项 popcount 直接进入 accumulator。目标频率提高时可能需要树形
优化或流水。插入流水后 Ctrl 固定相位必须同步重构。

### 5.3 位宽和截断

Ctrl 使用不同宽度的乘除法、拼接和窄赋值。默认配置通过不代表参数化安全。
重构应为地址、像素、组数和乘积定义明确的 unsigned 类型与上界。

### 5.4 Memory read-during-write

当前行为来自 RTL 数组和 nonblocking assignment。替换 SRAM macro 前必须定义
same-address read/write 是 read-first、write-first 还是 no-change，并确认 residual
覆盖场景不依赖未定义行为。

## 6. 禁止的局部修复

- 禁止为了首项错误单独停住 WeightAddr。
- 禁止通过额外 `ACC_LOAD` 掩盖数据源预取错误。
- 禁止只交换 128-channel 两组就推广到 256-channel；必须按 G 组整体反序。
- 禁止将 direction=0 写成正向比较结果取反。
- 禁止在 worksheet 新批次开始时清 ping-pong。
- 禁止把所有 Verilator warning 视为误报；当前通过只限定固定网络。

## 7. 兼容性与改进优先级

1. 先用断言固化本目录的不变量。
2. 重写 InBuf replay 为显式寄存状态。
3. 重写 Ctrl 为参数化 row/col/group token 流水。
4. 修复 WorkSheet 计数和 RAM owner 协议。
5. 引入 SRAM wrapper 并锁定 latency/read-during-write。
6. 最后处理 adder tree timing pipeline。

每一步都必须运行完整 `make check`，并优先比较 accumulator 整数，防止 SIMD 阈值
掩盖算术回归。

## 8. 旧文档归并表

| 原文档 | 在最终文档中的处理 |
| --- | --- |
| `docs/design/APU_DESIGN.md` | 系统层次、接口、数据流归并到 01/02/04/06；过时 residual 推断由 07 修正 |
| `docs/design/APU_DESIGN_DEV1_CONV.md` | normal 流水和 dev1 时序归并到 05；“cycle=kernel”只保留 IG=1 条件 |
| `docs/design/AHB_RAM_SEL_128_129.md` | ping-pong 和 RAM_SEL 规则归并到 01/02/03 |
| `docs/sim/tb_top_student详解.md` | TB task、AHB 相位和执行流程归并到 02/08；旧行号不再作为规范 |
| `docs/archive/CTRL.md` | 未完成草稿，不作为实现依据 |
| `LAYER1_0_OUTPUT_MISMATCH_REVIEW.md` | 启动、RAM_SEL、AHB dump 排查过程归并到 08/09 |
| `LAYER1_0_ALL_ZERO_AFTER_RUN_REVIEW.md` | 写回保持窗口经验归并到 05 的写回和 drain 合同 |
| `DEV1_LAYER1_0_PARTIAL_MISMATCH_REVIEW.md` | 同步读采样及 high/low half 修复归并到 02/04/08 |
| `DEV1_LAYER2_RESIDUAL_MISMATCH_REVIEW.md` | 首项预取和 128-channel 布局证据归并到 04/05/07 |
| `DEV1_LAYER2_RESIDUAL_FIX_LOG.md` | InBufSelect 修复、batch 和读回规则归并到 02/03/07/09 |
| `DEV1_LAYER3_OUTPUT_MISMATCH_REVIEW.md` | 保留为历史误判案例；无效 TB 和未重排 dump 已在本章纠正 |
| `DEV1_LAYER3_OUTPUT_FIX_LOG.md` | strict compare、4-group reverse 和最终回归归并到 04/08/09 |
| `RTL_BUG_REVIEW_AND_FIX_LOG.md` | 静态问题按“已关闭/固定配置规避/仍存在”在本章重新定级 |
| `SIM_OUTPUT_PATH_CLEANUP.md` | `build/sim` 输出约定归并到 08 |

所有旧文档继续作为证据和调试历史保留，但不应与 `design/final` 并列作为代码生成
输入，否则模型可能同时采纳修复前后互相矛盾的结论。
