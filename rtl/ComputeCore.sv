`timescale 1ns/1ps

module ComputeCore #(
    parameter int P_WORDS_WE        = 256,
    parameter int P_BITWIDTH_WE     = 64,
    parameter int P_ADDRWIDTH_WE    = $clog2(P_WORDS_WE),
    parameter int P_INNUM_MUL       = P_BITWIDTH_WE,
    parameter int P_INBITWIDTH_MUL  = 1,
    parameter int P_OUTBITWIDTH_MUL = 1,
    parameter int P_INNUM_ADD       = P_INNUM_MUL,
    parameter int P_INBITWIDTH_ADD  = P_OUTBITWIDTH_MUL,
    parameter int P_STAGES_ADD      = $clog2(P_INNUM_ADD),
    parameter int P_OUTBITWIDTH_ADD = P_INBITWIDTH_ADD + P_STAGES_ADD,
    parameter int P_INBITWIDTH_ACC  = 7,
    parameter int P_OUTBITWIDTH_ACC = 12
) (
    input  logic                                             clk,
    input  logic                                             nRst,
    input  logic [P_BITWIDTH_WE-1:0]                         weightData,
    input  logic [P_ADDRWIDTH_WE-1:0]                        weightReadAddr,
    input  logic [P_ADDRWIDTH_WE-1:0]                        weightWriteAddr,
    input  logic                                             nWeightCe,
    input  logic                                             nWeightWe,
    input  logic                                             enableBuf,
    input  logic [P_INNUM_MUL-1:0][P_INBITWIDTH_MUL-1:0]     actData,
    input  logic [1:0]                                       accInst,
    output logic [P_BITWIDTH_WE-1:0]                         oWeightData,
    output logic [P_OUTBITWIDTH_ACC-1:0]                     outData
);

  logic [P_BITWIDTH_WE-1:0] weightBufData;
  logic [P_INNUM_MUL-1:0][P_OUTBITWIDTH_MUL-1:0] mulData;
  logic [P_OUTBITWIDTH_ADD-1:0] addData;

  WeightSRAM #(
    .P_WORDS(P_WORDS_WE),
    .P_BITWIDTH(P_BITWIDTH_WE),
    .P_ADDRWIDTH(P_ADDRWIDTH_WE)
  ) u_weight_sram (
    .clk(clk),
    .iData(weightData),
    .iAddra(weightReadAddr),
    .iAddrb(weightWriteAddr),
    .nCe(nWeightCe),
    .nWe(nWeightWe),
    .oDataa(oWeightData)
  );

  WeightBuffer #(
    .P_INNUM(P_BITWIDTH_WE)
  ) u_weight_buffer (
    .clk(clk),
    .nRst(nRst),
    .enable(enableBuf),
    .iData(oWeightData),
    .oData(weightBufData)
  );

  Multiplier #(
    .P_INNUM(P_INNUM_MUL),
    .P_INBITWIDTH(P_INBITWIDTH_MUL),
    .P_OUTBITWIDTH(P_OUTBITWIDTH_MUL)
  ) u_multiplier (
    .iDataA(actData),
    .iDataB(weightBufData),
    .oData(mulData)
  );

  AdderTree #(
    .P_INNUM(P_INNUM_ADD),
    .P_INBITWIDTH(P_INBITWIDTH_ADD),
    .P_STAGES(P_STAGES_ADD),
    .P_OUTBITWIDTH(P_OUTBITWIDTH_ADD)
  ) u_adder_tree (
    .iData(mulData),
    .oData(addData)
  );

  Accumulator #(
    .P_INBITWIDTH(P_INBITWIDTH_ACC),
    .P_OUTBITWIDTH(P_OUTBITWIDTH_ACC)
  ) u_accumulator (
    .clk(clk),
    .nRst(nRst),
    .inst(accInst),
    .iData(addData[P_INBITWIDTH_ACC-1:0]),
    .oData(outData)
  );

endmodule
