# 阶段 D/E：APU DMA RTL 实现审查

## 1. 当前实现边界

新顶层是 `dma/rtl/apu_dma_top.sv`。旧 `apuYjb/APU_0`、AHB slave、地址译码和旧
bit/hwh均未修改。新 core 直接复用以下计算叶子：

```text
WorkSheet -> Ctrl -> FeatureProcessor/InBuf
          -> ComputeCoreGroup -> SIMD -> FeatureProcessor
```

AHB RAM 访问被替换为三阶段互斥所有权：

1. LOAD：`apu_stream_loader`拥有RAM写口；
2. RUN：现有Ctrl拥有feature/weight读口和feature写口；
3. READ_RESULT：`axis_result_streamer`拥有ACT或OUT同步读口。

控制器不会并行执行这三个阶段，因此首版不需要双口冲突仲裁。

## 2. 模块状态

| 文件 | 状态 | 作用 |
|---|---|---|
| `apu_dma_pkg.sv` | 已完成 | 协议常量、opcode、target、错误码 |
| `axis_job_decoder.sv` | Vivado elaboration通过 | 4-beat header、payload、TLAST和错误排空 |
| `apu_stream_loader.sv` | Vivado elaboration通过 | 32/64-bit payload写各RAM |
| `axis_result_streamer.sv` | Vivado elaboration通过 | 同步RAM读延迟和结果packet输出 |
| `apu_job_ctrl.sv` | Vivado elaboration通过 | LOAD/RUN/READ/END、timeout和错误恢复 |
| `apu_dma_perf_counters.sv` | Vivado elaboration通过 | 字节、busy和stall周期计数 |
| `apu_dma_axil_regs.sv` | Vivado elaboration通过 | 只读状态、W1C中断、计数清零 |
| `apu_dma_core.sv` | Vivado elaboration通过 | 复用现有计算叶子并替换AHB封装 |
| `apu_dma_top.sv` | 已打包为User IP | AXIS、AXI-Lite和内部模块连接 |

Vivado 2023.2 已对完整 RTL 层次执行独立 elaboration，结果为 0 error。User IP 已打包为
`apu.local:user:apu_dma:1.0`，并在新的 25 MHz BD 工程中完成实例化和连接验证。正式工程的
Synthesis、Implementation 和 bitstream 由用户在 GUI 中继续执行。

## 3. 关键握手设计

- decoder只在`TVALID && TREADY`时消耗beat；payload压力直接传回DMA MM2S；
- loader的写使能是单周期脉冲，地址只在有效payload握手后递增；
- 结果发送器在`TREADY=0`时保持`TDATA/TKEEP/TLAST/TVALID`不变；
- feature RAM为同步读，`READ_ISSUE -> READ_WAIT -> DATA`显式吸收1拍读延迟；
- 整个输入job只有`END_JOB` header最后一拍产生输入TLAST；
- 输出可以包含多个DATA packet，只有FINAL或ERROR packet拉高输出TLAST。

## 4. 错误恢复

decoder自身错误会排空输入直到TLAST。控制器或loader发现错误时，控制器输出
`decoder_abort`，同样丢弃当前job剩余输入，避免残余packet被当成新job。

APU timeout会复位worksheet、Ctrl、InBuf和计算累加控制状态，但不复位weight、feature和
BN存储。错误job结束后必须重新装载instruction；权重和BN仍保留。

## 5. AXI-Lite寄存器

| Offset | 名称 | 属性 | 说明 |
|---:|---|---|---|
| `0x00` | ID | RO | `0x44555041`，字节为`APUD` |
| `0x04` | PROTOCOL_VERSION | RO | 当前1 |
| `0x08` | STATUS | RO | bit0 job busy，bit1 core busy |
| `0x0C` | LAST_ERROR | RO | 低8位错误码 |
| `0x10` | ACTIVE_SEQUENCE | RO | 当前sequence ID |
| `0x14` | JOB_CYCLES | RO | 当前job周期数 |
| `0x18/1C` | RX_BYTES | RO | 64-bit输入字节数 |
| `0x20/24` | TX_BYTES | RO | 64-bit输出字节数 |
| `0x28/2C` | BUSY_CYCLES | RO | 64-bit job busy周期 |
| `0x30/34` | MM2S_STALL | RO | 输入valid但not ready周期 |
| `0x38/3C` | S2MM_STALL | RO | 输出valid但not ready周期 |
| `0x40/44` | COMPLETED_JOBS | RO | 正常job计数 |
| `0x48/4C` | ERROR_JOBS | RO | 错误job计数 |
| `0x50` | IRQ_STATUS | W1C | bit0 done，bit1 error |
| `0x54` | IRQ_ENABLE | RW | bit0 done，bit1 error |
| `0x58` | CONTROL | WO | 写bit0清性能计数器 |

## 6. 已知约束

1. 当前安全instruction数量为1到15，不允许16；这是现有`WorkSheet`计数宽度决定的。
2. 当前bring-up中AXIS和APU均为25 MHz单时钟，未实现CDC；性能验收需恢复到至少100 MHz。
3. 首版一次只执行一个job，不支持多个job排队。
4. 完整网络 wrapper 已能上板运行，但同一零输入重复运行输出 SHA 不一致，尚未达到 bit-exact 稳定。
5. Vivado第一次打开后必须确认User IP成功识别`S_AXIS_JOB`、`M_AXIS_RESULT`和`S_AXI_CTRL`。

