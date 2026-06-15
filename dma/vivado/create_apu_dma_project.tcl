# Create the complete PYNQ-Z2 APU DMA project and validate its block design.
# This script intentionally stops before synthesis, implementation, and bitstream generation.

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_dir [file normalize [file join $script_dir project apu_dma]]
if {[info exists ::env(APU_DMA_PROJECT_DIR)]} {
    set project_dir [file normalize $::env(APU_DMA_PROJECT_DIR)]
}

set project_name apu_dma
set design_name apu_dma_bd
set part_name xc7z020clg400-1
set board_name tul.com.tw:pynq-z2:part0:1.0

# Single PL clock frequency knob for the whole DMA design.
# Edit this value directly, or override it before sourcing this script:
#   set ::env(APU_DMA_PL_FREQ_MHZ) 100
set pl_freq_mhz 50.000000
if {[info exists ::env(APU_DMA_PL_FREQ_MHZ)]} {
    set pl_freq_mhz $::env(APU_DMA_PL_FREQ_MHZ)
}
if {![string is double -strict $pl_freq_mhz] || $pl_freq_mhz <= 0.0} {
    error "APU_DMA_PL_FREQ_MHZ must be a positive MHz value, got: $pl_freq_mhz"
}
set pl_freq_mhz [format %.6f $pl_freq_mhz]
set pl_freq_hz [expr {round($pl_freq_mhz * 1000000.0)}]

set ip_repo_root [file normalize [file join $script_dir ip_repo]]
if {[info exists ::env(APU_DMA_IP_REPO)]} {
    set ip_repo_root [file normalize $::env(APU_DMA_IP_REPO)]
}

puts "APU_DMA_PL_FREQ_MHZ=$pl_freq_mhz"
puts "APU_DMA_PL_FREQ_HZ=$pl_freq_hz"

create_project $project_name $project_dir -part $part_name -force
if {[llength [get_board_parts -quiet $board_name]] == 0} {
    error "Required board part not installed: $board_name"
}
set_property BOARD_PART $board_name [current_project]
set_property target_language Verilog [current_project]
if {![file exists [file join $ip_repo_root APU_DMA component.xml]]} {
    error "Packaged APU DMA IP not found. Run package_apu_dma_ip.tcl first."
}
set_property ip_repo_paths $ip_repo_root [current_project]
update_ip_catalog

create_bd_design $design_name

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {apply_board_preset "1" make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} \
    $ps7
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP1 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $pl_freq_mhz \
    ] $ps7
set_property CONFIG.PCW_M_AXI_GP0_FREQMHZ.VALUE_SRC PROPAGATED $ps7
set_property CONFIG.PCW_S_AXI_HP0_FREQMHZ.VALUE_SRC PROPAGATED $ps7
set_property CONFIG.PCW_S_AXI_HP1_FREQMHZ.VALUE_SRC PROPAGATED $ps7

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

set ctrl_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_ctrl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] $ctrl_smc
set mm2s_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_mm2s]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $mm2s_smc
set s2mm_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_s2mm]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $s2mm_smc

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_include_mm2s_dre {1} \
    CONFIG.c_include_s2mm_dre {1} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_s2mm_burst_size {64} \
    CONFIG.c_sg_length_width {26} \
    ] $dma

set fifo_in [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_fifo_job]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {8} \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    ] $fifo_in
set fifo_out [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_fifo_result]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {8} \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    ] $fifo_out

set apu_dma [create_bd_cell -type ip -vlnv apu.local:user:apu_dma:1.0 apu_dma_0]

set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
set_property -dict [list CONFIG.NUM_PORTS {3}] $irq_concat
set irq_intc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_0]
set_property -dict [list CONFIG.C_NUM_INTR_INPUTS {3} CONFIG.C_IRQ_CONNECTION {0}] $irq_intc
catch {set_property CONFIG.C_KIND_OF_INTR {0x00000000} $irq_intc}
catch {set_property CONFIG.C_KIND_OF_LVL {0xFFFFFFFF} $irq_intc}

connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] [get_bd_intf_pins $ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $ctrl_smc/M00_AXI] [get_bd_intf_pins $dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins $ctrl_smc/M01_AXI] [get_bd_intf_pins $apu_dma/S_AXI_CTRL]
connect_bd_intf_net [get_bd_intf_pins $ctrl_smc/M02_AXI] [get_bd_intf_pins $irq_intc/S_AXI]

connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_MM2S] [get_bd_intf_pins $mm2s_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $mm2s_smc/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP0]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_S2MM] [get_bd_intf_pins $s2mm_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $s2mm_smc/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP1]

connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] [get_bd_intf_pins $fifo_in/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins $fifo_in/M_AXIS] [get_bd_intf_pins $apu_dma/S_AXIS_JOB]
connect_bd_intf_net [get_bd_intf_pins $apu_dma/M_AXIS_RESULT] [get_bd_intf_pins $fifo_out/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins $fifo_out/M_AXIS] [get_bd_intf_pins $dma/S_AXIS_S2MM]

connect_bd_net [get_bd_pins $dma/mm2s_introut] [get_bd_pins $irq_concat/In0]
connect_bd_net [get_bd_pins $dma/s2mm_introut] [get_bd_pins $irq_concat/In1]
connect_bd_net [get_bd_pins $apu_dma/irq] [get_bd_pins $irq_concat/In2]
connect_bd_net [get_bd_pins $irq_concat/dout] [get_bd_pins $irq_intc/intr]
connect_bd_net [get_bd_pins $irq_intc/irq] [get_bd_pins $ps7/IRQ_F2P]

