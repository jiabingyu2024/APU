// Single-master native PicoRV32 interconnect. There are no outstanding requests.
module soc_interconnect (
    input  logic        mem_valid,
    input  logic [31:0] mem_addr,
    input  logic [31:0] mem_wdata,
    input  logic [ 3:0] mem_wstrb,
    output logic        mem_ready,
    output logic [31:0] mem_rdata,

    output logic        ram_valid,
    input  logic        ram_ready,
    input  logic [31:0] ram_rdata,
    output logic        console_valid,
    input  logic        console_ready,
    input  logic [31:0] console_rdata,
    output logic        timer_valid,
    input  logic        timer_ready,
    input  logic [31:0] timer_rdata,
    output logic        apu_valid,
    input  logic        apu_ready,
    input  logic [31:0] apu_rdata,
    output logic        model_valid,
    input  logic        model_ready,
    input  logic [31:0] model_rdata,
    output logic        default_valid,
    input  logic        default_ready,
    input  logic [31:0] default_rdata,

    output logic [31:0] slave_addr,
    output logic [31:0] slave_wdata,
    output logic [ 3:0] slave_wstrb
);

  logic ram_select;
  logic console_select;
  logic timer_select;
  logic apu_select;
  logic model_select;
  logic default_select;

  always_comb begin
    ram_select     = mem_addr < 32'h0001_0000;
    console_select = (mem_addr & 32'hffff_f000) == 32'h1000_0000;
    timer_select   = (mem_addr & 32'hffff_f000) == 32'h1000_1000;
    apu_select     = (mem_addr >= 32'h2000_0000) && (mem_addr < 32'h2000_4000);
    model_select   = (mem_addr >= 32'h4000_0000) && (mem_addr < 32'h4008_0000);
    default_select = !(ram_select || console_select || timer_select || apu_select ||
                       model_select);

    ram_valid     = mem_valid && ram_select;
    console_valid = mem_valid && console_select;
    timer_valid   = mem_valid && timer_select;
    apu_valid     = mem_valid && apu_select;
    model_valid   = mem_valid && model_select;
    default_valid = mem_valid && default_select;

    slave_addr  = mem_addr;
    slave_wdata = mem_wdata;
    slave_wstrb = mem_wstrb;

    mem_ready = ram_ready || console_ready || timer_ready || apu_ready || model_ready ||
                default_ready;

    unique case (1'b1)
      ram_ready:     mem_rdata = ram_rdata;
      console_ready: mem_rdata = console_rdata;
      timer_ready:   mem_rdata = timer_rdata;
      apu_ready:     mem_rdata = apu_rdata;
      model_ready:   mem_rdata = model_rdata;
      default_ready: mem_rdata = default_rdata;
      default:       mem_rdata = 32'b0;
    endcase
  end

endmodule
