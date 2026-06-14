// Generic PL-only board wrapper. Vivado work is limited to selecting the
// actual clock/reset pins, setting CLK_HZ, and constraining uart_tx_o/status.
module riscv_apu_board_top #(
    parameter int CLK_HZ = 100_000_000,
    parameter int UART_BAUD = 115_200,
    parameter string FIRMWARE_INIT_FILE = "soc/build/firmware.hex",
    parameter string MODEL_INIT_FILE = "soc/build/model.hex"
) (
    input  logic clk_i,
    input  logic resetn_i,
    output logic uart_tx_o,
    output logic trap_o,
    output logic done_o,
    output logic fail_o,
    output logic apu_done_o,
    output logic [7:0] debug_code_o,
    output logic soc_resetn_o
);

  // 异步按键复位进入时钟域后同步释放，便于 Vivado 正确放置同步寄存器。
  (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync_q;
  logic       resetn;
  logic       console_tx_ready;
  logic       console_tx_valid;
  logic [7:0] console_tx_data;
  logic       sim_done;
  logic [31:0] sim_exit_code;
  logic       bus_fault;
  logic [31:0] bus_fault_addr;
  logic       timer_irq;
  logic       apu_access_fault;
  logic [31:0] apu_fault_addr;

  always_ff @(posedge clk_i or negedge resetn_i) begin
    if (!resetn_i) begin
      reset_sync_q <= 2'b00;
    end else begin
      reset_sync_q <= {reset_sync_q[0], 1'b1};
    end
  end
  assign resetn = reset_sync_q[1];
  assign soc_resetn_o = resetn;

  riscv_apu_soc_top #(
      .FIRMWARE_INIT_FILE(FIRMWARE_INIT_FILE),
      .MODEL_INIT_FILE   (MODEL_INIT_FILE)
  ) u_soc (
      .clk             (clk_i),
      .resetn          (resetn),
      .trap            (trap_o),
      .console_tx_ready(console_tx_ready),
      .console_tx_valid(console_tx_valid),
      .console_tx_data (console_tx_data),
      .debug_code      (debug_code_o),
      .sim_done        (sim_done),
      .sim_exit_code   (sim_exit_code),
      .bus_fault       (bus_fault),
      .bus_fault_addr  (bus_fault_addr),
      .timer_irq       (timer_irq),
      .apu_access_fault(apu_access_fault),
      .apu_fault_addr  (apu_fault_addr),
      .apu_int_cal     (apu_done_o)
  );

  uart_tx #(
      .CLK_HZ(CLK_HZ),
      .BAUD  (UART_BAUD)
  ) u_uart_tx (
      .clk       (clk_i),
      .resetn    (resetn),
      .data_valid(console_tx_valid),
      .data      (console_tx_data),
      .data_ready(console_tx_ready),
      .tx        (uart_tx_o)
  );

  // The firmware writes EXIT only after all checks pass. On hardware this
  // output can drive an LED; sim_exit_code remains available for debug probes.
  assign done_o = sim_done && (sim_exit_code == 32'b0);
  assign fail_o = trap_o || debug_code_o[7] ||
                  (sim_done && (sim_exit_code != 32'b0));

  logic unused_status;
  assign unused_status = bus_fault | timer_irq | apu_access_fault |
                         (|bus_fault_addr) | (|apu_fault_addr);

endmodule
