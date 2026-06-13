# 阶段 3：RISC-V 启动最小真实 APU 计算

## 1. 阶段目标

本阶段不再只读写 APU RAM，而是由 PicoRV32 执行 C 程序，完成“装载参数 -> 写
WorkSheet -> 启动 Ctrl -> 等待完成 -> 读回结果”的闭环。测试使用一条已验证指令
`0x3ACC8000`，含义是普通 3x3、`H=W=32`、`Cin=Cout=64`、stride 1。

## 2. 英文变量与软件函数

| 名称 | 中文含义 | 关键作用 |
| --- | --- | --- |
| `APU_READY` | APU 启动寄存器 | 写 1 产生单周期启动脉冲 |
| `APU_CPL` | APU 完成寄存器 | bit0 为完成；读取同时清除粘滞完成位 |
| `APU_RAM_CTRL` | RAM 控制权 | 3 表示 CPU 装载/读回，0 表示 Ctrl/计算通路使用 |
| `apu_load_zero_conv` | 装载最小测试 | 写 Act、64 个 Weight bank、64 个 BN channel 和指令 |
| `apu_start_and_wait` | 启动并等待 | 带有限超时轮询 `CPL`，完成后保留尾写等待 |
| `apu_run_zero_conv` | 最小闭环测试 | 执行计算并检查 1024 个 64-bit 输出 word |

## 3. 可预测数据构造

输入激活和全部权重写 0。BN 参数对 64 个输出 channel 均写 `0x0FFF`：

```text
direction = 0
threshold = 4095
output bit = accumulator < 4095
```

本指令最大累加值为 `9*64=576`，所以边界 padding、流水首拍和具体输入均不会改变
期望：每个输出 bit 都必须是 1，最终 1024 个 word 均为
`0xFFFF_FFFF_FFFF_FFFF`。该向量用于验证完整控制和写回，不用于验证模型精度。

## 4. 启动与延迟响应

```text
CPU 写 RAM_CTRL=3
 -> 装载 Act/Weight/BN/WorkSheet
 -> 写 RAM_CTRL=0，把 RAM 交给计算通路
 -> 写 APU_READY=1
 -> 循环读取 CPL，超过 200000 次则失败
 -> CPL 返回 1，同时清除 int_cal 粘滞位
 -> 软件空转 16 次，等待 Ctrl 最后一个注册地址写入 SRAM
 -> 写 RAM_CTRL=3，CPU 读回结果
```

`WorkSheetDone` 早于 Ctrl 的最后一次注册写回到达 Feature SRAM。若看到 `CPL=1` 后立即
切换 RAM 所有权，最后一个 64-bit word 存在丢失风险，因此固件显式保留 completion
fence。所有轮询均有上限，不会再出现仿真无限等待。

## 5. RAM 读 priming

阶段 3 首次发现：原 APU `addr_map` 使用寄存后的 `t_waddr` 判断 RAM read 是否位于
RAM window。紧跟 `RAM_SEL` 写后的第一笔 RAM read 可能没有产生 `ram_ren`。SoC 桥对
`0x0000..0x1FFF` RAM window 重发一次相同 AHB read 地址；控制寄存器不重发，避免
`CPL` 的 read-to-clear 副作用被执行两次。

若删除 RAM priming，典型现象是 64-bit 读回低 32 bit 为旧值、高 32 bit 正确；若把
priming 用于 `CPL`，完成位会在返回 CPU 前被清零，软件将一直轮询到超时。

## 6. 验证结果

```text
APU ZERO CONV PASS
```

测试平台还记录 `apu_int_cal` 曾拉高，并要求固件读 `CPL` 后该信号已清零。最小闭环在
完整 SoC 中约 123291 个周期结束。
