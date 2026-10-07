`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/12 18:55:29
// Design Name: 
// Module Name: CPE_compensation
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


module CPE_compensation(
    input logic clk,
    input logic rst_n,
    input logic[23:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[23:0] m_out_tdata,
    output logic m_out_tvalid,
    input logic m_out_tready
    );
    /* 输入广播到路径一、二 */
    logic[23:0] sum_data_i;
    logic sum_valid_i;
    logic sum_ready_i;
    logic[23:0] fifo_data_i;
    logic fifo_valid_i;
    logic fifo_ready_i;
    always_comb begin: broadcast
        sum_data_i = s_in_tdata;
        fifo_data_i = s_in_tdata;
        s_in_tready = sum_ready_i & fifo_ready_i;
        sum_valid_i = s_in_tvalid & fifo_ready_i;
        fifo_valid_i = s_in_tvalid & sum_ready_i;
    end

    /* 路径1：计算CPE，并生成旋转因子 */
    // 第一级：计算导频和
    logic[27:0] sum_data_o;
    logic sum_valid_o;
    logic sum_ready_o;
    logic[5:0] sample_cnt;
    assign sum_ready_i = (~sum_valid_o)|sum_ready_o;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) sample_cnt <= 6'd0;
        else if(sum_valid_i&sum_ready_i) sample_cnt <= sample_cnt + 1;
    end
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) sum_valid_o <= 1'b0;
        else if(sum_valid_i&sum_ready_i&&(sample_cnt=='d53)) sum_valid_o <= 1'b1;
        else if(sum_valid_o&sum_ready_o) sum_valid_o <= 1'b0;
    end
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) sum_data_o <= 28'd0;
        else if(sum_valid_i&sum_ready_i) begin
            if(sample_cnt == 11) begin
                sum_data_o <= {{2{sum_data_i[23]}},sum_data_i[23:12],
                             {2{sum_data_i[11]}},sum_data_i[11:0]};
            end
            else if(sample_cnt inside {25,39}) begin
                sum_data_o <= sum_data_o + 
                          {{2{sum_data_i[23]}},sum_data_i[23:12],
                          {2{sum_data_i[11]}},sum_data_i[11:0]};
            end
            else if(sample_cnt == 53) begin
                sum_data_o <= sum_data_o + 
                        {-{{2{sum_data_i[23]}},sum_data_i[23:12]},
                         -{{2{sum_data_i[11]}},sum_data_i[11:0]}};
            end
        end
    end
    // 第二级：对 4 导频均值求复数倒数 = 1/G，公共相位与幅度缓变一起补
    //   定标推导：16QAM{±1,±3} 功率归一化后最小电平 = 1/sqrt(10)；本工程数据域
    //   以 1.0 = 1024 定标（soft_decision 判决门限 648 = 2*1024/sqrt(10) = 2*324
    //   佐证），故 BPSK 导频(±1)的标称幅度 A_id = 1024。
    //   导频和 sum_data_o = 4*A_id*G，右移 2 位得均值 = A_id*G；
    //   送 reciprocal_cplx（输入约定 Q1.10，输出约定 1.0 = 1024）得
    //       1024 / (A_id*G/1024) = 1024 / G
    //   恰好就是 A 端口(Q1.10, 1.0 = 1024)约定下的复数修正因子，无需再定标。
    logic[31:0] cpe_inv_data_o;      // Q5.10，I 在低 16 位、Q 在高 16 位
    logic cpe_inv_valid_o;
    logic cpe_inv_ready_o;
    reciprocal_cplx u_reciprocal (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata({sum_data_o[27:16],sum_data_o[13:2]}),   // {Q,I} = 导频和 >> 2
        .s_in_tvalid(sum_valid_o),
        .s_in_tready(sum_ready_o),
        .m_out_tdata(cpe_inv_data_o),
        .m_out_tvalid(cpe_inv_valid_o),
        .m_out_tready(cpe_inv_ready_o)
    );
    // 第三级：Q5.10 饱和到 12 位 Q1.10（复数乘法器 A 端口格式），修正范围约 ±6dB
    logic signed[15:0] inv_i_wide, inv_q_wide;
    logic signed[11:0] inv_i_sat,  inv_q_sat;
    assign inv_i_wide = cpe_inv_data_o[15:0];
    assign inv_q_wide = cpe_inv_data_o[31:16];
    assign inv_i_sat  = (inv_i_wide >  16'sd2047) ?  12'sd2047 :
                        (inv_i_wide < -16'sd2048) ? -12'sd2048 : inv_i_wide[11:0];
    assign inv_q_sat  = (inv_q_wide >  16'sd2047) ?  12'sd2047 :
                        (inv_q_wide < -16'sd2048) ? -12'sd2048 : inv_q_wide[11:0];
    // 第四级：保持64采样点
    logic[23:0] holder_data_o;
    logic holder_valid_o;
    logic holder_ready_o;
    axis_holder # (
        .WIDTH(24),
        .N(64)
    )
    axis_holder_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata({inv_q_sat,inv_i_sat}),
        .s_in_tvalid(cpe_inv_valid_o),
        .s_in_tready(cpe_inv_ready_o),
        .m_out_tdata(holder_data_o),
        .m_out_tvalid(holder_valid_o),
        .m_out_tready(holder_ready_o)
    );
    
    /* 路径2：缓存输入数据 */
    logic[23:0] fifo_data_o;
    logic fifo_valid_o;
    logic fifo_ready_o;
    axis_fifo # (
        .DEPTH(64),
        .WIDTH(24)
    )
    axis_fifo_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(fifo_data_i),
        .s_in_tvalid(fifo_valid_i),
        .s_in_tready(fifo_ready_i),
        .m_out_tdata(fifo_data_o),
        .m_out_tvalid(fifo_valid_o),
        .m_out_tready(fifo_ready_o)
    );

    //补偿复数增益（幅度 + 相位）
    logic[49:0] cmpy_data_o;
    // 同 frame_detection：25 位乘积直接切 12 位在满量程附近会回绕(符号翻转)，
    // 改为先取 14 位宽值(= 乘积/2048 的真值)，再饱和钳到 12 位有符号范围。
    logic signed[13:0] cpi_wide, cpq_wide;
    logic signed[11:0] cpi_sat,  cpq_sat;
    assign cpi_wide = cmpy_data_o[23:10];
    assign cpq_wide = cmpy_data_o[48:35];
    assign cpi_sat  = (cpi_wide >  14'sd2047) ?  12'sd2047 :
                      (cpi_wide < -14'sd2048) ? -12'sd2048 :  cpi_wide[11:0];
    assign cpq_sat  = (cpq_wide >  14'sd2047) ?  12'sd2047 :
                      (cpq_wide < -14'sd2048) ? -12'sd2048 :  cpq_wide[11:0];
    assign m_out_tdata = {cpq_sat, cpi_sat};
    complex_multiplier # (
        .A_W(12),
        .B_W(12)
    )
    u_cmpy (
        .clk(clk),
        .rst_n(rst_n),
        .s_a_tdata(holder_data_o),
        .s_a_tvalid(holder_valid_o),
        .s_a_tready(holder_ready_o),
        .s_b_tdata(fifo_data_o),
        .s_b_tvalid(fifo_valid_o),
        .s_b_tready(fifo_ready_o),
        .m_p_tdata(cmpy_data_o),
        .m_p_tvalid(m_out_tvalid),
        .m_p_tready(m_out_tready)
    );
endmodule
