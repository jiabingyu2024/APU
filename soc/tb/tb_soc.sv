`timescale 1ns/1ps

module tb_soc;

  logic        clk = 1'b0;
  logic        resetn = 1'b0;
  logic        trap;
  logic        console_tx_valid;
  logic [ 7:0] console_tx_data;
  logic        sim_done;
  logic [31:0] sim_exit_code;
  logic        bus_fault;
  logic [31:0] bus_fault_addr;
  logic        timer_irq;
  logic        apu_access_fault;
  logic [31:0] apu_fault_addr;
  logic        apu_int_cal;
  logic        apu_completion_seen;

  int unsigned cycle_count;

  always #5 clk = ~clk;

  riscv_apu_soc_top dut (
      .clk             (clk),
      .resetn          (resetn),
      .trap            (trap),
      .console_tx_ready(1'b1),
      .console_tx_valid(console_tx_valid),
      .console_tx_data (console_tx_data),
      .sim_done        (sim_done),
      .sim_exit_code   (sim_exit_code),
      .bus_fault       (bus_fault),
      .bus_fault_addr  (bus_fault_addr),
      .timer_irq       (timer_irq),
      .apu_access_fault(apu_access_fault),
      .apu_fault_addr  (apu_fault_addr),
      .apu_int_cal     (apu_int_cal)
  );

  initial begin
    repeat (10) @(posedge clk);
    resetn <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      cycle_count         <= 0;
      apu_completion_seen <= 1'b0;
    end else begin
      cycle_count <= cycle_count + 1;

      if (apu_int_cal) begin
        apu_completion_seen <= 1'b1;
      end

      if (console_tx_valid) begin
        $write("%c", console_tx_data);
      end

      if (trap) begin
        $fatal(1, "PicoRV32 trap at cycle %0d", cycle_count);
      end

      if (sim_done) begin
        if (sim_exit_code != 0) begin
          $fatal(1, "Firmware failed with code 0x%08x", sim_exit_code);
        end
        if (!bus_fault || bus_fault_addr != 32'h3000_0000) begin
          $fatal(1, "Default slave evidence missing: fault=%0b addr=0x%08x",
                 bus_fault, bus_fault_addr);
        end
        if (!timer_irq) begin
          $fatal(1, "Timer compare interrupt output was not asserted");
        end
        if (!apu_access_fault || apu_fault_addr != 32'h2000_0038) begin
          $fatal(1, "APU illegal-access evidence missing: fault=%0b addr=0x%08x",
                 apu_access_fault, apu_fault_addr);
        end
        if (!apu_completion_seen) begin
          $fatal(1, "APU completion interrupt was never observed");
        end
        if (apu_int_cal) begin
          $fatal(1, "APU completion interrupt was not cleared by CPL read");
        end
        $display("SIM PASS cycles=%0d", cycle_count);
        $finish;
      end

      if (cycle_count >= 20_000_000) begin
        $fatal(1, "Simulation timeout");
      end
    end
  end

endmodule
