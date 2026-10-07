`timescale 1ns / 1ps
// Channel split of an NHWC stream (merged engine output): channels [0, SPLIT) go to m0,
// channels [SPLIT, C) to m1.  Side band of each output is regenerated for its own channel
// range: tlast = last channel of the pixel, tuser[0] = last beat of the frame.
module axis_split #(
    parameter int DATA_W = 12,
    parameter int C      = 32,
    parameter int SPLIT  = 16,
    parameter int NPIX   = 4096
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic [DATA_W-1:0] s_tdata,
    input  logic              s_tvalid,
    output logic              s_tready,
    output logic [DATA_W-1:0] m0_tdata,
    output logic              m0_tvalid,
    input  logic              m0_tready,
    output logic              m0_tlast,
    output logic [0:0]        m0_tuser,
    output logic [DATA_W-1:0] m1_tdata,
    output logic              m1_tvalid,
    input  logic              m1_tready,
    output logic              m1_tlast,
    output logic [0:0]        m1_tuser
);
    function automatic int clog2m1(input int v);
        return (v <= 2) ? 1 : $clog2(v);
    endfunction
    logic [clog2m1(C)-1:0]    ch;
    logic [clog2m1(NPIX)-1:0] pix;
    wire  lo       = (int'(ch) < SPLIT);
    wire  lastpix  = (int'(pix) == NPIX - 1);

    assign m0_tdata  = s_tdata;
    assign m1_tdata  = s_tdata;
    assign m0_tvalid = s_tvalid && lo;
    assign m1_tvalid = s_tvalid && !lo;
    assign m0_tlast  = (int'(ch) == SPLIT - 1);
    assign m1_tlast  = (int'(ch) == C - 1);
    assign m0_tuser  = m0_tlast && lastpix;
    assign m1_tuser  = m1_tlast && lastpix;
    assign s_tready  = lo ? m0_tready : m1_tready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch <= '0; pix <= '0;
        end else if (s_tvalid && s_tready) begin
            if (int'(ch) == C - 1) begin
                ch  <= '0;
                pix <= lastpix ? '0 : pix + 1'b1;
            end else ch <= ch + 1'b1;
        end
    end
endmodule
