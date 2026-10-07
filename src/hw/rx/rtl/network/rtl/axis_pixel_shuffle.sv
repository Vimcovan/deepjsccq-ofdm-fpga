`timescale 1ns / 1ps
// PixelShuffle (depth-to-space, factor R) on an NHWC stream:
//     out[R*y + i, R*x + j, c] = in[y, x, c*R*R + i*R + j]
// Each input pixel is collected in a 2-slot LUTRAM pixel buffer.  Sub-row i = 0 of the
// pixel goes straight to the output (R output pixels, channels reordered); sub-rows
// i = 1..R-1 are written to a row buffer ((R-1) * W * R * CO elements, the "shuffle row"
// buffer of the memory plan).  After the last pixel of an input row the row buffer is read
// out sequentially, which is exactly the raster order of output rows R*y+1 .. R*y+R-1.
// Output: tlast = last channel of an output pixel, tuser[0] = last beat of the frame.
module axis_pixel_shuffle #(
    parameter int    DATA_W      = 12,
    parameter int    C           = 12,          // input channels (= CO * R * R)
    parameter int    R           = 2,
    parameter int    W           = 128,         // input width
    parameter int    H           = 128,         // input height
    parameter string RB_STYLE    = "block",
    parameter int    RB_LATENCY  = 2,
    parameter int    OFIFO       = 8            // power of two > RB_LATENCY + 1
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic [DATA_W-1:0] s_tdata,
    input  logic              s_tvalid,
    output logic              s_tready,
    output logic [DATA_W-1:0] m_tdata,
    output logic              m_tvalid,
    input  logic              m_tready,
    output logic              m_tlast,
    output logic [0:0]        m_tuser
);
    function automatic int clog2m1(input int v);
        return (v <= 2) ? 1 : $clog2(v);
    endfunction
    localparam int CO  = C / (R * R);
    localparam int RC  = R * CO;                  // elements of one sub-row of one input pixel
    localparam int RBN = (R - 1) * W * RC;        // row buffer elements
    localparam int CW  = clog2m1(C);
    localparam int AW  = clog2m1(RBN);
    localparam int FAW = $clog2(OFIFO);
    initial assert (CO * R * R == C && R >= 2) else $fatal(1, "axis_pixel_shuffle: C must be CO*R*R, R >= 2");

    // ---------------------------------------------------------------- input: pixel slots
    (* ram_style = "distributed" *) logic [DATA_W-1:0] pmem [2 << CW];
    logic [1:0]    full;
    logic          wslot, rslot;
    logic [CW-1:0] wc;
    wire  w_fire = s_tvalid && s_tready;
    assign s_tready = rst_n && !full[wslot];
    always_ff @(posedge clk) if (w_fire) pmem[{wslot, wc}] <= s_tdata;

    // ---------------------------------------------------------------- output FIFO (credit based)
    logic [FAW:0]            occ;                 // entries + reads in flight
    logic [DATA_W+1:0]       ofifo [OFIFO];       // {tuser, tlast, data}
    logic [FAW:0]            o_wp, o_rp;
    wire  pop    = m_tvalid && m_tready;
    wire  credit = (occ < OFIFO);

    // ---------------------------------------------------------------- sequencer
    typedef enum logic [0:0] {S_PIX, S_ROW} st_t;
    st_t st;
    // S_PIX counters: sub-row i, column j, channel c of the current input pixel
    logic [clog2m1(R)-1:0]  si, sj;
    logic [clog2m1(CO)-1:0] sc;
    logic [CW-1:0]          sch;                  // source channel c*R*R + i*R + j
    logic [CW-1:0]          sbase;                // i*R + j
    logic [AW-1:0]          wa;                   // row buffer write address
    logic [AW-1:0]          xoff;                 // x * RC
    logic [AW-1:0]          ioff;                 // (i-1) * W * RC
    logic [clog2m1(W)-1:0]  px;
    logic [clog2m1(H)-1:0]  py;
    // S_ROW counters
    logic [AW-1:0]          ra;
    logic [clog2m1(CO)-1:0] rc;

    wire  to_out  = (si == '0);
    logic [RB_LATENCY-1:0] d_v, d_l, d_u;         // row buffer read pipeline (see below)
    wire  pix_ok  = (st == S_PIX) && full[rslot] && (d_v == '0);   // row readout drained first
    wire  pstep   = pix_ok && (!to_out || credit);
    wire  plast   = pstep && (int'(si) == R - 1) && (int'(sj) == R - 1) && (int'(sc) == CO - 1);
    wire  rstep   = (st == S_ROW) && credit;
    wire  rend    = rstep && (int'(ra) == RBN - 1);
    wire  lastrow = (int'(py) == H - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            full <= 2'b00; wslot <= 1'b0; rslot <= 1'b0; wc <= '0;
            st <= S_PIX; si <= '0; sj <= '0; sc <= '0; sch <= '0; sbase <= '0;
            xoff <= '0; ioff <= '0; px <= '0; py <= '0; ra <= '0; rc <= '0;
        end else begin
            if (w_fire) begin
                wc <= (int'(wc) == C - 1) ? '0 : wc + 1'b1;
                if (int'(wc) == C - 1) wslot <= ~wslot;
            end
            for (int s = 0; s < 2; s++) begin
                if (w_fire && int'(wc) == C - 1 && wslot == 1'(s)) full[s] <= 1'b1;
                else if (plast && rslot == 1'(s))                  full[s] <= 1'b0;
            end
            if (pstep) begin
                if (int'(sc) == CO - 1) begin
                    sc <= '0;
                    if (int'(sj) == R - 1) begin
                        sj <= '0;
                        if (int'(si) == R - 1) begin
                            si <= '0; sbase <= '0; sch <= '0; ioff <= '0;
                            rslot <= ~rslot;
                            if (int'(px) == W - 1) begin
                                px <= '0; xoff <= '0; st <= S_ROW;
                            end else begin
                                px <= px + 1'b1; xoff <= xoff + AW'(RC);
                            end
                        end else begin
                            si <= si + 1'b1;
                            sbase <= sbase + 1'b1;
                            sch <= sbase + 1'b1;
                            if (si != '0) ioff <= ioff + AW'(W * RC);
                        end
                    end else begin
                        sj <= sj + 1'b1;
                        sbase <= sbase + 1'b1;
                        sch <= sbase + 1'b1;
                    end
                end else begin
                    sc  <= sc + 1'b1;
                    sch <= sch + CW'(R * R);
                end
            end
            if (rstep) begin
                rc <= (int'(rc) == CO - 1) ? '0 : rc + 1'b1;
                if (rend) begin
                    ra <= '0; rc <= '0; st <= S_PIX;
                    py <= lastrow ? '0 : py + 1'b1;
                end else ra <= ra + 1'b1;
            end
        end
    end
    // row buffer write address = ioff + xoff + j*CO + c (sub-rows i >= 1)
    logic [AW-1:0] jc;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) jc <= '0;
        else if (pstep) jc <= (int'(jc) == RC - 1) ? '0 : jc + 1'b1;
    end
    assign wa = ioff + xoff + jc;

    logic [DATA_W-1:0] rb_q;
    sdp_ram #(.DEPTH(RBN), .WIDTH(DATA_W), .RAM_STYLE(RB_STYLE), .READ_LATENCY(RB_LATENCY)) u_rb (
        .clk(clk), .we(pstep && !to_out), .waddr(wa), .wdata(pmem[{rslot, sch}]),
        .re(rstep), .raddr(ra), .rdata(rb_q)
    );

    // read pipeline of the row buffer: flags travel alongside
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin d_v <= '0; d_l <= '0; d_u <= '0; end
        else begin
            d_v <= {d_v, rstep};
            d_l <= {d_l, int'(rc) == CO - 1};
            d_u <= {d_u, rend && lastrow};
        end
    end

    wire                 push_p = pstep && to_out;
    wire                 push_r = d_v[RB_LATENCY-1];
    wire [DATA_W+1:0]    pdat   = {1'b0, int'(sc) == CO - 1, pmem[{rslot, sch}]};
    wire [DATA_W+1:0]    rdat   = {d_u[RB_LATENCY-1], d_l[RB_LATENCY-1], rb_q};
    // the two pushes never coincide: S_PIX waits until the row readout pipeline has drained
    always_ff @(posedge clk) if (push_p || push_r) ofifo[o_wp[FAW-1:0]] <= push_r ? rdat : pdat;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_wp <= '0; o_rp <= '0; occ <= '0;
        end else begin
            if (push_p || push_r) o_wp <= o_wp + 1'b1;
            if (pop) o_rp <= o_rp + 1'b1;
            occ <= occ + (push_p || rstep) - pop;
        end
    end
    assign m_tvalid = (o_wp != o_rp);
    assign {m_tuser, m_tlast, m_tdata} = ofifo[o_rp[FAW-1:0]];

    // synthesis translate_off
    always_ff @(posedge clk) assert (!(push_p && push_r)) else $error("axis_pixel_shuffle: push collision");
    // synthesis translate_on
endmodule
