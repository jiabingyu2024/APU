`timescale 1ns/1ps

module ComputeCoreGroup #(
    parameter int P_GROUP            = 64,
    parameter int P_GROUP_LOG2       = $clog2(P_GROUP),
    parameter int P_WORDS_WE         = 256,
    parameter int P_BITWIDTH_WE      = 64,
    parameter int P_ADDRWIDTH_WE     = $clog2(P_WORDS_WE),
    parameter int P_INNUM_MUL        = P_BITWIDTH_WE,
    parameter int P_INBITWIDTH_MUL   = 1,
    parameter int P_OUTBITWIDTH_MUL  = 1,
    parameter int P_INNUM_ADD        = P_INNUM_MUL,
    parameter int P_INBITWIDTH_ADD   = P_OUTBITWIDTH_MUL,
    parameter int P_STAGES_ADD       = $clog2(P_INNUM_ADD),
    parameter int P_OUTBITWIDTH_ADD  = P_INBITWIDTH_ADD + P_STAGES_ADD,
    parameter int P_INBITWIDTH_ACC   = 7,
    parameter int P_OUTBITWIDTH_ACC  = 12
) (
    input  logic                                             clk,
    input  logic                                             nRst,
    input  logic [P_BITWIDTH_WE-1:0]                         weightData,
    input  logic [P_ADDRWIDTH_WE-1:0]                        weightReadAddr,
    input  logic [P_ADDRWIDTH_WE-1:0]                        weightWriteAddr,
    input  logic [P_GROUP_LOG2-1:0]                          weightWriteSelect,
    input  logic                                             nWeightCe,
    input  logic                                             nWeightWe,
    input  logic                                             enableBuf,
    input  logic [P_INNUM_MUL-1:0][P_INBITWIDTH_MUL-1:0]     actData,
    input  logic [1:0]                                       accInst,
    output logic [P_BITWIDTH_WE-1:0]                         oWeightData,
    output logic [P_GROUP-1:0][P_OUTBITWIDTH_ACC-1:0]        outData
);

  logic [P_GROUP-1:0][P_BITWIDTH_WE-1:0] coreWeightData;
  logic [P_GROUP-1:0]                    weightBankWriteEn;

  always_comb begin
    weightBankWriteEn = '0;
    if (!nWeightWe) begin
      weightBankWriteEn[weightWriteSelect] = 1'b1;
    end
  end

  genvar i;
  generate
    for (i = 0; i < P_GROUP; i = i + 1) begin : gen_compute_core
      ComputeCore #(
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
      ) u_compute_core (
        .clk(clk),
        .nRst(nRst),
        .weightData(weightData),
        .weightReadAddr(weightReadAddr),
        .weightWriteAddr(weightWriteAddr),
        .nWeightCe(nWeightCe),
        .nWeightWe(!weightBankWriteEn[i]),
        .enableBuf(enableBuf),
        .actData(actData),
        .accInst(accInst),
        .oWeightData(coreWeightData[i]),
        .outData(outData[i])
      );
    end
  endgenerate

  assign oWeightData = coreWeightData[weightWriteSelect];

endmodule
