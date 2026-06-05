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
    output logic [P_BINDWIDTH-1:0]   oInData,

    input  logic                     regWe,
    input  logic                     regSelect
);

  logic [P_BINDWIDTH-1:0] rBuf;
  logic [P_BINDWIDTH-1:0] rBufReg [1:0];
  logic                   regWeReg ;
  logic                   regSelectReg;

  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      regWeReg <= 1'b0;
      regSelectReg <= 1'b0;
    end else begin
      regWeReg <= regWe;
      regSelectReg <= regSelect;
    end
  end
  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      rBufReg[0] <= '0;
      rBufReg[1] <= '0;
    end else begin
      if (regWeReg == 1'b1 && regWe) begin
        rBufReg[1] <= iWriteDataA;
      end
      else if (regWe) begin
        rBufReg[0] <= iWriteDataA;
      end
    end
  end
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
      if (regSelectReg == 1'b1 && regSelect == 1'b1) begin
        rBuf <= rBufReg[1];
      end
      else if (regSelect) begin
        rBuf <= rBufReg[0];
      end
      else if (!iSelect) begin
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