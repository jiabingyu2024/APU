set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir project loopback]]
if {[info exists ::env(APU_DMA_PROJECT_DIR)]} {
    set project_dir [file normalize $::env(APU_DMA_PROJECT_DIR)]
}

set project_file [file join $project_dir apu_dma_loopback.xpr]
if {![file exists $project_file]} {
    error "Loopback project not found. Run create_loopback_project.tcl first: $project_file"
}
open_project $project_file

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "Implementation/bitstream failed: [get_property STATUS [get_runs impl_1]]"
}

set reports_dir [file normalize [file join $script_dir reports loopback]]
file mkdir $reports_dir
open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -max_paths 20 -file [file join $reports_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $reports_dir utilization.rpt]
report_drc -file [file join $reports_dir drc.rpt]

set overlay_dir [file normalize [file join $script_dir .. overlay loopback]]
file mkdir $overlay_dir
set bit_file [get_property BITSTREAM.FILE [get_runs impl_1]]
file copy -force $bit_file [file join $overlay_dir apu_dma_loopback.bit]

set hwh_source [file join $project_dir apu_dma_loopback.gen sources_1 bd dma_loopback_bd hw_handoff dma_loopback_bd.hwh]
if {![file exists $hwh_source]} {
    puts "WARNING: No HWH found automatically; export hardware from Vivado GUI."
} else {
    file copy -force $hwh_source [file join $overlay_dir apu_dma_loopback.hwh]
}

puts "DMA_LOOPBACK_STATUS=BITSTREAM_COMPLETE"
puts "DMA_LOOPBACK_OVERLAY=$overlay_dir"
close_project
exit
