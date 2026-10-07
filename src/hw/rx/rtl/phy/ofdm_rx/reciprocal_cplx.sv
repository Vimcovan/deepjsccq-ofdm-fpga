`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/12 22:51:30
// Design Name: 
// Module Name: reciprocal_cplx
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


module reciprocal_cplx(
    input logic clk,
    input logic rst_n,
    input logic[23:0] s_in_tdata,       // Q1.10
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[31:0] m_out_tdata,     // Q5.10
    output logic m_out_tvalid,
    input logic m_out_tready
    );
    //stage: 计算a^2+b^2，并寄存输入数据
    logic unsigned[24:0] square_i;      //Q.20
    logic unsigned[24:0] square_q;
    logic unsigned[15:0] square_data_i; //Q.10
    logic unsigned[15:0] square_data_o;
    logic[23:0] cplx_data_o;
    logic square_valid_o;
    logic square_ready_o;
    always_comb begin
        square_i = $signed(s_in_tdata[11:0])**2;
        square_q = $signed(s_in_tdata[23:12])**2;
        square_data_i = (square_i >> 10) + (square_q >> 10);
    end
    axis_forward_register # (
        .WIDTH(40)
    )
    u_square_reg (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata({s_in_tdata,square_data_i}),
        .s_in_tvalid(s_in_tvalid),
        .s_in_tready(s_in_tready),
        .m_out_tdata({cplx_data_o,square_data_o}),
        .m_out_tvalid(square_valid_o),
        .m_out_tready(square_ready_o)
    );
    //计算a/(a^2+b^2)、b/(a^2+b^2)
    logic[39:0] div_a_o,div_b_o; //Q.10
    logic div_valid_o;
    logic div_ready_o;
    div_block u_div_a (
        .aclk(clk),                                      // input wire aclk
        .aresetn(rst_n),                           // input wire aresetn
        .s_axis_divisor_tvalid(square_valid_o),    // input wire s_axis_divisor_tvalid
        .s_axis_divisor_tready(square_ready_o),    // output wire s_axis_divisor_tready
        .s_axis_divisor_tdata(square_data_o),      // input wire [15 : 0] s_axis_divisor_tdata
        .s_axis_dividend_tvalid(square_valid_o),  // input wire s_axis_dividend_tvalid
        .s_axis_dividend_tready(),  // output wire s_axis_dividend_tready
        .s_axis_dividend_tdata({2'd0,cplx_data_o[11:0],10'd0}),    // input wire [23 : 0] s_axis_dividend_tdata
        .m_axis_dout_tvalid(div_valid_o),          // output wire m_axis_dout_tvalid
        .m_axis_dout_tready(div_ready_o),          // input wire m_axis_dout_tready
        .m_axis_dout_tdata(div_a_o)            // output wire [39 : 0] m_axis_dout_tdata
    );
    div_block u_div_b (
        .aclk(clk),                                      // input wire aclk
        .aresetn(rst_n),                           // input wire aresetn
        .s_axis_divisor_tvalid(square_valid_o),    // input wire s_axis_divisor_tvalid
        .s_axis_divisor_tready(),    // output wire s_axis_divisor_tready
        .s_axis_divisor_tdata(square_data_o),      // input wire [15 : 0] s_axis_divisor_tdata
        .s_axis_dividend_tvalid(square_valid_o),  // input wire s_axis_dividend_tvalid
        .s_axis_dividend_tready(),  // output wire s_axis_dividend_tready
        .s_axis_dividend_tdata({2'd0,-cplx_data_o[23:12],10'd0}),    // input wire [23 : 0] s_axis_dividend_tdata
        .m_axis_dout_tvalid(),          // output wire m_axis_dout_tvalid
        .m_axis_dout_tready(div_ready_o),          // input wire m_axis_dout_tready
        .m_axis_dout_tdata(div_b_o)            // output wire [39 : 0] m_axis_dout_tdata
    );
    //饱和与截断
    logic signed[21:0] div_q,div_i;
    logic[15:0] div_i_saturated,div_q_saturated;
    always_comb begin
        div_i = div_a_o[37:16];
        div_q = div_b_o[37:16];
        if(div_i < -22'sd32768) div_i_saturated = -16'd32768;
        else if(div_i > 22'sd32767) div_i_saturated = 16'd32767;
        else div_i_saturated = div_i[15:0];

        if(div_q < -22'sd32768) div_q_saturated = -16'd32768;
        else if(div_q > 22'sd32767) div_q_saturated = 16'd32767;
        else div_q_saturated = div_q[15:0];

        m_out_tdata = {div_q_saturated,div_i_saturated};
        m_out_tvalid = div_valid_o;
        div_ready_o = m_out_tready;
    end
endmodule
