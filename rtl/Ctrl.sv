module Ctrl #(
    parameter P_BINDWIDTH = 64,
    parameter P_FEATURE_MEMORY_SIZE = 65536
) (
    input  logic clk,
    input  logic nRst,
    input  logic nCe,

    // 来自 WorkSheet：当前正在执行的 32-bit 指令。
    // WorkSheet 仅在收到 oComputeDone 后切换到下一条指令。
    input  logic [31:0] iInstruction,

    // ActSRAM 读写控制。读地址表示当前卷积窗口中心的 group0 物理地址。
    output logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oActReadCenterAddr,
    output logic                                                    oActReadEn,
    output logic [                                          1:0] oActKernelSize,
    output logic [                                          5:0] oActHW,
    output logic [                                          3:0] oActlogInC,
    output logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oActWriteAddr,
    output logic                                                    oActWriteEn,

    // InBuf 控制：oInputBufNWe 为低有效写使能；Select=0 选择 ActSRAM，1 选择 OutSRAM。
    output logic oInputBufNWe,
    output logic oInputBufSelect,

    // OutSRAM 读写控制，语义与 ActSRAM 对称。
    output logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oOutReadCenterAddr,
    output logic                                                    oOutReadEn,
    output logic [                                          1:0] oOutKernelSize,
    output logic [                                          5:0] oOutHW,
    output logic [                                          3:0] oOutlogInC,
    output logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oOutWriteAddr,
    output logic                                                    oOutWriteEn,

    // SIMD/BN 参数表地址。每个 64-channel 输出组使用一个 entry。
    output logic [4:0] oBNAddr,

    // ComputeCoreGroup 控制：权重 SRAM 地址、读使能和累加器操作码。
    output logic [7:0] oWeightAddr,
    output logic       oWeightReadEn,
    output logic [1:0] oAccInstr,

    // 向 WorkSheet 返回单周期完成脉冲；同拍翻转 pingpong。
    output logic oComputeDone
);

  // Ctrl 是整条计算路径的时序所有者。它没有 valid-ready 握手，所有控制都依赖：
  // FeatureSRAM 同步读 1 拍 + InBuf 1 拍，以及 WeightSRAM 1 拍 + WeightBuffer 1 拍。
  // 修改任一存储/缓冲级延迟时，必须同步重做 acc/write 控制相位。
  localparam int FEATURE_ADDR_WIDTH = $clog2(P_FEATURE_MEMORY_SIZE / P_BINDWIDTH);

  localparam logic [1:0] CALC_NORMAL   = 2'b00;
  localparam logic [1:0] CALC_RESIDUAL = 2'b01;

  localparam logic [1:0] ACC_CLEAR = 2'b00;
  localparam logic [1:0] ACC_LOAD  = 2'b01;
  localparam logic [1:0] ACC_ADD   = 2'b10;

  typedef enum logic [1:0] {
    IDLE  = 2'b00,  // 等待指令或执行完成后的尾部写回
    CONV  = 2'b01,  // normal 主路径，或 residual 的 3x3 主路径
    CONV2 = 2'b11   // residual shortcut 的附加 1x1 累加拍
  } state_t;

  state_t state;

  // 双 Feature SRAM 的运行期角色：
  // pingpong=0：ActSRAM 为主输入，OutSRAM 为写回目标；
  // pingpong=1：OutSRAM 为主输入，ActSRAM 为写回目标。
  // 每条指令只允许翻转一次，nCe 不清零它，否则分批执行 layer3 时会读错 SRAM。
  logic pingpong;

  // 指令字段。拼接顺序固定，详见 docs/design/final/03_INSTRUCTION_AND_NETWORK.md。
  logic [1:0] calc_type;
  logic [1:0] kernel_size;
  logic [2:0] log_in_hw;
  logic [3:0] log_in_c;
  logic [3:0] log_out_c;
  logic [1:0] stride1;
  logic [1:0] stride2;
  logic [7:0] weight_base;
  logic [4:0] bn_base;

  // 指令派生出的 shape。当前经过完整回归的范围仅为：
  // H/W=8/16/32，输入/输出通道组 IG/OG=1/2/4，每组固定 64 channel。
  logic [5:0]  input_hw;
  logic [5:0]  output_hw;
  logic [2:0]  input_groups;
  logic [2:0]  output_groups;
  // 每个输出像素包含 IG*OG 个 9-cycle chunk。
  // 必须能表示 4*4=16；若误写成 4 bit，16 会截断为 0，layer3 residual 永不完成。
  logic [15:0] groups_per_pixel;
  logic [15:0] pixels_per_group;   // 输出空间点数 Hout*Wout
  logic [7:0]  cycles_per_chunk;   // 3x3 为 9，非 3x3 路径为 1
  logic [15:0] weight_span;        // 当前指令在每个 WeightSRAM bank 中的循环跨度

  // 主路径采用“扁平 token”顺序，而不是直观的三层 for 循环：
  //   cycle   ：当前 chunk 内的 kernel 相位 0..8；
  //   cut_num ：每完成一个 9-cycle chunk 加 1，是地址和组边界的规范索引；
  //   t/round ：只用于记录总进度和结束条件，不能拿它们重写数据展开顺序。
  // 若按变量名把 round/t 改写成标准 output-group/pixel 循环，会破坏权重文件顺序。
  logic [63:0] cut_num;
  logic [15:0] round;
  logic [15:0] t;
  logic [7:0]  cycle;

  logic [3:0] res_flag;    // CONV2 内 shortcut group 计数，IG=2/4 时长度为 1/2
  logic       CONV2_done;  // 防止同一主路径尾部重复进入 CONV2

  // 写回预控制。*_d 先由 FSM 产生，再寄存一拍输出到 FeatureProcessor。
  // 这一拍用于等待 accumulator 更新和组合 SIMD 比较结果稳定；删除会写入前一项结果。
  logic [FEATURE_ADDR_WIDTH-1:0] act_write_addr_d;
  logic [FEATURE_ADDR_WIDTH-1:0] out_write_addr_d;
  logic                          act_write_en_d;
  logic                          out_write_en_d;
  logic [1:0]                    acc_instr_d;

  logic [63:0] address_cut_num;       // 地址计算使用的稳定 cut_num
  logic [63:0] pixel_index;           // 当前输出空间点编号
  logic [63:0] row_skip_count;        // stride2/shortcut 的额外跨行次数
  logic [63:0] main_center_addr;       // 主路径 3x3 中心地址
  logic [63:0] shortcut_center_addr;   // residual 大 feature 的 stride2 采样地址
  logic [63:0] completed_word_addr;    // 已完成的 64-channel 输出 word 地址

  logic chunk_first;           // 当前 chunk 是否为一个输出 word 的第一个 IG chunk
  logic chunk_last;            // 当前 chunk 是否为一个输出 word 的最后一个 IG chunk
  logic final_chunk;           // 是否到达整条指令最后一个主路径 chunk
  logic final_shortcut_cycle;  // 是否到达当前 residual 的最后一个 shortcut 拍

  function automatic logic [5:0] decode_hw(input logic [2:0] encoded_hw);
    // 指令保存 log2(H/W)，这里转换成 FeatureProcessor 直接使用的实际尺寸。
    // default 仅用于保持旧实现兼容，不代表支持其他尺寸。
    case (encoded_hw)
      3'd3:    decode_hw = 6'd8;
      3'd4:    decode_hw = 6'd16;
      3'd5:    decode_hw = 6'd32;
      default: decode_hw = 6'd32;
    endcase
  endfunction

  function automatic logic [2:0] decode_groups(input logic [3:0] log_channels);
    // 将 log2(C) 转成 64-channel word 数，即 IG/OG=C/64。
    case (log_channels)
      4'd6:    decode_groups = 3'd1;
      4'd7:    decode_groups = 3'd2;
      4'd8:    decode_groups = 3'd4;
      default: decode_groups = 3'd1;
    endcase
  endfunction

  function automatic logic [3:0] normalized_log_channels(
      input logic [3:0] log_channels
  );
    // 输出给 FeatureProcessor 的仍是 log2(C)，非法编码回落到 64 channel。
    case (log_channels)
      4'd6, 4'd7, 4'd8: normalized_log_channels = log_channels;
      default:           normalized_log_channels = 4'd6;
    endcase
  endfunction

  function automatic logic is_first_chunk(
      input logic [63:0] chunk,
      input logic [ 2:0] groups
  );
    // IG 只支持 1/2/4，因此可用低位判断代替通用取模电路。
    // first chunk 同时决定 accumulator LOAD 和前一 word 的写回窗口。
    case (groups)
      3'd4:    is_first_chunk = (chunk[1:0] == 2'b00);
      3'd2:    is_first_chunk = (chunk[0] == 1'b0);
      default: is_first_chunk = 1'b1;
    endcase
  endfunction

  function automatic logic is_last_chunk(
      input logic [63:0] chunk,
      input logic [ 2:0] groups
  );
    // residual 仅在一个输出 word 的全部 IG 主路径 chunk 完成后进入 CONV2。
    case (groups)
      3'd4:    is_last_chunk = (chunk[1:0] == 2'b11);
      3'd2:    is_last_chunk = (chunk[0] == 1'b1);
      default: is_last_chunk = 1'b1;
    endcase
  endfunction

  function automatic logic [63:0] word_addr_from_chunk(
      input logic [63:0] chunk,
      input logic [ 2:0] groups
  );
    // 每 IG 个 chunk 生成一个物理输出 word，因此写地址为 cut_num/IG。
    case (groups)
      3'd4:    word_addr_from_chunk = chunk >> 2;
      3'd2:    word_addr_from_chunk = chunk >> 1;
      default: word_addr_from_chunk = chunk;
    endcase
  endfunction

  assign {
    calc_type,
    kernel_size,
    log_in_hw,
    log_in_c,
    log_out_c,
    stride1,
    stride2,
    weight_base,
    bn_base
  } = iInstruction;

  // ---------------------------------------------------------------------------
  // 指令组合解码
  // ---------------------------------------------------------------------------
  // stride2 字段保留在协议中，但当前 residual 地址使用固定网络等价公式，
  // 不是任意 shape/stride 的通用实现。
  always_comb begin
    input_hw        = decode_hw(log_in_hw);
    input_groups    = decode_groups(log_in_c);
    output_groups   = decode_groups(log_out_c);
    groups_per_pixel = 16'(input_groups) * 16'(output_groups);
    cycles_per_chunk = (kernel_size == 2'b11) ? 8'd9 : 8'd1;

    if ((calc_type == CALC_NORMAL) && stride1[1]) begin
      output_hw = input_hw >> 1;
    end else begin
      output_hw = input_hw;
    end

    pixels_per_group = output_hw * output_hw;

    // normal：每个输出组读取 9*IG 个权重 word。
    // residual：每个输出组额外读取 IG/2 个 shortcut 权重 word。
    // weight_span 是全局连续权重地址的回卷点，算错会造成整层周期性权重错位。
    weight_span = cycles_per_chunk * groups_per_pixel;
    if (calc_type == CALC_RESIDUAL) begin
      weight_span = weight_span + (groups_per_pixel >> 1);
    end
  end

  assign chunk_first = is_first_chunk(cut_num, input_groups);
  assign chunk_last  = is_last_chunk(cut_num, input_groups);
  assign completed_word_addr = word_addr_from_chunk(cut_num, input_groups);
  assign final_chunk = (round == (groups_per_pixel - 1'b1)) &&
                       (t == (pixels_per_group - 1'b1));
  assign final_shortcut_cycle =
      (res_flag == (4'(input_groups >> 1) - 4'd1));

  // ---------------------------------------------------------------------------
  // Feature 中心地址
  // ---------------------------------------------------------------------------
  // CONV 主路径结束的时钟沿已经执行 cut_num+1，下一拍进入 CONV2。
  // 因此 CONV2 地址必须使用 cut_num-1，保持在刚完成的输出 word；若直接使用
  // cut_num，shortcut 会提前到下一空间点。这里显式计算，避免旧实现的组合 latch。
  always_comb begin
    address_cut_num = cut_num;
    if (state == CONV2) begin
      address_cut_num = cut_num - 1'b1;
    end

    pixel_index = address_cut_num / groups_per_pixel;
    if (stride1[1] || (calc_type == CALC_RESIDUAL)) begin
      row_skip_count = pixel_index / (input_hw >> 1);
    end else begin
      row_skip_count = 64'd0;
    end

    main_center_addr = pixel_index * input_groups;
    if ((calc_type == CALC_NORMAL) && stride1[1]) begin
      // 固定网络的 stride2 等价式。常数 32 是输入 feature 每行的 word 数，
      // 只适用于文档列出的 32x64 和 16x128 等 shape。
      main_center_addr = main_center_addr * 2 + 32 * row_skip_count;
    end

    shortcut_center_addr = 64'd0;
    if (calc_type == CALC_RESIDUAL) begin
      // residual shortcut 来自尺寸加倍、通道减半的旧 feature。
      // 此公式只对已验证的 layer2/layer3 residual 成立。
      shortcut_center_addr = main_center_addr + 32 * (row_skip_count >> 1);
    end
  end

  // ---------------------------------------------------------------------------
  // 两块 Feature SRAM 的读所有权
  // ---------------------------------------------------------------------------
  // CONV 读取 pingpong 指定的主源；CONV2 反向读取另一块 SRAM 的 shortcut。
  // residual 模式下两侧中心地址始终保持有效，状态只负责切换 read enable。
  always_comb begin
    oActReadEn         = 1'b0;
    oOutReadEn         = 1'b0;
    oActReadCenterAddr = '0;
    oOutReadCenterAddr = '0;

    if (!pingpong) begin
      oActReadCenterAddr = main_center_addr[FEATURE_ADDR_WIDTH-1:0];
      oOutReadCenterAddr = shortcut_center_addr[FEATURE_ADDR_WIDTH-1:0];
    end else begin
      oOutReadCenterAddr = main_center_addr[FEATURE_ADDR_WIDTH-1:0];
      oActReadCenterAddr = shortcut_center_addr[FEATURE_ADDR_WIDTH-1:0];
    end

    case (state)
      CONV: begin
        // 主路径：pingpong=0 读 Act，pingpong=1 读 Out。
        oActReadEn = !pingpong;
        oOutReadEn = pingpong;
      end
      CONV2: begin
        // shortcut：读取主路径相反的 SRAM，其中仍保留 block 输入。
        oActReadEn = pingpong;
        oOutReadEn = !pingpong;
      end
      default: begin
        oActReadEn = 1'b0;
        oOutReadEn = 1'b0;
      end
    endcase
  end

  always_comb begin
    // shape 也必须随 SRAM 角色切换：主源使用 instruction 的 H/W、Cin、3x3；
    // residual 另一源使用 2*H/W、Cin/2、1x1。若 shape 与 read enable 不匹配，
    // FeatureProcessor 的行偏移和 depth 计数都会错误。
    oActKernelSize = 2'b00;
    oOutKernelSize = 2'b00;
    oActHW         = 6'd0;
    oOutHW         = 6'd0;
    oActlogInC     = 4'd0;
    oOutlogInC     = 4'd0;

    if (nRst) begin
      if (!pingpong) begin
        oActHW     = input_hw;
        oActlogInC = normalized_log_channels(log_in_c);
        if (calc_type == CALC_RESIDUAL) begin
          oOutHW     = input_hw << 1;
          oOutlogInC = normalized_log_channels(log_in_c) - 1'b1;
        end
      end else begin
        oOutHW     = input_hw;
        oOutlogInC = normalized_log_channels(log_in_c);
        if (calc_type == CALC_RESIDUAL) begin
          oActHW     = input_hw << 1;
          oActlogInC = normalized_log_channels(log_in_c) - 1'b1;
        end
      end

      if (!nCe) begin
        oActKernelSize = !pingpong ? kernel_size : 2'b01;
        oOutKernelSize =  pingpong ? kernel_size : 2'b01;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 写回和累加器控制流水
  // ---------------------------------------------------------------------------
  // 外部 SRAM 写控制固定延迟一拍。不要把该寄存器合并进 FSM：前一拍 accumulator
  // 才接收最后一个 popcount，组合 SIMDData 在本拍形成，下一时钟沿才能安全写 SRAM。
  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      // 全局复位同时建立初始 RAM 方向：Act -> Out。
      oActWriteAddr <= '0;
      oActWriteEn   <= 1'b0;
      oOutWriteAddr <= '0;
      oOutWriteEn   <= 1'b0;
    end else begin
      oActWriteAddr <= act_write_addr_d;
      oActWriteEn   <= act_write_en_d;
      oOutWriteAddr <= out_write_addr_d;
      oOutWriteEn   <= out_write_en_d;
    end
  end

  // AccInstr 相对 FSM 请求延迟一拍，用于匹配两条并行数据路径：
  // FeatureSRAM -> InBuf 与 WeightSRAM -> WeightBuffer。
  // 若删除该延迟，激活/权重与 LOAD/ADD 将属于不同 kernel 项。
  always_ff @(posedge clk) begin
    if (!nRst || nCe) begin
      oAccInstr <= ACC_CLEAR;
    end else begin
      oAccInstr <= acc_instr_d;
    end
  end

  // 在 InBuf 禁写阶段提前选择下一条指令的主 SRAM。
  // 这是指令边界的关键预取：若 residual 紧跟在 OutSRAM 生产者之后，而 IDLE 固定
  // 选择 ActSRAM，则 residual 第一个 accumulator word 会采到旧 ActSRAM 数据。
  always_ff @(posedge clk) begin
    if (!nRst || nCe) begin
      oInputBufSelect <= 1'b0;
    end else if ((state == IDLE) || oInputBufNWe) begin
      oInputBufSelect <= pingpong;
    end else begin
      oInputBufSelect <= oOutReadEn;
    end
  end

  // ---------------------------------------------------------------------------
  // 主控制状态机
  // ---------------------------------------------------------------------------
  // 控制优先级：异步复位 > nCe 停机 > IDLE/CONV/CONV2。
  // 例外：oComputeDone=1 时，即使 WorkSheet 同拍把 nCe 拉高，也要先进入 IDLE
  // 完成最后一个 word 的尾部写回。因此停机条件写成 nCe && !oComputeDone。
  // nCe 清运行计数但不清 pingpong，以支持 layer3 多批次连续执行。
  always_ff @(posedge clk or negedge nRst) begin
    if (!nRst) begin
      state             <= IDLE;
      pingpong          <= 1'b0;
      round             <= '0;
      t                 <= '0;
      cycle             <= '0;
      cut_num           <= '0;
      res_flag          <= '0;
      CONV2_done        <= 1'b0;
      oComputeDone      <= 1'b0;
      oInputBufNWe      <= 1'b1;
      oWeightAddr       <= '0;
      oWeightReadEn     <= 1'b0;
      oBNAddr           <= '0;
      acc_instr_d       <= ACC_CLEAR;
      act_write_addr_d  <= '0;
      act_write_en_d    <= 1'b0;
      out_write_addr_d  <= '0;
      out_write_en_d    <= 1'b0;
    end else if (nCe && !oComputeDone) begin
      // WorkSheet 未运行时关闭所有动态请求。pingpong 和 oBNAddr 保持，前者表示
      // 当前有效 feature 所在 SRAM，后者在尾写窗口仍可能被使用。
      state            <= IDLE;
      round            <= '0;
      t                <= '0;
      cycle            <= '0;
      cut_num          <= '0;
      res_flag         <= '0;
      CONV2_done       <= 1'b0;
      oComputeDone     <= 1'b0;
      oInputBufNWe     <= 1'b1;
      oWeightAddr      <= '0;
      oWeightReadEn    <= 1'b0;
      acc_instr_d      <= ACC_CLEAR;
      act_write_addr_d <= '0;
      act_write_en_d   <= 1'b0;
      out_write_addr_d <= '0;
      out_write_en_d   <= 1'b0;
    end else begin
      case (state)
        IDLE: begin
          oComputeDone     <= 1'b0;
          oInputBufNWe     <= 1'b1;
          oWeightReadEn    <= 1'b0;
          acc_instr_d      <= ACC_CLEAR;
          act_write_en_d   <= 1'b0;
          out_write_en_d   <= 1'b0;

          if (oComputeDone) begin
            // 正常稳态依赖“下一输出 word 开始”触发前一 word 写回，但整层最后一个
            // word 没有下一项。因此完成后的 IDLE 拍必须补发一次尾写使能。
            // 此时 pingpong 已翻转，所以目标 SRAM 要按新方向反选；删掉会丢最后
            // 一个 64-bit word，按旧方向选择则会写回源 SRAM。
            state          <= IDLE;
            round          <= '0;
            t              <= '0;
            cycle          <= '0;
            cut_num        <= '0;
            res_flag       <= '0;
            CONV2_done     <= 1'b0;
            oWeightAddr    <= '0;
            oWeightReadEn  <= 1'b0;
            act_write_en_d <= !pingpong;
            out_write_en_d <=  pingpong;
          end else if (calc_type != 2'b11) begin
            // 指令有效即进入主路径。首拍只发出地址并清 accumulator 控制，随后
            // 由固定两级数据延迟把首项送到计算阵列。
            state             <= CONV;
            round             <= '0;
            t                 <= '0;
            cycle             <= '0;
            cut_num           <= '0;
            res_flag          <= '0;
            CONV2_done        <= 1'b0;
            oWeightAddr       <= weight_base;
            oWeightReadEn     <= 1'b1;
            act_write_addr_d  <= '0;
            act_write_en_d    <= 1'b0;
            out_write_addr_d  <= '0;
            out_write_en_d    <= 1'b0;
          end
        end

        CONV: begin
          oComputeDone  <= 1'b0;
          oInputBufNWe  <= 1'b0;
          oWeightReadEn <= 1'b1;
          CONV2_done    <= 1'b0;

          // 每个主路径计算拍消费一个连续权重 word。到达当前指令跨度末尾后回到
          // weight_base，使每个新像素复用相同卷积核。首地址不能额外停一拍，否则
          // combined residual 文件中的 main/shortcut 权重边界会整体错位。
          if ((oWeightAddr - weight_base) < (weight_span - 1'b1)) begin
            oWeightAddr <= oWeightAddr + 1'b1;
          end else begin
            oWeightAddr <= weight_base;
          end

          // 一个物理输出 word 只允许 LOAD 一次：cycle=0 且处于第一个 IG chunk。
          // 其余主路径项均 ADD；CONV2 shortcut 也继续 ADD，不可重新 LOAD，否则
          // 会覆盖已经完成的 3x3 主路径和。
          if ((cycle == 0) && chunk_first) begin
            acc_instr_d <= ACC_LOAD;
          end else begin
            acc_instr_d <= ACC_ADD;
          end

          // 当下一个输出 word 开始时，前一个 word 的最终 accumulator/SIMD 结果
          // 正好进入写回窗口。此处产生预写脉冲，*_d 中仍保存前一 word 地址。
          act_write_en_d <= 1'b0;
          out_write_en_d <= 1'b0;
          if ((cycle == 0) && (cut_num != 0) && chunk_first) begin
            act_write_en_d <= pingpong;
            out_write_en_d <= !pingpong;
          end

          // 利用非阻塞赋值旧值语义：检测“上一拍预写脉冲”后才更新 *_addr_d。
          // 这使当前注册写脉冲使用旧地址，而新地址留给下一次写回。若把地址和
          // 使能在同一逻辑条件下直接更新，会产生一拍地址前移。
          if (act_write_en_d || out_write_en_d) begin
            if (pingpong) begin
              act_write_addr_d <= completed_word_addr[FEATURE_ADDR_WIDTH-1:0];
              out_write_addr_d <= '0;
            end else begin
              act_write_addr_d <= '0;
              out_write_addr_d <= completed_word_addr[FEATURE_ADDR_WIDTH-1:0];
            end
          end

          // BN entry 在“注册后的 SRAM 写使能”发生后才推进，确保当前 SIMDData、
          // 写地址和 physical output group 属于同一 token。推进过早会让相邻输出组
          // 使用错误阈值，常表现为每个像素按 64-channel 周期错位。
          if ((cut_num == 0) && (cycle == 0)) begin
            oBNAddr <= bn_base;
          end else if (oActWriteEn || oOutWriteEn) begin
            if ((oBNAddr - bn_base) == (output_groups - 1'b1)) begin
              oBNAddr <= bn_base;
            end else begin
              oBNAddr <= oBNAddr + 1'b1;
            end
          end

          // residual 在每个输出组最后一个 9-cycle chunk 后插入 IG/2 个 shortcut
          // 拍。WeightAddr 不停顿，正好对应 combined 权重文件中紧随 main 权重的
          // shortcut words。CONV2_done 防止返回 CONV 后在同一边界重复跳转。
          if ((calc_type == CALC_RESIDUAL) &&
              (cycle == (cycles_per_chunk - 1'b1)) && chunk_last &&
              !CONV2_done) begin
            state <= CONV2;
          end

          if (cycle < (cycles_per_chunk - 1'b1)) begin
            cycle <= cycle + 1'b1;
          end else begin
            cut_num <= cut_num + 1'b1;

            if (final_chunk) begin
              // normal 到这里已经完成整层；residual 还必须等待 CONV2 消费最后一组
              // shortcut，因此这里只冻结主路径计数，完成动作放在 CONV2。
              cycle <= cycle;
              t     <= t;
              if (calc_type == CALC_NORMAL) begin
                state         <= IDLE;
                pingpong      <= !pingpong;
                oComputeDone  <= 1'b1;
                oWeightAddr   <= '0;
                oWeightReadEn <= 1'b0;
              end
            end else begin
              // 每个 chunk 完成后推进线性进度。t 先遍历空间点，round 再推进
              // IG*OG 组合；实际地址仍以 cut_num 为准。
              cycle <= '0;
              if (t < (pixels_per_group - 1'b1)) begin
                t <= t + 1'b1;
              end else begin
                t     <= '0;
                round <= round + 1'b1;
              end
            end
          end
        end

        CONV2: begin
          // shortcut 与主路径共享 accumulator，所以控制固定为 ADD；InBufSelect
          // 同时随 oOutReadEn 切到另一块 SRAM，后续输出组由 InBuf 内部 replay。
          oComputeDone   <= 1'b0;
          oInputBufNWe   <= 1'b0;
          oWeightReadEn  <= 1'b1;
          acc_instr_d    <= ACC_ADD;
          act_write_en_d <= 1'b0;
          out_write_en_d <= 1'b0;
          CONV2_done     <= 1'b1;

          // shortcut 权重紧跟当前输出组的 main 权重，地址推进规则与 CONV 完全相同。
          if ((oWeightAddr - weight_base) < (weight_span - 1'b1)) begin
            oWeightAddr <= oWeightAddr + 1'b1;
          end else begin
            oWeightAddr <= weight_base;
          end

          if (!final_shortcut_cycle) begin
            // layer2 IG=2：1 个 shortcut 拍；layer3 IG=4：2 个 shortcut 拍。
            res_flag <= res_flag + 1'b1;
          end else begin
            res_flag <= '0;
            if (final_chunk) begin
              // 最后一个输出组的 shortcut 完成后，整条 residual 才真正完成。
              // pingpong 仅在这里翻转一次，尾 word 仍由下一拍 IDLE 补写。
              state          <= IDLE;
              round          <= '0;
              t              <= '0;
              cycle          <= '0;
              cut_num        <= '0;
              pingpong       <= !pingpong;
              oComputeDone   <= 1'b1;
              oWeightAddr    <= '0;
              oWeightReadEn  <= 1'b0;
            end else begin
              state <= CONV;
            end
          end
        end

        default: begin
          state             <= IDLE;
          oComputeDone      <= 1'b0;
          oInputBufNWe      <= 1'b1;
          oWeightReadEn     <= 1'b0;
          acc_instr_d       <= ACC_CLEAR;
          act_write_en_d    <= 1'b0;
          out_write_en_d    <= 1'b0;
        end
      endcase
    end
  end

endmodule
