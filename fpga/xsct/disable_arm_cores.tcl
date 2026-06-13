# Disable both Cortex-A9 cores after the PL bitstream has been loaded.
# Run with: xsct fpga/xsct/disable_arm_cores.tcl

set slcr_unlock       0xF8000008
set slcr_unlock_key   0x0000DF0D
set a9_cpu_rst_ctrl   0xF8000244

# A9_CPU_RST_CTRL bits:
#   [5] A9_CLKSTOP1 = 1
#   [4] A9_CLKSTOP0 = 1
#   [1] A9_RST1     = 1
#   [0] A9_RST0     = 1
# PERI_RST remains zero so PS MIO/peripheral infrastructure is not reset.
set arm_disable_value 0x00000033

connect

# Use the APU/DAP target for direct PS register access. Target names vary
# slightly by XSCT version, so try the aggregate APU target first.
set apu_targets [targets -filter {name =~ "APU*"}]
if {[llength $apu_targets] == 0} {
  error "No Zynq-7000 APU target found. Check JTAG connection and target power."
}
targets -set [lindex $apu_targets 0]

puts "Unlocking SLCR..."
mwr $slcr_unlock $slcr_unlock_key

puts "Asserting reset and stopping clocks for both Cortex-A9 cores..."
mwr $a9_cpu_rst_ctrl $arm_disable_value

# This access is performed through the debug access path, not by executing ARM
# instructions. Some XSCT versions may lose the CPU target immediately after
# clock stop; in that case the write is still the final required operation.
if {[catch {mrd $a9_cpu_rst_ctrl} readback]} {
  puts "ARM cores disabled; post-disable readback unavailable: $readback"
} else {
  puts "A9_CPU_RST_CTRL readback: $readback"
}

puts "Both Cortex-A9 cores are now held in reset with their clocks stopped."
puts "The PL PicoRV32/APU continues from the external H16 clock."
disconnect
