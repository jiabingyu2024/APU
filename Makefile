VERILATOR ?= verilator

TOP       := tb_top
BUILD_ROOT := build
BUILD_DIR := $(BUILD_ROOT)/verilator
SIM_OUT_DIR := $(BUILD_ROOT)/sim
TB_SRC    := tb/tb_top_student.sv
CPP_SRC   := tb/verilator_main.cpp
RTL_SRCS  := $(sort $(wildcard rtl/*.sv))
SIM       := $(BUILD_DIR)/V$(TOP)

VERILATOR_FLAGS := \
	--cc \
	--exe \
	--build \
	--timing \
	--trace \
	--trace-depth 4 \
	--top-module $(TOP) \
	--Mdir $(BUILD_DIR) \
	-Wall \
	-Wno-fatal \
	-CFLAGS "-std=c++17"

.PHONY: all run clean

all: $(SIM)

$(BUILD_DIR) $(SIM_OUT_DIR):
	mkdir -p $@

$(SIM): $(RTL_SRCS) $(TB_SRC) $(CPP_SRC) | $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) $(RTL_SRCS) $(TB_SRC) $(CPP_SRC) -o V$(TOP)

run: $(SIM) | $(SIM_OUT_DIR)
	./$(SIM)

clean:
	rm -rf $(BUILD_ROOT)
