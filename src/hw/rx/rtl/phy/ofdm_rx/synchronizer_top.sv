`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/26 09:10:49
// Design Name: 
// Module Name: synchronizer_top
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


module synchronizer_top#(
    parameter NSYM = 20         // data OFDM symbols per frame (FFT window back-off: see time_sync / coe/ltf_cplx_bo8.coe)
)
(
    input logic clk,
    input logic rst_n,
    input logic[23:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[23:0] m_out_tdata,
    output logic m_out_tvalid,
    output logic m_out_tlast,
    input logic m_out_tready
    );
    logic[23:0] fd_odata;
    logic fd_ovalid;
    logic fd_oready;
    frame_detection # (.SYMBOL_PER_FRAME(NSYM)) frame_detection_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(s_in_tdata),
        .s_in_tvalid(s_in_tvalid),
        .s_in_tready(s_in_tready),
        .m_out_tdata(fd_odata),
        .m_out_tvalid(fd_ovalid),
        .m_out_tready(fd_oready)
    );
    logic[23:0] ts_odata;
    logic ts_ovalid;
    logic ts_oready;
    logic ts_olast;
    time_sync # (.SYMBOL_PER_FRAME(NSYM)) time_sync_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(fd_odata),
        .s_in_tvalid(fd_ovalid),
        .s_in_tready(fd_oready),
        .m_out_tdata(ts_odata),
        .m_out_tvalid(ts_ovalid),
        .m_out_tlast(ts_olast),
        .m_out_tready(ts_oready)
    );
    cp_remover  cp_remover_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(ts_odata),
        .s_in_tlast(ts_olast),
        .s_in_tvalid(ts_ovalid),
        .s_in_tready(ts_oready),
        .m_out_tdata(m_out_tdata),
        .m_out_tlast(m_out_tlast),
        .m_out_tvalid(m_out_tvalid),
        .m_out_tready(m_out_tready)
    );
endmodule
