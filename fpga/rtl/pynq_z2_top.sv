// PYNQ-Z2 专用纯 PL 顶层：不实例化 Zynq Processing System。
module pynq_z2_top (
    input  logic       clk_125mhz_i,
    input  logic       btn0_i,
    input  logic       btn1_i,
    input  logic [1:0] sw_i,
    output logic       uart_tx_o,
    output logic [3:0] led_o,
    output logic       rgb0_r_n_o,
    output logic       rgb0_g_n_o,
    output logic       rgb0_b_n_o,
    output logic       rgb1_r_n_o,
    output logic       rgb1_g_n_o,
    output logic       rgb1_b_n_o
);

  logic resetn_board;
  logic clk_25mhz;
  logic clock_locked;
  logic trap;
  logic done;
  logic fail;
  logic soc_resetn;
  logic apu_done_pulse;
  logic apu_seen_q;
  logic [7:0] debug_code;

  clock_gen_25mhz u_clock_gen (
      .clk_125mhz_i(clk_125mhz_i),
      .reset_i     (btn0_i),
      .clk_25mhz_o (clk_25mhz),
      .locked_o    (clock_locked)
  );

  // 按键按下或 MMCM 尚未锁定时均保持复位，避免 CPU 在不稳定时钟下取指。
  assign resetn_board = ~btn0_i && clock_locked;

  riscv_apu_board_top #(
      .CLK_HZ            (25_000_000),
      .UART_BAUD         (115_200),
      .FIRMWARE_INIT_FILE("firmware.hex"),
      .MODEL_INIT_FILE   ("model.hex")
  ) u_board (
      .clk_i     (clk_25mhz),
      .resetn_i  (resetn_board),
      .uart_tx_o (uart_tx_o),
      .trap_o    (trap),
      .done_o    (done),
      .fail_o    (fail),
      .apu_done_o(apu_done_pulse),
      .debug_code_o(debug_code),
      .soc_resetn_o(soc_resetn)
  );

  // APU 完成信号只有一个脉冲，锁存后再接 LED，按 BTN0 清除。
  always_ff @(posedge clk_25mhz or negedge soc_resetn) begin
    if (!soc_resetn) begin
      apu_seen_q <= 1'b0;
    end else if (apu_done_pulse) begin
      apu_seen_q <= 1'b1;
    end
  end

  pynq_z2_debug_display u_debug_display (
      .clk_i         (clk_25mhz),
      .resetn_i      (soc_resetn),
      .clock_locked_i(clock_locked),
      .lamp_test_i   (btn1_i),
      .sw_i          (sw_i),
      .done_i        (done),
      .fail_i        (fail),
      .trap_i        (trap),
      .apu_seen_i    (apu_seen_q),
      .debug_code_i  (debug_code),
      .led_o         (led_o),
      .rgb0_r_n_o    (rgb0_r_n_o),
      .rgb0_g_n_o    (rgb0_g_n_o),
      .rgb0_b_n_o    (rgb0_b_n_o),
      .rgb1_r_n_o    (rgb1_r_n_o),
      .rgb1_g_n_o    (rgb1_g_n_o),
      .rgb1_b_n_o    (rgb1_b_n_o)
  );

endmodule