set fclk [get_bd_pins $ps7/FCLK_CLK0]
connect_bd_net $fclk \
    [get_bd_pins $ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins $ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins $ps7/S_AXI_HP1_ACLK] \
    [get_bd_pins $ctrl_smc/aclk] \
    [get_bd_pins $mm2s_smc/aclk] \
    [get_bd_pins $s2mm_smc/aclk] \
    [get_bd_pins $dma/s_axi_lite_aclk] \
    [get_bd_pins $dma/m_axi_mm2s_aclk] \
    [get_bd_pins $dma/m_axi_s2mm_aclk] \
    [get_bd_pins $irq_intc/s_axi_aclk] \
    [get_bd_pins $fifo_in/s_axis_aclk] \
    [get_bd_pins $fifo_out/s_axis_aclk] \
    [get_bd_pins $apu_dma/aclk] \
    [get_bd_pins $rst/slowest_sync_clk]

foreach clk_pin [list \
    $fclk \
    [get_bd_pins $ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins $ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins $ps7/S_AXI_HP1_ACLK] \
    [get_bd_pins $ctrl_smc/aclk] \
    [get_bd_pins $mm2s_smc/aclk] \
    [get_bd_pins $s2mm_smc/aclk] \
    [get_bd_pins $dma/s_axi_lite_aclk] \
    [get_bd_pins $dma/m_axi_mm2s_aclk] \
    [get_bd_pins $dma/m_axi_s2mm_aclk] \
    [get_bd_pins $irq_intc/s_axi_aclk] \
    [get_bd_pins $fifo_in/s_axis_aclk] \
    [get_bd_pins $fifo_out/s_axis_aclk] \
    [get_bd_pins $apu_dma/aclk] \
    [get_bd_pins $rst/slowest_sync_clk] \
    ] {
        catch {set_property CONFIG.FREQ_HZ $pl_freq_hz $clk_pin}
}

foreach intf_pin [list \
    [get_bd_intf_pins $ps7/M_AXI_GP0] \
    [get_bd_intf_pins $ps7/S_AXI_HP0] \
    [get_bd_intf_pins $ps7/S_AXI_HP1] \
    [get_bd_intf_pins $ctrl_smc/S00_AXI] \
    [get_bd_intf_pins $ctrl_smc/M00_AXI] \
    [get_bd_intf_pins $ctrl_smc/M01_AXI] \
    [get_bd_intf_pins $ctrl_smc/M02_AXI] \
    [get_bd_intf_pins $dma/S_AXI_LITE] \
    [get_bd_intf_pins $dma/M_AXI_MM2S] \
    [get_bd_intf_pins $dma/M_AXI_S2MM] \
    [get_bd_intf_pins $dma/M_AXIS_MM2S] \
    [get_bd_intf_pins $dma/S_AXIS_S2MM] \
    [get_bd_intf_pins $mm2s_smc/S00_AXI] \
    [get_bd_intf_pins $mm2s_smc/M00_AXI] \
    [get_bd_intf_pins $s2mm_smc/S00_AXI] \
    [get_bd_intf_pins $s2mm_smc/M00_AXI] \
    [get_bd_intf_pins $fifo_in/S_AXIS] \
    [get_bd_intf_pins $fifo_in/M_AXIS] \
    [get_bd_intf_pins $fifo_out/S_AXIS] \
    [get_bd_intf_pins $fifo_out/M_AXIS] \
    [get_bd_intf_pins $apu_dma/S_AXIS_JOB] \
    [get_bd_intf_pins $apu_dma/M_AXIS_RESULT] \
    [get_bd_intf_pins $apu_dma/S_AXI_CTRL] \
    [get_bd_intf_pins $irq_intc/S_AXI] \
    ] {
        catch {set_property CONFIG.FREQ_HZ $pl_freq_hz $intf_pin}
}

connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]
set peripheral_resetn [get_bd_pins $rst/peripheral_aresetn]
connect_bd_net $peripheral_resetn \
    [get_bd_pins $ctrl_smc/aresetn] \
    [get_bd_pins $mm2s_smc/aresetn] \
    [get_bd_pins $s2mm_smc/aresetn] \
    [get_bd_pins $dma/axi_resetn] \
    [get_bd_pins $irq_intc/s_axi_aresetn] \
    [get_bd_pins $fifo_in/s_axis_aresetn] \
    [get_bd_pins $fifo_out/s_axis_aresetn] \
    [get_bd_pins $apu_dma/aresetn]

assign_bd_address
set dma_reg_seg [get_bd_addr_segs -quiet -of_objects [get_bd_intf_pins $dma/S_AXI_LITE]]
set apu_reg_seg [get_bd_addr_segs -quiet -of_objects [get_bd_intf_pins $apu_dma/S_AXI_CTRL]]
set intc_reg_seg [get_bd_addr_segs -quiet -of_objects [get_bd_intf_pins $irq_intc/S_AXI]]
if {[llength $dma_reg_seg] != 1} {
    error "Unable to identify AXI DMA register address segment"
}
if {[llength $apu_reg_seg] != 1} {
    error "Unable to identify APU DMA control address segment"
}
if {[llength $intc_reg_seg] != 1} {
    error "Unable to identify AXI interrupt controller address segment"
}
assign_bd_address -offset 0x40400000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps7/Data] $dma_reg_seg -force
assign_bd_address -offset 0x43C00000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps7/Data] $apu_reg_seg -force
assign_bd_address -offset 0x41800000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps7/Data] $intc_reg_seg -force

validate_bd_design
save_bd_design
generate_target all [get_files ${design_name}.bd]

set wrapper_files [make_wrapper -files [get_files ${design_name}.bd] -top]
add_files -norecurse $wrapper_files
set_property top ${design_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "APU_DMA_STATUS=BD_VALIDATED"
puts "Project: $project_dir/$project_name.xpr"
puts "Next step: open the project in Vivado GUI and run synthesis/implementation/bitstream manually."
