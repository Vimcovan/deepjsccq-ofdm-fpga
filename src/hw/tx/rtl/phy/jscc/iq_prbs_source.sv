`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// iq_prbs_source: stand-in for the DeepJSCC encoder (board test without the network). Emits FRAME_SYMS
//   Gray-mapped 64-QAM symbols per frame in the encoder's format (PHY_INTERFACE.md): tdata = {Q[11:0], I[11:0]}
//   Q10, levels 158*(2k-7) = +-158..+-1106, tlast = tuser[0] on the last symbol.
//   Bits: PRBS-15 (x^15+x^14+1, seed all ones), restarted every frame, 6 bits per symbol:
//   b0 b1 b2 -> I, b3 b4 b5 -> Q, k = Gray^-1(b_msb..b_lsb). rx_iq_checker regenerates the same sequence.
//////////////////////////////////////////////////////////////////////////////////
module iq_prbs_source #(
    parameter int FRAME_SYMS = 32768
)(
    input  logic        clk,
    input  logic        rst_n,
    output logic [23:0] m_tdata,
    output logic        m_tlast,
    output logic        m_tuser,
    output logic        m_tvalid,
    input  logic        m_tready
);
    logic [14:0] st;
    logic [$clog2(FRAME_SYMS)-1:0] cnt;
    logic [5:0]  b;
    logic [14:0] st_n;
    always_comb begin
        st_n = st;
        for (int k = 0; k < 6; k++) begin
            b[k] = st_n[14] ^ st_n[13];
            st_n = {st_n[13:0], b[k]};
        end
    end
    function automatic logic [11:0] lvl(input logic [2:0] g);      // g = {b_msb, b_mid, b_lsb} (Gray)
        logic [2:0] k;
        k[2] = g[2]; k[1] = g[2] ^ g[1]; k[0] = g[2] ^ g[1] ^ g[0];
        return 12'($signed({1'b0, k, 1'b0}) - 7) * 12'sd158;         // 158*(2k-7)
    endfunction
    assign m_tdata  = {lvl({b[3], b[4], b[5]}), lvl({b[0], b[1], b[2]})};
    assign m_tlast  = (cnt == FRAME_SYMS-1);
    assign m_tuser  = m_tlast;
    assign m_tvalid = rst_n;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st <= '1; cnt <= '0; end
        else if (m_tvalid & m_tready) begin
            if (m_tlast) begin st <= '1; cnt <= '0; end
            else begin st <= st_n; cnt <= cnt + 1'b1; end
        end
    end
endmodule
