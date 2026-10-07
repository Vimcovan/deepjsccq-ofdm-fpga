`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/17 21:28:54
// Design Name: 
// Module Name: axis_combine
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


module axis_combine#(
    parameter CHANNEL = 2,
    parameter MAX_WIDTH = 24
)
(
    input logic clk,
    input logic rst_n,
    input logic[MAX_WIDTH*CHANNEL-1:0] s_in_tdata,
    input logic[CHANNEL-1:0] s_in_tvalid,
    output logic[CHANNEL-1:0] s_in_tready,
    output logic[MAX_WIDTH*CHANNEL-1:0] m_out_tdata,
    output logic m_out_tvalid,
    input logic m_out_tready
);
    logic[CHANNEL-1:0] ch_valid_o;  
    logic[CHANNEL-1:0] ch_ready_o; 
    assign m_out_tvalid = &ch_valid_o;
        generate for(genvar i=0;i<CHANNEL;i++) begin
            always_comb ch_ready_o[i] = m_out_tready & m_out_tvalid;
            axis_forward_register# (
                .WIDTH(MAX_WIDTH)
            )
            u_reg (
                .clk(clk),
                .rst_n(rst_n),
                .s_in_tdata(s_in_tdata[i*MAX_WIDTH+:MAX_WIDTH]),
                .s_in_tvalid(s_in_tvalid[i]),
                .s_in_tready(s_in_tready[i]),
                .m_out_tdata(m_out_tdata[i*MAX_WIDTH+:MAX_WIDTH]),
                .m_out_tvalid(ch_valid_o[i]),
                .m_out_tready(ch_ready_o[i])
            );
        end
    endgenerate
endmodule
