`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// iq_pn_scrambler: sign flip of I and Q by a PN sequence (PAPR: the DeepJSCC symbols are correlated along
//   the NHWC order, which raises the OFDM PAPR by ~1-2 dB; independent sign flips decorrelate them).
//   802.11 scrambler LFSR x^7+x^4+1, seed 7'b1011101, two LFSR steps per symbol: 1st bit -> I, 2nd -> Q
//   (bit 1 = negate). Restarts every FRAME_SYMS symbols (TX and RX use the same module -> self-inverse).
//   Pure AXI-Stream pass-through (combinational data path), no multipliers.
//////////////////////////////////////////////////////////////////////////////////
module iq_pn_scrambler #(
    parameter int FRAME_SYMS = 32768
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] s_tdata,        // {Q[11:0], I[11:0]}
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [23:0] m_tdata,
    output logic        m_tvalid,
    input  logic        m_tready
);
    localparam logic [6:0] SEED = 7'b1011101;
    logic [6:0] st;
    logic [$clog2(FRAME_SYMS)-1:0] cnt;
    wire fb1 = st[6] ^ st[3];                 // bit for I
    wire fb2 = st[5] ^ st[2];                 // bit for Q (= next step)
    wire fire = s_tvalid & m_tready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st <= SEED; cnt <= '0; end
        else if (fire) begin
            if (cnt == FRAME_SYMS-1) begin cnt <= '0; st <= SEED; end
            else begin cnt <= cnt + 1'b1; st <= {st[4:0], fb1, fb2}; end
        end
    end
    function automatic logic [11:0] neg_sat(input logic [11:0] x);
        return (x == 12'h800) ? 12'h7FF : 12'(-$signed(x));
    endfunction
    wire [11:0] di = s_tdata[11:0], dq = s_tdata[23:12];
    assign m_tdata  = {fb2 ? neg_sat(dq) : dq, fb1 ? neg_sat(di) : di};
    assign m_tvalid = s_tvalid;
    assign s_tready = m_tready;
endmodule
