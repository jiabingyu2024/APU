// Board-visible diagnostics for the pure-PL SoC. The normal acceptance path
// needs no UART: switches select status or firmware progress-code display.
module pynq_z2_debug_display (
    input  logic       clk_i,
    input  logic       resetn_i,
    input  logic       clock_locked_i,
    input  logic       lamp_test_i,
    input  logic [1:0] sw_i,
    input  logic       done_i,
    input  logic       fail_i,
    input  logic       trap_i,
    input  logic       apu_seen_i,
    input  logic [7:0] debug_code_i,
    output logic [3:0] led_o,
    output logic       rgb0_r_n_o,
    output logic       rgb0_g_n_o,
    output logic       rgb0_b_n_o,
    output logic       rgb1_r_n_o,
    output logic       rgb1_g_n_o,
    output logic       rgb1_b_n_o
);

  logic [23:0] heartbeat_q;
  logic        heartbeat;
  logic        pwm_on;
  logic        cpu_alive;
  logic        running;

  always_ff @(posedge clk_i or negedge resetn_i) begin
    if (!resetn_i) begin
      heartbeat_q <= '0;
    end else begin
      heartbeat_q <= heartbeat_q + 1'b1;
    end
  end

  assign heartbeat = heartbeat_q[23];
  assign pwm_on     = heartbeat_q[5:4] == 2'b00;
  assign cpu_alive  = debug_code_i != 8'h00;
  assign running    = cpu_alive && !done_i && !fail_i && !trap_i;

  always_comb begin
    if (lamp_test_i) begin
      // This path is combinational so BTN1 can verify the four LED pins even
      // when H16/MMCM is not running.
      led_o = 4'hf;
    end else if (sw_i[0]) begin
      led_o = sw_i[1] ? debug_code_i[7:4] : debug_code_i[3:0];
    end else begin
      led_o[0] = done_i;
      led_o[1] = fail_i || trap_i;
      led_o[2] = apu_seen_i;
      led_o[3] = clock_locked_i && resetn_i && heartbeat;
    end
  end

  // RGB LEDs are active low. Limit every asserted channel to 25% duty cycle.
  // LD4: global result/running state. LD5: detailed activity indicators.
  assign rgb0_r_n_o = ~(pwm_on && (fail_i || trap_i));
  assign rgb0_g_n_o = ~(pwm_on && done_i);
  assign rgb0_b_n_o = ~(pwm_on && running);

  assign rgb1_r_n_o = ~(pwm_on && trap_i);
  assign rgb1_g_n_o = ~(pwm_on && cpu_alive);
  assign rgb1_b_n_o = ~(pwm_on && apu_seen_i);

endmodule
