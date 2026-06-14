# Run this after Generate Bitstream in the opened apu_dma project.

set script_dir [file dirname [file normalize [info script]]]
set overlay_dir [file normalize [file join $script_dir .. overlay]]
file mkdir $overlay_dir

set project_dir [get_property DIRECTORY [current_project]]
set top_name [get_property TOP [get_filesets sources_1]]
set bit_file [file join $project_dir apu_dma.runs impl_1 ${top_name}.bit]
set hwh_file [file join $project_dir apu_dma.gen sources_1 bd apu_dma_bd hw_handoff apu_dma_bd.hwh]

if {![file exists $bit_file]} {
    error "Bitstream not found: $bit_file"
}
if {![file exists $hwh_file]} {
    error "HWH not found: $hwh_file"
}

file copy -force $bit_file [file join $overlay_dir apu_dma.bit]
file copy -force $hwh_file [file join $overlay_dir apu_dma.hwh]

puts "APU_DMA_OVERLAY_EXPORTED=$overlay_dir"
puts "Copy the complete dma/ directory to the PYNQ board before running tests."
