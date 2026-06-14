# Package the APU DMA RTL as a reusable Vivado User IP.

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set build_dir [file normalize [file join $script_dir work ip_pack]]
if {[info exists ::env(APU_DMA_IP_BUILD_DIR)]} {
    set build_dir [file normalize $::env(APU_DMA_IP_BUILD_DIR)]
}
set ip_repo_root [file normalize [file join $script_dir ip_repo]]
if {[info exists ::env(APU_DMA_IP_REPO)]} {
    set ip_repo_root [file normalize $::env(APU_DMA_IP_REPO)]
}
set ip_root [file join $ip_repo_root APU_DMA]

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
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -quiet $core
ipx::save_core $core

puts "APU_DMA_IP_PACKAGED=$ip_root"
puts "APU_DMA_IP_VLNV=apu.local:user:apu_dma:1.0"
close_project
