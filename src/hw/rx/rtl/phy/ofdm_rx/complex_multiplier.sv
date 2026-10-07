`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/13 10:56:30
// Design Name: 
// Module Name: complex_multiplier
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


module complex_multiplier#(
    parameter A_W = 12,
    parameter B_W = 12   
)
(
    input logic clk,
    input logic rst_n,
    input logic[2*A_W-1:0] s_a_tdata,
    input logic s_a_tvalid,
    output logic s_a_tready,
    input logic[2*B_W-1:0] s_b_tdata,
    input logic s_b_tvalid,
    output logic s_b_tready,
    output logic[2*(A_W+B_W+1)-1:0] m_p_tdata,
    output logic m_p_tvalid,
    input logic m_p_tready
);
    //阻挡模式
    logic block_valid;
    logic block_ready;
    always_comb begin
        block_valid = s_a_tvalid & s_b_tvalid;
        s_a_tready = block_ready & s_b_tvalid;
        s_b_tready = block_ready & s_a_tvalid;
    end
    logic[A_W-1:0] a_re,a_im;
    logic[B_W-1:0] b_re,b_im;
    always_comb begin
        a_re = s_a_tdata[0+:A_W];
        a_im = s_a_tdata[A_W+:A_W];
        b_re = s_b_tdata[0+:B_W];
        b_im = s_b_tdata[B_W+:B_W];
    end
    //预加
    logic[(A_W+1)-1:0] a_sum,a_diff;
    logic[(B_W+1)-1:0] b_sum;
    logic[(A_W+1)-1:0] a_sum_q,a_diff_q;
    logic[(B_W+1)-1:0] b_sum_q;
    logic[A_W-1:0] a_re_q;
    logic[B_W-1:0] b_re_q,b_im_q;
    logic pre_add_valid;
    logic pre_add_ready;
    always_comb begin
        a_sum = {a_re[A_W-1],a_re} + {a_im[A_W-1],a_im};
        a_diff =  {a_im[A_W-1],a_im} - {a_re[A_W-1],a_re};
        b_sum = {b_re[B_W-1],b_re} + {b_im[B_W-1],b_im};
    end
    axis_forward_register # (
        .WIDTH(2*(A_W+1)+(B_W+1)+A_W+2*B_W)
    )
    u_pre_add_reg (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata({a_sum,a_diff,b_sum,a_re,b_re,b_im}),
        .s_in_tvalid(block_valid),
        .s_in_tready(block_ready),
        .m_out_tdata({a_sum_q,a_diff_q,b_sum_q,a_re_q,b_re_q,b_im_q}),
        .m_out_tvalid(pre_add_valid),
        .m_out_tready(pre_add_ready)
    );
    //乘法
    (*use_dsp48 = "yes"*)logic signed[(A_W+B_W+1)-1:0] t1,t2,t3;
    logic[(A_W+B_W+1)-1:0] t1_q,t2_q,t3_q;
    logic mult_valid;
    logic mult_ready;
    always_comb begin
        t1 = $signed(a_re_q) * $signed(b_sum_q);
        t2 = $signed(b_im_q) * $signed(a_sum_q);
        t3 = $signed(b_re_q) * $signed(a_diff_q);
    end
    axis_forward_register # (
        .WIDTH(3*(A_W+B_W+1))
    )
    u_mult_reg (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata({t1,t2,t3}),
        .s_in_tvalid(pre_add_valid),
        .s_in_tready(pre_add_ready),
        .m_out_tdata({t1_q,t2_q,t3_q}),
        .m_out_tvalid(mult_valid),
        .m_out_tready(mult_ready)
    );
    //后加
    logic[(A_W+B_W+1)-1:0] p_re,p_im;
    always_comb begin
        p_re = t1_q - t2_q;
        p_im = t1_q + t3_q;
    end
    axis_forward_register # (
        .WIDTH(2*(A_W+B_W+1))
    )
    u_final_add_reg (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata({p_im,p_re}),
        .s_in_tvalid(mult_valid),
        .s_in_tready(mult_ready),
        .m_out_tdata(m_p_tdata),
        .m_out_tvalid(m_p_tvalid),
        .m_out_tready(m_p_tready)
    );
endmodule
