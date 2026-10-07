`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// frame_src_mux (250 MHz): 2:1 AXI-Stream mux of whole frames: the select input (async, from the register
//   block) is only taken at a frame boundary (after a beat with tlast), so a frame is never mixed from two
//   sources. The unselected source is back-pressured. sel = 0: encoder, 1: PRBS 64-QAM self test.
//////////////////////////////////////////////////////////////////////////////////
module frame_src_mux #(
    parameter int W = 24
)(
    input  logic         clk,
    input  logic         rst_n,
    input  logic         sel_async,
    input  logic [W-1:0] s0_tdata, input logic s0_tlast, input logic s0_tuser, input logic s0_tvalid, output logic s0_tready,
    input  logic [W-1:0] s1_tdata, input logic s1_tlast, input logic s1_tuser, input logic s1_tvalid, output logic s1_tready,
    output logic [W-1:0] m_tdata,  output logic m_tlast,  output logic m_tuser,  output logic m_tvalid,  input  logic m_tready,
    output logic         sel_active
);
    (* ASYNC_REG = "TRUE" *) logic [1:0] sel_s;
    logic at_bound;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sel_s <= '0; at_bound <= 1'b1; sel_active <= 1'b0; end
        else begin
            sel_s <= {sel_s[0], sel_async};
            // switch only between frames and never in the cycle in which a frame's first beat is taken
            if (at_bound && !(m_tvalid & m_tready)) sel_active <= sel_s[1];
            if (m_tvalid & m_tready) at_bound <= m_tlast;
        end
    end
    assign m_tdata   = sel_active ? s1_tdata  : s0_tdata;
    assign m_tlast   = sel_active ? s1_tlast  : s0_tlast;
    assign m_tuser   = sel_active ? s1_tuser  : s0_tuser;
    assign m_tvalid  = sel_active ? s1_tvalid : s0_tvalid;
    assign s0_tready = ~sel_active & m_tready;
    assign s1_tready =  sel_active & m_tready;
endmodule
