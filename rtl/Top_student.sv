module Top#(
    //-------------------WorkSheet----------------------//
    parameter P_INSTRUCTION_NUM = 16,
    //----------------------Ctrl------------------------//
    parameter P_BINDWIDTH = 64,
    //-------------------ACT/OUTSRAM--------------------//
    parameter P_FEATURE_MEMORY_SIZE = 65536,
    //----------------ComputeCoreGroup------------------//
    // GROUP RELATED
    parameter P_GROUP = 64,
    parameter P_GROUP_LOG2 = $clog2(P_GROUP),
    // WEIGHT RELATED
    parameter P_WORDS_WE = 256,
    parameter P_BITWIDTH_WE = 64,
    parameter P_ADDRWIDTH_WE = $clog2(P_WORDS_WE),
    // MULTIPLIER RELATED
    parameter P_INNUM_MUL = P_BITWIDTH_WE,
    parameter P_INBITWIDTH_MUL = 1,
    parameter P_OUTBITWIDTH_MUL = 1,
    // ADDERTREE RELADTED
    parameter P_INNUM_ADD = P_INNUM_MUL,
    parameter P_INBITWIDTH_ADD = P_OUTBITWIDTH_MUL,
    parameter P_STAGES_ADD = $clog2(P_INNUM_ADD),
    parameter P_OUTBITWIDTH_ADD = P_INBITWIDTH_ADD + P_STAGES_ADD,
    // ACCUMULATOR RELATED
    parameter P_INBITWIDTH_ACC = 7,
    parameter P_OUTBITWIDTH_ACC = 12,
    //---------------------SIMD------------------------//
    parameter P_CHANNELS = 64,
    parameter P_COMPAREWIDTH = 13,
    parameter P_TOTAL64BN = 32

) (
    input        clk,
    input        nRst,
    //--------------------AHBSlave-----------------------//
    input        hsel,
    input [31:0] haddr,
    input [ 1:0] htrans,
    input        hwrite,
    input [ 2:0] hsize,
    input [ 2:0] hburst,
    input [31:0] hwdata,
    input        hready,
    input        hlock,   // Not used in this module
    input [ 3:0] hprot,   // Not used in this module

    output [31:0] hrdata,
    output [ 1:0] hresp,
    output        hreadyout,
    output        int_cal
);
  //----------------------------------------------Signal Declaration----------------------------------------------//
  //--------------------AHBSlave-----------------------//
  wire                                                                          data_ram_ctrl;
  wire                                                                          conv_ram_ctrl;
  wire                                                                          apu_ready;
  wire                                                                          cal_cpl;
  wire                                                                          ir_ram_wen;
  wire [                                          3:0]                          ir_ram_waddr;
  wire [                                         31:0]                          ir_ram_wdata;
  wire                                                                          ir_ram_ren;
  wire [                                          3:0]                          ir_ram_raddr;

  wire                                                                          in_ram_wen;
  wire [                                          9:0]                          in_ram_waddr;
  wire [                                         63:0]                          in_ram_wdata;
  wire                                                                          in_ram_ren;
  wire [                                          9:0]                          in_ram_raddr;

  wire                                                                          out_ram_wen;
  wire [                                          9:0]                          out_ram_waddr;
  wire [                                         63:0]                          out_ram_wdata;
  wire                                                                          out_ram_ren;
  wire [                                          9:0]                          out_ram_raddr;

  wire [                                          5:0]                          conv_ram_sel;
  wire                                                                          conv_ram_wen;
  wire [                                          7:0]                          conv_ram_waddr;
  wire [                                         63:0]                          conv_ram_wdata;
  wire                                                                          conv_ram_ren;
  wire [                                          7:0]                          conv_ram_raddr;

  // Under corrections, depth of bn_ram
  wire [                                          5:0]                          bn_ram_sel;
  wire                                                                          bn_ram_wen;
  wire [                                          4:0]                          bn_ram_waddr;
  wire [                                         12:0]                          bn_ram_wdata;
  wire                                                                          bn_ram_ren;
  wire [                                          4:0]                          bn_ram_raddr;

  //--------------------WorkSheet----------------------//
  wire                                                                          WorkSheetDone;
  wire                                                                          CtrlnCe;
  wire [                                         31:0]                          Instruction;
  wire [                                         31:0]                          WorkSheetData;
  //-----------------------Ctrl------------------------//
  wire [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]                          ActReadCenterAddr;
  wire                                                                          ActReadEn;
  wire [                                          1:0]                          ActKernelSize;
  wire [                                          5:0]                          ActHW;
  wire [                                          3:0]                          ActlogInC;
  wire [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]                          ActWriteAddr;
  wire                                                                          ActWriteEn;
  wire                                                                          InputBufNWe;
  wire                                                                          InputBufSelect;
  wire [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]                          OutReadCenterAddr;
  wire                                                                          OutReadEn;
  wire [                                          1:0]                          OutKernelSize;
  wire [                                          5:0]                          OutHW;
  wire [                                          3:0]                          OutlogInC;
  wire [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]                          OutWriteAddr;
  wire                                                                          OutWriteEn;
  wire                                                                          Compute;
  wire [                                          7:0]                          WeightAddr;
  wire                                                                          WeightReadEn;
  wire [                                          4:0]                          BNAddr;
  wire [                                          1:0]                          AccInstr;
  wire                                                                          ComputeDone;
  //----------------------InBuf-----------------------//
  wire [                              P_BINDWIDTH-1:0]                          InBufData;
  //---------------------ActSRAM----------------------//
  wire [                              P_BINDWIDTH-1:0]                          ActData;
  //---------------------OutSRAM----------------------//
  wire [                              P_BINDWIDTH-1:0]                          OutData;
  //----------------ComputeCoreGroup------------------//
  wire [                            P_BITWIDTH_WE-1:0]                          WeightSRAMReadData;
  wire [                                P_GROUP - 1:0][P_OUTBITWIDTH_ACC - 1:0] ComputeCoreData;
  //----------------------SIMD------------------------//
  wire [                           P_COMPAREWIDTH-1:0]                          SIMDReadData;
  wire [                               P_CHANNELS-1:0]                          SIMDData;



  //----------------------------------------------Universal Instantiation----------------------------------------------//
  //-------------------AHBSlave-----------------------//
  ahb_slave_top U_ahb_slave_top (
      // For AHB interface
      .hresetn      (nRst),           // Input, active low reset signal
      .hclk         (clk),            // Input, clock signal
      .hsel         (hsel),           // Input, select signal
      .haddr        (haddr[31:0]),    // Input [31:0], address bus
      .htrans       (htrans[1:0]),    // Input [1:0], transfer type
      .hwrite       (hwrite),         // Input, write signal
      .hsize        (hsize[2:0]),     // Input [2:0], transfer size
      .hburst       (hburst[2:0]),    // Input [2:0], burst type
      .hwdata       (hwdata[31:0]),   // Input [31:0], write data
      .hrdata       (hrdata[31:0]),   // Output [31:0], read data
      .hresp        (hresp[1:0]),     // Output [1:0], response
      .hready       (hreadyout),      // Output, ready signal
      //For ActSRAM and  ConvSRAM
      .data_ram_ctrl(data_ram_ctrl),  // Output, data RAM control signal, 1 for AHB, 0 for SRAM
      .conv_ram_ctrl(conv_ram_ctrl),  // Output, convolution RAM control signal, 1 for AHB, 0 for SRAM
      .apu_ready    (apu_ready),
      //For WorkSheet
      .ir_ram_wen   (ir_ram_wen),     // Output, instruction RAM write enable
      .ir_ram_waddr (ir_ram_waddr),   // Output [3:0], instruction RAM write address
      .ir_ram_wdata (ir_ram_wdata),   // Output [31:0], instruction RAM write data
      .ir_ram_ren   (ir_ram_ren),     // Output, instruction RAM read enable
      .ir_ram_raddr (ir_ram_raddr),   // Output [3:0], instruction RAM read address
      .ir_ram_rdata (WorkSheetData),  // Output [31:0], instruction register


      .cal_cpl       (cal_cpl),             // Input [1:0], calculation control
      .int_cal       (int_cal),
      //For ActSRAM
      .in_ram_wen    (in_ram_wen),          // Output, input RAM write enable
      .in_ram_waddr  (in_ram_waddr),        // Output [9:0], input RAM write address
      .in_ram_wdata  (in_ram_wdata),        // Output [63:0], input RAM write data
      .in_ram_ren    (in_ram_ren),          // Output, input RAM read enable
      .in_ram_raddr  (in_ram_raddr),        // Output [9:0], input RAM read address
      .in_ram_rdata  (ActData),             // Input [63:0], input RAM read data
      //For OutSRAM
      .out_ram_wen   (out_ram_wen),         // Output, output RAM write enable
      .out_ram_waddr (out_ram_waddr),       // Output [9:0], output RAM write address
      .out_ram_wdata (out_ram_wdata),       // Output [63:0], output RAM write data
      .out_ram_ren   (out_ram_ren),         // Output, output RAM read enable
      .out_ram_raddr (out_ram_raddr),       // Output [9:0], output RAM read address
      .out_ram_rdata (OutData),             // Input [63:0], output RAM read data
      //For ComputeCoreGroup
      .conv_ram_sel  (conv_ram_sel),        // Output [5:0], convolution RAM select signal
      .conv_ram_wen  (conv_ram_wen),        // Output, convolution RAM write enable
      .conv_ram_waddr(conv_ram_waddr),      // Output [7:0], convolution RAM write address
      .conv_ram_wdata(conv_ram_wdata),      // Output [63:0], convolution RAM write data
      .conv_ram_ren  (conv_ram_ren),        // Output, convolution RAM read enable
      .conv_ram_raddr(conv_ram_raddr),      // Output [7:0], convolution RAM read address
      .conv_ram_rdata(WeightSRAMReadData),  // Input [63:0], convolution RAM read data
      //For SIMD
      .bn_ram_sel    (bn_ram_sel),          // Output [5:0], batch normalization RAM select signal
      .bn_ram_wen    (bn_ram_wen),          // Output, batch normalization RAM write enable
      .bn_ram_waddr  (bn_ram_waddr),        // Output [4:0], batch normalization RAM write address
      .bn_ram_wdata  (bn_ram_wdata),        // Output [12:0], batch normalization RAM write data
      .bn_ram_ren    (),                    // Output, batch normalization RAM read enable
      .bn_ram_raddr  (bn_ram_raddr),        // Output [4:0], batch normalization RAM read address
      .bn_ram_rdata  (SIMDReadData)         // Input [12:0], batch normalization RAM read data
  );

  assign cal_cpl = WorkSheetDone;

  //-------------------WorkSheet----------------------//
  WorkSheet #(
      .P_INSTRUCTION_NUM(P_INSTRUCTION_NUM)
  ) U_WorkSheet (
      .clk         (clk),
      .nRst        (nRst),
      //From AHB Slave
      .nWe         (~ir_ram_wen),
      .iWriteAddr  (ir_ram_waddr),
      .iWriteData  (ir_ram_wdata),
      .iReadAddr   (ir_ram_raddr),
      .iAPUReady   (apu_ready),
      //From Ctrl
      .iComputeDone(ComputeDone),

      //For AHB Slave
      .oWorkSheetDone(WorkSheetDone),
      .oWorkSheetData(WorkSheetData[31:0]),
      //For Ctrl
      .oCtrlnCe      (CtrlnCe),
      .oInstruction  (Instruction[31:0])
  );

  //-----------------------Ctrl------------------------//
  Ctrl #(
      .P_BINDWIDTH(P_BINDWIDTH),
      .P_FEATURE_MEMORY_SIZE(P_FEATURE_MEMORY_SIZE)
  ) U_Ctrl (
      .clk         (clk),
      .nRst        (nRst),
      //From WorkSheet
      .nCe         (CtrlnCe),
      .iInstruction(Instruction[31:0]),

      //For ActSRAM
      .oActReadCenterAddr(ActReadCenterAddr[$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]),
      .oActReadEn        (ActReadEn),
      .oActKernelSize    (ActKernelSize[1:0]),
      .oActHW            (ActHW),
      .oActlogInC        (ActlogInC[3:0]),
      .oActWriteAddr     (ActWriteAddr[$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]),
      .oActWriteEn       (ActWriteEn),
      //For InputBuf
      .oInputBufNWe      (InputBufNWe),
      .oInputBufSelect   (InputBufSelect),
      //For OutSRAM
      .oOutReadCenterAddr(OutReadCenterAddr[$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]),
      .oOutReadEn        (OutReadEn),
      .oOutKernelSize    (OutKernelSize[1:0]),
      .oOutHW            (OutHW),
      .oOutlogInC        (OutlogInC[3:0]),
      .oOutWriteAddr     (OutWriteAddr[$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]),
      .oOutWriteEn       (OutWriteEn),
      //For BN Regfile
      .oBNAddr           (BNAddr[4:0]),
      //For ComputeCoreGroup
      .oWeightAddr       (WeightAddr[7:0]),
      .oWeightReadEn     (WeightReadEn),
      .oAccInstr         (AccInstr[1:0]),
      //For WorkSheet to fetch next Instruction
      .oComputeDone      (ComputeDone)
  );

  //----------------------InBuf-----------------------//
  InBuf #(
      .P_BINDWIDTH(P_BINDWIDTH)
  ) U_InBuf (
      .clk        (clk),
      .nRst       (nRst),
      .nWe        (InputBufNWe),
      .iWriteDataA(ActData[P_BINDWIDTH-1:0]),
      .iWriteDataB(OutData[P_BINDWIDTH-1:0]),
      .iSelect    (InputBufSelect),
      .nCe        (1'b0),                      //Always enable

      .oInData(InBufData[P_BINDWIDTH-1:0]),
      //.iActSramReadCenterAddr(ActReadCenterAddr[$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]),
      .iInstruction(Instruction[31:0])
      //.iComputeDone(ComputeDone)，
  );
  //---------------------ActSRAM----------------------//
  wire        U_ActSRAMnCe = !(in_ram_ren | ActReadEn);
  wire        U_ActSRAMnWe = !(in_ram_wen | ActWriteEn);
  wire [ 9:0] U_ActSRAMWriteAddr = (data_ram_ctrl == 1) ? in_ram_waddr : ActWriteAddr;
  wire [63:0] U_ActSRAMWriteData = (data_ram_ctrl == 1) ? in_ram_wdata : SIMDData;
  wire [ 9:0] U_ActSRAMReadAddr = (data_ram_ctrl == 1) ? in_ram_raddr : ActReadCenterAddr;
  wire [ 1:0] U_ActSRAMKernelSize = (data_ram_ctrl == 1) ? 1 : ActKernelSize;
  wire [ 3:0] U_ActDepth = 1 << (ActlogInC - 6);
  FeatureProcessor #(
      .P_FEATURE_MEMORY_SIZE(P_FEATURE_MEMORY_SIZE),
      .P_BINDWIDTH          (P_BINDWIDTH)
  ) U_ActSRAM (
      .clk            (clk),
      .nRst           (nRst),
      .nWe            (U_ActSRAMnWe),
      .iWriteAddr     (U_ActSRAMWriteAddr),
      .iWriteData     (U_ActSRAMWriteData),
      .nCe            (U_ActSRAMnCe),
      .iReadCenterAddr(U_ActSRAMReadAddr),
      .iKernelSize    (U_ActSRAMKernelSize),
      .inHW           (ActHW),
      .iDepth         (U_ActDepth),

      .oFeatureData(ActData[P_BINDWIDTH-1:0])
  );
  //---------------------OutSRAM----------------------//
  wire        U_OutSRAMnCe = !(out_ram_ren | OutReadEn);
  wire        U_OutSRAMnWe = !(out_ram_wen | OutWriteEn);
  wire [ 9:0] U_OutSRAMWriteAddr = (data_ram_ctrl == 1) ? out_ram_waddr : OutWriteAddr;
  wire [63:0] U_OutSRAMWriteData = (data_ram_ctrl == 1) ? out_ram_wdata : SIMDData;
  wire [ 9:0] U_OutSRAMReadAddr = (data_ram_ctrl == 1) ? out_ram_raddr : OutReadCenterAddr;
  wire [ 1:0] U_OutSRAMKernelSize = (data_ram_ctrl == 1) ? 1 : OutKernelSize;
  wire [ 3:0] U_OutDepth = 1 << (OutlogInC - 6);
  FeatureProcessor #(
      .P_FEATURE_MEMORY_SIZE(P_FEATURE_MEMORY_SIZE),
      .P_BINDWIDTH          (P_BINDWIDTH)
  ) U_OutSRAM (
      .clk            (clk),
      .nRst           (nRst),
      .nWe            (U_OutSRAMnWe),
      .iWriteAddr     (U_OutSRAMWriteAddr),
      .iWriteData     (U_OutSRAMWriteData),
      .nCe            (U_OutSRAMnCe),
      .iReadCenterAddr(U_OutSRAMReadAddr),
      .iKernelSize    (U_OutSRAMKernelSize),
      .inHW           (OutHW),
      .iDepth         (U_OutDepth),

      .oFeatureData(OutData[P_BINDWIDTH-1:0])
  );
  //----------------ComputeCoreGroup------------------//
  wire        U_WeightSRAMnWe = !(conv_ram_wen);
  wire        U_WeightSRAMnCe = !(conv_ram_ren | WeightReadEn);
  wire [ 7:0] U_WeightSRAMWriteAddr = conv_ram_waddr;
  wire [ 5:0] U_WeightSRAMWriteSelect = conv_ram_sel;
  wire [63:0] U_WeightSRAMWriteData = conv_ram_wdata;
  wire [ 7:0] U_WeightSRAMReadAddr = (conv_ram_ctrl == 1) ? conv_ram_raddr : WeightAddr;
  ComputeCoreGroup #(
      .P_GROUP(P_GROUP),
      .P_GROUP_LOG2(P_GROUP_LOG2),
      .P_WORDS_WE(P_WORDS_WE),
      .P_BITWIDTH_WE(P_BITWIDTH_WE),
      .P_ADDRWIDTH_WE(P_ADDRWIDTH_WE),
      .P_INNUM_MUL(P_INNUM_MUL),
      .P_INBITWIDTH_MUL(P_INBITWIDTH_MUL),
      .P_OUTBITWIDTH_MUL(P_OUTBITWIDTH_MUL),
      .P_INNUM_ADD(P_INNUM_ADD),
      .P_INBITWIDTH_ADD(P_INBITWIDTH_ADD),
      .P_STAGES_ADD(P_STAGES_ADD),
      .P_OUTBITWIDTH_ADD(P_OUTBITWIDTH_ADD),
      .P_INBITWIDTH_ACC(P_INBITWIDTH_ACC),
      .P_OUTBITWIDTH_ACC(P_OUTBITWIDTH_ACC)
  ) U_ComputeCoreGroup (
      .clk              (clk),
      .nRst             (nRst),
      .weightData       (U_WeightSRAMWriteData),
      .weightReadAddr   (U_WeightSRAMReadAddr),
      .weightWriteAddr  (U_WeightSRAMWriteAddr),
      .weightWriteSelect(U_WeightSRAMWriteSelect),
      .nWeightCe        (U_WeightSRAMnCe),
      .nWeightWe        (U_WeightSRAMnWe),
      .enableBuf        (!InputBufNWe),
      .actData          (InBufData),
      .accInst          (AccInstr),
      .oWeightData      (WeightSRAMReadData),
      .outData          (ComputeCoreData)
  );
  //----------------------SIMD-------------------------//
  wire [4:0] U_SIMDAddr = (data_ram_ctrl == 1) ? bn_ram_raddr : BNAddr;
  SIMD #(
      .P_CHANNELS    (P_CHANNELS),
      .P_COMPAREWIDTH(P_COMPAREWIDTH),
      .P_TOTAL64BN   (P_TOTAL64BN)
  ) U_SIMD (
      .clk       (clk),
      .nRst      (nRst),
      .nWe       (!bn_ram_wen),
      .iWriteAddr(bn_ram_waddr),
      .iChannel  (bn_ram_sel),
      .iWriteData(bn_ram_wdata),
      .iAccData  (ComputeCoreData),

      .iAddr(U_SIMDAddr),

      .oReadData(SIMDReadData[P_COMPAREWIDTH-1:0]),
      .oSIMDData(SIMDData[P_CHANNELS-1:0])
  );

endmodule
