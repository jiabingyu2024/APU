# 阶段 2：PicoRV32 接入 APU 总线桥

## 1. 阶段目标与完成边界

本阶段把阶段 1 的 PicoRV32 SoC 与现有 APU 顶层 `Top` 连接起来，但不启动卷积计算。
目标是证明 CPU 发出的 C 语言 MMIO 访问能够经过 native 总线、SoC 地址译码和 AHB
相位转换，最终正确访问 APU 寄存器和各类内部 RAM。

已完成：

- `0x2000_0000..0x2000_3FFF` APU 地址区译码；
- PicoRV32 native 请求到现有 APU AHB 风格接口的桥接；
- `RAM_CTRL`、`RAM_SEL` 写入和读回；
- ActSRAM、OutSRAM、WeightSRAM 的 64-bit 写入和读回；
- SIMD/BN 参数和 WorkSheet 的 32-bit 写入和读回；
- byte、halfword、非对齐访问拦截；
- bridge 独立单元测试和 RISC-V C 固件集成测试。

未完成：

- 写 `APU_READY` 启动计算；
- 等待 `int_cal/CPL`；
- 最小卷积、单层卷积和完整网络推理。

## 2. 当前数据通路

```text
PicoRV32
  mem_valid/mem_addr/mem_wdata/mem_wstrb
                |
                v
        soc_interconnect
                |
                | apu_valid + 原始全局地址
                v
      native_to_apu_ahb
                |
                | hsel/haddr/htrans/hwrite/hwdata
                v
         原 APU 顶层 Top
                |
       ahb_slave -> addr_map -> ram_mux
                |
       Act / Out / Weight / SIMD / WorkSheet
```

原 `rtl/` 下的 APU 文件没有修改。新增行为全部位于 `soc/rtl/`，因此原 APU testbench
仍然可以绕过 PicoRV32 独立运行。

## 3. 桥接口变量解释

### 3.1 PicoRV32 native 一侧

| 英文变量 | 中文含义 | 关键规则 |
| --- | --- | --- |
| `req_valid` | CPU 对 APU 的请求有效 | 在 `req_ready` 返回前保持有效 |
| `req_addr` | CPU 32-bit 全局字节地址 | APU 范围是 `0x2000_0000..0x2000_3FFF` |
| `req_wdata` | CPU 写数据 | 写事务中被桥锁存，供 AHB 数据相位使用 |
| `req_wstrb[3:0]` | 四个字节的写使能 | `0000` 是读，`1111` 是合法 32-bit 写 |
| `req_ready` | 桥已完成请求 | 只在读数据稳定或写入完成后拉高一拍 |
| `req_rdata` | 返回 CPU 的 32-bit 读数据 | CPU 在 `req_valid && req_ready` 时采样 |

### 3.2 AHB 一侧

| 英文变量 | 中文含义 | 当前桥产生的值 |
| --- | --- | --- |
| `hsel` | 选择 APU 从设备 | 只在地址相位为 1 |
| `haddr` | APU 局部字节地址 | `req_addr - 0x2000_0000` |
| `htrans` | AHB 传输类型 | 地址相位为 `NONSEQ=2'b10` |
| `hwrite` | 读写方向 | 1 为写，0 为读 |
| `hsize` | 单次传输宽度 | 固定 `3'b010`，即 32 bit |
| `hburst` | burst 类型 | 固定 single，不产生 burst |
| `hwdata` | AHB 写数据相位数据 | 使用桥锁存的 `wdata_q` |
| `hrdata` | APU 读返回数据 | 在桥的读响应状态返回 CPU |
| `hresp` | AHB 响应状态 | 当前 APU 固定返回 OKAY |
| `hreadyout` | APU 声称的完成信号 | 当前实现常高，桥不以它判断同步 RAM 数据有效 |

### 3.3 桥内部寄存器

| 英文变量 | 中文含义 | 为什么必须存在 |
| --- | --- | --- |
| `state_q` | 当前桥状态 | 将 native 一拍语义展开成 AHB 多相位事务 |
| `addr_q` | 锁存的 CPU 全局地址 | 等待期间不依赖 CPU 组合输出变化 |
| `wdata_q` | 锁存的 CPU 写数据 | 保证后一拍 AHB 数据相位仍是原事务数据 |
| `write_q` | 锁存的读写方向 | 地址相位结束后决定进入读还是写路径 |
| `legal_request` | 请求格式是否合法 | 只允许对齐 read 或全字 write |
| `access_fault` | 曾发生非法 APU 访问 | sticky 状态，保持到复位 |
| `fault_addr` | 最近一次非法访问地址 | 用于测试平台和未来系统错误寄存器定位 |

