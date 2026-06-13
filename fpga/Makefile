VIVADO ?= vivado
JOBS ?= 4

.PHONY: assets project bitstream clean

assets:
	$(MAKE) -C ../soc firmware model

project: assets
	$(VIVADO) -mode batch -source scripts/create_project.tcl

bitstream: assets
	$(VIVADO) -mode batch -source scripts/build_bitstream.tcl -tclargs $(JOBS)

clean:
	rm -rf build output vivado*.jou vivado*.log .Xil
