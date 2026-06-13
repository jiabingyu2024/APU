VIVADO ?= vivado
PYTHON ?= python3
JOBS ?= 4

.PHONY: environment-check assets project project-prebuilt bitstream bitstream-prebuilt clean

environment-check:
	$(MAKE) -C ../soc asset-toolchain-check PYTHON="$(PYTHON)"
	"$(VIVADO)" -version

assets:
	$(MAKE) -C ../soc firmware model PYTHON="$(PYTHON)"

project: assets
	"$(VIVADO)" -mode batch -source scripts/create_project.tcl

# Use firmware.hex/model.hex already generated in soc/build. This is convenient
# when the RISC-V toolchain is installed in WSL but Vivado runs on Windows.
project-prebuilt:
	"$(VIVADO)" -mode batch -source scripts/create_project.tcl

bitstream: assets
	"$(VIVADO)" -mode batch -source scripts/build_bitstream.tcl -tclargs $(JOBS)

bitstream-prebuilt:
	"$(VIVADO)" -mode batch -source scripts/build_bitstream.tcl -tclargs $(JOBS)

clean:
	rm -rf build output vivado*.jou vivado*.log .Xil