## 4. 全局地址到局部地址的变换

CPU 使用统一 32-bit 地址空间：

```text
CPU global address = 0x2000_0000 + APU local address
APU local address  = req_addr - 0x2000_0000
```

| CPU 全局地址 | 桥输出 `haddr` | APU 内部含义 |
| --- | --- | --- |
| `0x2000_0000` | `0x0000` | RAM window 第一个 32-bit word |
| `0x2000_0038` | `0x0038` | RAM window 的 64-bit word 7 低半字 |
| `0x2000_2000` | `0x2000` | `RAM_CTRL` |
| `0x2000_2004` | `0x2004` | `RAM_SEL` |
| `0x2000_2008` | `0x2008` | `APU_READY` |
| `0x2000_200C` | `0x200C` | `CPL` |

虽然当前 APU 最终只使用 `haddr[13:0]`，仍由桥显式减基址。否则更换全局基址时，依赖
“截低位碰巧相同”的设计会静默访问错误寄存器。

## 5. 七状态控制逻辑

| 状态 | 中文作用 | 对外信号/下一状态 |
| --- | --- | --- |
| `ST_IDLE` | 等待并锁存 native 请求 | 合法请求进入 `ST_ADDR`，非法请求进入 `ST_ERROR_RESP` |
| `ST_ADDR` | 产生 AHB 地址相位 | 写转数据相位；控制寄存器读转响应；RAM 读转 priming |
| `ST_READ_WAIT` | RAM read priming | 对 RAM window 重发相同地址，适配原 `addr_map` 的注册地址判断 |
| `ST_READ_RESP` | 返回同步读数据 | `req_ready=1`，`req_rdata=hrdata` |
| `ST_WRITE_DATA` | 产生 AHB 写数据相位 | `hwdata=wdata_q`，下一拍进入写响应 |
| `ST_WRITE_RESP` | 告知 CPU 写事务完成 | `req_ready=1` |
| `ST_ERROR_RESP` | 完成非法请求但不访问 APU | `req_ready=1`，读值为 `0xBAD0_ACCE` |

桥只允许一笔 outstanding 请求；返回 `req_ready` 前不会接收第二笔请求。

如果删除 `addr_q/wdata_q`，AHB 写数据相位可能使用 CPU 下一笔访问对应的数据。如果在
`ST_ADDR` 就对写请求返回 ready，CPU 会认为写入已完成，但 APU 的延迟写使能和
`hwdata` 尚未在数据相位相遇。

## 6. 写事务逐拍时序

以 CPU 写 `RAM_SEL=128` 为例：

```text
T0：req_valid=1, req_addr=0x2000_2004
    req_wdata=128, req_wstrb=1111
T0 上升沿：桥锁存请求，进入 ST_ADDR

T1：hsel=1, htrans=NONSEQ, haddr=0x2004, hwrite=1
T1 上升沿：APU 锁存写地址，并将内部 t_wren 延迟置位

T2：桥进入 ST_WRITE_DATA，hwdata=128
T2 上升沿：addr_map 看到延迟后的 t_wren，同时采样 hwdata，更新 RAM_SEL

T3：桥进入 ST_WRITE_RESP，req_ready=1
T3 上升沿：CPU 确认 store 完成
```

关键点是 `haddr` 和 `hwdata` 不属于同一 AHB 相位。现有 APU testbench 也是先给地址，
下一拍才给写数据，桥必须复现这个节奏。

## 7. 读事务逐拍时序

控制寄存器读保持一次地址相位后返回，尤其 `CPL` 具有 read-to-clear 副作用，不能重发。
RAM window 读采用两次相同地址相位：

```text
T0：CPU 输出对齐读请求，桥锁存地址
T1：第一次输出 AHB 地址；原 wrapper 更新内部 t_waddr
T2：ST_READ_WAIT 重发同一 RAM 地址；t_waddr/t_raddr 都指向 RAM window
T2 上升沿：ram_ren 有效，目标同步 RAM 更新读数据
T3：ST_READ_RESP 返回 hrdata，CPU 完成 load
```

