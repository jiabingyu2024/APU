# Job, Packet, Header Concepts

本文专门解释 `job`、`packet`、`header` 这些概念。它们容易和 DMA、AXI-Stream 的术语混在一起，需要先分清楚。

## 1. 先给结论

`job`、`packet`、`header` 不是 Xilinx AXI DMA IP 强制规定的术语。

在本项目里：

- `DMA transfer` 是 AXI DMA 的一次搬运。
- `AXI-Stream beat` 是 AXI-Stream 每握手成功一次传的 64-bit 数据。
- `job` 是本项目自定义的“一次完整 APU 任务”。
- `packet` 是本项目自定义 job 里的“一条命令”。
- `header` 是每个 packet 前面的固定 4 个 64-bit word，用来说明这条命令是什么。
- `payload` 是 header 后面的真实数据，例如输入特征、权重、BN 参数、指令。

可以理解为：

```text
DMA transfer
  contains one job
    contains many packets
      each packet has one header
      LOAD packet also has payload
```

## 2. DMA 本身只会搬字节

AXI DMA 不知道神经网络，也不知道 APU 的 ACT RAM、Weight RAM、BN 参数。

对 AXI DMA 来说，它只做两件事：

```text
MM2S: 从 DDR 某个地址开始读 N 字节，变成 AXI-Stream
S2MM: 从 AXI-Stream 接收 N 字节，写回 DDR 某个地址
```

它不会理解：

- 这段数据是不是权重。
- 什么时候该启动 APU。
- 输出应该从哪个 RAM 读。
- 错误码是什么意思。

所以如果只给 DMA 一大串字节，硬件自定义 IP 必须知道怎么解释这串字节。`job/packet/header` 就是为了解决“怎么解释”这个问题。

## 3. 为什么需要自定义 job

旧 MMIO/AHB 方案里，Python 可以一条一条调用函数：

```python
write_input()
write_weights()
write_bn()
write_instructions()
start_apu()
wait_done()
read_output()
```

这些函数调用本身就表达了“我要做什么”。

换成 DMA 后，Python 不是逐字写寄存器，而是提前准备一整块连续 buffer，让 DMA 一次搬过去：

```text
DDR buffer: [一大串 64-bit word]
```

问题来了：硬件看到这串 word，怎么知道前面是输入，后面是权重，再后面是 BN，然后什么时候启动？

答案就是在数据里加命令结构：

```text
LOAD input packet
LOAD weight packet
LOAD BN packet
LOAD instruction packet
RUN packet
READ_RESULT packet
END_JOB packet
```

这些 packet 合起来就是一个 job。

## 4. 什么是 job

`job` 是一次完整的 APU 工作任务。

在本项目里，一个 job 通常表示：

```text
把本次推理需要的数据装进 APU
启动 APU 计算
读回输出结果
结束本次任务
```

一个 job 会被 Python 构造成一个连续的 DMA 输入 buffer。AXI DMA MM2S 把这个 buffer 送入 `apu_dma` RTL。

本项目规定：

```text
一次 MM2S DMA transfer = 一个完整 job
```

也就是说，DMA 这次传输从第一个 packet 开始，到 `END_JOB` 结束。

## 5. 什么是 packet

`packet` 是 job 里的一个小命令。

例如：

```text
LOAD ACT
LOAD WEIGHT bank 0
LOAD BN bank 0
LOAD INSTRUCTION
RUN
READ_RESULT
END_JOB
```

每个 packet 解决一个具体动作：

| Packet | 作用 |
| --- | --- |
| `LOAD` | 把 payload 写到某个 APU 内部 RAM |
| `RUN` | 启动 APU 计算 |
| `READ_RESULT` | 从 ACT/OUT RAM 读结果，通过 S2MM 返回 |
| `END_JOB` | 标记整个 job 结束 |

AXI DMA 不认识 packet。packet 是 `dma/rtl/axis_job_decoder.sv` 和 `dma/rtl/apu_job_ctrl.sv` 认识的。

