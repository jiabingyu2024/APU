# AHB RAM_SEL 128/129 使用规则

## 1. 这条语句的含义

```systemverilog
ahb_write(RAM_SEL_ADDR, 4, 128);
```

三个参数分别表示：

```text
RAM_SEL_ADDR：写 RAM 片选寄存器
4：           AHB 传输宽度为 4 byte，即 32 bit
128：         后续 RAM 窗口访问选择 ActSRAM
```

`128` 和 `129` 选择的是两块物理 SRAM，并不直接表示“输入”或“输出”：

| RAM_SEL | 物理存储器 |
| ---: | --- |
| `128` | ActSRAM |
| `129` | OutSRAM |

## 2. 什么时候使用 128

### 写入网络初始输入

复位后 `Ctrl.pingpong = 0`，第一条计算指令固定从 ActSRAM 读取，因此初始输入应写入 `128`：

```systemverilog
ahb_write(RAM_CTRL_ADDR, 4, 32'h3);
ahb_write(RAM_SEL_ADDR, 4, 128);
ahb_write_burst(0, 0, input_word_count);
```

### 读取偶数条指令后的结果

每完成一条计算指令，ActSRAM 和 OutSRAM 的读写角色交换一次。因此完成第 2、4、6... 条指令后，结果位于 ActSRAM，应选择 `128`。

## 3. 什么时候使用 129

完成第 1、3、5... 条指令后，结果位于 OutSRAM，应选择 `129`。

例如只运行 layer1.0 的第一条普通卷积：

```systemverilog
run_apu();

ahb_write(RAM_CTRL_ADDR, 4, 32'h3);
ahb_write(RAM_SEL_ADDR, 4, 129);
ahb_read_burst_save(0, output_word_count);
```

## 4. 最简单的判断公式

设 `N` 为本次复位以来已经完成的计算指令总数：

```text
N 为奇数：最终结果在 OutSRAM，使用 RAM_SEL = 129
N 为偶数：最终结果在 ActSRAM，使用 RAM_SEL = 128
```

对应关系：

| 已完成指令数 N | 读源 | RAM_SEL |
| ---: | --- | ---: |
| 0 | 初始输入所在的 ActSRAM | `128` |
| 1 | OutSRAM | `129` |
| 2 | ActSRAM | `128` |
| 3 | OutSRAM | `129` |
| 4 | ActSRAM | `128` |

当前 TB 连续执行以下四条指令：

```text
layer1.0 conv1
layer1.0 conv2
layer1.1 conv1
layer1.1 conv2
```

所以 `N = 4`，最终读回应使用：

```systemverilog
ahb_write(RAM_SEL_ADDR, 4, 128);
```

## 5. 容易判断错误的地方

1. 不要按 `run_apu()` 的调用次数判断。一次 `run_apu()` 会执行 WorkSheet 中已经装入的全部指令。
2. `conv_layer()` 和 `conv_resident_layer()` 每调用一次，各向 WorkSheet 写入一条计算指令。
3. 残差指令内部即使经历 `CONV` 和 `CONV2` 两个阶段，整条指令完成后也只切换一次乒乓方向。
4. `WorkSheet.totalInstrCount` 在一批指令完成后会清零，但 `Ctrl.pingpong` 不会因 `nCe` 清零。因此分多次调用 `run_apu()` 时，要累计本次硬件复位以来完成的指令总数。
5. 只有硬件复位 `nRst` 才会令 `pingpong` 回到 0，使下一条指令重新从 ActSRAM 读、向 OutSRAM 写。

## 6. 一句话规则

```text
初始输入写 128；运行后奇数条读 129，偶数条读 128。
```
