`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/17 21:08:17
// Design Name: 
// Module Name: axis_broadcast
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


module axis_broadcast#(
    parameter WIDTH = 24,
    parameter CHANNEL = 2
)
(
    input logic clk,
    input logic rst_n,
    input logic[WIDTH-1:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[WIDTH*CHANNEL-1:0] m_out_tdata,
    output logic[CHANNEL-1:0] m_out_tvalid,
    input logic[CHANNEL-1:0] m_out_tready
);
    logic[CHANNEL-1:0] ch_ready_i;
    logic[CHANNEL-1:0] ch_valid_i;
    assign s_in_tready = &ch_ready_i;
    generate for(genvar i=0;i<CHANNEL;i++) begin
            always_comb ch_valid_i[i] = s_in_tvalid & s_in_tready;
            axis_forward_register# (
                .WIDTH(WIDTH)
            )
            u_reg (
                .clk(clk),
                .rst_n(rst_n),
                .s_in_tdata(s_in_tdata),
                .s_in_tvalid(ch_valid_i[i]),
                .s_in_tready(ch_ready_i[i]),
                .m_out_tdata(m_out_tdata[i*WIDTH+:WIDTH]),
                .m_out_tvalid(m_out_tvalid[i]),
                .m_out_tready(m_out_tready[i])
            );
        end
    endgenerate
endmodule
