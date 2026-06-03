// `timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/04/13 09:33:37
// Design Name: 
// Module Name: ahb_slave_top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
//
// limitations:
//  - no partial access supported; only word access
//  - no wait process
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ahb_slave_top #(
    parameter T_ADDR_WID = 14
) (
    input         hresetn,
    input         hclk,
    input         hsel,
    input  [31:0] haddr,
    input  [ 1:0] htrans,
    input         hwrite,
    input  [ 2:0] hsize,
    input  [ 2:0] hburst,
    input  [31:0] hwdata,
    output [31:0] hrdata,
    output [ 1:0] hresp,
    output        hready,

    output data_ram_ctrl,
    output conv_ram_ctrl,
    output        apu_ready,
    input      cal_cpl,
    output    int_cal,

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

  wire [T_ADDR_WID-1:0] t_waddr;
  wire [T_ADDR_WID-1:0] t_raddr;
  wire                  t_wren;
  wire                  t_rden;
  wire [          31:0] t_wdata;
  wire [          31:0] t_rdata;
  wire [          10:0] ram_raddr;
  wire [          10:0] ram_waddr;
  wire                  ram_wen;
  wire                  ram_ren;
  wire [          31:0] ram_wdata;
  wire [          31:0] ram_rdata;
  wire [           7:0] ram_sel;

  ahb_slave #(
      .T_ADDR_WID(T_ADDR_WID)
  ) ahb_slave_inst (
      .hresetn(hresetn),
      .hclk   (hclk),
      .hsel   (hsel),
      .haddr  (haddr),
      .htrans (htrans),
      .hwrite (hwrite),
      .hsize  (hsize),
      .hburst (hburst),
      .hwdata (hwdata),
      .hrdata (hrdata),
      .hresp  (hresp),
      .hready (hready),
      .t_waddr(t_waddr),
      .t_raddr(t_raddr),
      .t_wren (t_wren),
      .t_rden (t_rden),
      .t_wdata(t_wdata),
      .t_rdata(t_rdata)
  );

  addr_map #(
      .T_ADDR_WID(T_ADDR_WID)
  ) addr_map_inst (
      .clk          (hclk),
      .rstn         (hresetn),
      .t_waddr      (t_waddr),
      .t_raddr      (t_raddr),
      .t_wren       (t_wren),
      .t_rden       (t_rden),
      .t_wdata      (t_wdata),
      .t_rdata      (t_rdata),
      .ram_waddr    (ram_waddr),
      .ram_raddr    (ram_raddr),
      .ram_wen      (ram_wen),
      .ram_ren      (ram_ren),
      .ram_wdata    (ram_wdata),
      .ram_rdata    (ram_rdata),
      .ram_sel      (ram_sel),
      .data_ram_ctrl(data_ram_ctrl),
      .conv_ram_ctrl(conv_ram_ctrl),
      .apu_ready    (apu_ready),
      .cal_cpl      (cal_cpl),
      .int_cal      (int_cal)
  );

  ram_mux ram_mux_inst (
      .clk           (hclk),
      .rstn          (hresetn),
      .ram_waddr     (ram_waddr),
      .ram_raddr     (ram_raddr),
      .ram_wen       (ram_wen),
      .ram_ren       (ram_ren),
      .ram_wdata     (ram_wdata),
      .ram_rdata     (ram_rdata),
      .ram_sel       (ram_sel),
      .ir_ram_wen    (ir_ram_wen),
      .ir_ram_waddr  (ir_ram_waddr),
      .ir_ram_wdata  (ir_ram_wdata),
      .ir_ram_ren    (ir_ram_ren),
      .ir_ram_raddr  (ir_ram_raddr),
      .ir_ram_rdata  (ir_ram_rdata),
      .in_ram_wen    (in_ram_wen),
      .in_ram_waddr  (in_ram_waddr),
      .in_ram_wdata  (in_ram_wdata),
      .in_ram_ren    (in_ram_ren),
      .in_ram_raddr  (in_ram_raddr),
      .in_ram_rdata  (in_ram_rdata),
      .out_ram_wen   (out_ram_wen),
      .out_ram_waddr (out_ram_waddr),
      .out_ram_wdata (out_ram_wdata),
      .out_ram_ren   (out_ram_ren),
      .out_ram_raddr (out_ram_raddr),
      .out_ram_rdata (out_ram_rdata),
      .conv_ram_sel  (conv_ram_sel),
      .conv_ram_wen  (conv_ram_wen),
      .conv_ram_waddr(conv_ram_waddr),
      .conv_ram_wdata(conv_ram_wdata),
      .conv_ram_ren  (conv_ram_ren),
      .conv_ram_raddr(conv_ram_raddr),
      .conv_ram_rdata(conv_ram_rdata),
      .bn_ram_sel    (bn_ram_sel),
      .bn_ram_wen    (bn_ram_wen),
      .bn_ram_waddr  (bn_ram_waddr),
      .bn_ram_wdata  (bn_ram_wdata),
      .bn_ram_ren    (bn_ram_ren),
      .bn_ram_raddr  (bn_ram_raddr),
      .bn_ram_rdata  (bn_ram_rdata)
  );
