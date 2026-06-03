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

  integer i;

  always_comb begin
    oData = '0;
    for (i = 0; i < P_INNUM; i = i + 1) begin
      oData = oData + {{(P_OUTBITWIDTH-P_INBITWIDTH){1'b0}}, iData[i]};
    end
  end

endmodule
