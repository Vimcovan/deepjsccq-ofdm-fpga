`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/26 09:13:14
// Design Name: 
// Module Name: rx_baseband_top
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


module rx_baseband_top#(
    parameter NSYM = 683,       // data OFDM symbols per frame (must match OFDM_TX)
    parameter FRAME_SYMS = 32768 // DeepJSCC symbols per frame (the last NSYM*48-FRAME_SYMS are padding)
    // FFT window back-off (8 samples into the CP, margin for SFO drift) is set by the LTF correlator
    // coefficients coe/ltf_cplx_bo8.coe (see time_sync)
)
(
    input logic clk,
    input logic rst_n,
    input logic[23:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    // DeepJSCC IQ frame (PHY_INTERFACE.md): {Q[11:0], I[11:0]} Q10, tlast = tuser on symbol FRAME_SYMS-1
    output logic[23:0] m_out_tdata,
    output logic m_out_tlast,
    output logic m_out_tuser,
    output logic m_out_tvalid,
    input logic m_out_tready,
    // read-only debug taps (telemetry), see equalizer_top
    output logic[23:0] dbg_pre_data,
    output logic       dbg_pre_fire,
    output logic[23:0] dbg_ce_data,
    output logic       dbg_ce_fire,
    output logic[23:0] dbg_cpe_data,
    output logic       dbg_cpe_fire,
    output logic[23:0] dbg_sfo_data,
    output logic       dbg_sfo_fire
    );
    logic[23:0] sync_odata;
    logic sync_ovalid;
    logic sync_olast;
    logic sync_oready;
    synchronizer_top # (.NSYM(NSYM)) synchronizer_top_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(s_in_tdata),
        .s_in_tvalid(s_in_tvalid),
        .s_in_tready(s_in_tready),
        .m_out_tdata(sync_odata),
        .m_out_tvalid(sync_ovalid),
        .m_out_tready(sync_oready),
        .m_out_tlast(sync_olast)
    );
    logic[23:0] equal_odata;
    logic equal_ovald;
    logic equal_oready;
    equalizer_top # (.NSYM(NSYM)) equalizer_top_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(sync_odata),
        .s_in_tvalid(sync_ovalid),
        .s_in_tready(sync_oready),
        .m_out_tdata(equal_odata),
        .m_out_tvalid(equal_ovald),
        .m_out_tready(equal_oready),
        .dbg_pre_data(dbg_pre_data), .dbg_pre_fire(dbg_pre_fire),
        .dbg_ce_data (dbg_ce_data),  .dbg_ce_fire (dbg_ce_fire),
        .dbg_cpe_data(dbg_cpe_data), .dbg_cpe_fire(dbg_cpe_fire),
        .dbg_sfo_data(dbg_sfo_data), .dbg_sfo_fire(dbg_sfo_fire)
    );
    // JSCC version: no bit decoding; drop the padding, undo the PN sign scrambling, frame the IQ symbols
    rx_jscc_framer # (.FRAME_SYMS(FRAME_SYMS), .PAD(NSYM*48-FRAME_SYMS)) u_jscc_framer (
        .clk(clk),
        .rst_n(rst_n),
        .s_tdata(equal_odata),
        .s_tvalid(equal_ovald),
        .s_tready(equal_oready),
        .m_tdata(m_out_tdata),
        .m_tlast(m_out_tlast),
        .m_tuser(m_out_tuser),
        .m_tvalid(m_out_tvalid),
        .m_tready(m_out_tready)
    );
endmodule
