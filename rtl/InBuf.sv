/*
  InBuf #(
      .P_BINDWIDTH(P_BINDWIDTH)
  ) U_InBuf (
      .clk        (clk),
      .nRst       (nRst),
      .iSelect    (InputBufSelect),
        
      .nWe        (InputBufNWe),
      .iInstruction(Instruction[31:0]),
      .iWriteDataA(ActData[P_BINDWIDTH-1:0]),
      .iWriteDataB(OutData[P_BINDWIDTH-1:0]),
      
      .nCe        (1'b0),                      //Always enable

      .oInData(InBufData[P_BINDWIDTH-1:0]),


      .iActSramReadCenterAddr(ActReadCenterAddr[$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0]),
      
      .iComputeDone(ComputeDone)
  );
*/
module InBuf 
#(
    parameter PERIOD=10,
    parameter P_BINDWIDTH=64
)
(
    input clk,
    input nRst,
    input iSelect,
    
    input nWe,
    input [31:0] iInstruction,
    input [P_BINDWIDTH-1:0] iWriteDataA ,
    input [P_BINDWIDTH-1:0] iWriteDataB ,
    input nCe,
    output logic [P_BINDWIDTH-1:0] oInData
);  
    logic [1:0]  calc_type;
    logic [1:0]  kernel_size;
    logic [2:0]  in_hw;
    assign calc_type=iInstruction[31:30];
    assign in_hw=iInstruction[27:25];

    
    
    logic [P_BINDWIDTH-1:0] rBuf;
    logic [P_BINDWIDTH-1:0] dataB,dataA,data;
    logic[31:0] count;//记录残差卷计一次完整计算需要多少clk，conv7一次（4*9+2）*4个clk，conv6一次（2*9+1）*2个clk
    logic[31:0] count_top;
    assign count_top=(in_hw==3'b100)?38:152;

    logic[1:0] fromram ;//输入是哪个ram
    logic[P_BINDWIDTH-1:0] temp,temp1,temp2;//寄存

    always_comb begin
        if(count==1)
        begin
            if(iSelect==0)
            begin
                fromram=0;//dataA是主信号，要寄存dataB的值
            end
            else
            begin
                fromram=1;//dataB是主信号
            end
        end
    end


    always_comb begin 
        if (calc_type==2'b01) begin
            if (fromram!=iSelect) begin
                if(count_top==38)//conv6一次（2*9+1）*2个clk
                begin
                    if (count==18) begin
                        temp1=data;
                    end
                end
                else//conv7一次（4*9+2）*4个clk
                begin
                    if (count==36) begin
                        temp1=data;
                    end
                    else if(count==37)
                    begin
                        temp2=data;
                    end
                end
            end
        end
    end
    assign temp=(count_top==38)?temp1:(((count%38)==36)?temp1:temp2);


    assign data=(iSelect)?iWriteDataB:iWriteDataA;
    /*
    always_comb begin 

        if(calc_type==2'b00)
        begin
            if (iSelect) begin
                data=iWriteDataB;
            end
            else
            begin
                data=iWriteDataA;
            end
        end
    end
    */
    always_ff @ (posedge clk or negedge nRst)
    begin
        if(nRst==0)
        begin
        rBuf<=0;
        count<=0;
        end
        else 
        begin
                
            if(calc_type==2'b01)
            begin
                if (count<(count_top-1)) begin
                    count<=count+1;
                end
                else
                begin
                    count<=0;
                end
            end
            else
            begin
                count<=0;
            end







            if(nWe==1'b1)
            begin
                rBuf<=rBuf;
                count<=0;
            end
            else
            begin
                if(count==0)
                begin
                    rBuf<=data;
                end
                else
                begin
                    if(count_top==38)//是卷积6，（2*9+1）*2个clk
                    begin
                        if ((fromram!=iSelect)&(count>20)) begin
                            rBuf<=temp[P_BINDWIDTH-1:0];
                        end
                        else
                        begin
                            rBuf<=data;
                        end
                    end
                    else//卷积7,conv7一次（4*9+2）*4个clk
                    begin
                        if ((fromram!=iSelect)&(count>40)) begin
                            rBuf<=temp[P_BINDWIDTH-1:0];
                        end
                        else
                        begin
                            rBuf<=data;
                        end
                    end
                end
                
            end

        end
    end
    assign oInData=(nCe)?0:rBuf;
endmodule
/*
module InBuf
#(
 parameter PERIOD = 10, // 100MHz时钟频率
 parameter P_BINDWIDTH = 64 // 数据宽度
)
(
 input clk,
 input nRst,
 input nWe,
 input [P_BINDWIDTH-1:0] iWriteDataA,
 input [P_BINDWIDTH-1:0]iWriteDataB,
 input iSelect,
 input nCe,
 output wire [P_BINDWIDTH-1:0] oInData
);
reg [P_BINDWIDTH-1:0] rBuf;
always @(posedge clk or negedge nRst) begin
 if(~nRst) begin rBuf<=0;end
 else begin if(nWe==0&&iSelect==0) begin
 rBuf<=iWriteDataA;end
 else if(nWe==0&&iSelect==1) begin
 rBuf<=iWriteDataB;end
 else rBuf<=rBuf;end
end
assign oInData=(nCe)?0:rBuf;
endmodule

*/