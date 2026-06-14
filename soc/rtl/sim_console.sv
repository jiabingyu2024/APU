// Simulation console. This is an MMIO peripheral, not the final board UART.
module sim_console (
    input  logic        clk,
    input  logic        resetn,
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic [31:0] req_wdata,
    input  logic [ 3:0] req_wstrb,
    output logic        req_ready,
    output logic [31:0] req_rdata,
    input  logic        tx_ready,
    output logic        tx_valid,
    output logic [ 7:0] tx_data,
    output logic [ 7:0] debug_code,
    output logic        sim_done,
    output logic [31:0] exit_code
);

  localparam logic [3:0] TXDATA_OFFSET = 4'h0;
  localparam logic [3:0] DEBUG_OFFSET  = 4'h4;
  localparam logic [3:0] STATUS_OFFSET = 4'h8;
  localparam logic [3:0] EXIT_OFFSET   = 4'hc;

  logic        pending_q;
  logic [31:0] rdata_q;

  assign req_ready = pending_q;
  assign req_rdata = rdata_q;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      pending_q  <= 1'b0;
      rdata_q    <= 32'b0;
      tx_valid   <= 1'b0;
      tx_data    <= 8'b0;
      debug_code <= 8'b0;
      sim_done   <= 1'b0;
      exit_code  <= 32'b0;
    end else begin
      tx_valid <= 1'b0;

      if (pending_q) begin
        pending_q <= 1'b0;
      end else if (req_valid) begin
        pending_q <= 1'b1;
        rdata_q   <= 32'b0;

        unique case (req_addr[3:0])
          TXDATA_OFFSET: begin
            if (|req_wstrb) begin
              tx_valid <= 1'b1;
              tx_data  <= req_wdata[7:0];
            end
          end
          DEBUG_OFFSET: begin
            if (|req_wstrb) begin
              debug_code <= req_wdata[7:0];
            end else begin
              rdata_q <= {24'b0, debug_code};
            end
          end
          STATUS_OFFSET: rdata_q <= {31'b0, tx_ready};
          EXIT_OFFSET: begin
            if (|req_wstrb) begin
              sim_done  <= 1'b1;
              exit_code <= req_wdata;
            end
          end
          default: rdata_q <= 32'b0;
        endcase
      end
    end
  end

endmodule
