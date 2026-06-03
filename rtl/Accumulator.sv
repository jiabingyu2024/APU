`timescale 1ns/1ps

module Accumulator #(
    parameter int P_INBITWIDTH  = 7,
    parameter int P_OUTBITWIDTH = 12
) (
    input  logic                       clk,
    input  logic                       nRst,
    input  logic [1:0]                 inst,
    input  logic [P_INBITWIDTH-1:0]    iData,
    output logic [P_OUTBITWIDTH-1:0]   oData
);

  wire [P_OUTBITWIDTH-1:0] extendData =
      {{(P_OUTBITWIDTH-P_INBITWIDTH){1'b0}}, iData};

  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      oData <= '0;
    end else begin
      case (inst)
        2'b00: oData <= '0;
        2'b01: oData <= extendData;
        2'b10: oData <= oData + extendData;
        2'b11: oData <= oData;
        default: oData <= oData;
      endcase
    end
  end

endmodule
