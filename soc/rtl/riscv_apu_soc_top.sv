// Simulation-first SoC top. The APU port is added after the CPU/bus baseline is stable.
module riscv_apu_soc_top #(
    parameter string FIRMWARE_INIT_FILE = "soc/build/firmware.hex",
    parameter string MODEL_INIT_FILE = "soc/build/model.hex"
) (
    input  logic        clk,
    input  logic        resetn,
    output logic        trap,
    input  logic        console_tx_ready,
    output logic        console_tx_valid,
    output logic [ 7:0] console_tx_data,
    output logic        sim_done,
    output logic [31:0] sim_exit_code,
    output logic        bus_fault,
    output logic [31:0] bus_fault_addr,
    output logic        timer_irq,
    output logic        apu_access_fault,
    output logic [31:0] apu_fault_addr,
    output logic        apu_int_cal
);

  logic        mem_valid;
  logic        mem_instr;
  logic        mem_ready;
  logic [31:0] mem_addr;
  logic [31:0] mem_wdata;
  logic [ 3:0] mem_wstrb;
  logic [31:0] mem_rdata;

  logic        ram_valid;
  logic        ram_ready;
  logic [31:0] ram_rdata;
  logic        console_valid;
  logic        console_ready;
  logic [31:0] console_rdata;
  logic        timer_valid;
  logic        timer_ready;
  logic [31:0] timer_rdata;
  logic        default_valid;
  logic        default_ready;
  logic [31:0] default_rdata;
  logic        model_valid;
  logic        model_ready;
  logic [31:0] model_rdata;
  logic [31:0] slave_addr;
  logic [31:0] slave_wdata;
  logic [ 3:0] slave_wstrb;

  logic        apu_valid;
  logic        apu_ready;
  logic [31:0] apu_rdata;
  logic        apu_hsel;
  logic [31:0] apu_haddr;
  logic [ 1:0] apu_htrans;
  logic        apu_hwrite;
  logic [ 2:0] apu_hsize;
  logic [ 2:0] apu_hburst;
  logic [31:0] apu_hwdata;
  logic [31:0] apu_hrdata;
  logic [ 1:0] apu_hresp;
  logic        apu_hreadyout;

  picorv32_wrapper u_cpu_wrapper (
      .clk       (clk),
      .resetn    (resetn),
      .trap      (trap),
      .mem_valid (mem_valid),
      .mem_instr (mem_instr),
      .mem_ready (mem_ready),
      .mem_addr  (mem_addr),
      .mem_wdata (mem_wdata),
      .mem_wstrb (mem_wstrb),
      .mem_rdata (mem_rdata)
  );

  soc_interconnect u_interconnect (
      .mem_valid    (mem_valid),
      .mem_addr     (mem_addr),
      .mem_wdata    (mem_wdata),
      .mem_wstrb    (mem_wstrb),
      .mem_ready    (mem_ready),
      .mem_rdata    (mem_rdata),
      .ram_valid    (ram_valid),
      .ram_ready    (ram_ready),
      .ram_rdata    (ram_rdata),
      .console_valid(console_valid),
      .console_ready(console_ready),
      .console_rdata(console_rdata),
      .timer_valid  (timer_valid),
      .timer_ready  (timer_ready),
      .timer_rdata  (timer_rdata),
      .apu_valid    (apu_valid),
      .apu_ready    (apu_ready),
      .apu_rdata    (apu_rdata),
      .model_valid  (model_valid),
      .model_ready  (model_ready),
      .model_rdata  (model_rdata),
      .default_valid(default_valid),
      .default_ready(default_ready),
      .default_rdata(default_rdata),
      .slave_addr   (slave_addr),
      .slave_wdata  (slave_wdata),
      .slave_wstrb  (slave_wstrb)
  );

  boot_ram #(
      .INIT_FILE(FIRMWARE_INIT_FILE)
  ) u_boot_ram (
      .clk       (clk),
      .resetn    (resetn),
      .req_valid (ram_valid),
      .req_addr  (slave_addr),
      .req_wdata (slave_wdata),
      .req_wstrb (slave_wstrb),
      .req_ready (ram_ready),
      .req_rdata (ram_rdata)
  );

  sim_console u_sim_console (
      .clk       (clk),
      .resetn    (resetn),
      .req_valid (console_valid),
      .req_addr  (slave_addr),
      .req_wdata (slave_wdata),
      .req_wstrb (slave_wstrb),
      .req_ready (console_ready),
      .req_rdata (console_rdata),
      .tx_ready  (console_tx_ready),
      .tx_valid  (console_tx_valid),
      .tx_data   (console_tx_data),
      .sim_done  (sim_done),
      .exit_code (sim_exit_code)
  );

  soc_timer u_timer (
      .clk       (clk),
      .resetn    (resetn),
      .req_valid (timer_valid),
      .req_addr  (slave_addr),
      .req_wdata (slave_wdata),
      .req_wstrb (slave_wstrb),
      .req_ready (timer_ready),
      .req_rdata (timer_rdata),
      .irq       (timer_irq)
  );

  default_slave u_default_slave (
      .clk       (clk),
      .resetn    (resetn),
      .req_valid (default_valid),
      .req_addr  (slave_addr),
      .req_ready (default_ready),
      .req_rdata (default_rdata),
      .fault     (bus_fault),
      .fault_addr(bus_fault_addr)
  );

  model_rom #(
      .INIT_FILE(MODEL_INIT_FILE)
  ) u_model_rom (
      .clk       (clk),
      .resetn    (resetn),
      .req_valid (model_valid),
      .req_addr  (slave_addr),
      .req_wstrb (slave_wstrb),
      .req_ready (model_ready),
      .req_rdata (model_rdata)
  );

  native_to_apu_ahb u_apu_bridge (
      .clk         (clk),
      .resetn      (resetn),
      .req_valid   (apu_valid),
      .req_addr    (slave_addr),
      .req_wdata   (slave_wdata),
      .req_wstrb   (slave_wstrb),
      .req_ready   (apu_ready),
      .req_rdata   (apu_rdata),
      .hsel        (apu_hsel),
      .haddr       (apu_haddr),
      .htrans      (apu_htrans),
      .hwrite      (apu_hwrite),
      .hsize       (apu_hsize),
      .hburst      (apu_hburst),
      .hwdata      (apu_hwdata),
      .hrdata      (apu_hrdata),
      .hresp       (apu_hresp),
      .hreadyout   (apu_hreadyout),
      .access_fault(apu_access_fault),
      .fault_addr  (apu_fault_addr)
  );

  Top u_apu (
      .clk      (clk),
      .nRst     (resetn),
      .hsel     (apu_hsel),
      .haddr    (apu_haddr),
      .htrans   (apu_htrans),
      .hwrite   (apu_hwrite),
      .hsize    (apu_hsize),
      .hburst   (apu_hburst),
      .hwdata   (apu_hwdata),
      .hready   (1'b1),
      .hlock    (1'b0),
      .hprot    (4'b0011),
      .hrdata   (apu_hrdata),
      .hresp    (apu_hresp),
      .hreadyout(apu_hreadyout),
      .int_cal  (apu_int_cal)
  );

endmodule
