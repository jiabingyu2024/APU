// Free-running cycle counter and optional compare interrupt source.
module soc_timer (
    input  logic        clk,
    input  logic        resetn,
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic [31:0] req_wdata,
    input  logic [ 3:0] req_wstrb,
    output logic        req_ready,
    output logic [31:0] req_rdata,
    output logic        irq
);

  logic [63:0] counter_q;
  logic [31:0] compare_q;
  logic [31:0] control_q;
  logic [31:0] rdata_q;
  logic        pending_q;

  function automatic logic [31:0] merge_wstrb(
      input logic [31:0] old_value,
      input logic [31:0] new_value,
      input logic [ 3:0] write_strobe
  );
    logic [31:0] result;
    begin
      result = old_value;
      for (int byte_index = 0; byte_index < 4; byte_index++) begin
        if (write_strobe[byte_index]) begin
          result[byte_index*8+:8] = new_value[byte_index*8+:8];
        end
      end
      return result;
    end
  endfunction

  assign req_ready = pending_q;
  assign req_rdata = rdata_q;
  assign irq = control_q[0] && control_q[1] && (counter_q[31:0] >= compare_q);

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      counter_q <= 64'b0;
      compare_q <= 32'hffff_ffff;
      control_q <= 32'b0;
      rdata_q   <= 32'b0;
      pending_q <= 1'b0;
    end else begin
      counter_q <= counter_q + 64'd1;

      if (pending_q) begin
        pending_q <= 1'b0;
      end else if (req_valid) begin
        pending_q <= 1'b1;

        unique case (req_addr[3:0])
          4'h0: rdata_q <= counter_q[31:0];
          4'h4: rdata_q <= counter_q[63:32];
          4'h8: begin
            rdata_q <= compare_q;
            if (|req_wstrb) compare_q <= merge_wstrb(compare_q, req_wdata, req_wstrb);
          end
          4'hc: begin
            rdata_q <= control_q;
            if (|req_wstrb) control_q <= merge_wstrb(control_q, req_wdata, req_wstrb);
          end
          default: rdata_q <= 32'b0;
        endcase
      end
    end
  end

endmodule
