// Read-only 512 KiB model store. Vivado can infer initialized block RAM from
// the same readmemh image used by Verilator; board-specific storage is deferred.
module model_rom #(
    parameter int WORDS = 128 * 1024,
    parameter string INIT_FILE = "soc/build/model.hex"
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic [ 3:0] req_wstrb,
    output logic        req_ready,
    output logic [31:0] req_rdata
);

  localparam int ADDR_WIDTH = $clog2(WORDS);

  logic [31:0] mem [0:WORDS-1];
  logic [ADDR_WIDTH-1:0] addr_q;
  logic                  pending_q;
  logic                  write_q;

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  assign req_ready = pending_q;
  assign req_rdata = write_q ? 32'hbad0_4000 : mem[addr_q];

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      addr_q    <= '0;
      pending_q <= 1'b0;
      write_q   <= 1'b0;
    end else if (pending_q) begin
      pending_q <= 1'b0;
    end else if (req_valid) begin
      addr_q    <= req_addr[ADDR_WIDTH+1:2];
      write_q   <= |req_wstrb;
      pending_q <= 1'b1;
    end
  end

endmodule
