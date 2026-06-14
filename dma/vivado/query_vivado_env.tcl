create_project query_dma D:/APU_dma_query/query_project -part xc7z020clg400-1 -force
set board_matches [get_board_parts -quiet *pynq-z2*]
puts "DMA_QUERY BOARD_PARTS=$board_matches"
puts "DMA_QUERY AXI_DMA=[get_ipdefs -all -quiet xilinx.com:ip:axi_dma:*]"
puts "DMA_QUERY AXIS_FIFO=[get_ipdefs -all -quiet xilinx.com:ip:axis_data_fifo:*]"
puts "DMA_QUERY SMARTCONNECT=[get_ipdefs -all -quiet xilinx.com:ip:smartconnect:*]"
puts "DMA_QUERY PS7=[get_ipdefs -all -quiet xilinx.com:ip:processing_system7:*]"

create_bd_design query_bd
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_query]
foreach property_name [lsort [list_property $dma]] {
    if {[string match "CONFIG.*" $property_name]} {
        puts "DMA_PROPERTY $property_name=[get_property $property_name $dma]"
    }
}
close_project
exit
