`timescale 1ns / 1ps
// Pixel buffer for 1x1 convolutions (replaces axis_line_buffer with K = 1, which would keep
// a whole row): two pixel slots in LUTRAM (ping-pong); each stored pixel is replayed GROUPS
// times (one pass per output-channel group of the conv engine) while the next pixel is written.
// Output side band is the same as axis_line_buffer:
//   m_out_tlast    : last element of a pass
//   m_out_tuser[0] : first element of a pass
//   m_out_tuser[1] : pass of the last group of this pixel
//   m_out_tuser[2] : pixel is the last one of the frame
module axis_pixel_buffer #(
    parameter int DATA_W = 12,
    parameter int C      = 32,             // channels
    parameter int NPIX   = 4096,           // pixels per frame
    parameter int GROUPS = 1
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic [DATA_W-1:0] s_in_tdata,
    input  logic              s_in_tvalid,
    output logic              s_in_tready,
    output logic [DATA_W-1:0] m_out_tdata,
    output logic              m_out_tvalid,
    input  logic              m_out_tready,
    output logic              m_out_tlast,
    output logic [2:0]        m_out_tuser
);
    function automatic int clog2m1(input int v);
        return (v <= 2) ? 1 : $clog2(v);
    endfunction
    localparam int CW = clog2m1(C);
    localparam int GW = clog2m1(GROUPS);
    localparam int PW = clog2m1(NPIX);

    (* ram_style = "distributed" *) logic [DATA_W-1:0] mem [2 << CW];
    logic [1:0]    full, flast;
    logic          wslot, rslot;
    logic [CW-1:0] wc, rc;
    logic [GW-1:0] rg;
    logic [PW-1:0] wpix;

    wire w_fire = s_in_tvalid && s_in_tready;
    wire r_fire = m_out_tvalid && m_out_tready;
    wire w_end  = w_fire && (int'(wc) == C - 1);
    wire r_end  = r_fire && (int'(rc) == C - 1) && (int'(rg) == GROUPS - 1);
    assign s_in_tready  = rst_n && !full[wslot];
    assign m_out_tvalid = full[rslot];
    assign m_out_tdata  = mem[{rslot, rc}];
    assign m_out_tlast  = (int'(rc) == C - 1);
    assign m_out_tuser  = {flast[rslot], int'(rg) == GROUPS - 1, rc == '0};

    always_ff @(posedge clk) if (w_fire) mem[{wslot, wc}] <= s_in_tdata;
    always_ff @(posedge clk) if (w_end) flast[wslot] <= (int'(wpix) == NPIX - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            full <= 2'b00; wslot <= 1'b0; rslot <= 1'b0; wc <= '0; rc <= '0; rg <= '0; wpix <= '0;
        end else begin
            if (w_fire) begin
                wc <= (int'(wc) == C - 1) ? '0 : wc + 1'b1;
                if (w_end) begin
                    wslot <= ~wslot;
                    wpix  <= (int'(wpix) == NPIX - 1) ? '0 : wpix + 1'b1;
                end
            end
            if (r_fire) begin
                if (int'(rc) == C - 1) begin
                    rc <= '0;
                    rg <= (int'(rg) == GROUPS - 1) ? '0 : rg + 1'b1;
                end else rc <= rc + 1'b1;
                if (r_end) rslot <= ~rslot;
            end
            for (int s = 0; s < 2; s++) begin
                if (w_end && wslot == 1'(s))      full[s] <= 1'b1;
                else if (r_end && rslot == 1'(s)) full[s] <= 1'b0;
            end
        end
    end
endmodule
