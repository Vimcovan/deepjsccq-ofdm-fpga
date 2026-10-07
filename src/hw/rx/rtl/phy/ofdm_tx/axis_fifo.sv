`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/11 12:02:08
// Design Name: 
// Module Name: axis_fifo
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


module axis_fifo#(
    parameter DEPTH = 256,
    parameter WIDTH = 16
)
(
    input logic               clk             ,
    input logic               rst_n           ,
    
    input logic[WIDTH-1:0]    s_in_tdata      ,
    input logic               s_in_tvalid     ,
    output logic              s_in_tready     ,

    output logic[WIDTH-1:0]   m_out_tdata     ,
    output logic              m_out_tvalid    ,
    input logic               m_out_tready
);
    logic wr_en,rd_en;
    logic empty,full;
    always_comb begin
        m_out_tvalid = ~empty;
        s_in_tready = ~full;
        wr_en = s_in_tvalid & s_in_tready;
        rd_en = m_out_tvalid & m_out_tready;
    end
    fwft_fifo#(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH)
    )
    u_fifo(
        .clk         (clk),
        .rst_n       (rst_n),
        .din         (s_in_tdata),
        .dout        (m_out_tdata),
        .wr_en       (wr_en),
        .rd_en       (rd_en),
        .full        (full),
        .empty       (empty)
    );
endmodule
