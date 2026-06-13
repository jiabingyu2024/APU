# PYNQ-Z2 / xc7z020clg400-1
# 125 MHz PL reference clock from the Ethernet PHY. The board top uses an MMCM
# to generate the 25 MHz CPU/APU clock; Vivado derives that generated clock.
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk_125mhz_i]
create_clock -name clk_125mhz -period 8.000 [get_ports clk_125mhz_i]

# BTN0 is active high. pynq_z2_top converts it to an active-low reset.
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports btn0_i]
set_false_path -from [get_ports btn0_i]

# PL UART TX: PMODB pin 1 (JB1_P). Connect it to an external 3.3 V USB-TTL RX.
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports uart_tx_o]

# LED0=PASS, LED1=TRAP, LED2=APU seen, LED3=25 MHz clock locked/out of reset.
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led_o[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led_o[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led_o[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led_o[3]}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
