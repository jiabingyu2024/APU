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

create_project $project_name $project_dir -part $part_name -force
if {[llength [get_board_parts -quiet $board_name]] == 0} {
    error "Required board part not installed: $board_name"
}
set_property BOARD_PART $board_name [current_project]
set_property target_language Verilog [current_project]

set dma_rtl [list \
    [file join $repo_root dma rtl apu_dma_pkg.sv] \
    [file join $repo_root dma rtl axis_job_decoder.sv] \
    [file join $repo_root dma rtl apu_stream_loader.sv] \
    [file join $repo_root dma rtl axis_result_streamer.sv] \
    [file join $repo_root dma rtl apu_job_ctrl.sv] \
    [file join $repo_root dma rtl apu_dma_perf_counters.sv] \
    [file join $repo_root dma rtl apu_dma_axil_regs.sv] \
    [file join $repo_root dma rtl apu_dma_core.sv] \
    [file join $repo_root dma rtl apu_dma_top.sv] \
]

set apu_leaf_rtl [list \
    [file join $repo_root rtl WorkSheet.sv] \
    [file join $repo_root rtl Ctrl.sv] \
    [file join $repo_root rtl InBuf.sv] \
    [file join $repo_root rtl FeatureProcessor.sv] \
    [file join $repo_root rtl ComputeCoreGroup.sv] \
    [file join $repo_root rtl ComputeCore.sv] \
    [file join $repo_root rtl WeightSRAM.sv] \
    [file join $repo_root rtl WeightBuffer.sv] \
    [file join $repo_root rtl SIMD.sv] \
    [file join $repo_root rtl AdderTree.sv] \
    [file join $repo_root rtl Multiplier.sv] \
    [file join $repo_root rtl Accumulator.sv] \
]

foreach source_file [concat $dma_rtl $apu_leaf_rtl] {
    if {![file exists $source_file]} {
        error "Missing RTL source: $source_file"
    }
}
add_files -norecurse [concat $dma_rtl $apu_leaf_rtl]
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] *.sv]
set_property top apu_dma_top [current_fileset]
update_compile_order -fileset sources_1

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
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
] $ps7
set_property CONFIG.PCW_M_AXI_GP0_FREQMHZ.VALUE_SRC PROPAGATED $ps7
set_property CONFIG.PCW_S_AXI_HP0_FREQMHZ.VALUE_SRC PROPAGATED $ps7
set_property CONFIG.PCW_S_AXI_HP1_FREQMHZ.VALUE_SRC PROPAGATED $ps7

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

set ctrl_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_ctrl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ctrl_smc
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

set apu_dma [create_bd_cell -type module -reference apu_dma_top apu_dma_0]

set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
set_property -dict [list CONFIG.NUM_PORTS {3}] $irq_concat

connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] [get_bd_intf_pins $ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $ctrl_smc/M00_AXI] [get_bd_intf_pins $dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins $ctrl_smc/M01_AXI] [get_bd_intf_pins $apu_dma/S_AXI_CTRL]

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
connect_bd_net [get_bd_pins $irq_concat/dout] [get_bd_pins $ps7/IRQ_F2P]

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
    [get_bd_pins $fifo_in/s_axis_aclk] \
    [get_bd_pins $fifo_out/s_axis_aclk] \
    [get_bd_pins $apu_dma/aclk] \
    [get_bd_pins $rst/slowest_sync_clk]

connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]
set peripheral_resetn [get_bd_pins $rst/peripheral_aresetn]
connect_bd_net $peripheral_resetn \
    [get_bd_pins $ctrl_smc/aresetn] \
    [get_bd_pins $mm2s_smc/aresetn] \
    [get_bd_pins $s2mm_smc/aresetn] \
    [get_bd_pins $dma/axi_resetn] \
    [get_bd_pins $fifo_in/s_axis_aresetn] \
    [get_bd_pins $fifo_out/s_axis_aresetn] \
    [get_bd_pins $apu_dma/aresetn]

assign_bd_address
set dma_reg_seg [get_bd_addr_segs -quiet $dma/S_AXI_LITE/Reg]
set apu_reg_seg [get_bd_addr_segs -quiet $apu_dma/S_AXI_CTRL/Reg]
if {[llength $dma_reg_seg] != 1} {
    error "Unable to identify AXI DMA register address segment"
}
if {[llength $apu_reg_seg] != 1} {
    error "Unable to identify APU DMA control address segment"
}
assign_bd_address -offset 0x40400000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps7/Data] $dma_reg_seg -force
assign_bd_address -offset 0x43C00000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps7/Data] $apu_reg_seg -force

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
