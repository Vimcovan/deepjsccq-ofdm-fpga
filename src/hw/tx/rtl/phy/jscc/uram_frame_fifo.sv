`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// uram_frame_fifo: frame buffer in UltraRAM, 3 x 24-bit samples packed per 72-bit word (FRAME_LEN samples per
//   frame, framing by count; the last word of a frame may be partial when FRAME_LEN % 3 != 0).
//   PACKET_MODE = 1 (TX, in front of the DAC): input back-pressured when full; a frame is only released when it
//                  is complete in the buffer, so the 20 MSPS reader never underruns inside a frame.
//   PACKET_MODE = 0 (RX, PHY -> decoder): input never back-pressured (the PHY runs at line rate); at the first
//                  sample of a frame the whole frame is accepted only if it fits, otherwise the whole frame is
//                  dropped (dropped_frames++). Output is cut-through.
//   Single clock (URAM). Read latency 2 + a 2-word prefetch queue; output m_tlast/m_tuser on the last sample.
//////////////////////////////////////////////////////////////////////////////////
module uram_frame_fifo #(
    parameter int FRAME_LEN   = 32768,
    parameter int DEPTH_WORDS = 24576,      // 6 x URAM288 (4K x 72)
    parameter bit PACKET_MODE = 0
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] s_tdata,
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [23:0] m_tdata,
    output logic        m_tlast,
    output logic        m_tuser,
    output logic        m_tvalid,
    input  logic        m_tready,
    output logic [31:0] frames_in,
    output logic [31:0] dropped_frames
);
    localparam int W  = (FRAME_LEN + 2) / 3;          // words per frame
    localparam int AW = $clog2(DEPTH_WORDS);
    localparam int CW = $clog2(DEPTH_WORDS + 1);
    localparam int FW = $clog2(FRAME_LEN);
    initial assert (DEPTH_WORDS >= W) else $fatal(1, "uram_frame_fifo: buffer smaller than one frame");

    (* ram_style = "ultra" *) logic [71:0] mem [0:DEPTH_WORDS-1];

    logic [CW-1:0] used;       // words written and not yet read out of the RAM
    logic [CW-1:0] avail;      // words written and not yet issued for reading
    logic          we, issue;

    //---------------------------------------------------------------- write side
    logic [FW-1:0] in_cnt;
    logic [1:0]    widx;
    logic [47:0]   wacc;
    logic          keep;
    logic [AW-1:0] wptr;
    wire first   = (in_cnt == 0);
    wire last_in = (in_cnt == FRAME_LEN-1);
    wire fits    = (DEPTH_WORDS - used) >= W;
    wire keep_now = PACKET_MODE ? 1'b1 : (first ? fits : keep);
    assign s_tready = PACKET_MODE ? (used != DEPTH_WORDS) : 1'b1;
    wire fire_in = s_tvalid & s_tready;
    assign we = fire_in & keep_now & ((widx == 2) | last_in);
    wire [71:0] wd = (widx == 0) ? {48'd0, s_tdata} :
                     (widx == 1) ? {24'd0, s_tdata, wacc[23:0]} : {s_tdata, wacc[47:0]};
    always_ff @(posedge clk) if (we) mem[wptr] <= wd;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_cnt <= '0; widx <= '0; wacc <= '0; keep <= 1'b0; wptr <= '0; frames_in <= '0; dropped_frames <= '0;
        end
        else if (fire_in) begin
            in_cnt <= last_in ? '0 : in_cnt + 1'b1;
            if (first) begin
                keep <= keep_now; frames_in <= frames_in + 1'b1;
                if (!keep_now) dropped_frames <= dropped_frames + 1'b1;
            end
            if (keep_now) begin
                if (widx == 0) wacc[23:0]  <= s_tdata;
                if (widx == 1) wacc[47:24] <= s_tdata;
                widx <= ((widx == 2) | last_in) ? 2'd0 : widx + 1'b1;
            end
            if (we) wptr <= (wptr == DEPTH_WORDS-1) ? '0 : wptr + 1'b1;
        end
    end

    //---------------------------------------------------------------- read side
    logic [AW-1:0] rptr;
    logic [71:0]   rd1, rd2;
    logic          v1, v2;
    logic [71:0]   q0, q1;             // prefetch queue (q0 = head)
    logic [1:0]    qn;                 // entries in the queue
    logic [1:0]    oidx;
    logic [FW-1:0] out_cnt;
    logic [15:0]   frames_rdy;         // complete frames in the buffer not yet started/finished at the output
    wire inflight = v1 + v2;
    assign issue = (avail != 0) && ((qn + v1 + v2) < 2);
    always_ff @(posedge clk) if (issue) rd1 <= mem[rptr];
    always_ff @(posedge clk) rd2 <= rd1;

    wire out_last = (out_cnt == FRAME_LEN-1);
    wire gate     = PACKET_MODE ? ((out_cnt != 0) || (frames_rdy != 0)) : 1'b1;
    assign m_tvalid = (qn != 0) && gate;
    assign m_tdata  = (oidx == 0) ? q0[23:0] : (oidx == 1) ? q0[47:24] : q0[71:48];
    assign m_tlast  = out_last;
    assign m_tuser  = out_last;
    wire fire_out = m_tvalid & m_tready;
    wire pop      = fire_out & ((oidx == 2) | out_last);
    wire push     = v2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rptr <= '0; v1 <= 1'b0; v2 <= 1'b0; qn <= '0; q0 <= '0; q1 <= '0; oidx <= '0; out_cnt <= '0;
            frames_rdy <= '0; used <= '0; avail <= '0;
        end
        else begin
            v1 <= issue; v2 <= v1;
            if (issue) rptr <= (rptr == DEPTH_WORDS-1) ? '0 : rptr + 1'b1;
            // prefetch queue
            case ({push, pop})
                2'b10: begin if (qn == 0) q0 <= rd2; else q1 <= rd2; qn <= qn + 1'b1; end
                2'b01: begin q0 <= q1; qn <= qn - 1'b1; end
                2'b11: begin if (qn == 1) q0 <= rd2; else begin q0 <= q1; q1 <= rd2; end end
                default: ;
            endcase
            if (fire_out) begin
                out_cnt <= out_last ? '0 : out_cnt + 1'b1;
                oidx    <= ((oidx == 2) | out_last) ? 2'd0 : oidx + 1'b1;
            end
            frames_rdy <= frames_rdy + (fire_in & last_in & keep_now) - (fire_out & out_last);
            used  <= used  + we - pop;
            avail <= avail + we - issue;
        end
    end
endmodule
