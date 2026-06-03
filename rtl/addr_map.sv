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