APU 的 `hreadyout` 固定为 1，只表示 wrapper 没有实现标准 wait state，不代表内部同步 RAM
在地址相位同拍已经有数据。因此桥采用地址分类后的固定等待和 priming。如果直接组合连接
`req_ready=hreadyout`，CPU 可能采到上一次 RAM 访问的数据。

该问题在阶段 3 读回真实结果时暴露：OutSRAM word0 实际为全 1，但 CPU 首次得到
`0xFFFF_FFFF_0000_0000`。低 32-bit 的第一笔 read 没有产生 `ram_ren`。若错误地对
`CPL` 也 priming 两次，完成位会在返回前被清零，软件会一直轮询到超时。

## 8. 64-bit RAM 映射

ActSRAM、OutSRAM 和 WeightSRAM 内部均为 64-bit word，但 CPU 总线为 32 bit：

```text
64-bit index N 的低半字地址 = APU_WINDOW + N*8
64-bit index N 的高半字地址 = APU_WINDOW + N*8 + 4
```

软件函数 `apu_write64()` 必须先写低 32 bit，再写高 32 bit。`ram_mux` 在低半字写入时
只暂存数据，高半字写入时才提交 `{high32, low32}` 到目标 RAM。

| 目标 | `RAM_SEL` | index | 64-bit 测试数据 |
| --- | ---: | ---: | --- |
| ActSRAM | 128 | 7 | `0x01234567_DEADBEEF` |
| OutSRAM | 129 | 9 | `0x89ABCDEF_76543210` |
| Weight bank 0 | 64 | 3 | `0xFEDCBA98_76543210` |

如果高低半字顺序颠倒，读回会成为半字交换值；如果低半字和高半字之间切换 `RAM_SEL`，
共享的 `ram_wdata_r` 会把两个目标的数据错误拼接。

## 9. 非法访问控制

合法格式只有：

```text
read : addr[1:0] == 0 && req_wstrb == 0000
write: addr[1:0] == 0 && req_wstrb == 1111
```

固件对 ActSRAM word 7 的低字节发出 `sb`，地址为 `0x2000_0038`，`req_wstrb=0001`。
桥进入 `ST_ERROR_RESP`，不产生 `hsel`，同时置位：

```text
access_fault = 1
fault_addr   = 0x2000_0038
```

随后再次读取完整 64-bit word，仍为原值，证明非法 byte store 没有穿透到 APU。

## 10. 验证结果

独立桥测试：

```bash
make soc-bridge-check
```

结果为 `BRIDGE UNIT PASS`。该测试检查：

- write 只有一次地址相位；RAM read 有两次相同地址相位；
- `0x2000_2004 -> 0x0000_2004` 地址转换；
- `htrans=NONSEQ`、`hsize=WORD`、`hburst=SINGLE`；
- 写数据保持到地址相位后的数据相位；
- 读数据只在读响应状态返回；
- 非法 partial write 不产生新的 AHB 地址相位。

完整集成测试：

```bash
CCACHE_DISABLE=1 timeout 240s make soc-check
```

关键输出：

```text
BRIDGE UNIT PASS
HELLO RISCV APU SOC
RAM BYTE/HALF/WORD PASS
RV32IM PASS
TIMER PASS cycles=0x00000921
DEFAULT SLAVE PASS
APU MMIO BRIDGE PASS
SOC STAGE2 PASS
SIM PASS cycles=12757
```

阶段 2 的历史基线中 `apu_int_cal` 保持 0。阶段 3/4 已覆盖真实启动和完整推理，见
[05_STAGE3_MINIMAL_APU_RUN.md](05_STAGE3_MINIMAL_APU_RUN.md) 与
[06_FULL_NETWORK_PREBOARD.md](06_FULL_NETWORK_PREBOARD.md)。

## 11. 后续阶段

下一阶段完成“最小 APU 计算闭环”，不立即搬运完整模型：

1. 选取一条参数规模最小、执行周期可控的合法 WorkSheet 指令；
2. C 固件装载该指令所需的 Act、Weight 和 BN 参数；
3. 写 `RAM_CTRL=0` 归还内部 RAM 控制权；
4. 写 `APU_READY=1`；
5. 带超时轮询 `CPL` 或观察 `apu_int_cal`；
6. 写 `RAM_CTRL=3`，读回结果 SRAM；
7. 与独立软件期望值或原 APU testbench 的同一最小用例比较。

上述步骤现已完成，并已继续实现完整 12-op 网络和最终 bit-exact 对拍。
