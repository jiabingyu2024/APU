`timescale 1ns/1ps

module tb_inbuf_replay;
  logic clk = 1'b0;
  logic nRst = 1'b0;
  logic iSelect = 1'b0;
  logic nWe = 1'b1;
  logic [31:0] iInstruction = '0;
  logic [63:0] iWriteDataA = '0;
  logic [63:0] iWriteDataB = '0;
  logic nCe = 1'b0;
  logic [63:0] oInData;

  InBuf dut (
      .clk(clk),
      .nRst(nRst),
      .iSelect(iSelect),
      .nWe(nWe),
      .iInstruction(iInstruction),
      .iWriteDataA(iWriteDataA),
      .iWriteDataB(iWriteDataB),
      .nCe(nCe),
      .oInData(oInData)
  );

  always #5 clk = ~clk;

  task automatic step;
    @(posedge clk);
    #1;
  endtask

  task automatic reset_dut;
    nRst = 1'b0;
    repeat (2) step();
    nRst = 1'b1;
    step();
  endtask

  initial begin
    reset_dut();

    // Layer2 residual: main=B, shortcut=A. The registered A value captured
    // after count 18 must be replayed at the second output-group shortcut.
    iInstruction[31:30] = 2'b01;
    iInstruction[27:25] = 3'd4;
    iSelect = 1'b1;
    nWe = 1'b0;
    while (dut.count != 8'd18) step();
    iSelect = 1'b0;
    iWriteDataA = 64'h1122_3344_5566_7788;
    step();
    step();
    iWriteDataA = 64'hCAFE_BABE_DEAD_BEEF;
    iSelect = 1'b1;
    while (dut.count != 8'd37) step();
    iSelect = 1'b0;
    step();
    if (oInData !== 64'h1122_3344_5566_7788) begin
      $fatal(1, "layer2 replay mismatch: %h", oInData);
    end

    // Layer3 residual: capture two shortcut groups and replay both in order.
    nWe = 1'b1;
    step();
    iInstruction[27:25] = 3'd3;
    iSelect = 1'b1;
    nWe = 1'b0;
    while (dut.count != 8'd36) step();
    iSelect = 1'b0;
    iWriteDataA = 64'h0101_0101_0101_0101;
    step();
    iWriteDataA = 64'h0202_0202_0202_0202;
    step();
    iSelect = 1'b1;
    step();
    while (dut.count != 8'd74) step();
    iSelect = 1'b0;
    step();
    if (oInData !== 64'h0101_0101_0101_0101) begin
      $fatal(1, "layer3 replay word0 mismatch: %h", oInData);
    end
    step();
    if (oInData !== 64'h0202_0202_0202_0202) begin
      $fatal(1, "layer3 replay word1 mismatch: %h", oInData);
    end

    $display("TB_INBUF_REPLAY_PASS");
    $finish;
  end
endmodule
