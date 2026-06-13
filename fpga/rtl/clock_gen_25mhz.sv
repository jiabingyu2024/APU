// PYNQ-Z2 clock adapter: convert the external 125 MHz PL clock to the
// 25 MHz clock used by the initial board validation build.
module clock_gen_25mhz (
    input  logic clk_125mhz_i,
    input  logic reset_i,
    output logic clk_25mhz_o,
    output logic locked_o
);

`ifdef SYNTHESIS
  logic clk_125mhz_buf;
  logic clk_25mhz_mmcm;
  logic clk_feedback;
  logic clk_feedback_buf;

  IBUF u_clk_ibuf (
      .I(clk_125mhz_i),
      .O(clk_125mhz_buf)
  );

  // VCO = 125 MHz * 8 = 1000 MHz; CLKOUT0 = 1000 MHz / 40 = 25 MHz.
  MMCME2_BASE #(
      .BANDWIDTH         ("OPTIMIZED"),
      .CLKFBOUT_MULT_F   (8.0),
      .CLKIN1_PERIOD     (8.0),
      .CLKOUT0_DIVIDE_F  (40.0),
      .DIVCLK_DIVIDE     (1),
      .STARTUP_WAIT      ("FALSE")
  ) u_mmcm (
      .CLKIN1  (clk_125mhz_buf),
      .CLKFBIN (clk_feedback_buf),
      .RST     (reset_i),
      .PWRDWN  (1'b0),
      .CLKFBOUT(clk_feedback),
      .CLKOUT0 (clk_25mhz_mmcm),
      .LOCKED  (locked_o)
  );

  BUFG u_feedback_bufg (
      .I(clk_feedback),
      .O(clk_feedback_buf)
  );

  BUFG u_clk_25mhz_bufg (
      .I(clk_25mhz_mmcm),
      .O(clk_25mhz_o)
  );
`else
  // Non-Vivado tools do not provide the 7-series MMCM primitives. This branch
  // is used only for structural lint; functional SoC tests use their own clock.
  assign clk_25mhz_o = clk_125mhz_i;
  assign locked_o = !reset_i;
`endif

endmodule
