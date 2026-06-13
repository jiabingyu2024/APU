`timescale 1ns/1ps

// Converts one PicoRV32 native request into the fixed AHB transaction shape
// required by the existing APU wrapper. Only aligned 32-bit accesses are legal.
module native_to_apu_ahb #(
    parameter logic [31:0] APU_BASE = 32'h2000_0000
) (
    input  logic        clk,
    input  logic        resetn,

    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic [31:0] req_wdata,
    input  logic [ 3:0] req_wstrb,
    output logic        req_ready,
    output logic [31:0] req_rdata,

    output logic        hsel,
    output logic [31:0] haddr,
    output logic [ 1:0] htrans,
    output logic        hwrite,
    output logic [ 2:0] hsize,
    output logic [ 2:0] hburst,
    output logic [31:0] hwdata,
    input  logic [31:0] hrdata,
    input  logic [ 1:0] hresp,
    input  logic        hreadyout,

    output logic        access_fault,
    output logic [31:0] fault_addr
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_ADDR,
    ST_READ_WAIT,
    ST_READ_RESP,
    ST_WRITE_DATA,
    ST_WRITE_RESP,
    ST_ERROR_RESP
  } state_t;

  state_t state_q;

  logic [31:0] addr_q;
  logic [31:0] wdata_q;
  logic        write_q;
  logic        legal_request;

  always_comb begin
    legal_request = (req_addr[1:0] == 2'b00) &&
                    ((req_wstrb == 4'b0000) || (req_wstrb == 4'b1111));

    req_ready = 1'b0;
    req_rdata = 32'b0;

    hsel   = 1'b0;
    haddr  = addr_q - APU_BASE;
    htrans = 2'b00;
    hwrite = write_q;
    hsize  = 3'b010;
    hburst = 3'b000;
    hwdata = wdata_q;

    unique case (state_q)
      ST_ADDR: begin
        // The APU latches the write address here and observes read enable here.
        hsel   = 1'b1;
        htrans = 2'b10;
      end
      ST_READ_WAIT: begin
        // addr_map qualifies RAM reads with its registered t_waddr. Reissue the
        // same RAM address once so t_waddr and t_raddr both identify RAM space.
        hsel   = 1'b1;
        htrans = 2'b10;
      end
      ST_READ_RESP: begin
        // The nested APU read pipeline is now stable for every RAM_SEL target.
        req_ready = 1'b1;
        req_rdata = (hresp == 2'b00) ? hrdata : 32'hbad0_0001;
      end
      ST_WRITE_DATA: begin
        // Existing ahb_slave delays write enable by one cycle and consumes HWDATA now.
        hwdata = wdata_q;
      end
      ST_WRITE_RESP: begin
        req_ready = 1'b1;
      end
      ST_ERROR_RESP: begin
        req_ready = 1'b1;
        req_rdata = 32'hbad0_acce;
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state_q      <= ST_IDLE;
      addr_q       <= 32'b0;
      wdata_q      <= 32'b0;
      write_q      <= 1'b0;
      access_fault <= 1'b0;
      fault_addr   <= 32'b0;
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          if (req_valid) begin
            addr_q  <= req_addr;
            wdata_q <= req_wdata;
            write_q <= |req_wstrb;

            if (legal_request) begin
              state_q <= ST_ADDR;
            end else begin
              access_fault <= 1'b1;
              fault_addr   <= req_addr;
              state_q      <= ST_ERROR_RESP;
            end
          end
        end
        ST_ADDR: begin
          if (write_q) begin
            state_q <= ST_WRITE_DATA;
          end else if ((addr_q - APU_BASE) < 32'h0000_2000) begin
            // Prime the wrapper's registered RAM-space qualification.
            state_q <= ST_READ_WAIT;
          end else begin
            // Control/status registers, especially read-to-clear CPL, must not
            // receive the RAM-only extra delay.
            state_q <= ST_READ_RESP;
          end
        end
        ST_READ_WAIT: begin
          state_q <= ST_READ_RESP;
        end
        ST_READ_RESP, ST_WRITE_RESP, ST_ERROR_RESP: begin
          state_q <= ST_IDLE;
        end
        ST_WRITE_DATA: begin
          state_q <= ST_WRITE_RESP;
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // hreadyout is intentionally not used as a completion indication. The current
  // APU wrapper ties it high even though its internal RAM read data is registered.
  logic unused_hreadyout;
  assign unused_hreadyout = hreadyout;

endmodule
