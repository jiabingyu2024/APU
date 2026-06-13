// PicoRV32 configuration wrapper for the simulation-first SoC.
module picorv32_wrapper (
    input  logic        clk,
    input  logic        resetn,
    output logic        trap,
    output logic        mem_valid,
    output logic        mem_instr,
    input  logic        mem_ready,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [ 3:0] mem_wstrb,
    input  logic [31:0] mem_rdata
);

  logic        mem_la_read;
  logic        mem_la_write;
  logic [31:0] mem_la_addr;
  logic [31:0] mem_la_wdata;
  logic [ 3:0] mem_la_wstrb;
  logic        pcpi_valid;
  logic [31:0] pcpi_insn;
  logic [31:0] pcpi_rs1;
  logic [31:0] pcpi_rs2;
  logic [31:0] eoi;
  logic        trace_valid;
  logic [35:0] trace_data;

  picorv32 #(
      .ENABLE_COUNTERS   (1),
      .ENABLE_COUNTERS64 (0),
      .COMPRESSED_ISA    (1),
      .ENABLE_MUL        (1),
      .ENABLE_DIV        (1),
      .ENABLE_IRQ        (0),
      .CATCH_MISALIGN    (1),
      .CATCH_ILLINSN     (1),
      .PROGADDR_RESET    (32'h0000_0000),
      .STACKADDR         (32'h0001_0000)
  ) u_cpu (
      .clk          (clk),
      .resetn       (resetn),
      .trap         (trap),
      .mem_valid    (mem_valid),
      .mem_instr    (mem_instr),
      .mem_ready    (mem_ready),
      .mem_addr     (mem_addr),
      .mem_wdata    (mem_wdata),
      .mem_wstrb    (mem_wstrb),
      .mem_rdata    (mem_rdata),
      .mem_la_read  (mem_la_read),
      .mem_la_write (mem_la_write),
      .mem_la_addr  (mem_la_addr),
      .mem_la_wdata (mem_la_wdata),
      .mem_la_wstrb (mem_la_wstrb),
      .pcpi_valid   (pcpi_valid),
      .pcpi_insn    (pcpi_insn),
      .pcpi_rs1     (pcpi_rs1),
      .pcpi_rs2     (pcpi_rs2),
      .pcpi_wr      (1'b0),
      .pcpi_rd      (32'b0),
      .pcpi_wait    (1'b0),
      .pcpi_ready   (1'b0),
      .irq          (32'b0),
      .eoi          (eoi),
      .trace_valid  (trace_valid),
      .trace_data   (trace_data)
  );

endmodule
