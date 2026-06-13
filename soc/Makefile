VERILATOR ?= verilator
TOOLCHAIN_PREFIX ?= riscv64-unknown-elf-

CC      := $(TOOLCHAIN_PREFIX)gcc
OBJCOPY := $(TOOLCHAIN_PREFIX)objcopy
OBJDUMP := $(TOOLCHAIN_PREFIX)objdump
SIZE    := $(TOOLCHAIN_PREFIX)size

BUILD_DIR := build
FW_DIR    := firmware
TB_DIR    := tb
RTL_DIR   := rtl
FW_ELF    := $(BUILD_DIR)/firmware.elf
FW_BIN    := $(BUILD_DIR)/firmware.bin
FW_HEX    := $(BUILD_DIR)/firmware.hex
MODEL_HEX := $(BUILD_DIR)/model.hex
MODEL_HEADER := $(BUILD_DIR)/model_layout.h
MODEL_STAMP := $(BUILD_DIR)/model.stamp
MODEL_SCRIPT := tools/build_model_image.py
MODEL_INPUTS := $(wildcard ../data/param_files/*.txt) \
	../data/data_flow/layer3.1_bn3_output.txt
SIM       := $(BUILD_DIR)/Vtb_soc
BRIDGE_SIM := $(BUILD_DIR)/bridge/Vtb_native_to_apu_ahb
UART_SIM := $(BUILD_DIR)/uart/Vtb_uart_tx

CFLAGS := -march=rv32imc -mabi=ilp32 -Os -ffreestanding -nostdlib \
	-nostartfiles -fno-builtin -fdata-sections -ffunction-sections \
	-msmall-data-limit=0 -Wall -Wextra -I$(BUILD_DIR)
LDFLAGS := -Wl,-T,$(FW_DIR)/link.ld -Wl,-Map,$(BUILD_DIR)/firmware.map \
	-Wl,--gc-sections

RTL_SRCS := \
	../third_party/picorv32/picorv32.v \
	$(RTL_DIR)/picorv32_wrapper.sv \
	$(RTL_DIR)/boot_ram.sv \
	$(RTL_DIR)/model_rom.sv \
	$(RTL_DIR)/sim_console.sv \
	$(RTL_DIR)/soc_timer.sv \
	$(RTL_DIR)/default_slave.sv \
	$(RTL_DIR)/native_to_apu_ahb.sv \
	$(RTL_DIR)/soc_interconnect.sv \
	$(RTL_DIR)/riscv_apu_soc_top.sv \
	$(RTL_DIR)/uart_tx.sv \
	$(RTL_DIR)/riscv_apu_board_top.sv \
	$(sort $(wildcard ../rtl/*.sv))

.PHONY: all toolchain-check model firmware bridge-sim bridge-check uart-sim uart-check sim run check clean

all: check

toolchain-check:
	$(CC) --version
	$(OBJCOPY) --version
	$(VERILATOR) --version

$(BUILD_DIR):
	mkdir -p $@

$(MODEL_STAMP): $(MODEL_SCRIPT) $(MODEL_INPUTS) | $(BUILD_DIR)
	python3 $(MODEL_SCRIPT) --root .. --hex $(MODEL_HEX) --header $(MODEL_HEADER)
	touch $@

$(MODEL_HEX) $(MODEL_HEADER): $(MODEL_STAMP)

model: $(MODEL_HEX) $(MODEL_HEADER)

$(FW_ELF): $(FW_DIR)/start.S $(FW_DIR)/main.c $(FW_DIR)/link.ld $(MODEL_HEADER) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(FW_DIR)/start.S $(FW_DIR)/main.c -o $@
	$(SIZE) $@
	$(OBJDUMP) -d -S $@ > $(BUILD_DIR)/firmware.dis

$(FW_BIN): $(FW_ELF)
	$(OBJCOPY) -O binary $< $@

$(FW_HEX): $(FW_BIN)
	python3 ../third_party/picorv32/firmware/makehex.py $< 16384 > $@

firmware: $(FW_HEX)

$(SIM): $(RTL_SRCS) $(TB_DIR)/tb_soc.sv $(FW_HEX) $(MODEL_HEX) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --trace -Wall -Wno-fatal \
		--top-module tb_soc --Mdir $(BUILD_DIR) \
		$(RTL_SRCS) $(TB_DIR)/tb_soc.sv

sim: $(SIM)

$(BRIDGE_SIM): $(RTL_DIR)/native_to_apu_ahb.sv $(TB_DIR)/tb_native_to_apu_ahb.sv | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --trace -Wall -Wno-fatal \
		--top-module tb_native_to_apu_ahb --Mdir $(BUILD_DIR)/bridge \
		$(RTL_DIR)/native_to_apu_ahb.sv $(TB_DIR)/tb_native_to_apu_ahb.sv

bridge-sim: $(BRIDGE_SIM)

bridge-check: $(BRIDGE_SIM)
	./$(BRIDGE_SIM)

$(UART_SIM): $(RTL_DIR)/uart_tx.sv $(TB_DIR)/tb_uart_tx.sv | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --trace -Wall -Wno-fatal \
		--top-module tb_uart_tx --Mdir $(BUILD_DIR)/uart \
		$(RTL_DIR)/uart_tx.sv $(TB_DIR)/tb_uart_tx.sv

uart-sim: $(UART_SIM)

uart-check: $(UART_SIM)
	./$(UART_SIM)

run: $(SIM)
	cd .. && ./soc/$(SIM)

check: bridge-check uart-check run

clean:
	rm -rf $(BUILD_DIR)
