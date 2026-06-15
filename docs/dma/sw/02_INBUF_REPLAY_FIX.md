# InBuf residual replay 修复记录

日期：2026-06-15

## 修改范围

本次只修改计算核公共 RTL：

- `rtl/InBuf.sv`
- 新增定向仿真：`tb/tb_inbuf_replay.sv`

没有修改：

- `rtl/Ctrl.sv`
- `dma/rtl/*.sv`
- Python 推理、参数和软件理想模型
- 现有 `dma/overlay/apu_dma.bit/.hwh`

因此仓库中当前 bit/hwh 仍是旧版本，必须重新打包 IP、综合、实现并导出后才能验证修复。

## 修复原因

板上分层测试确定：

```text
layer1.0.conv1   0 mismatch
layer1.0.conv2   0 mismatch
layer1.1.conv1   0 mismatch
layer1.1.conv2   0 mismatch
layer2.0.conv1   0 mismatch
layer2.0.conv2   880 mismatch
```

`layer2.0.conv2` 的 880 个错误全部位于第二个 64 通道输出组：

```text
channels 0..63:    0 mismatch
channels 64..127: 880 mismatch
```

旧 `InBuf.sv` 使用不完整 `always_comb` 保存 `fromram/temp1/temp2`，会推断无复位锁存器。shortcut 捕获又与同步 Feature SRAM 的读延迟处于同一边沿附近，第二输出组可能重放旧值或相邻值。

## RTL 修改

### 1. 删除隐式锁存器

以下状态全部改为 `always_ff` 寄存器并提供复位：

- `main_select`
- `replay_word0`
- `replay_word1`
- `count`
- `rBuf`

`main_select` 记录当前 residual 主路径使用的 SRAM。shortcut 数据始终从相反 SRAM 获取，不再依赖切换中的当前 `iSelect`。

### 2. 对齐同步 SRAM 读延迟

Feature SRAM 输出为寄存读。Ctrl 发出 shortcut 请求后，InBuf 在下一拍捕获：

| residual | 请求位置 | 新捕获位置 |
|---|---|---|
| layer2 shortcut group 0 | count 18 | count 19 |
| layer3 shortcut group 0 | count 36 | count 37 |
| layer3 shortcut group 1 | count 37 | count 38 |

layer3 第二个 shortcut 捕获时 Ctrl 可能已经切回主 SRAM，因此捕获数据由 `main_select` 明确选择相反 SRAM，而不是使用当前 `iSelect`。

### 3. 保持原执行协议

没有改变 Ctrl 或指令格式：

- layer2 每像素仍为 38 拍
- layer3 每像素仍为 152 拍
- layer2 后续输出组仍重放一个 shortcut word
- layer3 后续输出组仍按顺序重放两个 shortcut word
- 普通卷积仍是单拍 InBuf 缓冲

layer3 `replay_word0` 的位置显式写为 `74/112/150`，避免使用常数取模逻辑。

## PC 验证结果

定向 replay 仿真：

```text
TB_INBUF_REPLAY_PASS
```

覆盖：

- layer2：主 SRAM 为 B、shortcut SRAM 为 A，第二输出组重放第一个输出组捕获值。
- layer3：捕获两个 shortcut word，后续输出组按 word0、word1 顺序重放。

完整 `apu_dma_top` 使用 Icarus Verilog elaboration 成功，退出码为 0。输出仅包含工程原有警告，没有 InBuf latch、语法或端口错误。

当前机器没有 Verilator，未执行仓库的 `make check`。重新综合前建议在带 Verilator 的环境补跑：

```bash
CCACHE_DISABLE=1 make check
```

## Vivado 重新生成步骤

必须重新打包 `apu.local:user:apu_dma:1.0`。不要直接打开旧工程只点 Generate Bitstream，因为旧工程/IP cache 中可能仍保存旧 `InBuf.sv`。

为避免 Windows 长路径问题，在 Vivado Tcl Console 中使用短目录：

```tcl
cd {E:/Resources/01_lessons/class2_NS/APU/finalTest/prj/APU}

set ::env(APU_DMA_IP_BUILD_DIR) {E:/apu_fix/ip_pack}
set ::env(APU_DMA_IP_REPO)      {E:/apu_fix/ip_repo}
source dma/vivado/package_apu_dma_ip.tcl

set ::env(APU_DMA_PROJECT_DIR)  {E:/apu_fix/project}
source dma/vivado/create_apu_dma_project.tcl

set ::env(APU_DMA_PROJECT_DIR)  {E:/apu_fix/project}
source dma/vivado/build_apu_dma_bitstream.tcl
```

这条流程仍然是“先把 APU DMA 封装成 IP，再由 BD Tcl 创建工程”，没有改成 module reference。

构建完成后确认同一轮导出的文件已更新：

```text
dma/overlay/apu_dma.bit
dma/overlay/apu_dma.hwh
```

不要混用新 bit 和旧 hwh。

## 上板验收顺序

将新 `dma/overlay/apu_dma.bit/.hwh` 放到板上仓库后执行：

```bash
cd /home/xilinx/jupyter_notebooks/APUdma

python3 dma/pynq/test_apu_dma_smoke.py --require-interrupts
python3 dma/sw/diagnose_dma_prefixes.py --prefix 6
python3 dma/sw/diagnose_dma_stages.py
python3 dma/final_tests/05_apu_dma_inference.py
python3 dma/sw/compare_hardware.py
```

第一验收目标：

```text
layer2.0.conv2 mismatch_bits=0 total_bits=32768
```

随后要求五个阶段均为 0 mismatch，最终 05 输出应与软件参考一致：

```text
prediction: 0 (plane)
apu_output_sha256:
a236f489b1f93b1df7d9f801b436f70b644ab3874329ff13b2f979b7fd97c345
```

如果首次 residual 已归零但最终层仍有差异，再单独处理完成信号早于尾写的问题；本次没有同时修改该风险点。
