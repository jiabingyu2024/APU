`timescale 1ns/1ps

// Minimal 8-N-1 UART transmitter with valid/ready backpressure.
module uart_tx #(
    parameter int CLK_HZ = 100_000_000,
    parameter int BAUD = 115_200,
    parameter int CLKS_PER_BIT = CLK_HZ / BAUD
) (
    input  logic       clk,
    input  logic       resetn,
    input  logic       data_valid,
    input  logic [7:0] data,
    output logic       data_ready,
    output logic       tx
);

  localparam int COUNT_WIDTH = (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

  logic [9:0] shift_q;
  logic [3:0] bit_q;
  logic [COUNT_WIDTH-1:0] count_q;
  logic busy_q;

  assign data_ready = !busy_q;
  assign tx = busy_q ? shift_q[0] : 1'b1;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      shift_q <= 10'h3ff;
      bit_q   <= '0;
      count_q <= '0;
      busy_q  <= 1'b0;
    end else if (!busy_q) begin
      if (data_valid) begin
        shift_q <= {1'b1, data, 1'b0};
        bit_q   <= '0;
        count_q <= '0;
        busy_q  <= 1'b1;
      end
    end else if (count_q == COUNT_WIDTH'(CLKS_PER_BIT - 1)) begin
      count_q <= '0;
      if (bit_q == 4'd9) begin
        busy_q <= 1'b0;
      end else begin
        shift_q <= {1'b1, shift_q[9:1]};
        bit_q   <= bit_q + 1'b1;
      end
    end else begin
      count_q <= count_q + 1'b1;
    end
  end

endmodule
