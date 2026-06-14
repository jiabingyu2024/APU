set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir project loopback]]
if {[info exists ::env(APU_DMA_PROJECT_DIR)]} {
    set project_dir [file normalize $::env(APU_DMA_PROJECT_DIR)]
}

set project_name apu_dma_loopback
set design_name dma_loopback_bd
set part_name xc7z020clg400-1
set board_name tul.com.tw:pynq-z2:part0:1.0

create_project $project_name $project_dir -part $part_name -force
if {[llength [get_board_parts -quiet $board_name]] == 0} {
    error "Required board part not installed: $board_name"
}
set_property BOARD_PART $board_name [current_project]

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
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ctrl_smc
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

set axis_fifo [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_data_fifo_0]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {8} \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
] $axis_fifo

set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
set_property -dict [list CONFIG.NUM_PORTS {2}] $irq_concat

connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] [get_bd_intf_pins $ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $ctrl_smc/M00_AXI] [get_bd_intf_pins $dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_MM2S] [get_bd_intf_pins $mm2s_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $mm2s_smc/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP0]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_S2MM] [get_bd_intf_pins $s2mm_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $s2mm_smc/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP1]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] [get_bd_intf_pins $axis_fifo/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins $axis_fifo/M_AXIS] [get_bd_intf_pins $dma/S_AXIS_S2MM]

connect_bd_net [get_bd_pins $dma/mm2s_introut] [get_bd_pins $irq_concat/In0]
connect_bd_net [get_bd_pins $dma/s2mm_introut] [get_bd_pins $irq_concat/In1]
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
    [get_bd_pins $axis_fifo/s_axis_aclk] \
    [get_bd_pins $rst/slowest_sync_clk]

connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]
set peripheral_resetn [get_bd_pins $rst/peripheral_aresetn]
connect_bd_net $peripheral_resetn \
    [get_bd_pins $ctrl_smc/aresetn] \
    [get_bd_pins $mm2s_smc/aresetn] \
    [get_bd_pins $s2mm_smc/aresetn] \
    [get_bd_pins $dma/axi_resetn] \
    [get_bd_pins $axis_fifo/s_axis_aresetn]

assign_bd_address
set dma_reg_seg [get_bd_addr_segs -quiet $dma/S_AXI_LITE/Reg]
if {[llength $dma_reg_seg] != 1} {
    error "Unable to identify AXI DMA register address segment"
}
assign_bd_address -offset 0x40400000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps7/Data] $dma_reg_seg -force

validate_bd_design
save_bd_design
generate_target all [get_files ${design_name}.bd]

set wrapper_files [make_wrapper -files [get_files ${design_name}.bd] -top]
add_files -norecurse $wrapper_files
set_property top ${design_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

set reports_dir [file normalize [file join $script_dir reports loopback]]
file mkdir $reports_dir
report_ip_status -file [file join $reports_dir ip_status.rpt]

puts "DMA_LOOPBACK_PROJECT=$project_dir/$project_name.xpr"
puts "DMA_LOOPBACK_STATUS=BD_VALIDATED"
close_project
exit
