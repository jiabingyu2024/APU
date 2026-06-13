// Completes unmapped accesses instead of leaving the CPU permanently stalled.
module default_slave (
    input  logic        clk,
    input  logic        resetn,
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    output logic        req_ready,
    output logic [31:0] req_rdata,
    output logic        fault,
    output logic [31:0] fault_addr
);

  logic pending_q;

  assign req_ready = pending_q;
  assign req_rdata = 32'hdead_beef;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      pending_q <= 1'b0;
      fault     <= 1'b0;
      fault_addr <= 32'b0;
    end else if (pending_q) begin
      pending_q <= 1'b0;
    end else if (req_valid) begin
      pending_q <= 1'b1;
      fault     <= 1'b1;
      fault_addr <= req_addr;
    end
  end

endmodule
