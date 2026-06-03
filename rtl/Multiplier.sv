`timescale 1ns/1ps

module Multiplier #(
    parameter int P_INNUM       = 64,
    parameter int P_INBITWIDTH  = 1,
    parameter int P_OUTBITWIDTH = 1
) (
    input  logic [P_INNUM-1:0][P_INBITWIDTH-1:0]  iDataA,
    input  logic [P_INNUM-1:0][P_INBITWIDTH-1:0]  iDataB,
    output logic [P_INNUM-1:0][P_OUTBITWIDTH-1:0] oData
);

  genvar i;
  generate
    for (i = 0; i < P_INNUM; i = i + 1) begin : gen_mul
      assign oData[i] = iDataA[i] ^ iDataB[i];
    end
  endgenerate

endmodule
