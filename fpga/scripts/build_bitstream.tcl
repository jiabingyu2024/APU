# Build bitstream and export reports for the PYNQ-Z2 pure-PL SoC.

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]
set fpga_dir   [file join $repo_root fpga]
set output_dir [file join $fpga_dir output]
set report_dir [file join $output_dir reports]
set jobs 4
if {$argc >= 1} {
  set jobs [lindex $argv 0]
}

source [file join $script_dir create_project.tcl]
file mkdir $output_dir
file mkdir $report_dir

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
  error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

open_run synth_1
report_utilization -hierarchical -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
  -file [file join $report_dir post_synth_timing_summary.rpt]
report_drc -file [file join $report_dir post_synth_drc.rpt]
close_design

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
  error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_utilization -hierarchical -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 50 -report_unconstrained \
  -file [file join $report_dir post_route_timing_summary.rpt]
report_clock_utilization -file [file join $report_dir post_route_clock_utilization.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_methodology -file [file join $report_dir post_route_methodology.rpt]
write_checkpoint -force [file join $output_dir pynq_z2_top_routed.dcp]

set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set bit_files [glob -nocomplain [file join $impl_dir *.bit]]
if {[llength $bit_files] != 1} {
  error "Expected one bitstream in $impl_dir, found: $bit_files"
}
file copy -force [lindex $bit_files 0] [file join $output_dir riscv_apu_pynq_z2.bit]

# A pure RTL project has no AXI addressable block design, so PYNQ HWH metadata is
# normally absent and unnecessary. XSA is exported when supported by this Vivado version.
if {[catch {
  write_hw_platform -fixed -include_bit -force \
    [file join $output_dir riscv_apu_pynq_z2.xsa]
} xsa_error]} {
  puts "WARNING: XSA export skipped: $xsa_error"
}

set note_file [open [file join $output_dir HWH_NOT_REQUIRED.txt] w]
puts $note_file "This is a pure-RTL, non-AXI design. Use pynq.Bitstream with the .bit file."
puts $note_file "No HWH register map is required because the ARM cannot MMIO-access this SoC."
close $note_file

set worst_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $worst_paths] > 0} {
  set worst_slack [get_property SLACK [lindex $worst_paths 0]]
  puts "Post-route worst setup slack: $worst_slack ns"
  if {$worst_slack < 0.0} {
    puts "WARNING: timing is not closed. Do not treat this bitstream as an acceptance build."
  }
}

puts "Bitstream: [file join $output_dir riscv_apu_pynq_z2.bit]"
puts "Reports:   $report_dir"
close_project
