`timescale 1ns/1ps

module WeightBuffer #(
    parameter int P_INNUM = 64
) (
    input  logic               clk,
    input  logic               nRst,
    input  logic               enable,
    input  logic [P_INNUM-1:0] iData,
    output logic [P_INNUM-1:0] oData
);

  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      oData <= '0;
    end else if (enable) begin
      oData <= iData;
    end
  end

endmodule
