# RTL 集成 Bug 审查与修复记录

## 1. 记录信息

- 首次审查日期：2026-06-06
- 审查范围：`rtl/` 下全部 17 个 SystemVerilog 文件
- 审查方式：静态代码审查与跨模块接口推导
- 当前阶段：仅完成问题识别，尚未修改 RTL，尚未编译或仿真
- 审查重点：AHB 数据相位、RAM 所有权、worksheet 调度、残差数据流、权重地址生成

单模块测试通过只能证明局部输入约束下的行为。以下问题主要出现在模块组合后的地址语义、周期对齐和资源所有权上。

## 2. 问题总表

| ID | 严重度 | 状态 | 涉及模块 | 问题摘要 |
|---|---|---|---|---|
| BUG-001 | Critical | 待修复 | `Ctrl`, `Top` | 残差支路深度计算使用右移，导致 `iDepth` 变成 0 |
| BUG-002 | Critical | 待修复 | `Ctrl`, `FeatureProcessor` | 残差支路复用主卷积读地址，`stride2Code` 未参与地址生成 |
| BUG-003 | Critical | 待确认后修复 | `Ctrl`, `WeightSRAM` | resident 权重组跨度与实际组合权重布局不一致 |
| BUG-004 | High | 待修复 | `addr_map`, `ram_mux` | RAM 读使能错误地由上一次写地址判定 |
| BUG-005 | High | 待修复 | `WorkSheet` | 16 条指令时计数器回卷，且计数语义不支持稀疏/覆盖写 |
| RISK-001 | Medium | 待加固 | `Top` | RAM 地址/数据按 owner 选择，但读写使能未按 owner 隔离 |
| RISK-002 | Medium | 待加固 | `FeatureProcessor` | 存储阵列异步复位清零，难以推断 SRAM/BRAM |
| RISK-003 | Low | 待加固 | `Top`, `Ctrl` | 多处地址和组计数宽度仅对当前默认参数成立 |

## 3. 详细记录

### BUG-001：残差支路通道深度计算错误

**证据**

- `rtl/Ctrl.sv:160`：残差模式下 `oActlogInC = inCLog >> 1'b1`。
- `rtl/Top_student.sv:293`：`U_ActDepth = 1 << (ActlogInC - 6)`。

例如 layer2 resident 指令的 `inCLog=7`，残差源应为 64 通道，即 log2 深度应为 6；当前逻辑得到 `7 >> 1 = 3`。随后 `3-6` 在无符号窄位运算中回卷，最终 4 位 `U_ActDepth` 很可能截断为 0。`FeatureProcessor` 会判定 shape 无效，残差支路不能正确读取。

**拟修方向**

- 明确定义 resident 指令中主支路和 shortcut 支路的通道关系。
- 若 shortcut 固定为主支路通道数的一半，应使用 `inCLog - 1`，而不是右移 log 值。
- 对 `inCLog < 6` 和超出深度表示范围的情况增加保护。

**验证要求**

- layer2 resident：主支路 depth=2，shortcut depth=1。
- layer3 resident：主支路 depth=4，shortcut depth=2。
- 检查边界像素和全部 shortcut depth 的读地址序列。

### BUG-002：残差支路地址没有使用独立 stride

**证据**

- `rtl/Ctrl.sv:65` 解码了 `stride2Code`，但后续未使用。
- `rtl/Ctrl.sv:148` 只生成一套 `readCenterAddr`。
- `rtl/Ctrl.sv:152-153` 将同一地址同时送给 ActSRAM 和 OutSRAM。
- `rtl/Ctrl.sv:158` 又把残差 ActSRAM 的空间尺寸改成 `inHW << 1`，地址和 shape 语义不一致。

下采样 resident 层中，主支路通常读取较小特征图，shortcut 支路读取上一阶段较大特征图并按 `stride2` 采样。两者不能共享同一个线性中心地址。当前从第二行像素开始就会读错 shortcut 行地址。

**拟修方向**

- 分离 `mainReadCenterAddr` 与 `shortcutReadCenterAddr`。
- 主支路使用 `stride1Code`、主支路 `HW/depth`。
- shortcut 使用 `stride2Code`、shortcut `HW/depth`。
- 分别驱动 `oOutReadCenterAddr` 和 resident 模式下的 `oActReadCenterAddr`。

**验证要求**

- 对 `(row,col)=(0,0)、(0,1)、(1,0)` 手算两套地址。
- 覆盖 stride1=1/2、stride2=1/2，以及 layer2/layer3 两种 depth。

### BUG-003：resident 权重地址跨度与组合文件布局不一致

**证据**

- `rtl/Ctrl.sv:141` 扩展了 resident 的计算周期。
- `rtl/Ctrl.sv:150` 的输出组基址仍只使用 `kernelCycle * inGroup`。
- 组合权重还包含 shortcut 权重，因此相邻输出组的实际跨度大于普通卷积跨度。

当 `outGroup > 1` 时，`t=1` 的基址会落入 `t=0` 的 resident 附加权重区域，造成组间权重重叠。当前 `cyclePerTimeResidual` 还可能包含流水线补偿周期，因此不能只改一个加法常量，必须先冻结“SRAM 中每组权重字数”和“控制器实际累加次数”的契约。

**拟修方向**

- 定义 `normalWordsPerGroup`、`shortcutWordsPerGroup`、`residentWordsPerGroup`。
- `weightAddrNow` 的 `t` 跨度使用 resident 总字数。
- 将 SRAM 读延迟/WeightBuffer 延迟与有效 MAC 周期分开表达，避免用地址越界周期冲刷流水线。

