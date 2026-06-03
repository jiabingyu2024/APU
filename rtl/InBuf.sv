module InBuf #(
    parameter int P_BINDWIDTH = 64
) (
    input  logic                     clk,
    input  logic                     nRst,
    input  logic                     nWe,
    input  logic [P_BINDWIDTH-1:0]   iWriteDataA,
    input  logic [P_BINDWIDTH-1:0]   iWriteDataB,
    input  logic                     iSelect,
    input  logic                     nCe,
    output logic [P_BINDWIDTH-1:0]   oInData
);

  logic [P_BINDWIDTH-1:0] rBuf;
  // always_ff @(posedge clk or negedge nRst) begin
  //   if (!nRst) begin
  //     rBuf <= '0;
  //   end else if (!nWe) begin
  //     // 正常写入：根据 iSelect 选择 A 或 B
  //     if (!iSelect) begin
  //       rBuf <= iWriteDataA;
  //     end else begin
  //       rBuf <= iWriteDataB;
  //     end
  //   end else begin
  //     // nWe 为高电平：对 rBuf 做循环左移一位
  //     rBuf <= {rBuf[P_BINDWIDTH-2:0], rBuf[P_BINDWIDTH-1]};
  //   end
  // end
  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      rBuf <= '0;
    end else if (!nWe) begin
      if (!iSelect) begin
        rBuf <= iWriteDataA;
      end else begin
        rBuf <= iWriteDataB;
      end
    end else begin
      rBuf <= rBuf;
    end
  end

  assign oInData = nCe ? '0 : rBuf;

endmodule