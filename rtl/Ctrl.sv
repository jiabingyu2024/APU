module Ctrl#(
    parameter P_BINDWIDTH = 64,
    parameter P_FEATURE_MEMORY_SIZE = 65536
) (
    input clk,
    input nRst,
    input nCe,

    // From Instruction Registerfile
    input [31:0] iInstruction,

    // For ActSRAM
    output logic    [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oActReadCenterAddr,
    output logic                                                    oActReadEn,
    output logic    [                                          1:0] oActKernelSize,
    output logic    [                                          5:0] oActHW,
    output logic    [                                          3:0] oActlogInC,
    output logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oActWriteAddr,
    output logic                                                 oActWriteEn,
    
    // For InputBuf
    output logic                                                 oInputBufNWe,
    output logic                                                 oInputBufSelect,
    
    // For OutSRAM
    output logic    [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oOutReadCenterAddr,
    output logic                                                    oOutReadEn,
    output logic    [                                          1:0] oOutKernelSize,
    output logic    [                                          5:0] oOutHW,
    output logic    [                                          3:0] oOutlogInC,
    output logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oOutWriteAddr,
    output logic                                                 oOutWriteEn,
    
    // For SIMD
    output logic [                                          4:0] oBNAddr,
    
    // For ComputeCoreGroup
    output logic [                                          7:0] oWeightAddr,
    output logic                                                 oWeightReadEn,
    output logic [                                          1:0] oAccInstr,
    
    // For WorkSheet
    output logic                                                 oComputeDone

	
);
logic [63:0] cut_num,cut_num_top;
//assign cut_num_top=
/*
// State definitions
typedef enum logic [1:0] {
    IDLE,
    CONV
} state_t;
*/

// 状态值自动分配
parameter logic [1:0] 
  IDLE = 2'b00,  // 第一个枚举值默认0
  CONV = 2'b01,  // 后续值自动+1
  CONV2=2'b11;

// 定义state_t类型
typedef logic [1:0] state_t;


logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oOutWriteAddr_notdelay;
logic                                                 oOutWriteEn_notdelay;
logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)-1:0] oActWriteAddr_notdelay;
logic                                                 oActWriteEn_notdelay;

logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)*2-1:0] oOutWriteAddr_temp;
logic  [1:0]                                               oOutWriteEn_temp;
logic [$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)*2-1:0] oActWriteAddr_temp;
logic   [1:0]                                              oActWriteEn_temp;

always_ff@(posedge clk,negedge nRst)
begin
    if ((!nRst)) begin
        oActWriteEn<='b0;
        oOutWriteEn<='b0;
        oActWriteAddr<='b0;
        oOutWriteAddr<='b0;
    end
    else
    begin

        oActWriteEn<=oActWriteEn_notdelay;
        oOutWriteEn<=oOutWriteEn_notdelay;
        oActWriteAddr<=oActWriteAddr_notdelay;
        oOutWriteAddr<=oOutWriteAddr_notdelay;


        //oOutWriteAddr_temp<={oOutWriteAddr_temp[$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)*1-1:0],oOutWriteAddr_notdelay};
        //oOutWriteEn_temp[1:0]<={oOutWriteEn_temp[0],oOutWriteEn_notdelay};
        //oActWriteAddr_temp<={oActWriteAddr_temp[$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)*1-1:0],oActWriteAddr_notdelay};
        //oActWriteEn_temp[1:0]<={oActWriteEn_temp[0],oActWriteEn_notdelay};
    end
end
//assign oOutWriteAddr=oOutWriteAddr_temp[($clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)*2-1)-:$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)];
//////assign oActWriteAddr=oActWriteAddr_temp[($clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)*2-1)-:$clog2(P_FEATURE_MEMORY_SIZE/P_BINDWIDTH)];
//assign oOutWriteEn=oOutWriteEn_temp[1];
//assign oActWriteEn=oActWriteEn_temp[1];

