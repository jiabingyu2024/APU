`timescale 1ns/1ps

module tb_native_to_apu_ahb;

  logic        clk = 1'b0;
  logic        resetn = 1'b0;
  logic        req_valid;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [ 3:0] req_wstrb;
  logic        req_ready;
  logic [31:0] req_rdata;
  logic        hsel;
  logic [31:0] haddr;
  logic [ 1:0] htrans;
  logic        hwrite;
  logic [ 2:0] hsize;
  logic [ 2:0] hburst;
  logic [31:0] hwdata;
  logic [31:0] hrdata;
  logic [ 1:0] hresp;
  logic        hreadyout;
  logic        access_fault;
  logic [31:0] fault_addr;

  int unsigned address_phase_count;
  logic        previous_address_was_write;

  always #5 clk = ~clk;

  native_to_apu_ahb dut (
      .clk         (clk),
      .resetn      (resetn),
      .req_valid   (req_valid),
      .req_addr    (req_addr),
      .req_wdata   (req_wdata),
      .req_wstrb   (req_wstrb),
      .req_ready   (req_ready),
      .req_rdata   (req_rdata),
      .hsel        (hsel),
      .haddr       (haddr),
      .htrans      (htrans),
      .hwrite      (hwrite),
      .hsize       (hsize),
      .hburst      (hburst),
      .hwdata      (hwdata),
      .hrdata      (hrdata),
      .hresp       (hresp),
      .hreadyout   (hreadyout),
      .access_fault(access_fault),
      .fault_addr  (fault_addr)
  );

  always_ff @(posedge clk) begin
    if (!resetn) begin
      address_phase_count       <= 0;
      previous_address_was_write <= 1'b0;
    end else begin
      previous_address_was_write <= hsel && htrans[1] && hwrite;

      if (hsel && htrans[1]) begin
        if (htrans != 2'b10) $fatal(1, "AHB transfer must be NONSEQ");
        if (address_phase_count == 0 && (haddr != 32'h0000_2004 || !hwrite)) begin
          $fatal(1, "Write global-to-local address translation mismatch");
        end
        if ((address_phase_count == 1 || address_phase_count == 2) &&
            (haddr != 32'h0000_0000 || hwrite)) begin
          $fatal(1, "Read global-to-local address translation mismatch");
        end
        address_phase_count <= address_phase_count + 1;
        if (haddr[31:14] != 0 || hsize != 3'b010 || hburst != 3'b000) begin
          $fatal(1, "Malformed AHB address phase");
        end
      end

      if (previous_address_was_write && hwdata != 32'h55aa_c33c) begin
        $fatal(1, "Write data was not held in the AHB data phase");
      end
    end
  end

  task automatic native_access(
      input logic [31:0] address,
      input logic [31:0] write_data,
      input logic [ 3:0] write_strobe,
      output logic [31:0] read_data
  );
    begin
      @(negedge clk);
      req_valid = 1'b1;
      req_addr  = address;
      req_wdata = write_data;
      req_wstrb = write_strobe;
      do @(posedge clk); while (!req_ready);
      read_data = req_rdata;
      @(negedge clk);
      req_valid = 1'b0;
      req_addr  = 32'b0;
      req_wdata = 32'b0;
      req_wstrb = 4'b0;
    end
  endtask

  logic [31:0] read_data;

  initial begin
    req_valid = 1'b0;
    req_addr = 32'b0;
    req_wdata = 32'b0;
    req_wstrb = 4'b0;
    hrdata = 32'hcafe_babe;
    hresp = 2'b00;
    hreadyout = 1'b1;

    repeat (4) @(posedge clk);
    resetn = 1'b1;

    native_access(32'h2000_2004, 32'h55aa_c33c, 4'b1111, read_data);
    if (address_phase_count != 1) $fatal(1, "Write address phase count mismatch");

    native_access(32'h2000_0000, 32'b0, 4'b0000, read_data);
    if (address_phase_count != 3 || read_data != 32'hcafe_babe) begin
      $fatal(1, "Read transaction mismatch");
    end

    native_access(32'h2000_0000, 32'h0000_00ff, 4'b0001, read_data);
    if (address_phase_count != 3 || !access_fault || fault_addr != 32'h2000_0000) begin
      $fatal(1, "Illegal partial access reached AHB or fault was not recorded");
    end

    $display("BRIDGE UNIT PASS");
    $finish;
  end

endmodule
