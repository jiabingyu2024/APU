`timescale 1ns / 1ps

module tb_top();

parameter period=10;
reg hclk=1'b1;
reg hresetn=1'b1;


always #(period/2)
hclk=~hclk;
initial
begin
   hresetn = 1'b0;
   #(100*period)
   hresetn = 1'b1;
end

reg          hbusreq  ;
wire         hgrant   ;
reg  [31:0]  haddr    ;
reg  [ 1:0]  htrans   ;
reg          hwrite   ;
reg  [ 2:0]  hsize    ;
reg  [ 2:0]  hburst   ;
reg  [31:0]  hwdata   ;
wire [31:0]  hrdata   ;
wire [ 1:0]  hresp    ;
wire         hready   ;
wire         hsel     ;

reg [31:0] data_burst_wr[32767:0];
reg [31:0] data_burst_SIMD_wr[32767:0];
reg [31:0] data_burst_rd[2047:0];
reg [31:0] rdata;
integer    sadr, i, j;
integer    error,w_r_val,w_r_chanel;

parameter saddr=32'h0000_0000;
parameter RAM_CTRL_ADDR = 14'h2000;
parameter RAM_SEL_ADDR  = 14'h2004;
parameter APU_READY_ADDR      = 14'h2008;
parameter CPL_ADDR      = 14'h200c;
integer IN_C = 64;
integer OUT_C = 64;
integer IN_H = 8;
integer IN_W = 8;
integer STRIDE1 = 1;
integer STRIDE2 = 0;
integer inst = 0;
integer kernal_size = 3;
integer IN_H_LOG = $clog2(IN_H);
integer IN_C_LOG = $clog2(IN_C);
integer OUT_C_LOG = $clog2(OUT_C);
reg [31:0] instruction;



wire int_cal;

integer fp_datao_w;
//write data


initial begin
    hbusreq= 0;
    haddr  = 0;
    htrans = 0;
    hwrite = 0;
    hsize  = 0;
    hburst = 0;
    hwdata = 0;
    wait  (hresetn==1'b0);
    wait  (hresetn==1'b1);
    repeat (20) @ (posedge hclk);

	//set ram ctrl
    ahb_write(RAM_CTRL_ADDR, 4, 32'h3 );
    //---------------------------Set Input----------------------------//      
  
    //set in data
    $readmemb ("data/param_files/input_binary.txt",data_burst_wr);

    //write in ram  
    ahb_write(RAM_SEL_ADDR, 4, 128);
    ahb_write_burst(0, 0, 32*32*64/32);

    //---------------------------Run layer1--------------------------//
 
    //set layer1.0      conv and SIMD parameter
    $readmemb ("data/param_files/layer1.0.conv1.txt",data_burst_wr);
    $readmemb ("data/param_files/layer1.0.bn1_combined.txt",data_burst_SIMD_wr);
    //set layer1.0 instruction {opcode, kernalSize, logInHW, logInC, logOutC, stride1, stride2, wAdddr, bnAddr}
    conv_layer(2'b00, 2'd3, 3'd5, 4'd6, 4'd6, 2'd1, 2'd0, 8'd0, 5'd0 ,0);
    // run_apu();


	//set layer1.0      conv and SIMD parameter
    $readmemb ("data/param_files/layer1.0.conv2.txt",data_burst_wr);
    $readmemb ("data/param_files/layer1.0.bn3_combined.txt",data_burst_SIMD_wr);
    //set layer1.0 instruction {opcode, kernalSize, logInHW, logInC, logOutC, stride1, stride2, wAdddr, bnAddr}
    conv_layer(2'b00, 2'd3, 3'd5, 4'd6, 4'd6, 2'd1, 2'd0, 8'd9, 5'd1 ,1);

	//set layer1.1      conv and SIMD parameter
    $readmemb ("data/param_files/layer1.1.conv1.txt",data_burst_wr);
    $readmemb ("data/param_files/layer1.1.bn1_combined.txt",data_burst_SIMD_wr);
    //set layer1.1 instruction {opcode, kernalSize, logInHW, logInC, logOutC, stride1, stride2, wAdddr, bnAddr}
    conv_layer(2'b00, 2'd3, 3'd5, 4'd6, 4'd6, 2'd1, 2'd0, 8'd18, 5'd2 ,2);

	//set layer1.1      conv and SIMD parameter
    $readmemb ("data/param_files/layer1.1.conv2.txt",data_burst_wr);
    $readmemb ("data/param_files/layer1.1.bn3_combined.txt",data_burst_SIMD_wr);
    //set layer1.1 instruction {opcode, kernalSize, logInHW, logInC, logOutC, stride1, stride2, wAdddr, bnAddr}
    conv_layer(2'b00, 2'd3, 3'd5, 4'd6, 4'd6, 2'd1, 2'd0, 8'd27, 5'd3 ,3);
    run_apu();


	// //---------------------------Run layer2--------------------------//
 
    // //set layer2.0      conv and SIMD parameter C: 64->128
    // $readmemb ("data/param_files/layer2.0.conv1.txt",data_burst_wr);
    // $readmemb ("data/param_files/layer2.0.bn1_combined.txt",data_burst_SIMD_wr);
    // //set layer2.0 instruction {opcode, kernalSize, logInHW, logInC, logOutC, stride1, stride2, wAdddr, bnAddr}
    // conv_layer(2'b00, 2'd3, 3'd5, 4'd6, 4'd7, 2'd2, 2'd0, 8'd36, 5'd4 ,4);

	// //set layer2.0      conv and SIMD parameter resident
    // $readmemb ("data/param_files/layer2.0.conv2_combined.txt",data_burst_wr);
    // $readmemb ("data/param_files/layer2.0.bn3_combined.txt",data_burst_SIMD_wr);
    // //set layer2.0 instruction {opcode, kernalSize, logInHW, logInC, logOutC, stride1, stride2, wAdddr, bnAddr}+36
    // conv_resident_layer(2'b01, 2'd3, 3'd4, 4'd7, 4'd7, 2'd1, 2'd2, 8'd54, 5'd6 ,5);

	
	// //set layer2.1      conv and SIMD parameter
    // $readmemb ("data/param_files/layer2.1.conv1.txt",data_burst_wr);
    // $readmemb ("data/param_files/layer2.1.bn1_combined.txt",data_burst_SIMD_wr);
    // //set layer2.1 instruction {opcode, kernalSize, logInHW, logInC, logOutC, stride1, stride2, wAdddr, bnAddr}
    // conv_layer(2'b00, 2'd3, 3'd4, 4'd7, 4'd7, 2'd1, 2'd0, 8'd92, 5'd10 ,6);

	// //set layer2.1      conv and SIMD parameter
    // $readmemb ("data/param_files/layer2.1.conv2.txt",data_burst_wr);
    // $readmemb ("data/param_files/layer2.1.bn3_combined.txt",data_burst_SIMD_wr);
    // //set layer2.1 instruction {opcode, kernalSize, logInHW, logInC, logOutC, stride1, stride2, wAdddr, bnAddr}
    // conv_layer(2'b00, 2'd3, 3'd4, 4'd7, 4'd7, 2'd1, 2'd0, 8'd128, 5'd14 ,7);

    // // Run the first eight instructions as one worksheet batch. Their weights
    // // occupy addresses 0..163, so they fit in the 256-entry weight SRAM.
    // run_apu();

    // //---------------------------Run layer3--------------------------//
    // // A complete layer3 weight set does not fit in Weight SRAM. Load and run
    // // each operation separately, reusing weight/BN/worksheet address zero.
    // $readmemb ("data/param_files/layer3.0.conv1.txt",data_burst_wr);
    // $readmemb ("data/param_files/layer3.0.bn1_combined.txt",data_burst_SIMD_wr);
    // conv_layer(2'b00, 2'd3, 3'd4, 4'd7, 4'd8, 2'd2, 2'd0, 8'd0, 5'd0, 0);
    // run_apu();

    // $readmemb ("data/param_files/layer3.0.conv2_combined.txt",data_burst_wr);
    // $readmemb ("data/param_files/layer3.0.bn3_combined.txt",data_burst_SIMD_wr);
    // conv_resident_layer(2'b01, 2'd3, 3'd3, 4'd8, 4'd8, 2'd1, 2'd2, 8'd0, 5'd0, 0);
    // run_apu();

    // $readmemb ("data/param_files/layer3.1.conv1.txt",data_burst_wr);
    // $readmemb ("data/param_files/layer3.1.bn1_combined.txt",data_burst_SIMD_wr);
    // conv_layer(2'b00, 2'd3, 3'd3, 4'd8, 4'd8, 2'd1, 2'd0, 8'd0, 5'd0, 0);
    // run_apu();

    // $readmemb ("data/param_files/layer3.1.conv2.txt",data_burst_wr);
    // $readmemb ("data/param_files/layer3.1.bn3_combined.txt",data_burst_SIMD_wr);
    // conv_layer(2'b00, 2'd3, 3'd3, 4'd8, 4'd8, 2'd1, 2'd0, 8'd0, 5'd0, 0);
    // run_apu();

    //read data
    ahb_write(RAM_CTRL_ADDR, 4, 32'h3 );
    ahb_write(RAM_SEL_ADDR, 4, 128);//129 for 1,3    128 for 2,4
    ahb_read_burst_save(0,4*512);//write 2048 here means write 2048 rows
    repeat (20) @ (posedge hclk);
    $finish;
end


wire                         data_ram_ctrl     ;
wire                         conv_ram_ctrl     ;
wire       [31:0]            ir                ;
wire       [1:0]             cal_cpl           ;

assign hgrant = hbusreq;// no arbiter
assign hsel   = htrans[1]; // no address decoder
assign cal_cpl = 2'b10;

Top dut_apu_inst(
.nRst           ( hresetn       ),
.clk              ( hclk          ),
.hsel              ( htrans[1]     ),
.haddr             ( haddr             ),
.htrans            ( htrans        ),
.hwrite            ( hwrite        ),
.hsize             ( hsize         ),
.hburst            ( hburst        ),
.hwdata            ( hwdata        ),
.hrdata            ( hrdata        ),
.hresp             ( hresp         ),
.hready            ( 1'b1          ),
.hreadyout         ( hready        ),
.int_cal           ( int_cal       ),
.hlock             ( 1'b0),   // Not used in this module
.hprot             (4'b0)   // Not used in this module
 );
 

`ifdef VERILATOR
initial begin
 $dumpfile("build/sim/top.vcd");
 $dumpvars(0, tb_top);
