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
