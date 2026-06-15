`timescale 1ns/1ps

module AdderTree #(
    parameter int P_INNUM        = 64,
    parameter int P_INBITWIDTH   = 1,
    parameter int P_STAGES       = $clog2(P_INNUM),
    parameter int P_OUTBITWIDTH  = P_INBITWIDTH + P_STAGES
) (
    input  logic [P_INNUM-1:0][P_INBITWIDTH-1:0] iData,
    output logic [P_OUTBITWIDTH-1:0]             oData
);

  generate
    if (P_INNUM == 64) begin : gen_balanced64
      logic [31:0][P_INBITWIDTH:0]   sum2;
      logic [15:0][P_INBITWIDTH+1:0] sum4;
      logic [ 7:0][P_INBITWIDTH+2:0] sum8;
      logic [ 3:0][P_INBITWIDTH+3:0] sum16;
      logic [ 1:0][P_INBITWIDTH+4:0] sum32;
      logic [      P_INBITWIDTH+5:0] sum64;

      genvar g;
      for (g = 0; g < 32; g = g + 1) begin : gen_sum2
        assign sum2[g] = {1'b0, iData[(2*g)]} +
                         {1'b0, iData[(2*g)+1]};
      end
      for (g = 0; g < 16; g = g + 1) begin : gen_sum4
        assign sum4[g] = {1'b0, sum2[(2*g)]} +
                         {1'b0, sum2[(2*g)+1]};
      end
      for (g = 0; g < 8; g = g + 1) begin : gen_sum8
        assign sum8[g] = {1'b0, sum4[(2*g)]} +
                         {1'b0, sum4[(2*g)+1]};
      end
      for (g = 0; g < 4; g = g + 1) begin : gen_sum16
        assign sum16[g] = {1'b0, sum8[(2*g)]} +
                          {1'b0, sum8[(2*g)+1]};
      end
      for (g = 0; g < 2; g = g + 1) begin : gen_sum32
        assign sum32[g] = {1'b0, sum16[(2*g)]} +
                          {1'b0, sum16[(2*g)+1]};
      end

      assign sum64 = {1'b0, sum32[0]} + {1'b0, sum32[1]};
      assign oData = sum64[P_OUTBITWIDTH-1:0];
    end else begin : gen_generic
      integer i;

      always_comb begin
        oData = '0;
        for (i = 0; i < P_INNUM; i = i + 1) begin
          oData = oData + {{(P_OUTBITWIDTH-P_INBITWIDTH){1'b0}}, iData[i]};
        end
      end
    end
  endgenerate

endmodule
