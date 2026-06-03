module SIMD #(

    parameter P_CHANNELS = 64,
    parameter P_COMPAREWIDTH = 13,
    parameter P_TOTAL64BN = 32

) (
    input                                                      clk,
    input                                                      nRst,
    input                                                      nWe,
    input        [$clog2(P_TOTAL64BN)-1:0]                     iWriteAddr,
    input        [ $clog2(P_CHANNELS)-1:0]                     iChannel,
    input        [     P_COMPAREWIDTH-1:0]                     iWriteData,
    input        [$clog2(P_TOTAL64BN)-1:0]                     iAddr,
    input        [         P_CHANNELS-1:0][P_COMPAREWIDTH-2:0] iAccData,
    output       [     P_COMPAREWIDTH-1:0]                     oReadData,
    output logic [         P_CHANNELS-1:0]                     oSIMDData

);
  reg [P_COMPAREWIDTH-1:0] SIMD_Reg[P_TOTAL64BN-1:0][P_CHANNELS-1:0];
  reg [P_CHANNELS-1:0] SIMD_Temp;
  //   reg [P_COMPAREWIDTH-2:0] compare;
  always @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      foreach (SIMD_Reg[i, j]) begin
        SIMD_Reg[i][j] <= 0;
      end
    end else if (!nWe) begin
      SIMD_Reg[iWriteAddr][iChannel] <= iWriteData;
    end
  end
  genvar gv_i;
  generate
    for (gv_i = 0; gv_i < P_CHANNELS; gv_i++) begin
      // SIMD_Temp[gv_i]=()
      always @(*) begin
        SIMD_Temp[gv_i] = (iAccData[gv_i] > SIMD_Reg[iAddr][gv_i][P_COMPAREWIDTH-2:0]) ? 1 : 0;
        oSIMDData[gv_i] = (SIMD_Reg[iAddr][gv_i][P_COMPAREWIDTH-1] == 1'b1) ? SIMD_Temp[gv_i] : (~SIMD_Temp[gv_i]);//我的问题？
      end
    end
  endgenerate
  assign oReadData = SIMD_Reg[iAddr][iChannel];
endmodule
