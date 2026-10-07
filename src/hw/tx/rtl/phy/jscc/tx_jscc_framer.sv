`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tx_jscc_framer: DeepJSCC IQ symbols -> OFDM data subcarrier stream of one PHY frame.
//   FRAME_SYMS symbols (PN sign scrambled) followed by PAD zero symbols, so that the frame fills
//   NSYM OFDM symbols x 48 data subcarriers (32768 + 16 = 683 x 48). Framing is by count; s_tlast is
//   only checked (tlast_err pulses when it does not come with the last symbol of a frame).
//////////////////////////////////////////////////////////////////////////////////
module tx_jscc_framer #(
    parameter int FRAME_SYMS = 32768,
    parameter int PAD        = 16
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] s_tdata,
    input  logic        s_tlast,
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [23:0] m_tdata,
    output logic        m_tvalid,
    input  logic        m_tready,
    output logic        tlast_err
);
    logic [23:0] pn_d; logic pn_v, pn_r;
    logic [$clog2(FRAME_SYMS+PAD)-1:0] cnt;
    wire in_pad = (cnt >= FRAME_SYMS);
    iq_pn_scrambler #(.FRAME_SYMS(FRAME_SYMS)) u_pn (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid & ~in_pad), .s_tready(pn_r),
        .m_tdata(pn_d), .m_tvalid(pn_v), .m_tready(m_tready & ~in_pad));
    assign s_tready = pn_r & ~in_pad;
    assign m_tdata  = in_pad ? 24'd0 : pn_d;
    assign m_tvalid = in_pad ? 1'b1  : pn_v;
    wire fire = m_tvalid & m_tready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cnt <= '0; tlast_err <= 1'b0; end
        else begin
            tlast_err <= s_tvalid & s_tready & (s_tlast != (cnt == FRAME_SYMS-1));
            if (fire) cnt <= (cnt == FRAME_SYMS+PAD-1) ? '0 : cnt + 1'b1;
        end
    end
endmodule
