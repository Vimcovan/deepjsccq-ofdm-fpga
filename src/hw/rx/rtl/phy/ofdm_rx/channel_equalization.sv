`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/13 11:58:04
// Design Name: 
// Module Name: channel_equalization
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

`define LTF_ONE {6,7,10,11,13,15,16,17,18,19,20,23,24,26,28,29,30,31,33,36,37,39,41,47,48,51,53,55,56,57,58}
`define LTF_MINUS_ONE {8,9,12,14,21,22,25,27,34,35,38,40,42,43,44,45,46,49,50,52,54}
module channel_equalization#(
    parameter NSYM = 20         // data OFDM symbols per frame (LTF1 + LTF2 + NSYM symbols)
)
(
    input logic clk,
    input logic rst_n,
    input logic[23:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[23:0] m_out_tdata,
    output logic m_out_tvalid,
    input logic m_out_tready
    );
    //采样点、符号计数
    reg[5:0] sample_cnt;
    reg[$clog2(NSYM+2)-1:0] symbol_cnt;     // 0 = LTF1, 1 = LTF2, 2.. = data
    always@(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            sample_cnt <= 6'd0;
            symbol_cnt <= 'd0;
        end
        else begin
            if(s_in_tvalid & s_in_tready) begin
                if(sample_cnt == 63) begin
                    sample_cnt <= 6'd0;
                    if(symbol_cnt == NSYM+1) symbol_cnt <= 'd0;
                    else symbol_cnt <= symbol_cnt + 1;
                end
                else sample_cnt <= sample_cnt + 1;
            end
        end
    end
    //LTF、DATA分流
    logic[23:0] ltf_data;
    logic ltf_valid;
    logic ltf_ready;
    logic[23:0] data_data;
    logic data_valid;
    logic data_ready;
    // LTF1 (sign-corrected) buffer, 64 x 24 distributed RAM, asynchronous read at the same subcarrier of LTF2
    logic[23:0] ltf1_ram[0:63];
    logic[11:0] ltf1_i, ltf1_q;
    logic[23:0] ltf_avg;
    assign {ltf1_q, ltf1_i} = ltf1_ram[sample_cnt];
    always_ff@(posedge clk) if(s_in_tvalid & s_in_tready & (symbol_cnt==0)) ltf1_ram[sample_cnt] <= ltf_data;
    always_comb begin
        data_data = s_in_tdata;
        if(sample_cnt inside `LTF_ONE) ltf_data = s_in_tdata;
        else if(sample_cnt inside `LTF_MINUS_ONE) ltf_data = {-s_in_tdata[23:12],-s_in_tdata[11:0]};
        else ltf_data = {12'd1,12'd1};
        // channel estimate = (LTF1 + LTF2)/2 (sign-corrected): LTF1 is stored, the average goes out with LTF2
        ltf_avg = {12'(($signed({ltf1_q[11],ltf1_q}) + $signed({ltf_data[23],ltf_data[23:12]})) >>> 1),
                   12'(($signed({ltf1_i[11],ltf1_i}) + $signed({ltf_data[11],ltf_data[11:0]})) >>> 1)};
        if(symbol_cnt==0) begin                 // LTF1: store only
            ltf_valid = 1'b0;
            s_in_tready = 1'b1;
            data_valid = 1'b0;
        end
        else if(symbol_cnt==1) begin            // LTF2: average -> reciprocal
            ltf_valid = s_in_tvalid;
            s_in_tready = ltf_ready;
            data_valid = 1'b0;
        end
        else begin
            data_valid = s_in_tvalid;
            s_in_tready = data_ready;
            ltf_valid = 1'b0;
        end
    end
    //计算信道估计值倒数
    logic[31:0] est_inv_data;
    logic est_inv_valid;
    logic est_inv_ready;
    reciprocal_cplx  reciprocal_cplx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(ltf_avg),
        .s_in_tvalid(ltf_valid),
        .s_in_tready(ltf_ready),
        .m_out_tdata(est_inv_data),
        .m_out_tvalid(est_inv_valid),
        .m_out_tready(est_inv_ready)
    );
    //重复信道估计值倒数20次
    logic[31:0] rep_data;
    logic rep_valid;
    logic rep_ready;
    axis_packet_repeat # (
        .WIDTH(32),
        .LENGTH(64),
        .TIMES(NSYM)
    )
    u_repeat (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(est_inv_data),
        .s_in_tvalid(est_inv_valid),
        .s_in_tready(est_inv_ready),
        .m_out_tdata(rep_data),
        .m_out_tvalid(rep_valid),
        .m_out_tready(rep_ready)
    );
    //信道均衡
    logic[57:0] cmpy_data;  //Q9.20
    complex_multiplier # (
        .A_W(12),
        .B_W(16)
    )
    u_cmpy (
        .clk(clk),
        .rst_n(rst_n),
        .s_a_tdata(data_data),
        .s_a_tvalid(data_valid),
        .s_a_tready(data_ready),
        .s_b_tdata(rep_data),
        .s_b_tvalid(rep_valid),
        .s_b_tready(rep_ready),
        .m_p_tdata(cmpy_data),
        .m_p_tvalid(m_out_tvalid),
        .m_p_tready(m_out_tready)
    );
    //饱和与截断
    logic signed[18:0] out_q,out_i;
    logic[11:0] out_i_saturated,out_q_saturated;
    always_comb begin
        out_i = cmpy_data[28:10];
        out_q = cmpy_data[57:39];
        if(out_i < -19'sd2048) out_i_saturated = -12'd2048;
        else if(out_i > 19'sd2047) out_i_saturated = 12'd2047;
        else out_i_saturated = out_i[11:0];

        if(out_q < -19'sd2048) out_q_saturated = -12'd2048;
        else if(out_q > 19'sd2047) out_q_saturated = 12'd2047;
        else out_q_saturated = out_q[15:0];

        m_out_tdata = {out_q_saturated,out_i_saturated};
    end
endmodule
