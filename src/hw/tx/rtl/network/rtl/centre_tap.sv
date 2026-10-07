`timescale 1ns / 1ps
// Centre-tap snoop: turns the KxK window stream of a host conv (axis_line_buffer output,
// passes of K*K*CIN beats in (ky, kx, ci) order) into the K=1 stream of a 1x1 skip conv
// with the same stride: only the CIN beats of the centre tap (ky = kx = PAD) are kept.
// Of the GH host passes per output pixel only the first GS are forwarded (GS = number of
// passes of the skip engine); the flags are rewritten for the 1x1 view:
//   tuser[0] first beat of a pass, tlast last beat, tuser[1] last forwarded pass,
//   tuser[2] last pixel of the frame (copied).
// Beats that are not forwarded are consumed without waiting for m_tready.
module centre_tap #(
    parameter int DATA_W = 12,
    parameter int CIN    = 3,
    parameter int K      = 3,
    parameter int PAD    = 1,
    parameter int GH     = 11,                  // host passes per output pixel
    parameter int GS     = 11                   // passes forwarded to the skip engine (<= GH)
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic [DATA_W-1:0] s_tdata,
    input  logic              s_tvalid,
    output logic              s_tready,
    input  logic              s_tlast,
    input  logic [2:0]        s_tuser,
    output logic [DATA_W-1:0] m_tdata,
    output logic              m_tvalid,
    input  logic              m_tready,
    output logic              m_tlast,
    output logic [2:0]        m_tuser
);
    localparam int KKC = K * K * CIN;
    localparam int CT0 = (PAD * K + PAD) * CIN;             // first beat of the centre tap

    logic [$clog2(KKC + 1)-1:0] e;                          // beat index inside the pass
    logic [$clog2(GH + 1)-1:0]  g;                          // pass index inside the pixel
    wire  keep = (int'(e) >= CT0) && (int'(e) < CT0 + CIN) && (int'(g) < GS);

    assign m_tdata   = s_tdata;
    assign m_tvalid  = s_tvalid && keep;
    assign m_tlast   = (int'(e) == CT0 + CIN - 1);
    assign m_tuser   = {s_tuser[2], int'(g) == GS - 1, int'(e) == CT0};
    assign s_tready  = keep ? m_tready : 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e <= '0; g <= '0;
        end else if (s_tvalid && s_tready) begin
            if (s_tlast) begin
                e <= '0;
                g <= s_tuser[1] ? '0 : g + 1'b1;            // host tuser[1]: last pass of the pixel
            end else begin
                e <= e + 1'b1;
            end
        end
    end
endmodule
