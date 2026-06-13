`timescale 1ns/1ps

module WeightSRAM #(
    parameter int P_WORDS     = 256,
    parameter int P_BITWIDTH  = 64,
    parameter int P_ADDRWIDTH = $clog2(P_WORDS)
) (
    input  logic                  clk,
    input  logic [P_BITWIDTH-1:0] iData,
    input  logic [P_ADDRWIDTH-1:0] iAddra,
    input  logic [P_ADDRWIDTH-1:0] iAddrb,
    input  logic                  nCe,
    input  logic                  nWe,
    output logic [P_BITWIDTH-1:0] oDataa
);

`ifdef FPGA_DISTRIBUTED_WEIGHT_RAM
  // PYNQ-Z2 的 BRAM 主要留给模型 ROM。该宏仅由 FPGA 工程定义，ASIC/仿真
  // 默认行为不变；综合时将每个计算核的 256x64 权重存储映射到 LUTRAM。
  (* ram_style = "distributed" *) reg [P_BITWIDTH-1:0] rData [P_WORDS-1:0];
`else
  reg [P_BITWIDTH-1:0] rData [P_WORDS-1:0];
`endif
  always @(posedge clk) begin
    if (!nWe) begin // 写使能有效
    rData[iAddrb] <= iData;
    end
  end
  always@(posedge clk)begin
    if (!nCe) begin 
    oDataa <= rData[iAddra];
    end
  end
endmodule
