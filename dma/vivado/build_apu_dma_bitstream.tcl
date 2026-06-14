# Build the APU DMA project through bitstream generation, emit implementation
# reports, and export the matching BIT/HWH overlay pair.

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file normalize [file join $script_dir project apu_dma]]
if {[info exists ::env(APU_DMA_PROJECT_DIR)]} {
    set project_dir [file normalize $::env(APU_DMA_PROJECT_DIR)]
}

set project_file [file join $project_dir apu_dma.xpr]
if {![file exists $project_file]} {
    error "Project not found: $project_file. Run create_apu_dma_project.tcl first."
}

open_project $project_file
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1

set report_dir [file normalize [file join $script_dir reports apu_dma]]
file mkdir $report_dir
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $report_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $report_dir utilization.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_clock_interaction -file [file join $report_dir clock_interaction.rpt]

source [file join $script_dir export_apu_dma_overlay.tcl]

puts "APU_DMA_STATUS=BITSTREAM_COMPLETE"
puts "APU_DMA_REPORT_DIR=$report_dir"
