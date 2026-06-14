# Create a reproducible Vivado RTL project for PYNQ-Z2.

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]
set fpga_dir   [file join $repo_root fpga]
set project_dir [file join $fpga_dir build vivado]
set project_name riscv_apu_pynq_z2

set firmware_hex [file join $repo_root soc build firmware.hex]
set model_hex    [file join $repo_root soc build model.hex]

foreach required_file [list $firmware_hex $model_hex] {
  if {![file exists $required_file]} {
    error "Missing $required_file. Run: make -C $repo_root/soc firmware model"
  }
}

file mkdir [file dirname $project_dir]
create_project -force $project_name $project_dir -part xc7z020clg400-1
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]

set design_sources [list \
  [file join $repo_root third_party picorv32 picorv32.v] \
]
set design_sources [concat $design_sources [lsort [glob [file join $repo_root soc rtl *.sv]]]]
set design_sources [concat $design_sources [lsort [glob [file join $repo_root rtl *.sv]]]]
set design_sources [concat $design_sources [lsort [glob [file join $fpga_dir rtl *.sv]]]]

add_files -norecurse -fileset sources_1 $design_sources
foreach source_file [get_files -of_objects [get_filesets sources_1]] {
  if {[string equal [file extension $source_file] ".sv"]} {
    set_property file_type SystemVerilog $source_file
  }
}

# Vivado copies memory-initialization files into the synthesis/implementation runs,
# so RTL can use the stable basenames firmware.hex and model.hex.
add_files -norecurse -fileset sources_1 [list $firmware_hex $model_hex]
set_property file_type {Memory Initialization Files} [get_files firmware.hex]
set_property file_type {Memory Initialization Files} [get_files model.hex]

add_files -norecurse -fileset constrs_1 [file join $fpga_dir constraints pynq_z2.xdc]
set_property target_constrs_file [get_files pynq_z2.xdc] [get_filesets constrs_1]

set_property top pynq_z2_top [get_filesets sources_1]

# The XC7Z020 BRAM budget cannot hold both the full model image and 64 independent
# 256x64 weight RAMs as block RAM. This board build maps weight RAMs to LUTRAM.
set_property verilog_define {FPGA_DISTRIBUTED_WEIGHT_RAM} [get_filesets sources_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Vivado project created: [file join $project_dir ${project_name}.xpr]"
puts "Top: pynq_z2_top"
puts "Part: xc7z020clg400-1"
puts "SoC clock: 25 MHz generated from the 125 MHz board clock by MMCME2_BASE"
puts "Architecture: pure RTL in PL; no block design and no Processing System instance"
puts "Board debug: BTN1 lamp test, SW0/SW1 debug-code selection, LEDs and RGB status"