endmodule
// limitations:
//  - no partial access supported; only word access
//  - no wait process
//
//----------------------------------------------------------

module ahb_slave #(
    parameter T_ADDR_WID = 14
) (
    input         hresetn,
    input         hclk,
    input         hsel,
    input  [31:0] haddr,
    input  [ 1:0] htrans,
    input         hwrite,
    input  [ 2:0] hsize,
    input  [ 2:0] hburst,
    input  [31:0] hwdata,
    output [31:0] hrdata,
    output [ 1:0] hresp,
    output        hready,

    output reg [T_ADDR_WID-1:0] t_waddr,
    output     [T_ADDR_WID-1:0] t_raddr,
    output reg                  t_wren,
    output                      t_rden,
    output     [          31:0] t_wdata,
    input      [          31:0] t_rdata
);

  wire wr_en;
  wire rd_en;
  wire ready_en;

  assign hresp    = 2'b00;  //always ok
  assign hready   = 1'b1;  //no wait
  assign ready_en = hsel & htrans[1];
  assign wr_en    = ready_en & hwrite;
  assign rd_en    = ready_en & (!hwrite);

  assign t_rden   = rd_en;
  assign t_raddr  = rd_en ? haddr[T_ADDR_WID-1:0] : 'h0;

  always @(posedge hclk or negedge hresetn) begin
    if (~hresetn) begin
      t_waddr <= 'h0;
    end else if (hsel) begin
      t_waddr <= haddr[T_ADDR_WID-1:0];
    end
  end

  always @(posedge hclk or negedge hresetn) begin
    if (~hresetn) begin
      t_wren <= 1'b0;
    end else if (wr_en) begin
      t_wren <= 1'b1;
    end else begin
      t_wren <= 1'b0;
    end
  end

  assign t_wdata = hwdata;
  assign hrdata  = t_rdata;


endmodule
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
//---------------------------------------------------------
//             __    __    __    __    __    _
// clk      __|  |__|  |__|  |__|  |__|  |__|
//             _____             _____
// t_addr   xxx_____xxxxxxxxxxxxx_____xxx
//             _____
// t_rden   __|     |____________________
//                   _____
// t_rdata  xxxxxxxxx_____xxxxxxxxxxxxxxx
//                               _____
// t_wren   ____________________|     |__
//                               _____
// t_wdata  xxxxxxxxxxxxxxxxxxxxx_____xxxx
//----------------------------------------------------------

