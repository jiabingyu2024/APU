# Package the APU DMA RTL as a reusable Vivado User IP.

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set build_dir [file normalize [file join $script_dir work ip_pack]]
if {[info exists ::env(APU_DMA_IP_BUILD_DIR)]} {
    set build_dir [file normalize $::env(APU_DMA_IP_BUILD_DIR)]
}
set pl_freq_mhz 25.000000
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
set ip_root [file join $ip_repo_root APU_DMA]

puts "APU_DMA_PL_FREQ_MHZ=$pl_freq_mhz"
puts "APU_DMA_PL_FREQ_HZ=$pl_freq_hz"

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

create_project apu_dma_ip_pack $build_dir -part xc7z020clg400-1 -force
set_property target_language Verilog [current_project]
add_files -norecurse [concat $dma_rtl $apu_leaf_rtl]
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] *.sv]
set_property top apu_dma_top [current_fileset]
update_compile_order -fileset sources_1

# Elaborate the RTL before packaging so a syntactically valid component.xml
# cannot hide missing modules or invalid port connections.
synth_design -rtl -top apu_dma_top -part xc7z020clg400-1
close_design

file mkdir $ip_repo_root
ipx::package_project -root_dir $ip_root -vendor apu.local -library user \
    -taxonomy /UserIP -import_files -set_current true -force
set core [ipx::current_core]
set_property name apu_dma $core
set_property display_name {APU DMA Accelerator} $core
set_property description {AXI-Stream DMA wrapper and AXI-Lite control plane for the APU accelerator} $core
set_property vendor_display_name {APU Project} $core
set_property company_url {https://localhost/apu} $core
set_property version 1.0 $core
set_property core_revision 1 $core

foreach busif {S_AXIS_JOB M_AXIS_RESULT S_AXI_CTRL} {
    ipx::associate_bus_interfaces -busif $busif -clock aclk $core
}
set aclk_busif [ipx::get_bus_interfaces ACLK -of_objects $core]
if {[llength $aclk_busif] != 1} {
    error "Unable to identify ACLK bus interface in packaged APU DMA IP"
}
set aclk_freq_param [ipx::get_bus_parameters FREQ_HZ -of_objects $aclk_busif]
if {[llength $aclk_freq_param] == 1} {
    set_property value $pl_freq_hz $aclk_freq_param
} else {
    set aclk_freq_param [ipx::add_bus_parameter FREQ_HZ $aclk_busif]
    set_property value $pl_freq_hz $aclk_freq_param
    set_property value_format long $aclk_freq_param
}
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -quiet $core
ipx::save_core $core

puts "APU_DMA_IP_PACKAGED=$ip_root"
puts "APU_DMA_IP_VLNV=apu.local:user:apu_dma:1.0"
close_project
