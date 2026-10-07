`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// rx_jscc_framer: equalizer output (48 data subcarriers per OFDM symbol, FRAME_SYMS+PAD per frame, framing
//   by count exactly like the rest of the RX chain) -> DeepJSCC IQ frame: the PAD zero symbols are dropped,
//   the PN sign scrambling is removed, tlast and tuser[0] are set on the last symbol of the frame
//   (PHY_INTERFACE.md). Output is not meant to be back-pressured (it feeds uram_frame_fifo in drop mode),
//   but valid/ready is honoured.
//////////////////////////////////////////////////////////////////////////////////
module rx_jscc_framer #(
    parameter int FRAME_SYMS = 32768,
    parameter int PAD        = 16
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] s_tdata,
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [23:0] m_tdata,
    output logic        m_tlast,
    output logic        m_tuser,
    output logic        m_tvalid,
    input  logic        m_tready
);
    logic [$clog2(FRAME_SYMS+PAD)-1:0] cnt;
    wire in_pad = (cnt >= FRAME_SYMS);
    logic pn_r;
    iq_pn_scrambler #(.FRAME_SYMS(FRAME_SYMS)) u_pn (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid & ~in_pad), .s_tready(pn_r),
        .m_tdata(m_tdata), .m_tvalid(), .m_tready(m_tready & ~in_pad));
    assign m_tvalid = s_tvalid & ~in_pad;
    assign s_tready = in_pad ? 1'b1 : m_tready;
    assign m_tlast  = (cnt == FRAME_SYMS-1);
    assign m_tuser  = m_tlast;
    wire fire = s_tvalid & s_tready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt <= '0;
        else if (fire) cnt <= (cnt == FRAME_SYMS+PAD-1) ? '0 : cnt + 1'b1;
    end
endmodule
