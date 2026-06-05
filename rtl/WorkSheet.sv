module WorkSheet #(

    parameter P_INSTRUCTION_NUM = 16

) (

    input clk,

    input nRst,
    //From AHB slave
    input                                 nWe,
    input [$clog2(P_INSTRUCTION_NUM)-1:0] iWriteAddr,
    input [31:0] iWriteData,
    input [$clog2(P_INSTRUCTION_NUM)-1:0] iReadAddr,

    input                                 iAPUReady,
    //From Ctrl
    input                                 iComputeDone,
    //For AHB slave
    output reg        oWorkSheetDone,
    output wire [31:0] oWorkSheetData,
    //For Ctrl
    output reg        oCtrlnCe,
    output reg [31:0] oInstruction

);
    parameter INS_LENGTH = 'd32;
    reg [INS_LENGTH-1:0] r_Instruction [P_INSTRUCTION_NUM-1:0] ;
    reg [$clog2(P_INSTRUCTION_NUM)-1:0] currentInstrAddress;
    reg [$clog2(P_INSTRUCTION_NUM)-1:0] totalInstrCount;
    reg IDEL;

    reg [31:0]  oWorkSheetDataReg;

    integer i;
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            for (i =0 ;i<=P_INSTRUCTION_NUM-1 ;i=i+1 ) begin
                r_Instruction[i]<=0;
            end
            totalInstrCount<=0;
        end
        else begin
            if(!nWe)begin
                r_Instruction[iWriteAddr]<=iWriteData;
                totalInstrCount<=totalInstrCount+1'b1;
            end
            else begin
                if (currentInstrAddress==totalInstrCount-1'b1 && iComputeDone==1'b1) begin
                    totalInstrCount<=0;
                end
                else begin
                    totalInstrCount<=totalInstrCount;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            oWorkSheetDataReg<=0;
        end
        else begin
            oWorkSheetDataReg<=r_Instruction[iReadAddr];
        end
    end

    assign oWorkSheetData=oWorkSheetDataReg;

    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            oWorkSheetDone<=0;
            oInstruction<=0;
            currentInstrAddress<=0;
            oCtrlnCe<=1'b1;
            IDEL<=1'b1;
        end
        else if (IDEL) begin
            if (iAPUReady) begin
                oInstruction<=r_Instruction[currentInstrAddress];
                currentInstrAddress<=0;
                oCtrlnCe<=0;
                IDEL<=0;
            end
            else begin
                oWorkSheetDone<=0;
            end
        end
        else begin
            if (currentInstrAddress==totalInstrCount-1'b1 && iComputeDone==1'b1) begin
                oWorkSheetDone<=1;
                oInstruction<=0;
                currentInstrAddress<=0;
                oCtrlnCe<=1'b1;
                IDEL<=1'b1;
            end
            else begin
                if (iComputeDone==1'b1) begin
                    oWorkSheetDone<=0;
                    oInstruction<=r_Instruction[currentInstrAddress+1'b1];
                    currentInstrAddress<=currentInstrAddress+1'b1;
                    oCtrlnCe<=0;
                    IDEL<=0;
                end
                else begin
                    oInstruction<=oInstruction;
                    oWorkSheetDone<=0;
                    oCtrlnCe<=0;
                    IDEL<=0;
                end
            end
                
        end
    end
endmodule