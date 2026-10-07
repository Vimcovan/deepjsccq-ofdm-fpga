`timescale 1ns / 1ps
// AXI-Stream fork 1 -> N with independent backpressure: the input beat is released only
// after every output has taken it (outputs may accept it in different cycles).
module axis_fork #(
    parameter int W = 16,                       // payload width (data + side band)
    parameter int N = 2
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic [W-1:0] s_tdata,
    input  logic         s_tvalid,
    output logic         s_tready,
    output logic [W-1:0] m_tdata,               // shared by all outputs
    output logic [N-1:0] m_tvalid,
    input  logic [N-1:0] m_tready
);
    logic [N-1:0] done;                         // output already took the current beat
    assign m_tdata  = s_tdata;
    assign m_tvalid = {N{s_tvalid}} & ~done;
    assign s_tready = &(done | m_tready);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        done <= '0;
        else if (s_tvalid) done <= s_tready ? '0 : (done | (m_tvalid & m_tready));
    end
endmodule
