// Read-only 512 KiB model store. Vivado can infer initialized block RAM from
// the same readmemh image used by Verilator; board-specific storage is deferred.
module model_rom #(
    // 当前模型镜像实际包含 90,880 个 32-bit 字。按实际深度综合可显著减少
    // XC7Z020 上的 BRAM 占用；模型布局变化时必须同步更新该参数。
    parameter int WORDS = 90_880,
    parameter string INIT_FILE = "soc/build/model.hex"
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic [ 3:0] req_wstrb,
    output logic        req_ready,
    output logic [31:0] req_rdata
);

  localparam int ADDR_WIDTH = $clog2(WORDS);

  // 标准同步读 ROM 模板，确保 355 KiB 模型映射到 Block RAM，而不是被
  // Vivado 尝试拆成 LUT/FF。
  (* ram_style = "block" *) logic [31:0] mem [0:WORDS-1];
  logic [31:0] req_rdata_q;
  logic        pending_q;

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  assign req_ready = pending_q;
  assign req_rdata = req_rdata_q;

  always_ff @(posedge clk) begin
    if (req_valid && !pending_q) begin
      req_rdata_q <= |req_wstrb ? 32'hbad0_4000 :
                     mem[req_addr[ADDR_WIDTH+1:2]];
    end
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      pending_q <= 1'b0;
    end else if (pending_q) begin
      pending_q <= 1'b0;
    end else if (req_valid) begin
      pending_q <= 1'b1;
    end
  end

endmodule