logic [                                          1:0] oAccInstr_notdelay;
// Internal registers
state_t state;
logic pingpong; // 0: ActSRAM read/OutSRAM write, 1: OutSRAM read/ActSRAM write

// Loop counters
logic [15:0] round;      // Output channel rounds
logic [15:0] t;          // Output position counter
logic [7:0]  cycle;      // Computation cycles per position

// Parameters from instruction
logic [1:0]  calc_type;
logic [1:0]  kernel_size;
logic [2:0]  in_hw;
logic [8:0]in_hw_num ;
logic [3:0]  in_c;
logic [3:0]  out_c;

logic[10:0] in_c_num;

logic[10:0] out_c_num;

logic [1:0]  stride1;
logic [1:0]  stride2;
logic [7:0]  w1_addr;
logic [4:0]  bn_addr;

// Derived parameters
logic [15:0] totalRound;
logic [15:0] totalRound1;
logic [15:0] totalRound2;

logic [15:0] timePerRound;
logic [7:0]  cyclePerTime;
logic [5:0]  out_hw;
logic[1:0] stride_num;


// Continuous assignments
//assign oActReadEn = (state == CONV) && (!pingpong);//乒乓为0选act
//assign oOutReadEn = (state == CONV) && pingpong;
always_comb
begin

        if(pingpong)//主要从outsram里读
        begin
            if(state==CONV)
            begin
                oOutReadEn=1;
                oActReadEn=0;
            end
            else if(state==CONV2)//进入残差
            begin
                oOutReadEn=0;
                oActReadEn=1;
            end
            else
            begin
                oOutReadEn=0;
                oActReadEn=0;
            end
        end
        else//主要从aact里读
        begin
            if(state==CONV)
            begin
                oOutReadEn=0;
                oActReadEn=1;
            end
            else if(state==CONV2)//进入残差
            begin
                oOutReadEn=1;
                oActReadEn=0;
            end
            else
            begin
                oOutReadEn=0;
                oActReadEn=0;
            end
        end
end

//oActKernelSize he oOutKernelSize

