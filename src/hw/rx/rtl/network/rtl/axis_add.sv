`timescale 1ns / 1ps
// Residual add of two int streams in the same NHWC order:
//     y = satY( rsr(a*MA + b*MB, SH) ),  optional ReLU after the shift
// MA, MB, SH are per-layer constants, so both products are constant multipliers built
// from LUTs (no DSP).  Side band (tlast/tuser) is taken from input a.
// The pipeline stalls as a whole when the output is not ready.
module axis_add #(
    parameter int A_W  = 12,
    parameter int Y_W  = 12,
    parameter int MA   = 65536,
    parameter int MB   = 65536,
    parameter int SH   = 16,
    parameter bit RELU = 1'b0,
    parameter int U_W  = 1                       // tuser width
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic signed [A_W-1:0] a_tdata,
    input  logic                  a_tvalid,
    output logic                  a_tready,
    input  logic                  a_tlast,
    input  logic [U_W-1:0]        a_tuser,
    input  logic signed [A_W-1:0] b_tdata,
    input  logic                  b_tvalid,
    output logic                  b_tready,
    output logic signed [Y_W-1:0] m_tdata,
    output logic                  m_tvalid,
    input  logic                  m_tready,
    output logic                  m_tlast,
    output logic [U_W-1:0]        m_tuser
);
    localparam int PW = A_W + 18;                // product width (constants < 2^17)

    // 3-stage pipeline, one global enable
    logic                 v1, v2;
    logic                 l1, l2;
    logic [U_W-1:0]       u1, u2;
    (* use_dsp = "no" *) logic signed [PW-1:0] pa1, pb1;
    logic signed [PW:0]   s2;
    wire  ce   = !m_tvalid || m_tready;
    wire  fire = ce && a_tvalid && b_tvalid;
    assign a_tready = fire;
    assign b_tready = fire;

    function automatic logic signed [63:0] rsr(input logic signed [63:0] v, input int k);
        if (k > 0)       return (v + (64'sd1 <<< (k - 1))) >>> k;
        else if (k == 0) return v;
        else             return v <<< (-k);
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; v2 <= 1'b0; m_tvalid <= 1'b0;
        end else if (ce) begin
            v1 <= fire; v2 <= v1; m_tvalid <= v2;
        end
    end

    always_ff @(posedge clk) begin
        if (ce) begin
            pa1 <= a_tdata * PW'(MA);
            pb1 <= b_tdata * PW'(MB);
            l1  <= a_tlast; u1 <= a_tuser;
            s2  <= pa1 + pb1;
            l2  <= l1; u2 <= u1;
            begin
                logic signed [63:0] y;
                y = rsr(64'(s2), SH);
                if (RELU && y < 0) y = 0;
                if (y > (64'sd1 <<< (Y_W - 1)) - 1) y = (64'sd1 <<< (Y_W - 1)) - 1;
                if (y < -(64'sd1 <<< (Y_W - 1)))    y = -(64'sd1 <<< (Y_W - 1));
                m_tdata <= Y_W'(y);
            end
            m_tlast <= l2; m_tuser <= u2;
        end
    end
endmodule
