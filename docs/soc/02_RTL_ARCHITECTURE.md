# 阶段 1 RTL 架构与时序

## 1. 模块定位

当前 SoC 是单发请求、按序完成的微控制器式系统，不是超标量或乱序处理器。PicoRV32
内部负责执行 RV32IMC 指令；本项目代码负责给 CPU 提供可访问的 RAM 和 MMIO 从设备。
CPU 的取指和 load/store 共用一组 native memory interface，互连每次只处理一笔请求，
所有 slave 最迟在请求后的响应周期拉高 `mem_ready`。

```text
picorv32_wrapper
       |
       | mem_valid/addr/wdata/wstrb
       v
soc_interconnect
  |          |             |              |
  v          v             v              v
boot_ram  sim_console   soc_timer   default_slave
```

## 2. 模块职责

| 文件/模块 | 中文职责 | 不负责什么 |
| --- | --- | --- |
| `picorv32_wrapper.sv` | 固定 CPU 参数，导出 native memory interface，绑住未使用 PCPI/IRQ | 不做地址译码，不修改 CPU 内核 |
| `soc_interconnect.sv` | 按地址产生唯一 slave select，合并 `ready/rdata` 返回 CPU | 不存数据，不处理 AHB |
| `boot_ram.sv` | 64 KiB 统一指令/数据 RAM，按 byte strobe 写入 | 不在 RTL 内读取固件文件 |
| `sim_console.sv` | 将 MMIO 字符写和退出码变成测试平台信号 | 不实现真实串口波形 |
| `soc_timer.sv` | 周期计数、比较值和 IRQ 条件 | 当前不负责 CPU 中断入口 |
| `default_slave.sv` | 完成所有未映射访问并锁存错误地址 | 不让非法请求永久等待 |
| `riscv_apu_soc_top.sv` | 实例化并连接以上模块 | 当前未实例化 APU |
| `tb_soc.sv` | 初始化 RAM、打印字符、监控 trap/退出/超时 | 不属于可综合 RTL |

## 3. PicoRV32 native 接口速查

| 信号 | 方向（相对 CPU） | 英文名含义 | 工程语义与关键时机 |
| --- | --- | --- | --- |
| `mem_valid` | 输出 | memory request valid | 为 1 表示当前取指或数据访问有效；等待期间保持为 1 |
| `mem_instr` | 输出 | instruction access | 为 1 表示取指，仅用于观察；RAM 对指令和数据统一响应 |
| `mem_ready` | 输入 | memory response ready | 与 `mem_valid` 同拍为 1 时事务完成，CPU 才能推进 |
| `mem_addr` | 输出 | byte address | 32-bit 字节地址，不是 word index |
| `mem_wdata` | 输出 | write data | store 指令产生的 32-bit 写数据 |
| `mem_wstrb[3:0]` | 输出 | write byte strobe | 全 0 为读；每个 bit 对应一个 byte 写使能 |
| `mem_rdata` | 输入 | read data | 在 `mem_valid && mem_ready` 的完成拍被 CPU 采样 |
| `trap` | 输出 | fatal CPU trap | 非法指令、非对齐等异常；测试平台见到后立即失败 |

若删除 `mem_ready` 的有限响应保证，CPU 会停在当前取指或 load/store，仿真表现为一直运行。

## 4. 地址译码和返回优先级

`soc_interconnect` 组合计算四个选择条件：

```text
ram_select     = mem_addr < 0x0001_0000
console_select = (mem_addr & 0xffff_f000) == 0x1000_0000
timer_select   = (mem_addr & 0xffff_f000) == 0x1000_1000
default_select = 前三者全部不成立
```

`ram_valid/console_valid/timer_valid/default_valid` 中同一时刻只能有一个为 1。返回优先级按
RAM、console、Timer、default 排列，但正确译码下不会出现两个 `ready` 同时为 1。

如果地址范围发生重叠，两个 slave 可能同时执行写操作，返回数据也会由代码优先级而不是
架构定义决定。因此后续增加 APU 时必须先检查 `0x2000_0000..0x2000_3FFF` 与现有范围
无重叠，并新增 one-hot 断言。

## 5. 正常读时序

以 CPU 读取 Timer 为例：

```text
周期 T0：CPU 拉高 mem_valid，mem_addr=0x1000_1000，mem_wstrb=0000
          interconnect 只拉高 timer_valid
T0 上升沿：soc_timer 锁存请求和 counter_q[31:0]，pending_q 置 1
周期 T1：timer_ready=1，timer_rdata 为锁存值
          interconnect 返回 mem_ready=1、mem_rdata=timer_rdata
T1 上升沿：CPU 接收数据，Timer 清除 pending_q，该事务完成
```

