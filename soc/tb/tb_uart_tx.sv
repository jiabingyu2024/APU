`timescale 1ns/1ps

module tb_uart_tx;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  logic data_valid;
  logic [7:0] data;
  logic data_ready;
  logic tx;

  logic [9:0] expected;

  always #5 clk = ~clk;

  uart_tx #(
      .CLK_HZ(40),
      .BAUD  (10)
  ) dut (
      .clk       (clk),
      .resetn    (resetn),
      .data_valid(data_valid),
      .data      (data),
      .data_ready(data_ready),
      .tx        (tx)
  );

  initial begin
    data_valid = 1'b0;
    data = 8'h00;
    expected = {1'b1, 8'ha5, 1'b0};

    repeat (3) @(posedge clk);
    resetn = 1'b1;
    @(negedge clk);
    if (!data_ready || tx !== 1'b1) $fatal(1, "UART was not idle after reset");

    data = 8'ha5;
    data_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    data_valid = 1'b0;

    for (int bit_index = 0; bit_index < 10; bit_index++) begin
      repeat (2) @(posedge clk);
      if (tx !== expected[bit_index]) begin
        $fatal(1, "UART bit %0d mismatch: got=%0b expected=%0b",
               bit_index, tx, expected[bit_index]);
      end
      repeat (2) @(posedge clk);
    end

    @(negedge clk);
    if (!data_ready || tx !== 1'b1) $fatal(1, "UART did not return idle");
    $display("UART UNIT PASS");
    $finish;
  end

endmodule
