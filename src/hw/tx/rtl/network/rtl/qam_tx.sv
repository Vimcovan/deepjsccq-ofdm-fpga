`timescale 1ns / 1ps
// Encoder PHY interface: pair adjacent NHWC latent elements into one 64-QAM symbol.
// The first element of a pair is I and the second is Q. The output is one
// {Q[11:0], I[11:0]} word per beat; the PHY owns any burst buffering.
module qam_tx #(
    parameter int X_W = 12,
    parameter int C   = 16,
    parameter int T0 = -343, T1 = -229, T2 = -115, T3 = 0,
    parameter int T4 = 114, T5 = 228, T6 = 342
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic signed [X_W-1:0]   s_tdata,
    input  logic                    s_tvalid,
    output logic                    s_tready,
    input  logic                    s_tlast,
    input  logic [0:0]              s_tuser,
    output logic [23:0]             m_tdata,
    output logic                    m_tvalid,
    input  logic                    m_tready,
    output logic                    m_tlast,
    output logic [0:0]              m_tuser
);
    initial assert (C % 2 == 0)
        else $fatal(1, "qam_tx: channel count must be even");

    function automatic logic [2:0] level(input logic signed [X_W-1:0] x);
        level = 3'(int'(x > X_W'(T0)) + int'(x > X_W'(T1)) +
                   int'(x > X_W'(T2)) + int'(x > X_W'(T3)) +
                   int'(x > X_W'(T4)) + int'(x > X_W'(T5)) +
                   int'(x > X_W'(T6)));
    endfunction

    function automatic logic signed [11:0] level_q10(input logic [2:0] l);
        case (l)
            3'd0: level_q10 = -12'sd1106;
            3'd1: level_q10 = -12'sd790;
            3'd2: level_q10 = -12'sd474;
            3'd3: level_q10 = -12'sd158;
            3'd4: level_q10 =  12'sd158;
            3'd5: level_q10 =  12'sd474;
            3'd6: level_q10 =  12'sd790;
            default: level_q10 = 12'sd1106;
        endcase
    endfunction

    logic                    have_i;
    logic signed [X_W-1:0]   i_reg;
    logic [23:0]             out_data;
    logic                    out_valid, out_last;
    logic [0:0]              out_user;
    wire                     out_fire = out_valid && m_tready;
    // One saved I element and one output symbol are sufficient. The Q beat is
    // accepted only when the output register can accept the completed symbol.
    assign s_tready = rst_n && (!have_i || !out_valid || m_tready);
    wire in_fire = s_tvalid && s_tready;

    assign m_tdata  = out_data;
    assign m_tvalid = out_valid;
    assign m_tlast  = out_last;
    assign m_tuser  = out_user;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            have_i    <= 1'b0;
            i_reg     <= '0;
            out_data  <= '0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;
            out_user  <= '0;
        end else begin
            if (out_fire) out_valid <= 1'b0;
            if (in_fire) begin
                if (!have_i) begin
                    i_reg  <= s_tdata;
                    have_i <= 1'b1;
                end else begin
                    // s_tdata is Q; the frame marker is attached to the final
                    // symbol by the input axis_tag (s_tuser on the Q beat).
                    out_data  <= {level_q10(level(s_tdata)), level_q10(level(i_reg))};
                    out_last  <= s_tuser[0];
                    out_user  <= s_tuser;
                    out_valid <= 1'b1;
                    have_i    <= 1'b0;
                end
            end
        end
    end
endmodule


