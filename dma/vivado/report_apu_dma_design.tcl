# Export implementation reports from an open, implemented APU DMA project.

set script_dir [file dirname [file normalize [info script]]]
set report_dir [file normalize [file join $script_dir reports apu_dma]]
file mkdir $report_dir

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation is not complete. Run Implementation before exporting reports."
}

open_run impl_1
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $report_dir timing_summary.rpt]
report_utilization -hierarchical -file [file join $report_dir utilization.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_clock_interaction -file [file join $report_dir clock_interaction.rpt]

puts "APU_DMA_REPORTS_EXPORTED=$report_dir"
