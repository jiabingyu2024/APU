// PYNQ-Z2 专用纯 PL 顶层：不实例化 Zynq Processing System。
module pynq_z2_top (
    input  logic       clk_125mhz_i,
    input  logic       btn0_i,
    output logic       uart_tx_o,
    output logic [3:0] led_o
);

  logic resetn_board;
  logic clk_25mhz;
  logic clock_locked;
  logic trap;
  logic done;
  logic apu_done_pulse;
  logic apu_seen_q;

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
      .apu_done_o(apu_done_pulse)
  );

  // APU 完成信号只有一个脉冲，锁存后再接 LED，按 BTN0 清除。
  always_ff @(posedge clk_25mhz or negedge resetn_board) begin
    if (!resetn_board) begin
      apu_seen_q <= 1'b0;
    end else if (apu_done_pulse) begin
      apu_seen_q <= 1'b1;
    end
  end

  // LED0: 全部固件检查通过；LED1: CPU trap；LED2: APU 至少完成过一次；
  // LED3: 25 MHz 时钟已锁定且当前未按复位键。普通 LED 均为高电平点亮。
  assign led_o[0] = done;
  assign led_o[1] = trap;
  assign led_o[2] = apu_seen_q;
  assign led_o[3] = resetn_board;

endmodule