## 6. 什么是 header

`header` 是每个 packet 开头的固定说明字段。

你可以把它理解成“包裹单”：

```text
这个包裹是什么类型？
送到哪里？
后面有多少数据？
写到哪个地址？
属于哪个 job？
这是第几条命令？
```

本项目 header 固定是 4 个 64-bit beat，也就是 32 字节：

```text
Header beat 0: magic/version/opcode/target/flags
Header beat 1: sequence_id/payload_bytes
Header beat 2: address/element_count
Header beat 3: arg0/command_id
```

### Header beat 0

```text
[31:0]  magic
[39:32] version
[47:40] opcode
[55:48] target
[63:56] flags
```

含义：

- `magic`：固定值，用来判断是不是合法 job packet。
- `version`：协议版本。
- `opcode`：这条 packet 是 LOAD、RUN、READ_RESULT 还是 END_JOB。
- `target`：目标 RAM，例如 ACT、OUT、WEIGHT、BN、INSTRUCTION。
- `flags`：保留字段，目前必须为 0。

### Header beat 1

```text
[31:0]  sequence_id
[63:32] payload_bytes
```

含义：

- `sequence_id`：这整个 job 的编号。
- `payload_bytes`：header 后面跟多少真实 payload 字节。

### Header beat 2

```text
[31:0]  address
[63:32] element_count
```

含义：

- `address`：目标 RAM 的 word index。
- `element_count`：元素数量。

注意：这里的 `address` 不是 AXI 地址，不是 `0x43C00000`，而是 APU 内部目标 RAM 的 word 编号。

### Header beat 3

```text
[31:0]  arg0
[63:32] command_id
```

含义：

- `arg0`：附加参数。对 WEIGHT/BN 来说通常是 bank；对 RUN 来说是 timeout cycles。
- `command_id`：这个 job 里的命令序号。

## 7. 什么是 payload

`payload` 是 header 后面真正要写入硬件的数据。

例如 `LOAD ACT`：

```text
header: 说明这是 LOAD ACT，从 address 0 开始，写 1024 个 64-bit word
payload: 1024 个 64-bit 输入特征 word
```

例如 `RUN`：

```text
header: 说明这是 RUN，instruction_count 是多少，timeout 是多少
payload: 没有
```

不是每种 packet 都有 payload：

| Packet | 是否有 payload |
| --- | --- |
| `LOAD` | 有 |
| `RUN` | 无 |
| `READ_RESULT` | 无 |
| `END_JOB` | 无 |

## 8. 什么是 beat

`beat` 是 AXI/AXI-Stream 中很常见的概念，表示一次成功握手传输的数据单位。

本项目 AXI-Stream 数据宽度是 64 bit，所以：

```text
1 beat = 64 bit = 8 byte
```

当：

```text
TVALID = 1
TREADY = 1
```

时，一个 beat 传输成功。

所以 4-beat header 就是：

```text
4 * 8 byte = 32 byte
```

## 9. 什么是 TLAST

`TLAST` 是 AXI-Stream 的信号，不是本项目自己发明的。

它通常表示“一段 stream 的最后一拍”。

但 `TLAST` 到底表示一个 packet 结束、一个 frame 结束，还是一个 job 结束，是设计者自己约定的。

本项目约定：

```text
TLAST 表示整个 job 结束
不表示每个 packet 结束
```

所以只有 `END_JOB` header 的最后一个 beat 才应该 `TLAST=1`。

packet 的边界靠 header 里的 `payload_bytes` 判断。

## 10. 一个简化例子

假设只做一个很小的任务：

```text
LOAD ACT: 写 2 个 64-bit word
RUN: 启动 1 条 instruction
READ_RESULT: 读 2 个 64-bit word
END_JOB
```

DMA 输入 buffer 逻辑上是：