module addr_map #(
    parameter T_ADDR_WID = 14
) (
    input                       clk,
    input                       rstn,
    input      [T_ADDR_WID-1:0] t_waddr,
    input      [T_ADDR_WID-1:0] t_raddr,
    input                       t_wren,
    input                       t_rden,
    input      [          31:0] t_wdata,
    output reg [          31:0] t_rdata,

    output [10:0] ram_waddr,
    output [10:0] ram_raddr,
    output        ram_wen,
    output        ram_ren,
    output [31:0] ram_wdata,
    input  [31:0] ram_rdata,
    output [ 7:0] ram_sel,

    output data_ram_ctrl,
    output conv_ram_ctrl,
    output reg apu_ready,

    input     cal_cpl,
    output   int_cal
);

  localparam RAM_CTRL_ADDR = 14'h2000;
  localparam RAM_SEL_ADDR = 14'h2004;
  localparam APU_READY_ADDR = 14'h2008;
  localparam CPL_ADDR = 14'h200C;

  reg  [           7:0] ram_sel_reg;
  reg  [           1:0] ram_ctrl_reg;

  wire                  ram_space;
   
  reg  [T_ADDR_WID-1:0] t_raddr_d;

  reg                   cal_cpl_r;
  reg                   cal_cpl_r_d;

  assign int_cal = cal_cpl_r;

  always @(posedge clk or negedge rstn) begin
    if (~rstn) begin
      cal_cpl_r <= 'h0;
    end else if (cal_cpl) begin
      cal_cpl_r <= 1'b1;
    end else if(t_raddr == CPL_ADDR && t_rden == 1'b1) begin
      cal_cpl_r <= 1'b0;
    end
  end

  always @(posedge clk or negedge rstn) begin
    if (~rstn) begin
      cal_cpl_r_d <= 'h0;
    end else  begin
      cal_cpl_r_d <= cal_cpl_r;
    end
  end

  always @(posedge clk or negedge rstn) begin
    if (~rstn) begin
      t_raddr_d <= 'h0;
    end else if (t_rden) begin
      t_raddr_d <= t_raddr;
    end
  end

  //read pro
  always @(*) begin
    if (t_raddr_d < RAM_CTRL_ADDR) begin
      t_rdata = ram_rdata;
    end else if (t_raddr_d == RAM_CTRL_ADDR) begin
      t_rdata = {30'b0, ram_ctrl_reg};
    end else if (t_raddr_d == RAM_SEL_ADDR) begin
      t_rdata = {24'b0, ram_sel_reg};
    end else if (t_raddr_d == CPL_ADDR) begin
      t_rdata = {31'b0, cal_cpl_r_d}; 
    end else begin
      t_rdata = 32'haabbccdd;
    end
  end

  always @(posedge clk or negedge rstn) begin
    if (~rstn) begin
      ram_ctrl_reg <= 'h0;
      ram_sel_reg  <= 'h0;
      apu_ready    <= 1'b0;
    end else if (t_wren) begin
      if (t_waddr == RAM_CTRL_ADDR) begin
        ram_ctrl_reg <= ram_wdata[1:0];
      end
      if (t_waddr == RAM_SEL_ADDR) begin
        ram_sel_reg <= ram_wdata[7:0];
      end 
      if (t_waddr == APU_READY_ADDR) begin
        apu_ready <= ram_wdata[0];
      end 
    end else begin
      apu_ready <= 1'b0;
    end
  end

  assign ram_space     = (t_waddr < RAM_CTRL_ADDR) ? 1'b1 : 1'b0;

  assign ram_wen       = ram_space ? t_wren : 1'b0;
  assign ram_ren       = ram_space ? t_rden : 1'b0;
  assign ram_waddr     = t_waddr[12:2];
  assign ram_raddr     = t_raddr[12:2];
  assign ram_wdata     = t_wdata;

  assign data_ram_ctrl = ram_ctrl_reg[0];
  assign conv_ram_ctrl = ram_ctrl_reg[1];
  assign ram_sel       = ram_sel_reg;

endmodule