end
`elsif FSDB
initial begin
 $fsdbDumpfile("top.fsdb");
 $fsdbDumpvars(0,"+mda");
end
`endif

//////////////////////////////////////////////////////////////////////////////////
// task define
//////////////////////////////////////////////////////////////////////////////////
task conv_layer;
	input [1:0] opcode;
	input [1:0] kernalSize;
	input [2:0] logInHW;
    input [3:0] logInC;
    input [3:0] logOutC;
	input [1:0] stride1;
	input [1:0] stride2;
	input [7:0] wAddr;
	input [4:0] bnAddr;
    input [3:0] worksheet_waddr;
    integer i;
    integer j;
    integer words_per_bank;
    integer output_groups;
    begin
        output_groups = (1 << logOutC) / 64;
        words_per_bank = 2 * kernalSize * kernalSize * ((1 << logInC) / 64);

        if ((wAddr + (words_per_bank / 2) * output_groups) > 256)
            $fatal(1, "conv weights exceed Weight SRAM");
        if ((bnAddr + output_groups) > 32)
            $fatal(1, "conv parameters exceed SIMD register depth");

        ahb_write(RAM_CTRL_ADDR, 4, 32'h3);

        // The parameter file is grouped by output group, then PE/bank.
        for (j = 0; j < output_groups; j = j + 1) begin
            for (i = 0; i < 64; i = i + 1) begin
                ahb_write(RAM_SEL_ADDR, 4, i + 64);
                ahb_write_burst((j * 64 + i) * words_per_bank,
                                wAddr * 8 + j * words_per_bank * 4,
                                words_per_bank);
            end
        end

        // One threshold/control word is stored for every output channel.
        for (j = 0; j < output_groups; j = j + 1) begin
            for (i = 0; i < 64; i = i + 1) begin
                ahb_write(RAM_SEL_ADDR, 4, i);
                ahb_write_SIMD_burst(j * 64 + i, (bnAddr + j) * 4, 1);
            end
        end

        ahb_write(RAM_SEL_ADDR, 4, 130);
        ahb_write(worksheet_waddr * 4, 4,
                  {opcode, kernalSize, logInHW, logInC, logOutC,
                   stride1, stride2, wAddr, bnAddr});
    end
endtask

task conv_resident_layer;
	input [1:0] opcode;
	input [1:0] kernalSize;
	input [2:0] logInHW;
    input [3:0] logInC;
    input [3:0] logOutC;
	input [1:0] stride1;
	input [1:0] stride2;
	input [7:0] wAddr;
	input [4:0] bnAddr;
    input [3:0] worksheet_waddr;
    integer i;
    integer j;
    integer words_per_bank;
    integer output_groups;
    begin
        output_groups = (1 << logOutC) / 64;
        words_per_bank = (2 * kernalSize * kernalSize + 1)
                         * ((1 << logInC) / 64);

        // ram_mux combines adjacent 32-bit writes into one 64-bit weight word.
        if ((words_per_bank % 2) != 0)
            $fatal(1, "resident weight count must be even");
        if ((wAddr + (words_per_bank / 2) * output_groups) > 256)
            $fatal(1, "resident weights exceed Weight SRAM");
        if ((bnAddr + output_groups) > 32)
            $fatal(1, "resident parameters exceed SIMD register depth");

        ahb_write(RAM_CTRL_ADDR, 4, 32'h3);

        for (j = 0; j < output_groups; j = j + 1) begin
            for (i = 0; i < 64; i = i + 1) begin
                ahb_write(RAM_SEL_ADDR, 4, i + 64);
                ahb_write_burst((j * 64 + i) * words_per_bank,
                                wAddr * 8 + j * words_per_bank * 4,
                                words_per_bank);
            end
        end

        for (j = 0; j < output_groups; j = j + 1) begin
            for (i = 0; i < 64; i = i + 1) begin
                ahb_write(RAM_SEL_ADDR, 4, i);
                ahb_write_SIMD_burst(j * 64 + i, (bnAddr + j) * 4, 1);
            end
        end

        ahb_write(RAM_SEL_ADDR, 4, 130);
        ahb_write(worksheet_waddr * 4, 4,
                  {opcode, kernalSize, logInHW, logInC, logOutC,
                   stride1, stride2, wAddr, bnAddr});
    end
endtask

task run_apu;
    integer wait_cycles;
    begin
        ahb_write(RAM_CTRL_ADDR, 4, 32'h0);
        ahb_write(APU_READY_ADDR, 4, 32'h1);

        wait_cycles = 0;
        while ((int_cal !== 1'b1) && (wait_cycles < 10000000)) begin
            @ (posedge hclk);
            wait_cycles = wait_cycles + 1;
        end
        if (int_cal !== 1'b1)
            $fatal(1, "APU completion timeout");

        ahb_read(CPL_ADDR, 4, rdata);
        $display($time,, " cpl_data: %d ", rdata);
    end
endtask

task ahb_read;
input  [31:0] address;
input  [ 2:0] size;
output [31:0] data;
begin
    @ (posedge hclk);
    hbusreq <=  1'b1;
    @ (posedge hclk);
    while ((hgrant!==1'b1)||(hready!==1'b1)) @ (posedge hclk);
    hbusreq <=  1'b0;
    haddr   <=  address;
//    hprot   <=  4'b0001; //`hprot_data
    htrans  <=  2'b10;  //`htrans_nonseq;
    hburst  <=  3'b000; //`hburst_single;
    hwrite  <=  1'b0;   //`hwrite_read;
    case (size)
    1:  hsize <=  3'b000; //`hsize_byte;
    2:  hsize <=  3'b001; //`hsize_hword;
    4:  hsize <=  3'b010; //`hsize_word;
    default: $display($time,, "error: unsupported transfer size: %d-byte", size);
    endcase
    @ (posedge hclk);
    while (hready!==1'b1) @ (posedge hclk);
    `ifndef low_power
    haddr  <=  32'b0;
//    hprot  <=  4'b0000; //`hprot_opcode
    hburst <=  3'b0;
    hwrite <=  1'b0;
    hsize  <=  3'b0;
    `endif
    htrans <=  2'b0;
    @ (posedge hclk);
    while (hready===0) @ (posedge hclk);
    data = hrdata; // must be blocking
    if (hresp!=2'b00) //if (hresp!=`hresp_okay)
        $display($time,, "error: non ok response for read");
    @ (posedge hclk);
end
endtask

//-----------------------------------------------------
task ahb_write;
input  [31:0] address;
input  [ 2:0] size;
input  [31:0] data;
begin
    @ (posedge hclk);
    hbusreq <=  1;
    @ (posedge hclk);
    while ((hgrant!==1'b1)||(hready!==1'b1)) @ (posedge hclk);
    hbusreq <=  1'b0;
    haddr   <=  address;
//    hprot   <=  4'b0001; //`hprot_data
    htrans  <=  2'b10;  //`htrans_nonseq;
    hburst  <=  3'b000; //`hburst_single;
    hwrite  <=  1'b1;   //`hwrite_write;
    case (size)
    1:  hsize <=  3'b000; //`hsize_byte;
    2:  hsize <=  3'b001; //`hsize_hword;
    4:  hsize <=  3'b010; //`hsize_word;
    default: $display($time,, "error: unsupported transfer size: %d-byte", size);
    endcase
    @ (posedge hclk);
    while (hready!==1) @ (posedge hclk);
    `ifndef low_power
    haddr  <=  32'b0;
//    hprot  <=  4'b0000; //`hprot_opcode
    hburst <=  3'b0;
    hwrite <=  1'b0;
    hsize  <=  3'b0;
    `endif
    hwdata <=  data;
    htrans <=  2'b0;
    @ (posedge hclk);
    while (hready===0) @ (posedge hclk);
    if (hresp!=2'b00) //if (hresp!=`hresp_okay)
         $display($time,, "error: non ok response write");
    `ifndef low_power
    hwdata <=  0;
    `endif
    @ (posedge hclk);
end
endtask

//-------------------------------------------------------------
task ahb_read_burst;
     input  [31:0] addr;
     input  [31:0] leng;
     integer       i;
     begin
         @ (posedge hclk);
         hbusreq <=  1'b1;
         @ (posedge hclk);
         while ((hgrant!==1'b1)||(hready!==1'b1)) @ (posedge hclk);
         haddr  <=  addr;
         htrans <=  2'b10; //`htrans_nonseq;
         if (leng==4)       hburst <=  3'b011; //`hburst_incr4;
         else if (leng==8)  hburst <=  3'b101; //`hburst_incr8;
         else if (leng==16) hburst <=  3'b111; //`hburst_incr16;
         else               hburst <=  3'b001; //`hburst_incr;
         hwrite <=  1'b0; //`hwrite_read;
         hsize  <=  3'b010; //`hsize_word;
         @ (posedge hclk);
         while (hready==1'b0) @ (posedge hclk);
         for (i=0; i<leng-1; i=i+1) begin
             haddr  <=  addr+(i+1)*4;
             htrans <=  2'b11; //`htrans_seq;
             @ (posedge hclk);
             while (hready==1'b0) @ (posedge hclk);
             data_burst_rd[i] = hrdata; // must be blocking
         end
         //hsel   <=  0;
         haddr  <=  0;
         htrans <=  0;
         hburst <=  0;
         hwrite <=  0;
         hsize  <=  0;
         hbusreq <=  1'b0;
         @ (posedge hclk);
         while (hready==0) @ (posedge hclk);
         data_burst_rd[i] = hrdata; // must be blocking
         if (hresp!=2'b00) begin //`hresp_okay
$display($time,, "error: non ok response for read");
            end
`ifdef debug
$display($time,, "info: read(%x, %d, %x)", address, size, data);
`endif
         @ (posedge hclk);
     end
endtask

task ahb_read_burst_save;     
     input  [31:0] addr;
     input  [31:0] leng;
     integer       i;
     reg    [31:0] read_data;
     reg    [31:0] low_word;
     begin
         fp_datao_w = $fopen("build/sim/data_out.txt","w");
         if (fp_datao_w == 0)
             $fatal(1, "failed to open build/sim/data_out.txt");
         if (leng[0] != 1'b0)
             $fatal(1, "64-bit SRAM dump requires an even number of 32-bit words");

         @ (posedge hclk);
         hbusreq <= 1'b1;
         @ (posedge hclk);
         while ((hgrant !== 1'b1) || (hready !== 1'b1)) @ (posedge hclk);

         hwrite <= 1'b0;
         hsize  <= 3'b010;
         hburst <= (leng == 4)  ? 3'b011 :
                   (leng == 8)  ? 3'b101 :
                   (leng == 16) ? 3'b111 : 3'b001;

         for (i=0; i<leng; i=i+1) begin
             haddr  <= addr + i * 4;
             htrans <= (i == 0) ? 2'b10 : 2'b11;
             @ (posedge hclk);
             while (hready !== 1'b1) @ (posedge hclk);
             @ (negedge hclk);
             read_data = hrdata;
             if (hresp != 2'b00)
                 $fatal(1, "non-OK response while dumping AHB read data");
             if (i[0] == 1'b0) begin
                 low_word = read_data;
             end else begin
                 $fwrite(fp_datao_w,"%32b\n",read_data);
                 $fwrite(fp_datao_w,"%32b\n",low_word);
             end
         end

         haddr   <= 0;
         htrans  <= 0;
         hburst  <= 0;
         hwrite  <= 0;
         hsize   <= 0;
         hbusreq <= 1'b0;
         @ (posedge hclk);
         $fclose(fp_datao_w);
     end
endtask


//-------------------------------------------------------------
task ahb_write_burst;
     input  [31:0] start_addr;
     input  [31:0] addr;
     input  [31:0] leng;
     integer       i;
     begin
         @ (posedge hclk);
         hbusreq <=  1'b1;
         @ (posedge hclk);
         while ((hgrant!==1'b1)||(hready!==1'b1)) @ (posedge hclk);
         haddr  <=  addr;
         htrans <=  2'b10; //`htrans_nonseq;
         if (leng==4)       hburst <=  3'b011; //`hburst_incr4;
         else if (leng==8)  hburst <=  3'b101; //`hburst_incr8;
         else if (leng==16) hburst <=  3'b111; //`hburst_incr16;
         else               hburst <=  3'b001; //`hburst_incr;
         hwrite <=  1'b1; //`hwrite_write;
         hsize  <=  3'b010; //`hsize_word;
         for (i=0; i<leng-1; i=i+1) begin
             @ (posedge hclk);
             while (hready==1'b0) @ (posedge hclk);
             hwdata <=  data_burst_wr[start_addr+i];
             haddr  <=  addr+(i+1)*4;
             htrans <=  2'b11; //`htrans_seq;
             while (hready==1'b0) @ (posedge hclk);
         end
         @ (posedge hclk);
         while (hready==0) @ (posedge hclk);
         hwdata <=  data_burst_wr[start_addr+i];
         //hsel   <=  0;
         haddr  <=  0;
         htrans <=  0;
         hburst <=  0;
         hwrite <=  0;
         hsize  <=  0;
         hbusreq <=  1'b0;
         @ (posedge hclk);
         while (hready==0) @ (posedge hclk);
         if (hresp!=2'b00) begin //`hresp_okay
$display($time,, "error: non ok response write");
         end
`ifdef debug
$display($time,, "info: write(%x, %d, %x)", addr, size, data);
`endif
         hwdata <=  0;
         @ (posedge hclk);
     end
endtask
task ahb_write_SIMD_burst;
     input  [31:0] start_addr;
     input  [31:0] addr;
     input  [31:0] leng;
     integer       i;
     begin
         @ (posedge hclk);
         hbusreq <=  1'b1;
         @ (posedge hclk);
         while ((hgrant!==1'b1)||(hready!==1'b1)) @ (posedge hclk);
         haddr  <=  addr;
         htrans <=  2'b10; //`htrans_nonseq;
         if (leng==4)       hburst <=  3'b011; //`hburst_incr4;
         else if (leng==8)  hburst <=  3'b101; //`hburst_incr8;
         else if (leng==16) hburst <=  3'b111; //`hburst_incr16;
         else               hburst <=  3'b001; //`hburst_incr;
         hwrite <=  1'b1; //`hwrite_write;
         hsize  <=  3'b010; //`hsize_word;
         for (i=0; i<leng-1; i=i+1) begin
             @ (posedge hclk);
             while (hready==1'b0) @ (posedge hclk);
             hwdata <=  data_burst_SIMD_wr[start_addr+i];
             haddr  <=  addr+(i+1)*4;
             htrans <=  2'b11; //`htrans_seq;
             while (hready==1'b0) @ (posedge hclk);
         end
         @ (posedge hclk);
         while (hready==0) @ (posedge hclk);
         hwdata <=  data_burst_SIMD_wr[start_addr+i];
         //hsel   <=  0;
         haddr  <=  0;
         htrans <=  0;
         hburst <=  0;
         hwrite <=  0;
         hsize  <=  0;
         hbusreq <=  1'b0;
         @ (posedge hclk);
         while (hready==0) @ (posedge hclk);
         if (hresp!=2'b00) begin //`hresp_okay
$display($time,, "error: non ok response write");
         end
`ifdef debug
$display($time,, "info: write(%x, %d, %x)", addr, size, data);
`endif
         hwdata <=  0;
         @ (posedge hclk);
     end
endtask
endmodule
