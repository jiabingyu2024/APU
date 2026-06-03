`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/04/11 21:30:32
// Design Name: 
// Module Name: ram_mux
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ram_mux (
    input clk,
    input rstn,

    input      [10:0] ram_waddr,
    input      [10:0] ram_raddr,
    input             ram_wen,
    input             ram_ren,
    input      [31:0] ram_wdata,
    output reg [31:0] ram_rdata,
    input      [ 7:0] ram_sel,

    output        ir_ram_wen,
    output [ 3:0] ir_ram_waddr,
    output [31:0] ir_ram_wdata,
    output        ir_ram_ren,
    output [ 3:0] ir_ram_raddr,
    input  [31:0] ir_ram_rdata,

    output        in_ram_wen,
    output [ 9:0] in_ram_waddr,
    output [63:0] in_ram_wdata,
    output        in_ram_ren,
    output [ 9:0] in_ram_raddr,
    input  [63:0] in_ram_rdata,

    output        out_ram_wen,
    output [ 9:0] out_ram_waddr,
    output [63:0] out_ram_wdata,
    output        out_ram_ren,
    output [ 9:0] out_ram_raddr,
    input  [63:0] out_ram_rdata,

    output [ 5:0] conv_ram_sel,
    output        conv_ram_wen,
    output [ 7:0] conv_ram_waddr,
    output [63:0] conv_ram_wdata,
    output        conv_ram_ren,
    output [ 7:0] conv_ram_raddr,
    input  [63:0] conv_ram_rdata,

    output [ 5:0] bn_ram_sel,
    output        bn_ram_wen,
    output [ 4:0] bn_ram_waddr,
    output [12:0] bn_ram_wdata,
    output        bn_ram_ren,
    output [ 4:0] bn_ram_raddr,
    input  [12:0] bn_ram_rdata
);

  reg [31:0] ram_wdata_r;
  reg [10:0] ram_raddr_d;
  always @(posedge clk or negedge rstn) begin
    if (~rstn) begin
      ram_wdata_r <= 'h0;
    end else if (ram_wen & (!ram_waddr[0])) begin
      ram_wdata_r <= ram_wdata;
    end
  end

  always @(posedge clk or negedge rstn) begin
    if (~rstn) begin
      ram_raddr_d <= 'h0;
    end else if (ram_ren) begin
      ram_raddr_d <= ram_raddr;
    end
  end

  wire bn_sel;
  wire conv_sel;

  assign bn_sel         = (ram_sel[7:6] == 2'b00) ? 1'b1 : 1'b0;

  assign bn_ram_sel     = ram_sel[5:0];
  assign bn_ram_wen     = bn_sel ? ram_wen : 1'b0;
  assign bn_ram_waddr   = bn_sel ? ram_waddr[4:0] : 'h0;
  assign bn_ram_wdata   = bn_sel ? ram_wdata[12:0] : 'h0;
  assign bn_ram_ren     = bn_sel ? ram_ren : 'h0;
  assign bn_ram_raddr   = bn_sel ? ram_raddr[4:0] : 'h0;

  assign conv_sel       = (ram_sel[7:6] == 2'b01) ? 1'b1 : 1'b0;

  assign conv_ram_sel   = ram_sel[5:0];
  assign conv_ram_wen   = conv_sel ? (ram_wen & ram_waddr[0]) : 1'b0;
  assign conv_ram_waddr = conv_sel ? ram_waddr[8:1] : 'h0;
  assign conv_ram_wdata = conv_sel ? {ram_wdata, ram_wdata_r} : 'h0;
  assign conv_ram_ren   = conv_sel ? ram_ren : 1'b0;
  assign conv_ram_raddr = conv_sel ? ram_raddr[8:1] : 'h0;

  assign in_ram_wen     = (ram_sel == 8'd128) ? (ram_wen & ram_waddr[0]) : 1'b0;
  assign in_ram_waddr   = (ram_sel == 8'd128) ? ram_waddr[10:1] : 'h0;
  assign in_ram_wdata   = (ram_sel == 8'd128) ? {ram_wdata, ram_wdata_r} : 'h0;
  assign in_ram_ren     = (ram_sel == 8'd128) ? ram_ren : 1'b0;
  assign in_ram_raddr   = (ram_sel == 8'd128) ? ram_raddr[10:1] : 'h0;

  assign out_ram_wen    = (ram_sel == 8'd129) ? (ram_wen & ram_waddr[0]) : 1'b0;
  assign out_ram_waddr  = (ram_sel == 8'd129) ? ram_waddr[10:1] : 'h0;
  assign out_ram_wdata  = (ram_sel == 8'd129) ? {ram_wdata, ram_wdata_r} : 'h0;
  assign out_ram_ren    = (ram_sel == 8'd129) ? ram_ren : 1'b0;
  assign out_ram_raddr  = (ram_sel == 8'd129) ? ram_raddr[10:1] : 'h0;

  assign ir_ram_wen     = (ram_sel == 8'd130) ? ram_wen : 1'b0;
  assign ir_ram_waddr   = (ram_sel == 8'd130) ? ram_waddr[3:0] : 'h0;
  assign ir_ram_wdata   = (ram_sel == 8'd130) ? ram_wdata : 'h0;
  assign ir_ram_ren     = (ram_sel == 8'd130) ? ram_ren : 'h0;
  assign ir_ram_raddr   = (ram_sel == 8'd130) ? ram_raddr[3:0] : 'h0;

  always @(*) begin
    if (bn_sel) begin
      ram_rdata = {19'b0, bn_ram_rdata};
    end else if (conv_sel) begin
      ram_rdata = (!ram_raddr_d[0]) ? conv_ram_rdata[31:0] : conv_ram_rdata[63:32];
    end else if (ram_sel == 8'd128) begin
      if (!ram_raddr_d[0]) begin
        ram_rdata = in_ram_rdata[31:0];
      end else begin
        ram_rdata = in_ram_rdata[63:32];
      end
    end else if (ram_sel == 8'd129) begin
      if (!ram_raddr_d[0]) begin
        ram_rdata = out_ram_rdata[31:0];
      end else begin
        ram_rdata = out_ram_rdata[63:32];
      end
    end else if (ram_sel == 8'd130) begin
      ram_rdata = ir_ram_rdata;
    end else begin
      ram_rdata = 'h0;
    end
  end

endmodule
