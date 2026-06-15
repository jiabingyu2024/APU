`timescale 1ns/1ps

module InBuf #(
    parameter int PERIOD = 10,
    parameter int P_BINDWIDTH = 64
) (
    input  logic                    clk,
    input  logic                    nRst,
    input  logic                    iSelect,
    input  logic                    nWe,
    input  logic [31:0]             iInstruction,
    input  logic [P_BINDWIDTH-1:0]  iWriteDataA,
    input  logic [P_BINDWIDTH-1:0]  iWriteDataB,
    input  logic                    nCe,
    output logic [P_BINDWIDTH-1:0]  oInData
);

  localparam logic [1:0] CALC_RESIDUAL = 2'b01;
  localparam logic [2:0] LAYER2_IN_HW  = 3'd4;
  localparam logic [7:0] LAYER2_PERIOD = 8'd38;
  localparam logic [7:0] LAYER3_PERIOD = 8'd152;

  logic [1:0] calc_type;
  logic [2:0] in_hw;
  logic       residual_mode;
  logic       layer2_mode;

  logic [7:0] count;
  logic [7:0] count_top;
  logic       main_select;
  logic [P_BINDWIDTH-1:0] replay_word0;
  logic [P_BINDWIDTH-1:0] replay_word1;
  logic [P_BINDWIDTH-1:0] selected_data;
  logic [P_BINDWIDTH-1:0] shortcut_data;
  logic [P_BINDWIDTH-1:0] replay_data;
  logic                   replay_enable;
  logic [P_BINDWIDTH-1:0] rBuf;

  assign calc_type    = iInstruction[31:30];
  assign in_hw        = iInstruction[27:25];
  assign residual_mode = (calc_type == CALC_RESIDUAL);
  assign layer2_mode   = (in_hw == LAYER2_IN_HW);
  assign count_top     = layer2_mode ? LAYER2_PERIOD : LAYER3_PERIOD;

  assign selected_data = iSelect ? iWriteDataB : iWriteDataA;

  // The shortcut is always in the SRAM opposite the registered main source.
  // Use main_select rather than the current iSelect so the final layer3
  // shortcut word can still be captured after Ctrl switches back to main.
  assign shortcut_data = main_select ? iWriteDataA : iWriteDataB;

  always_comb begin
    if (layer2_mode) begin
      replay_data = replay_word0;
    end else if ((count == 8'd74) ||
                 (count == 8'd112) ||
                 (count == 8'd150)) begin
      replay_data = replay_word0;
    end else begin
      replay_data = replay_word1;
    end

    replay_enable = residual_mode && (iSelect != main_select);
    if (layer2_mode) begin
      replay_enable = replay_enable && (count > 8'd20);
    end else begin
      replay_enable = replay_enable && (count > 8'd40);
    end
  end

  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      count        <= '0;
      main_select  <= 1'b0;
      replay_word0 <= '0;
      replay_word1 <= '0;
      rBuf         <= '0;
    end else if (nWe) begin
      count        <= '0;
      main_select  <= iSelect;
      replay_word0 <= '0;
      replay_word1 <= '0;
    end else begin
      if (residual_mode) begin
        if (count == count_top - 1'b1) begin
          count <= '0;
        end else begin
          count <= count + 1'b1;
        end

        // Ctrl preselects the main SRAM before the instruction starts. Capture
        // it after one active cycle, matching the original protocol.
        if (count == 8'd1) begin
          main_select <= iSelect;
        end

        // FeatureProcessor has a registered read output. The shortcut request
        // occurs at 18 (layer2) or 36/37 (layer3), so capture one cycle later.
        if (layer2_mode) begin
          if (count == 8'd19) begin
            replay_word0 <= shortcut_data;
          end
        end else begin
          if (count == 8'd37) begin
            replay_word0 <= shortcut_data;
          end
          if (count == 8'd38) begin
            replay_word1 <= shortcut_data;
          end
        end
      end else begin
        count <= '0;
      end

      if (replay_enable) begin
        rBuf <= replay_data;
      end else begin
        rBuf <= selected_data;
      end
    end
  end

  assign oInData = nCe ? '0 : rBuf;

endmodule