**验证要求**

- 记录每个 `t` 的首尾权重地址，确认相邻区间不重叠且不留错误空洞。
- 对照 `layer2.0.conv2_combined.txt` 和 `layer3.0.conv2_combined.txt` 的每 bank 字数。
- 波形核对 SRAM 输出、WeightBuffer、Accumulator 三者的有效周期。

### BUG-004：RAM 读使能使用了写地址空间判断

**证据**

- `rtl/addr_map.sv:122`：`ram_space` 仅由 `t_waddr < RAM_CTRL_ADDR` 产生。
- `rtl/addr_map.sv:125`：`ram_ren` 也使用该 `ram_space`。

如果上一笔事务是写 `RAM_SEL_ADDR(0x2004)` 或其他控制寄存器，`t_waddr` 会保留在控制空间。紧接着读取 RAM 时，即使 `t_raddr` 位于 RAM 空间，`ram_ren` 仍为 0。读取结果会保持旧值或无效值。

**拟修方向**

- 写通路使用 `t_waddr < RAM_CTRL_ADDR`。
- 读通路独立使用 `t_raddr < RAM_CTRL_ADDR`。
- 不再用同一个 `ram_space` 同时控制读写。

**验证要求**

- 执行“写 RAM_SEL -> 读 RAM”连续事务。
- 执行“读控制寄存器 -> 读 RAM”和连续 burst read。
- 检查 `ram_ren`、`ram_raddr`、目标 SRAM 输出的周期关系。

### BUG-005：WorkSheet 指令计数器无法表示满深度

**证据**

- `rtl/WorkSheet.sv:30`：`totalInstrCount` 宽度为 `$clog2(P_INSTRUCTION_NUM)`。
- `rtl/WorkSheet.sv:46`：每次写入都直接加一。
- 默认 `P_INSTRUCTION_NUM=16` 时，4 位计数器写满 16 条后回卷为 0。
- 当前计数按“写事务数量”统计，不按最高有效地址或显式提交长度统计。

因此满 16 条指令无法执行；覆盖写同一地址也会虚增条数；稀疏写会执行未初始化或旧指令。`iAPUReady` 在计数为 0 时也没有拒绝启动。

**拟修方向**

- 计数器宽度改为 `$clog2(P_INSTRUCTION_NUM+1)`。
- 明确采用顺序 append、最高地址加一或显式 instruction count 寄存器中的一种协议。
- count=0 时禁止启动，并定义运行期间写 worksheet 的行为。

**验证要求**

- 覆盖 0、1、15、16 条指令。
- 覆盖重复写地址、乱序写地址和运行期间写入。

### RISK-001：RAM owner 只选择地址/数据，没有隔离使能

**证据**

- `rtl/Top_student.sv:287-318`：`nCe/nWe` 由 AHB 和 Ctrl 请求直接 OR 后取反。
- 地址和写数据则由 `data_ram_ctrl` 二选一。
- Weight SRAM 写使能也没有使用 `conv_ram_ctrl` 进行 owner 隔离。

正常软件流程如果严格保证 AHB 与 APU 不并发，问题可能不出现；但 owner 切换附近的延迟写、误访问或未来 DMA 并发会让“一个主机的 enable”配上“另一个主机的地址/数据”。

**拟修方向**

- owner 选择同时覆盖 enable、address、data。
- 明确 owner 切换只能发生在控制器 idle 且写流水线排空之后。

### RISK-002：大容量存储阵列带异步清零

**证据**

- `rtl/FeatureProcessor.sv:48-55` 在异步复位分支中清零整个 feature memory。
- `rtl/SIMD.sv:24-31` 同样复位整个二维参数阵列。

这种写法功能仿真可以通过，但 FPGA BRAM/ASIC SRAM 通常不支持逐位异步清零，会退化为大量触发器或无法映射到目标 memory macro。

**拟修方向**

- feature memory 不做阵列级复位，由软件初始化或 valid 位管理内容。
- 将 SRAM 封装与控制逻辑分离，使用目标工艺可替换的 memory wrapper。

### RISK-003：参数化接口存在默认值依赖

**证据**

- `rtl/Top_student.sv:289-318` 将 feature RAM 地址固定为 10 位。
- `rtl/Ctrl.sv:73-74` 的 group 数只有 4 位。
- `rtl/Ctrl.sv:131` 的 `inHW` 只有 6 位，无法表示 64。

默认配置下暂时成立，但修改 feature memory、通道数或空间尺寸参数后会静默截断。

## 4. 建议修复顺序

1. 修复 BUG-004，先稳定 AHB 到各 RAM 的基本可观测性。
2. 冻结 resident 指令语义和组合权重布局，再联合修复 BUG-001、BUG-002、BUG-003。
3. 修复 BUG-005，稳定多指令调度和完成中断。
4. 加固 RISK-001，明确 AHB/APU RAM owner 切换协议。
5. 最后处理 memory wrapper 与参数化问题，避免功能修复和实现重构混在一起。

## 5. 修复过程日志

| 日期 | 阶段 | 操作 | 结果 |
|---|---|---|---|
| 2026-06-06 | 静态审查 | 阅读全部 RTL，核对顶层连接、地址生成、控制周期和 RAM 映射 | 记录 5 个功能问题和 3 个实现风险 |
| 2026-06-06 | 变更控制 | 按要求不修改 RTL、不运行编译或仿真 | RTL 保持原样 |

后续每次修复应追加：修改文件、根因、关键 diff、验证命令、波形/结果、回归影响和是否关闭对应 Bug ID。

