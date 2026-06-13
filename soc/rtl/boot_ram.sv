// 64 KiB unified instruction/data RAM with byte write enables.
module boot_ram #(
    parameter int WORDS = 16 * 1024,
    parameter string INIT_FILE = "soc/build/firmware.hex"
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic [31:0] req_wdata,
    input  logic [ 3:0] req_wstrb,
    output logic        req_ready,
    output logic [31:0] req_rdata
);

  localparam int ADDR_WIDTH = $clog2(WORDS);

  logic [31:0] mem [0:WORDS-1];
  logic [ADDR_WIDTH-1:0] addr_q;
  logic                  pending_q;

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  assign req_ready = pending_q;
  assign req_rdata = mem[addr_q];

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      addr_q    <= '0;
      pending_q <= 1'b0;
    end else if (pending_q) begin
      // The request completes during this cycle.
      pending_q <= 1'b0;
    end else if (req_valid) begin
      addr_q    <= req_addr[ADDR_WIDTH+1:2];
      pending_q <= 1'b1;

      if (req_wstrb[0]) mem[req_addr[ADDR_WIDTH+1:2]][7:0]   <= req_wdata[7:0];
      if (req_wstrb[1]) mem[req_addr[ADDR_WIDTH+1:2]][15:8]  <= req_wdata[15:8];
      if (req_wstrb[2]) mem[req_addr[ADDR_WIDTH+1:2]][23:16] <= req_wdata[23:16];
      if (req_wstrb[3]) mem[req_addr[ADDR_WIDTH+1:2]][31:24] <= req_wdata[31:24];
    end
  end

endmodule