```text
Packet 0: LOAD ACT
  header beat 0
  header beat 1
  header beat 2
  header beat 3
  payload beat 0  // ACT word 0
  payload beat 1  // ACT word 1

Packet 1: RUN
  header beat 0
  header beat 1
  header beat 2
  header beat 3

Packet 2: READ_RESULT
  header beat 0
  header beat 1
  header beat 2
  header beat 3

Packet 3: END_JOB
  header beat 0
  header beat 1
  header beat 2
  header beat 3 with TLAST=1
```

RTL 看到这个 stream 后：

1. `axis_job_decoder` 先读 4 个 header beat。
2. 发现是 `LOAD ACT`。
3. `apu_job_ctrl` 让 `apu_stream_loader` 接收 payload。
4. loader 把两个 64-bit word 写进 ACT RAM。
5. decoder 继续读下一个 packet header。
6. 发现 `RUN`。
7. job controller 启动 APU core。
8. 发现 `READ_RESULT`。
9. result streamer 从 ACT/OUT RAM 读数据并通过 S2MM 返回。
10. 发现 `END_JOB + TLAST`。
11. 返回 `FINAL` response。

## 11. Response 也有 header

APU DMA 返回给 Python 的 response 也使用类似结构。

输入 job 的 magic 是：

```text
APUJ
```

输出 response 的 magic 是：

```text
APUR
```

response 类型：

| Response | 含义 |
| --- | --- |
| `DATA` | `READ_RESULT` 返回的数据 |
| `FINAL` | job 正常结束 |
| `ERROR` | job 出错 |

这样 Python 不只是收到一串结果字节，还能知道：

- 结果属于哪个 sequence。
- 是哪个 command 产生的结果。
- 有没有错误。
- 错误码是什么。

## 12. 这些概念和 DMA 术语的关系

| 概念 | 是否 DMA 标准术语 | 本项目含义 |
| --- | --- | --- |
| DMA transfer | 是 | AXI DMA 的一次输入或输出搬运 |
| MM2S | 是 | DDR 到 AXI-Stream |
| S2MM | 是 | AXI-Stream 到 DDR |
| AXI-Stream beat | 是 | 一次 TVALID/TREADY 成功传输 |
| TDATA/TKEEP/TVALID/TREADY/TLAST | 是 | AXI-Stream 信号 |
| job | 不是 AXI DMA 固有术语 | 本项目一次完整 APU 任务 |
| packet | 不是 AXI DMA 固有术语 | 本项目 job 内的一条命令 |
| header | 通用通信概念，不是 AXI DMA 特有 | 本项目 packet 的固定 4-beat 描述字段 |
| payload | 通用通信概念，不是 AXI DMA 特有 | LOAD 后面真实写入 RAM 的数据 |

## 13. 为什么不直接把所有数据按固定顺序塞进去

理论上可以设计成：

```text
先输入
再权重
再 BN
再指令
然后自动运行
最后自动输出
```

这样就不需要 header 了。

但缺点很明显：

- 不灵活，不同网络层/不同测试很难复用。
- 硬件无法知道某段数据的长度是否正确。
- 出错后很难定位是哪个部分错。
- 不能方便支持多次 LOAD、多个 bank、READ_RESULT 等命令。
- Python 和 RTL 必须强绑定一个固定顺序。

使用 packet/header 后，数据流自描述，RTL 可以检查 magic、version、opcode、target、length、address、bank，错误也能返回明确 error code。

## 14. 和软件函数调用的类比

你可以把 packet 看成硬件版函数调用。

旧 Python 调用：

```python
load_act(address=0, count=1024, data=input_words)
load_weight(bank=0, address=0, count=256, data=weight_words)
run(instruction_count=12, timeout=1000000)
read_result(target="OUT", address=0, count=256)
end_job()
```

DMA packet 化后：

```text
LOAD ACT packet
LOAD WEIGHT packet
RUN packet
READ_RESULT packet
END_JOB packet
```

header 就是函数参数，payload 就是大数组参数。

这个类比对理解本项目最有用。