这里锁存读数据而不是在响应拍重新读取计数器，是为了让事务返回“请求被接受时”的确定值。
如果改成响应拍组合读取，计数值会晚一拍，虽不一定功能错误，但会让寄存器访问时刻含糊。

## 6. RAM byte/half/word 写时序

`mem_wstrb` 决定更新哪些字节：

```text
0001 -> 更新 [7:0]
0011 -> 更新 [15:0]
1100 -> 更新 [31:16]
1111 -> 更新整个 32-bit word
```

`boot_ram` 在接受请求的上升沿执行对应 byte lane 写入，下一周期以 `req_ready=1` 告知 CPU
事务完成。若把 RAM 简化成只支持 `1111`，C 字符串、`uint8_t`、`uint16_t` 和部分栈访问
会静默写错，通常表现为程序跑飞而不是立即报错。

## 7. 异常路径：未映射地址

固件读取 `0x3000_0000` 时：

```text
mem_valid -> default_valid -> default_slave.pending_q
下一周期 default_ready=1，mem_rdata=0xDEAD_BEEF
同时 fault=1，fault_addr=0x3000_0000 并保持到复位
```

PicoRV32 native 接口没有标准 bus error 输入，所以第一阶段采用“完成访问 + 记录错误”的
策略。若 default slave 不返回 ready，一处错误指针就会把整个 CPU 永久锁死，UART 也无法
继续输出错误信息。

## 8. 控制优先级

各 slave 的时序寄存器遵循：

```text
reset > 完成已有 pending 请求 > 接受新请求 > 保持状态
```

含义：一个 slave 已有请求在响应时，不会同拍再次接受 CPU 仍保持的旧请求，从而避免同一
store 被执行两次。CPU 看到 `mem_ready` 后在下一个周期撤销或更新请求，slave 随后可接收
下一笔事务。

## 9. 固件到硬件的数据流

```text
start.S 设置 sp、清理 .bss
 -> main.c 执行 MMIO 和 RAM 自检
 -> riscv64-unknown-elf-gcc 生成 firmware.elf
 -> objcopy 生成 little-endian firmware.bin
 -> makehex.py 按 32-bit word 生成 firmware.hex
 -> tb_soc 在复位释放前 $readmemh 到 boot_ram.mem
 -> PicoRV32 从地址 0 取 _start
```

工具链运行在开发电脑上，板子或 RTL 不编译 C。未来上板时变化的只是 HEX 如何进入 BRAM，
CPU 执行的仍然是同一类机器码。

## 10. APU 接入边界

阶段 2 已新增 `native_to_apu_ahb.sv`，并在互连中加入 APU select。桥负责：

1. 锁存 CPU 的全局地址、写数据和写 strobe；
2. 将 `0x2000_0000` 基址转换为 APU 低 14-bit 局部地址；
3. AHB 地址相位输出 `hsel/htrans/haddr/hwrite/hsize`；
4. 写事务下一拍输出 `hwdata`；
5. 对当前 APU 同步 RAM 读插入固定等待，不能直接相信其常高 `hreadyout`；
6. 只接受 32-bit 对齐全字访问，非法 partial access 返回错误而不写 APU；
7. 用独立 bridge TB 先对齐现有 APU testbench 的事务节奏，再连接 CPU。

如果直接把 `mem_valid` 接 `hsel`、把 `mem_wdata` 同拍接 `hwdata`，会破坏当前 AHB 写地址
相位与数据相位关系，典型结果是 RAM 选择正确但数据写入错误地址。

具体状态机、变量解释和验证结果见
[04_STAGE2_APU_BRIDGE.md](04_STAGE2_APU_BRIDGE.md)。

## 11. 当前预上板层次

```text
PicoRV32 native master
        |
        v
soc_interconnect
  | boot_ram 64 KiB
  | console -> uart_tx
  | timer / default slave
  | model_rom 512 KiB
  ` native_to_apu_ahb -> APU Top
```

`model_rom` 提供 90880 个有效 32-bit word，固件按 descriptor 将其搬运到 APU 内部
Act/Weight/SIMD/WorkSheet。`riscv_apu_board_top` 增加复位同步和串口发送，但不实例化
Zynq Processing System。完整数据和控制顺序见
[06_FULL_NETWORK_PREBOARD.md](06_FULL_NETWORK_PREBOARD.md)。
