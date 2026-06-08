# 仿真输出目录整理记录

- 日期：2026-06-08
- 目标：把仿真结果文件从 `build/` 根目录移到独立目录，避免和 Verilator 编译产物混在一起。
- 范围：`Makefile`、`tb/tb_top_student.sv`

## 1. 修改前问题

`build/` 根目录同时包含：

- Verilator 生成的 C++/object/makefile/binary 文件；
- 波形文件 `top.vcd`；
- AHB dump 结果 `data_out.txt`。

这会导致调试时难以区分“编译产物”和“仿真结果”，也不利于后续脚本稳定引用结果文件。

## 2. 新目录约定

```text
build/
  verilator/   # Verilator 编译产物和可执行文件
  sim/         # 仿真输出结果
```

当前输出文件：

```text
build/sim/top.vcd
build/sim/data_out.txt
```

## 3. 代码修改

### Makefile

- 新增 `BUILD_ROOT := build`
- 保留 `BUILD_DIR` 语义为 Verilator 编译目录，但路径改为 `build/verilator`
- 新增 `SIM_OUT_DIR := build/sim`
- `run` target 在执行仿真前创建 `build/sim`
- `clean` 仍清理整个 `build`

### tb/tb_top_student.sv

- `$dumpfile` 从 `build/top.vcd` 改为 `build/sim/top.vcd`
- `ahb_read_burst_save` 的 `$fopen` 从 `build/data_out.txt` 改为 `build/sim/data_out.txt`

## 4. 注意事项

旧的 `build/top.vcd` 和 `build/data_out.txt` 不会被本次修改自动删除。需要干净目录时执行：

```sh
make clean
CCACHE_DISABLE=1 make run
```

后续对拍脚本应读取 `build/sim/data_out.txt`。