assign oActKernelSize = (nRst&&(!nCe))?((!pingpong)?kernel_size:2'b01):0;
assign oOutKernelSize = (nRst&&(!nCe))?((pingpong)?kernel_size:2'b01):0;

always_comb begin
    // Parse instruction
    if(nRst)
    begin
    {calc_type, kernel_size, in_hw, in_c, out_c, stride1, stride2, w1_addr, bn_addr} = iInstruction;
    
    // Calculate output dimensions
    case (calc_type)
        2'b00: begin // Type 1
            if(stride1[1])//步长为2
            begin
                case (in_hw)
                    3'b011: out_hw=4;//输入为8
                    3'b100:out_hw=8;//输入为16
                    3'b101:out_hw=16;//输入为32
                    default: out_hw=32;
                endcase
                stride_num=2;
            end
            else
            begin
                case (in_hw)
                    3'b011:out_hw=8;
                    3'b100:out_hw=16;
                    3'b101:out_hw=32;
                    default: out_hw=32;
                endcase
                stride_num=1;
            end
        end
        2'b01: begin // Type 2，残差，主要卷积（3，5）的步长必然为1
            case (in_hw)
                3'b011:out_hw=8;
                3'b100:out_hw=16;
                3'b101:out_hw=32;
                default: out_hw=32;
            endcase
            stride_num=1;
        end
        default: begin
            out_hw = 32;
        end
    endcase
                //out_hw = (in_hw >> (stride1[1] ? 1 : 0));
            //
            case (in_c)
                4'b0110:begin totalRound1=1; end 
                4'b0111:begin totalRound1=2; end 
                4'b1000:begin totalRound1=4; end 
                default:begin totalRound1=1; end 
            endcase
            case (out_c)
                4'b0110:begin totalRound2=1; end 
                4'b0111:begin totalRound2=2; end 
                4'b1000:begin totalRound2=4; end 
                default:begin totalRound2=1; end 
            endcase

            totalRound = totalRound1*totalRound2;
            timePerRound = (out_hw * out_hw);
            cyclePerTime = (kernel_size == 2'b11) ? 9 : 1; // 3x3 vs 1x1

    case (in_hw)
        3'b011: in_hw_num=8;
        3'b100:in_hw_num=16;
        3'b101:in_hw_num=32;
        default: in_hw_num=32;
    endcase

    oOutHW =(pingpong)?in_hw_num:((calc_type==2'b00)?0:{in_hw_num,1'b0}) ;//残差的时候输入时in_hw_num的2备
    oActHW=(!pingpong)?in_hw_num:((calc_type==2'b00)?0:{in_hw_num,1'b0});


            case (in_c)
                4'b0110:begin in_c_num=6; end 
                4'b0111:begin in_c_num=7; end 
                4'b1000:begin in_c_num=8; end 
                default:begin in_c_num=6; end 
            endcase
            case (out_c)
                4'b0110:begin out_c_num=6; end 
                4'b0111:begin out_c_num=7; end 
                4'b1000:begin out_c_num=8; end 
                default:begin out_c_num=6; end 
            endcase

    oActlogInC = (~pingpong)?in_c_num:((calc_type==2'b00)?0:(in_c_num-1)); 
    oOutlogInC =  (pingpong)?in_c_num:((calc_type==2'b00)?0:(in_c_num-1)); //只用管输入通道数,残差的时候残差部分输入通道-1
end
end

//assign oActReadCenterAddr=(oActReadEn)?t*stride_num:0;
//assign oOutReadCenterAddr=(oOutReadEn)?t*stride_num:0;
logic[31:0]hang_temp;

logic [5:0] readchannel_num;
//logic [5:0] writechannel_num;

always_comb begin 
    if ((stride_num==2)||(calc_type==2'b01)) //指的是注卷积的步长
    begin
        hang_temp=((cut_num)/totalRound)/(in_hw_num[8:1]);//(cut_num)/totalRound指第几个写地址，每(in_hw_num[8:1]指的是输入图像长宽的一半，长32每16个写地址就要加一行),但注意残差的时候残差的输入尺寸是in_hw_num的2倍，残差的hangtemp要初二
    end
    else
    begin
        hang_temp=0;
    end

    if(state==CONV)//残差时还不能改变写地址
    begin
    if (pingpong)//数据主要来自outsram
    begin
        if((oActReadEn)||(oOutReadEn))
        begin
            oOutReadCenterAddr=(cut_num/totalRound)*stride_num*totalRound1+32*hang_temp*(calc_type==2'b00);//数据主要来自outsram的时候，caltype为00才是主卷积要加hangtemp
        end
        else
        begin
        //oActReadCenterAddr=0;
        oOutReadCenterAddr=0;
        end
        oActReadCenterAddr=(calc_type==2'b01)?(oOutReadCenterAddr+32*hang_temp[31:1]):'b0;
    end
    else//数据主要来自actsram
    begin
        if((oActReadEn)||(oOutReadEn))
        begin
            oActReadCenterAddr=(cut_num/totalRound)*stride_num*totalRound1+32*hang_temp*(calc_type==2'b00);
        end
        else
        begin
        oActReadCenterAddr=0;
        end
        oOutReadCenterAddr=(calc_type==2'b01)?(oActReadCenterAddr+32*hang_temp[31:1]):'b0;
    end
    end
end






/*
always_comb begin
    if(oActReadEn)
    begin
        oOutReadCenterAddr=0;
        if(cut_num==0)
        begin
            oActReadCenterAddr=0;
            hang_temp=0;
        end
        else if(cut_num%totalRound==0)
        begin
            if(stride_num==2)
            begin
                if(((((cut_num)/totalRound))%(32/totalRound2))==0)
                begin
                    hang_temp=hang_temp+1;
                end

            end
            else
            begin
                hang_temp=0;
            end



            oActReadCenterAddr=(cut_num/totalRound)*stride_num*totalRound1+32*hang_temp;//每次加输入通道数乘以步长
        end
        else 
        begin
            oActReadCenterAddr=oActReadCenterAddr;
        end

    end
    else if(oOutReadEn)
    begin
        oActReadCenterAddr=0;

        if(cut_num==0)
        begin
            oOutReadCenterAddr=0;
            hang_temp=0;
        end
        else if(cut_num%totalRound==0)
        begin
            if(stride_num==2)
            begin
                if(((((cut_num)/totalRound))%(32/totalRound2))==0)
                begin
                    hang_temp=hang_temp+1;
                end

            end
            else
            begin
                hang_temp=0;
            end
        end

        if(cut_num==0)
        begin
            oOutReadCenterAddr=0;
        end
        else if(cut_num%totalRound==0)
        begin
            oOutReadCenterAddr=(cut_num/totalRound)*stride_num*totalRound1+32*hang_temp;
        end
        else 
        begin
            oOutReadCenterAddr=oOutReadCenterAddr;
        end
        
    end
    else
    begin
        oActReadCenterAddr=0;
        oOutReadCenterAddr=0;
    end
end
*/
logic[4:0] oBNAddr_notdelay;
logic[4:0] oBNAddr_temp;

logic[3:0] res_flag;
logic CONV2_done;

always_ff@(posedge clk or negedge nRst) begin
    if ((!nRst)) begin
        state <= IDLE;
        pingpong <= 0;
        round <= 0;
        t <= 0;
        cycle <= 0;
        oComputeDone <= 0;
        // Reset other outputs
        oActWriteEn_notdelay <= 0;
        oOutWriteAddr_notdelay <= 0;
        oOutWriteEn_notdelay <= 0;
        oActWriteAddr_notdelay <= 0;
        oInputBufNWe <= 1;
        oWeightReadEn <= 0;
        oAccInstr_notdelay <= 2'b00; // Hold
        oBNAddr <= 'b0;
        oWeightAddr <= 'b0;

        cut_num<=0;
        readchannel_num<=0;
        res_flag<=0;
        CONV2_done<=0;
    end else if ((!nCe)||(oComputeDone)) begin
        case (state)
            IDLE: begin
                oComputeDone <= 0;
                if (iInstruction[31:30] != 2'b11) begin // Valid instruction
                    state <= oComputeDone?IDLE:CONV;
                    round <= 0;
                    t <= 0;
                    cycle <= 0;
                    oWeightAddr <= oComputeDone?0:w1_addr;
                    oWeightReadEn <= oComputeDone?0:1;
                    /*

                    if(oComputeDone)
                    begin
                        if(oActWriteEn||oOutWriteEn)
                    end





                    oBNAddr <= oComputeDone?oBNAddr:bn_addr;
                    */
                    oAccInstr_notdelay <= 2'b00; // Reset accumulator，00置零，01接收数据，10累加操作，11保持操作
                    oInputBufNWe <= 1;

                    if(oComputeDone)
                    begin
                        if (!pingpong)//ci时pingpong已经变了，单我们的写使能要维持上一个周期的
                                begin
                                    oActWriteEn_notdelay <= 1;
                                    oOutWriteEn_notdelay <= 0;
                                end
                                else
                                begin
                                    oActWriteEn_notdelay <= 0;
                                    oOutWriteEn_notdelay <= 1;
                                end
                    end
                    else
                    begin
                    oActWriteAddr_notdelay <= 0;
                    oActWriteEn_notdelay <= 0;
                    oOutWriteAddr_notdelay <= 0;
                    oOutWriteEn_notdelay <= 0;
                    end



                    /*
                    oActWriteAddr_notdelay <= 0;
                    oActWriteEn_notdelay <= 0;
                    oOutWriteAddr_notdelay <= 0;
                    oOutWriteEn_notdelay <= 0;
                    */

                    cut_num<=0;
                    readchannel_num<=0;

                    res_flag<=0;
                    CONV2_done<=0;


                end
            end
            
            CONV: begin
                            if((oWeightAddr-w1_addr)<(cyclePerTime*totalRound-1+calc_type*totalRound[15:1]))//残差可能会在conv2里达到oweight的最大值，所以那里也要判断一下
                            begin
                                oWeightAddr <=oWeightAddr+1;
                            end
                            else
                            begin
                                oWeightAddr <=w1_addr;
                            end
                            
                            oWeightReadEn <= 1;
                            oInputBufNWe <= 0;

                            //残差跳转
                            CONV2_done<=0;
                            if((calc_type==2'b01)&(cycle==8)&(!CONV2_done))//cutnum每经过totalround1我们就要跳到conv2里进行一个残差的计算,但注意在最后一次残差可能直接congconv2跳到idle
                            begin
                                if (totalRound1[2]) //输入通道是4，则cutnum每经过4进入残差
                                begin
                                    if(cut_num[1:0]==2'b11)
                                    begin
                                        state<=CONV2;
                                    end
                                end
                                else//输入通道是2
                                begin
                                    if(cut_num[0])
                                    begin
                                        state<=CONV2;
                                    end
                                end
                                //否则不进入残差
                            end


                            //acc的逻辑,每9，2*9，4*9，2*9+1，4*9+2个clk变一次和输入通道数有关
                            if(cycle==0)//是1也不一定？看看最后的时序
                            begin
                            if (totalRound1[2]) //输入通道是4，则cutnum每经过4开始一轮计算
                            begin
                                if(cut_num[1:0]==2'b00)
                                begin
                                    oAccInstr_notdelay <= 2'b01;//接受
                                end
                            end
                            else if(totalRound1[1])//输入通道是2
                            begin
                                if(cut_num[0]==1'b0)
                                begin
                                    oAccInstr_notdelay <= 2'b01;//接受
                                end
                            end
                            else//输入通道是1
                            begin
                                oAccInstr_notdelay <= 2'b01;//接受
                            end
                            end
                            else
                            begin
                                oAccInstr_notdelay <= 2'b10;//累加
                            end


                            /*
                            if (cycle == 0) begin
                                if(readchannel_num<(totalRound1-1))
                                begin
                                    readchannel_num<=readchannel_num+1;
                                end
                                else
                                begin
                                    readchannel_num<=0;
                                end
                                //oAccInstr_notdelay <= 2'b01; // 接受
                            end 
                            if((readchannel_num==0)&&(cycle==0))
                            begin
                                oAccInstr_notdelay <= 2'b01;//接受
                            end
                            else
                            begin
                                oAccInstr_notdelay <= 2'b10;//累加
                            end
                            */




                            //写地址和写使能的逻辑
                            if((cycle==0)&(cut_num!=0))//cycle==0，防止残差没有做完，记得最后在结束的时候还要输出一次写使能
                            begin
                            if (totalRound1[2]) //输入通道是4，则cutnum每经过4就换一个地址写
                            begin
                                if(cut_num[1:0]==2'b00)//写使能有效一下，下一个clk换地址
                                begin
                                    if (pingpong)//数据从out来，写道act
                                    begin
                                        oActWriteEn_notdelay <= 1;
                                        oOutWriteEn_notdelay <= 0;
                                    end
                                    else
                                    begin
                                        oActWriteEn_notdelay <= 0;
                                        oOutWriteEn_notdelay <= 1;
                                    end
                                end
                                else//写使能无效
                                begin
                                    oActWriteEn_notdelay <= 0;
                                    oOutWriteEn_notdelay <= 0;
                                end
                            end
                            else if(totalRound1[1])//输入通道是2
                            begin
                                if(cut_num[0]==1'b0)
                                begin
                                    if (pingpong)//数据从out来，写道act
                                    begin
                                        oActWriteEn_notdelay <= 1;
                                        oOutWriteEn_notdelay <= 0;
                                    end
                                    else
                                    begin
                                        oActWriteEn_notdelay <= 0;
                                        oOutWriteEn_notdelay <= 1;
                                    end
                                end
                                else//写使能无效
                                begin
                                    oActWriteEn_notdelay <= 0;
                                    oOutWriteEn_notdelay <= 0;
                                end
                            end
                            else//输入通道是1
                            begin
                                if (pingpong)//数据从out来，写道act
                                begin
                                    oActWriteEn_notdelay <= 1;
                                    oOutWriteEn_notdelay <= 0;
                                end
                                else
                                begin
                                    oActWriteEn_notdelay <= 0;
                                    oOutWriteEn_notdelay <= 1;
                                end
                            end
                            end
                            else
                            begin
                                oActWriteEn_notdelay <= 0;
                                oOutWriteEn_notdelay <= 0;
                            end

                            // Update write addresses

                            if((oActWriteEn_notdelay)||(oOutWriteEn_notdelay))//写使能有效后改变写地址，写地址和cut_num/totalRound1;有关
                            begin
                                if (totalRound1[2]) //输入通道是4，则cutnum每经过4就换一个地址写
                                begin
                                if (pingpong) //数据从out来，写道act
                                begin
                                oActWriteAddr_notdelay <= cut_num[63:2];//相当于除了4
                                oOutWriteAddr_notdelay <= 0;
                                end 
                                else 
                                begin
                                oOutWriteAddr_notdelay <= cut_num[63:2];
                                oActWriteAddr_notdelay <= 0;
                                end
                                end
                                else if(totalRound1[1])//输入通道是2
                                begin
                                if (pingpong) //数据从out来，写道act
                                begin
                                oActWriteAddr_notdelay <= cut_num[63:1];//相当于除了2
                                oOutWriteAddr_notdelay <= 0;
                                end 
                                else 
                                begin
                                oOutWriteAddr_notdelay <= cut_num[63:1];
                                oActWriteAddr_notdelay <= 0;
                                end
                                end
                                else//输入通道是1
                                begin
                                if (pingpong) //数据从out来，写道act
                                begin
                                oActWriteAddr_notdelay <= cut_num[63:0];//相当于除了1
                                oOutWriteAddr_notdelay <= 0;
                                end 
                                else 
                                begin
                                oOutWriteAddr_notdelay <= cut_num[63:0];
                                oActWriteAddr_notdelay <= 0;
                                end
                                end
                            end




                            //BN的逻辑
                            if ((cut_num==0)&(cycle==0))//bnaddr给的可能稍慢了一点？但是应该不影响使用
                            begin 
                                oBNAddr<=bn_addr;
                            end
                            else if(oActWriteEn||oOutWriteEn)
                            begin
                            if((oBNAddr-bn_addr)==(totalRound2-1))
                            begin
                                oBNAddr<=bn_addr;
                            end
                            else
                            begin
                                oBNAddr<=oBNAddr+1;
                            end
                            end









/*
                                //BN的逻辑


                                if(oActWriteEn||oOutWriteEn)//写地址变bn变，循环为输出通道数
                                begin
                                if((oBNAddr-bn_addr)==(totalRound2-1))
                                begin
                                    oBNAddr<=bn_addr;
                                end
                                else
                                begin
                                    oBNAddr<=oBNAddr+1;
                                end
                                end
                        
*/



                if (round < (totalRound-1)) begin
                    if (t < (timePerRound-1)) begin
                        if (cycle < (cyclePerTime-1)) begin
                            // Generate control signals


                            
                            cycle <= cycle + 1;
                        end else begin
                            cycle <= 0;
                            t <= t + 1;
                            cut_num<=cut_num+1;

                        end
                    end else begin
                        if (cycle < (cyclePerTime-1)) begin
                            // Generate control signals
                            


                            cycle <= cycle + 1;
                        end else begin
                            cycle <= 0;
                            t <=0;
                            cut_num<=cut_num+1;
                            round <= round + 1;

                            
                        end
                        //t <= 0;
                        
                        //oWeightAddr <= w1_addr; // Next weight bank
                    end
                end else begin
                        if (t < (timePerRound-1)) begin
                            if (cycle < (cyclePerTime-1)) begin
                            // Generate control signals


                            cycle <= cycle + 1;
                        end else begin
                            cycle <= 0;
                            t <= t + 1;
                            cut_num<=cut_num+1;
                            
                        end
                    end else begin
                        if (cycle < (cyclePerTime-1)) begin
                            // Generate control signals


                            
                            cycle <= cycle + 1;
                        end else begin//最后一次
                            //残差的ocomputerdone可能在conv2里完成
                            cut_num<=cut_num+1;
                            cycle <= cycle;
                            t <=t;
                            if(calc_type==2'b00)//只有前五个类型才会在conv里完成
                            begin
                            state <= IDLE;
                            oComputeDone <= 1;
                            pingpong <= ~pingpong;
                            oWeightReadEn <= 0;
                            oWeightAddr <=0;
                            end
                        end
                        
                    end
                    // Finalize computation

                    
                    
                end
            end


            CONV2:
            begin
                if((oWeightAddr-w1_addr)<(cyclePerTime*totalRound-1+calc_type*totalRound[15:1]))//残差可能会在conv2里达到oweight的最大值，所以那里也要判断一下
                begin
                    oWeightAddr <=oWeightAddr+1;
                end
                else
                begin
                    oWeightAddr <=w1_addr;
                end

                if(res_flag<(totalRound1[2:1]-1))//toaalround1是2则小于1，是4则小于2
                begin
                    res_flag<=res_flag+1;
                end
                else
                begin
                    res_flag<=0;
                    if((round==(totalRound-1))&(t==(timePerRound-1)))
                    begin
                        cut_num<=0;
                        cycle <= 0;
                        t <=0;
                        state <= IDLE;
                        oComputeDone <= 1;
                        pingpong <= ~pingpong;
                        oWeightReadEn <= 0;
                        oWeightAddr <=0;
                    end
                    else
                    begin
                        state<=CONV;
                    end
                end
                CONV2_done<=1;
            end
        endcase
    end
    else if(nCe)
    begin
        state <= IDLE;
        //pingpong <= 0;pingpong信号不会被nce归零
        round <= 0;
        t <= 0;
        cycle <= 0;
        oComputeDone <= 0;
        // Reset other outputs
        //oActWriteEn_notdelay <= 0;
        //oOutWriteEn_notdelay <= 0;
        oActWriteAddr_notdelay <= 0;
        oActWriteEn_notdelay <= 0;
        oOutWriteAddr_notdelay <= 0;
        oOutWriteEn_notdelay <= 0;




        oInputBufNWe <= 1;
        oWeightReadEn <= 0;
        oWeightAddr <= 'b0;
        oAccInstr_notdelay <= 2'b00; // Hold
        oBNAddr_notdelay <= 'b0;
        cut_num<=0;

        res_flag<=0;

    end
end


always_ff @( posedge clk )
begin
    if((!nRst)||(nCe)||(oInputBufNWe))
    begin
        oInputBufSelect<=0;
    end
    else
    begin
        if(state==IDLE)
        begin
            oInputBufSelect<=0;
        end
        else
        begin
            oInputBufSelect<=oOutReadEn;
        end
    end
end


//assign oInputBufSelect = ((!nRst)||(nCe)||(state==IDLE))?0:(oInputBufNWe?0:pingpong);//为1时选act
// Delay control signals to match pipeline stages
always @(posedge clk) begin
    if ((!nRst)||(nCe)) begin
        oAccInstr <= 0;

       
    end else begin
        oAccInstr<=oAccInstr_notdelay;

      
    end
end

endmodule