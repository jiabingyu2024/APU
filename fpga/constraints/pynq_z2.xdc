# PYNQ-Z2 / xc7z020clg400-1
# 125 MHz PL reference clock from the Ethernet PHY. The board top uses an MMCM
# to generate the 25 MHz CPU/APU clock; Vivado derives that generated clock.
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk_125mhz_i]
create_clock -name clk_125mhz -period 8.000 [get_ports clk_125mhz_i]

# BTN0 is active high reset. BTN1 is a combinational four-LED lamp test.
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports btn0_i]
set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} [get_ports btn1_i]
set_false_path -from [get_ports btn0_i]
set_false_path -from [get_ports btn1_i]

# SW0 selects status/code display. SW1 selects the low/high debug-code nibble.
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports {sw_i[0]}]
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports {sw_i[1]}]
set_false_path -from [get_ports {sw_i[*]}]

# Optional PL UART TX on PMODB pin 1 (JB1_P); not used by the LED/RGB acceptance flow.
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports uart_tx_o]

# SW0=0: LED0=PASS, LED1=FAIL/TRAP, LED2=APU seen, LED3=25 MHz heartbeat.
# SW0=1: LED[3:0] shows debug-code low nibble (SW1=0) or high nibble (SW1=1).
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led_o[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led_o[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led_o[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports {led_o[3]}]

# Board RGB LEDs are active low. RTL applies 25% PWM to limit brightness.
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports rgb0_r_n_o]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports rgb0_g_n_o]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports rgb0_b_n_o]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports rgb1_r_n_o]
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports rgb1_g_n_o]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33 DRIVE 8 SLEW SLOW} [get_ports rgb1_b_n_o]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
