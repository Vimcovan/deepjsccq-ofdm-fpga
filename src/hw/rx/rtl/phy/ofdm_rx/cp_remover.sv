`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/12 15:14:01
// Design Name: 
// Module Name: cp_remover
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module cp_remover(
    input logic            clk             ,
    input logic            rst_n           ,
    input logic [23:0]     s_in_tdata      ,
    input logic            s_in_tlast      ,
    input logic            s_in_tvalid     ,
    output logic           s_in_tready     ,
    output logic [23:0]    m_out_tdata     ,
    output logic           m_out_tlast     ,
    output logic           m_out_tvalid    ,
    input logic            m_out_tready
    );
    logic in_fire;
    assign in_fire = s_in_tvalid & s_in_tready;
    //状态编码
    typedef enum logic[2:0] { 
        IDLE = 3'b000,
        LTF = 3'b001,
        CP = 3'b010,
        DATA = 3'b100
    } state_t;
    state_t state_c,state_n;
    //计数器
    logic[6:0] sample_cnt;
    localparam DATA_LENGTH = 'd64;
    localparam CP_LENGTH = 'd16;
    localparam LTF_LENGTH = 'd128;     // LTF1 + LTF2 (two back-to-back 64-sample FFT windows)
    //第一段：状态寄存器
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) state_c <= IDLE;
        else state_c <= state_n;
    end
    //第二段：产生状态的组合逻辑
    always_comb begin
        state_n = state_c;
        case(state_c)
            IDLE: begin
                if(rst_n) state_n = LTF;
            end
            LTF: begin
                if(in_fire&(sample_cnt == LTF_LENGTH-1))
                    state_n = CP;
            end
            CP: begin
                if(in_fire&(sample_cnt == CP_LENGTH-1))
                    state_n = DATA;
            end
            DATA: begin
                if(in_fire&(sample_cnt == DATA_LENGTH-1)) begin
                    if(s_in_tlast) state_n = LTF;
                    else state_n = CP;
                end
            end
        endcase
    end
    //第三段：计数器
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) sample_cnt <= 'd0;
        else begin
            case(state_c)
                IDLE: sample_cnt <= 'd0;
                CP: begin
                    if(in_fire) begin
                        if(sample_cnt == CP_LENGTH - 1) sample_cnt <= 'd0;
                        else sample_cnt <= sample_cnt + 1;
                    end
                end
                LTF: begin
                    if(in_fire) begin
                        if(sample_cnt == LTF_LENGTH - 1) sample_cnt <= 'd0;
                        else sample_cnt <= sample_cnt + 1;
                    end
                end
                DATA: begin
                    if(in_fire) begin
                        if(sample_cnt == DATA_LENGTH - 1) sample_cnt <= 'd0;
                        else sample_cnt <= sample_cnt + 1;
                    end
                end
            endcase
        end
    end

    always_comb begin
        m_out_tdata = s_in_tdata;
        m_out_tlast = s_in_tlast;
        m_out_tvalid = 1'b0;
        s_in_tready = 1'b0;
        if(state_c inside {LTF,DATA}) begin
            m_out_tvalid = s_in_tvalid;
            s_in_tready = m_out_tready;
        end
        else if(state_c == CP) begin
            m_out_tvalid = 1'b0;
            s_in_tready = 1'b1;
        end
    end
endmodule
