module Ctrl #(
    parameter P_BINDWIDTH = 64,
    parameter P_FEATURE_MEMORY_SIZE = 65536
) (
    input clk,
    input nRst,
    input nCe,

    //From Instruction Registerfile
    input [31:0] iInstruction,

    //For ActSRAM
    output     [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oActReadCenterAddr,
    output                                                     oActReadEn,
    output     [                                          1:0] oActKernelSize,
    output     [                                          5:0] oActHW,
    output     [                                          3:0] oActlogInC,
    output reg [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oActWriteAddr,       //need delay 3 cycle
    output reg                                                 oActWriteEn,         //need delay 2 cycle
    //For InputBuf
    output reg                                                 oInputBufNWe,        //need delay 1 cycle
    output reg                                                 oInputBufSelect,     //need delay 1 cycle

    //For OutSRAM
    output     [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oOutReadCenterAddr,
    output                                                     oOutReadEn,
    output     [                                          1:0] oOutKernelSize,
    output     [                                          5:0] oOutHW,
    output     [                                          3:0] oOutlogInC,
    output reg [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oOutWriteAddr,       //need delay 3 cycle
    output reg                                                 oOutWriteEn,         //need delay 2 cycle
    //For SIMD
    output reg [                                          4:0] oBNAddr,
    //For ComputeCoreGroup
    output reg [                                          7:0] oWeightAddr,
    output reg                                                 oWeightReadEn,
    output reg [                                          1:0] oAccInstr,           // 00 for reset, 01 for assign value, 10 for accumulate, 11 for hold on value
    //For WorkSheet to fetch next Instruction
    output reg                                                 oComputeDone
);

  localparam P_ADDR_WIDTH = $clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH);
  localparam P_BIND_LOG2  = $clog2(P_BINDWIDTH);

  localparam IDLE = 1'b0;
  localparam CONV = 1'b1;

  localparam ACC_RESET = 2'b00;
  localparam ACC_LOAD  = 2'b01;
  localparam ACC_ADD   = 2'b10;
  localparam ACC_HOLD  = 2'b11;

  reg state;
  reg pingpong;

  wire [1:0] opcode;
  wire [1:0] kernelSize;
  wire [2:0] inHWLog;
  wire [3:0] inCLog;
  wire [3:0] outCLog;
  wire [1:0] stride1Code;
  wire [1:0] stride2Code;
  wire [7:0] weightBaseAddr;
  wire [4:0] bnBaseAddr;

  wire normalConv;
  wire residualConv;
  wire [5:0] inHW;
  wire [5:0] outHW;
  wire [3:0] inGroup;
  wire [3:0] outGroup;
  wire [1:0] stride;
  wire [3:0] kernelCycle;

  reg [31:0] cycle;
  reg [31:0] t;
  reg [31:0] round;
  wire [31:0] cyclePerTime;
  wire [31:0] timePerRound;
  wire [31:0] totalRound;

  wire [31:0] pixelRow;
  wire [31:0] pixelCol;
  wire [31:0] readCenterAddr;
  wire [31:0] writeAddrNow;
  wire [31:0] weightAddrNow;

  reg [P_ADDR_WIDTH-1:0] writeAddr;
  reg                    writeEn;
  reg                    writeSelect;       // 0: write OutSRAM, 1: write ActSRAM
  reg                    inputBufNWe;
  reg                    inputBufSelect;

  reg [P_ADDR_WIDTH-1:0] writeAddrDelay1;
  reg [P_ADDR_WIDTH-1:0] writeAddrDelay2;
  reg [P_ADDR_WIDTH-1:0] writeAddrDelay3;
  reg                    writeEnDelay1;
  reg                    writeEnDelay2;
  reg                    writeSelectDelay1;
  reg                    writeSelectDelay2;
  reg                    writeSelectDelay3;
  reg                    inputBufNWeDelay1;
  reg                    inputBufSelectDelay1;

  assign opcode         = iInstruction[31:30];
  assign kernelSize     = iInstruction[29:28];
  assign inHWLog        = iInstruction[27:25];
  assign inCLog         = iInstruction[24:21];
  assign outCLog        = iInstruction[20:17];
  assign stride1Code    = iInstruction[16:15];
  assign stride2Code    = iInstruction[14:13];
  assign weightBaseAddr = iInstruction[12:5];
  assign bnBaseAddr     = iInstruction[4:0];

  assign normalConv   = (opcode == 2'b00);
  assign residualConv = (opcode == 2'b01);

  assign inHW        = 6'd1 << inHWLog;
  assign inGroup     = (inCLog > P_BIND_LOG2[3:0]) ? (4'd1 << (inCLog - P_BIND_LOG2[3:0])) : 4'd1;
  assign outGroup    = (outCLog > P_BIND_LOG2[3:0]) ? (4'd1 << (outCLog - P_BIND_LOG2[3:0])) : 4'd1;
  assign stride      = normalConv ? ((stride1Code == 2'b10) ? 2'd2 : 2'd1)
                                  : ((stride2Code == 2'b11) ? 2'd2 : 2'd1);
  assign outHW       = inHW >> (stride - 1'b1);
  assign kernelCycle = (kernelSize == 2'd3) ? 4'd9 : 4'd1;

  // round: output pixel, t: 64-output-channel block, cycle: MAC accumulation.
  assign cyclePerTime = kernelCycle * inGroup - 1'b1;
  assign timePerRound = outGroup - 1'b1;
  assign totalRound   = outHW * outHW - 1'b1;

  assign pixelRow       = round / outHW;
  assign pixelCol       = round % outHW;
  assign readCenterAddr = ((pixelRow * stride) * inHW + (pixelCol * stride)) * inGroup;
  assign writeAddrNow   = round * outGroup + t;
  assign weightAddrNow  = weightBaseAddr + t * (kernelCycle * inGroup) + cycle;

  assign oActReadCenterAddr = readCenterAddr[P_ADDR_WIDTH-1:0];
  assign oOutReadCenterAddr = readCenterAddr[P_ADDR_WIDTH-1:0];
  assign oActReadEn         = (state == CONV) && (!pingpong || residualConv);
  assign oOutReadEn         = (state == CONV) && ( pingpong || residualConv);
  assign oActKernelSize     = kernelSize;
  assign oOutKernelSize     = kernelSize;
  assign oActHW             = inHW;
  assign oOutHW             = inHW;
  assign oActlogInC         = inCLog;
  assign oOutlogInC         = inCLog;

  always @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      writeAddrDelay1      <= '0;
      writeAddrDelay2      <= '0;
      writeAddrDelay3      <= '0;
      writeEnDelay1        <= 1'b0;
      writeEnDelay2        <= 1'b0;
      writeSelectDelay1    <= 1'b0;
      writeSelectDelay2    <= 1'b0;
      writeSelectDelay3    <= 1'b0;
      inputBufNWeDelay1    <= 1'b1;
      inputBufSelectDelay1 <= 1'b0;
      oActWriteAddr        <= '0;
      oActWriteEn          <= 1'b0;
      oOutWriteAddr        <= '0;
      oOutWriteEn          <= 1'b0;
      oInputBufNWe         <= 1'b1;
      oInputBufSelect      <= 1'b0;
    end else begin
      writeAddrDelay1      <= writeAddr;
      writeAddrDelay2      <= writeAddrDelay1;
      writeAddrDelay3      <= writeAddrDelay2;
      writeEnDelay1        <= writeEn;
      writeEnDelay2        <= writeEnDelay1;
      writeSelectDelay1    <= writeSelect;
      writeSelectDelay2    <= writeSelectDelay1;
      writeSelectDelay3    <= writeSelectDelay2;
      inputBufNWeDelay1    <= inputBufNWe;
      inputBufSelectDelay1 <= inputBufSelect;

      oInputBufNWe    <= inputBufNWeDelay1;
      oInputBufSelect <= inputBufSelectDelay1;

      oActWriteEn <= writeEnDelay2 && writeSelectDelay2;
      oOutWriteEn <= writeEnDelay2 && !writeSelectDelay2;
      if (writeSelectDelay3) begin
        oActWriteAddr <= writeAddrDelay3;
      end else begin
        oOutWriteAddr <= writeAddrDelay3;
      end
    end
  end

  always @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      state          <= IDLE;
      pingpong       <= 1'b0;
      cycle          <= 32'd0;
      t              <= 32'd0;
      round          <= 32'd0;
      writeAddr      <= '0;
      writeEn        <= 1'b0;
      writeSelect    <= 1'b0;
      inputBufNWe    <= 1'b1;
      inputBufSelect <= 1'b0;
      oBNAddr        <= 5'd0;
      oWeightAddr    <= 8'd0;
      oWeightReadEn  <= 1'b0;
      oAccInstr      <= ACC_HOLD;
      oComputeDone   <= 1'b0;
    end else begin
      writeAddr      <= writeAddrNow[P_ADDR_WIDTH-1:0];
      writeEn        <= 1'b0;
      writeSelect    <= pingpong;
      inputBufNWe    <= 1'b1;
      inputBufSelect <= pingpong;
      oWeightReadEn  <= 1'b0;
      oAccInstr      <= ACC_HOLD;

      case (state)
        IDLE: begin
          cycle <= 32'd0;
          t     <= 32'd0;
          round <= 32'd0;

          if (oComputeDone) begin
            oComputeDone <= 1'b0;
          end else if (!nCe) begin
            state         <= CONV;
            inputBufNWe   <= 1'b0;
            oWeightReadEn <= 1'b1;
            oWeightAddr   <= weightBaseAddr;
            oBNAddr       <= bnBaseAddr;
            oAccInstr     <= ACC_LOAD;
          end
        end

        CONV: begin  // Normal Conv1
          inputBufNWe   <= 1'b0;
          oWeightReadEn <= 1'b1;
          oWeightAddr   <= weightAddrNow[7:0];
          oBNAddr       <= bnBaseAddr + t[4:0];
          oAccInstr     <= (cycle == 32'd0) ? ACC_LOAD : ACC_ADD;

          if (round < totalRound) begin
            if (t < timePerRound) begin
              if (cycle < cyclePerTime) begin
                cycle <= cycle + 1'b1;
              end else if (cycle == cyclePerTime) begin  // When finish computing current conv kernel, slide to next kernel
                writeEn <= 1'b1;
                cycle   <= 32'd0;
                t       <= t + 1'b1;
              end else begin
                cycle <= 32'd0;
              end
            end else if (t == timePerRound) begin  // start next input window, reset weight address
              if (cycle < cyclePerTime) begin
                cycle <= cycle + 1'b1;
              end else if (cycle == cyclePerTime) begin  // When finish 1 round for single pixel, slide to next window
                writeEn <= 1'b1;
                cycle   <= 32'd0;
                t       <= 32'd0;
                round   <= round + 1'b1;
              end else begin
                cycle <= 32'd0;
              end
            end else begin
              t <= 32'd0;
            end
          end else if (round == totalRound) begin  // Last round
            if (t < timePerRound) begin
              if (cycle < cyclePerTime) begin
                cycle <= cycle + 1'b1;
              end else if (cycle == cyclePerTime) begin  // When finish computing current conv kernel, slide to next kernel
                writeEn <= 1'b1;
                cycle   <= 32'd0;
                t       <= t + 1'b1;
              end else begin
                cycle <= 32'd0;
              end
            end else if (t == timePerRound) begin  // Last time
              if (cycle < cyclePerTime) begin
                cycle <= cycle + 1'b1;
              end else if (cycle == cyclePerTime) begin  // Last cycle for current conv layer
                writeEn      <= 1'b1;
                cycle        <= 32'd0;
                t            <= 32'd0;
                round        <= 32'd0;
                pingpong     <= !pingpong;  //switch pingpong ram control after each Conv operation
                oComputeDone <= 1'b1;
                state        <= IDLE;
              end else begin
                cycle <= 32'd0;
              end
            end else begin
              t <= 32'd0;
            end
          end else begin
            round <= 32'd0;
          end
        end
        default: begin
          state <= IDLE;
        end
      endcase
    end
  end

endmodule
