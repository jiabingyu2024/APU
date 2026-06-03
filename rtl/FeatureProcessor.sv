`timescale 1ns/1ps

module FeatureProcessor #(
    parameter int P_FEATURE_MEMORY_SIZE = 32 * 32 * 64,
    parameter int P_BINDWIDTH           = 64
) (
    input  logic                                                 clk,
    input  logic                                                 nRst,
    input  logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] iReadCenterAddr,
    input  logic [1:0]                                           iKernelSize,
    input  logic [5:0]                                           inHW,
    input  logic [3:0]                                           iDepth,
    input  logic                                                 nWe,
    input  logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] iWriteAddr,
    input  logic [P_BINDWIDTH-1:0]                               iWriteData,
    input  logic                                                 nCe,
    output logic [P_BINDWIDTH-1:0]                               oFeatureData
);

  localparam int P_FEATURE_WORDS = P_FEATURE_MEMORY_SIZE / P_BINDWIDTH;
  localparam int P_ADDR_WIDTH    = $clog2(P_FEATURE_WORDS);

  logic [P_BINDWIDTH-1:0] featureMemory [0:P_FEATURE_WORDS-1];

  logic [31:0] countConvCycles;
  logic [31:0] countDepthCycles;

  logic [P_ADDR_WIDTH-1:0] readAddr;
  logic [P_ADDR_WIDTH-1:0] safeReadAddr;
  logic [P_ADDR_WIDTH-1:0] rowOffset;
  logic [P_ADDR_WIDTH-1:0] colOffset;
  logic [P_ADDR_WIDTH-1:0] rowBase;
  logic [P_ADDR_WIDTH-1:0] rightColBase;
  logic                    kernel3x3;
  logic                    zeroMask;
  logic                    isTop;
  logic                    isBottom;
  logic                    isLeft;
  logic                    isRight;

  integer i;

  // always_ff @(posedge clk or negedge nRst) begin
  //   if (!nRst) begin
  //     for (i = 0; i < P_FEATURE_WORDS; i = i + 1) begin
  //       featureMemory[i] <= '0;
  //     end
  //   end else if (!nWe) begin
  //     featureMemory[iWriteAddr] <= iWriteData;
  //   end
  // end  

  // BRAM write
  always @(posedge clk) begin
    if (!nWe) begin
      featureMemory[iWriteAddr] <= iWriteData;
    end
  end

  // BRAM read
  reg [P_BINDWIDTH-1:0] featureMemory_data_out_reg;
  always @(posedge clk or negedge nRst) begin
    if(!nRst)begin
    featureMemory_data_out_reg<=0;
    end
    else if (!nCe)begin
    featureMemory_data_out_reg<=featureMemory[readAddr];
    end
  end


  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      countConvCycles  <= 32'd0;
      countDepthCycles <= 32'd0;
    end else if (nCe) begin
      countConvCycles  <= 32'd0;
      countDepthCycles <= 32'd0;
    end else if (iDepth <= 4'd1 || countDepthCycles == iDepth - 1'b1) begin
      countDepthCycles <= 32'd0;
      if (iKernelSize == 2'd3 && countConvCycles != 32'd8) begin
        countConvCycles <= countConvCycles + 1'b1;
      end else begin
        countConvCycles <= 32'd0;
      end
    end else begin
      countDepthCycles <= countDepthCycles + 1'b1;
    end
  end



  always_comb begin
    rowOffset   = inHW * iDepth;
    colOffset   = iDepth;
    rowBase     = (rowOffset == '0) ? '0 : iReadCenterAddr % rowOffset;
    rightColBase = (inHW == 6'd0 || iDepth == 4'd0) ? '0 : (inHW - 1'b1) * iDepth;

    kernel3x3 = (iKernelSize == 2'd3);
    isTop     = (iReadCenterAddr < rowOffset);
    isBottom  = (rowOffset == '0) ? 1'b0 :
                (iReadCenterAddr >= ((inHW - 1'b1) * rowOffset));
    isLeft    = (rowBase == '0);
    isRight   = (rowBase == rightColBase);

    zeroMask = 1'b0;
    if (kernel3x3) begin
      case (countConvCycles)
        32'd0: zeroMask = isTop    || isLeft;
        32'd1: zeroMask = isTop;
        32'd2: zeroMask = isTop    || isRight;
        32'd3: zeroMask = isLeft;
        32'd4: zeroMask = 1'b0;
        32'd5: zeroMask = isRight;
        32'd6: zeroMask = isBottom || isLeft;
        32'd7: zeroMask = isBottom;
        32'd8: zeroMask = isBottom || isRight;
        default: zeroMask = 1'b0;
      endcase
    end

    readAddr = iReadCenterAddr + countDepthCycles;
    if (kernel3x3) begin
      case (countConvCycles)
        32'd0: readAddr = iReadCenterAddr + countDepthCycles - rowOffset - colOffset;
        32'd1: readAddr = iReadCenterAddr + countDepthCycles - rowOffset;
        32'd2: readAddr = iReadCenterAddr + countDepthCycles - rowOffset + colOffset;
        32'd3: readAddr = iReadCenterAddr + countDepthCycles - colOffset;
        32'd4: readAddr = iReadCenterAddr + countDepthCycles;
        32'd5: readAddr = iReadCenterAddr + countDepthCycles + colOffset;
        32'd6: readAddr = iReadCenterAddr + countDepthCycles + rowOffset - colOffset;
        32'd7: readAddr = iReadCenterAddr + countDepthCycles + rowOffset;
        32'd8: readAddr = iReadCenterAddr + countDepthCycles + rowOffset + colOffset;
        default: readAddr = iReadCenterAddr + countDepthCycles;
      endcase
    end

    safeReadAddr  = zeroMask ? '0 : readAddr;
    oFeatureData  = (nCe || zeroMask) ? '0 : featureMemory_data_out_reg;
  end

endmodule
