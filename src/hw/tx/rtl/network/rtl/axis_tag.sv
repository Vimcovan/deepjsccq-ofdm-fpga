`timescale 1ns / 1ps
// Adds NHWC side band to a plain element stream: tlast = last channel of a pixel,
// tuser[0] = last beat of the frame.  Pure counters, the handshake passes through.
module axis_tag #(
    parameter int C    = 32,
    parameter int NPIX = 4096
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       valid,
    input  logic       ready,
    output logic       tlast,
    output logic [0:0] tuser
);
    function automatic int clog2m1(input int v);
        return (v <= 2) ? 1 : $clog2(v);
    endfunction
    logic [clog2m1(C)-1:0]    ch;
    logic [clog2m1(NPIX)-1:0] pix;
    assign tlast = (int'(ch) == C - 1);
    assign tuser = tlast && (int'(pix) == NPIX - 1);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch <= '0; pix <= '0;
        end else if (valid && ready) begin
            if (tlast) begin
                ch  <= '0;
                pix <= tuser ? '0 : pix + 1'b1;
            end else ch <= ch + 1'b1;
        end
    end
endmodule
