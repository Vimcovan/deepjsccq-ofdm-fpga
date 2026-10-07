`timescale 1ns / 1ps
// Decoder PHY interface: accept one {Q[11:0], I[11:0]} symbol per beat and
// emit its I then Q elements in NHWC order. No burst FIFO is present here;
// valid/ready backpressure is the network/PHY contract.
module rx_frame #(
    parameter int X_W = 12,
    parameter int H   = 64,
    parameter int W   = 64,
    parameter int C   = 16
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic [23:0]             s_tdata,
    input  logic                    s_tvalid,
    output logic                    s_tready,
    input  logic                    s_tlast,
    input  logic [0:0]              s_tuser,
    output logic signed [X_W-1:0]   m_tdata,
    output logic                    m_tvalid,
    input  logic                    m_tready,
    output logic                    m_tlast,
    output logic [0:0]              m_tuser
);
    initial assert (C % 2 == 0)
        else $fatal(1, "rx_frame: channel count must be even");

    logic [23:0] sym_reg;
    logic        sym_valid;
    logic        phase;                 // 0 = I, 1 = Q
    logic [$clog2(C)-1:0] ch;
    logic [$clog2(H*W)-1:0] pix;
    logic        sym_last, sym_user;
    wire         out_fire = m_tvalid && m_tready;

    // A single symbol register provides the required two element beats.
    assign s_tready = rst_n && !sym_valid;
    assign m_tvalid = sym_valid;
    assign m_tdata  = phase ? $signed(sym_reg[23:12]) : $signed(sym_reg[11:0]);
    assign m_tlast  = sym_valid && phase && (int'(ch) == C - 1);
    assign m_tuser  = m_tlast && (int'(pix) == H * W - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sym_reg   <= '0;
            sym_valid <= 1'b0;
            phase     <= 1'b0;
            ch        <= '0;
            pix       <= '0;
            sym_last  <= 1'b0;
            sym_user  <= 1'b0;
        end else begin
            if (!sym_valid && s_tvalid && s_tready) begin
                sym_reg   <= s_tdata;
                sym_valid <= 1'b1;
                phase     <= 1'b0;
                sym_last  <= s_tlast;
                sym_user  <= s_tuser[0];
            end else if (out_fire) begin
                if (!phase) begin
                    phase <= 1'b1;
                    ch    <= ch + 1'b1;
                end else begin
                    phase <= 1'b0;
                    sym_valid <= 1'b0;
                    if (int'(ch) == C - 1) begin
                        ch  <= '0;
                        pix <= sym_user ? '0 : pix + 1'b1;
                    end else begin
                        ch <= ch + 1'b1;
                    end
                end
            end
        end
    end
endmodule



