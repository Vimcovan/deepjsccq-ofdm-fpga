`timescale 1ns / 1ps
// ---------------------------------------------------------------------------------
// axis_line_buffer
//
// Row ring buffer + window read sequencer for one KxK convolution engine.
//
//   s_in  : NHWC feature map, one element per beat (row by row, pixel by pixel,
//           channel by channel), frames back to back.
//   m_out : the element sequence the conv engine consumes, one element per beat:
//               for each output pixel (oy, ox)            (raster order)
//                 for g  in 0..GROUPS-1                   (output-channel groups, = ceil(Cout/P))
//                   for ky in 0..K-1, kx in 0..K-1, c in 0..C-1
//           Out-of-image taps (zero padding) are emitted as 0.
//           m_out_tlast    : last element of a window pass (ky=K-1, kx=K-1, c=C-1)
//           m_out_tuser[0] : first element of a window pass
//           m_out_tuser[1] : pass belongs to the last group of this output pixel
//           m_out_tuser[2] : output pixel is the last one of the frame
//
// Storage: ROWS input rows in a ring, PACK elements per RAM word (continuous packing,
// word = element_index / PACK).  Each accepted element rewrites its whole word from
// the gather register ("write-through"), so rows may start inside a word without
// read-modify-write and without read-side bypass.
//
// Flow control:
//   * input  : an element of input row r is accepted only when the ring slot it goes
//              to is no longer needed by the current output row (backpressure otherwise);
//   * output : a window starts only when all its input rows/columns are in the RAM;
//              reads are issued against credits of an output FIFO, so m_out_tready
//              may be deasserted at any time.
// ---------------------------------------------------------------------------------
module axis_line_buffer #(
    parameter int    DATA_W      = 12,        // element width
    parameter int    C           = 32,        // channels
    parameter int    W           = 128,       // image width  (pixels per row)
    parameter int    H           = 128,       // image height (rows per frame)
    parameter int    K           = 3,         // kernel size
    parameter int    STRIDE      = 1,
    parameter int    PAD         = 1,
    parameter int    ROWS        = K,         // rows kept in the ring
    parameter int    GROUPS      = 1,         // window passes per output pixel
    parameter int    PACK        = 6,         // elements per RAM word
    parameter string RAM_STYLE   = "block",   // "block" | "ultra" | "distributed" | "auto"
    parameter int    RAM_LATENCY = 2,         // 1 or 2
    parameter int    FIFO_DEPTH  = 16         // output FIFO, power of two, > pipeline depth
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
    // -------------------------------------------------------------- derived constants
    function automatic int clog2m1(input int x);
        return (x <= 2) ? 1 : $clog2(x);
    endfunction

    localparam int HO     = (H + 2 * PAD - K) / STRIDE + 1;
    localparam int WO     = (W + 2 * PAD - K) / STRIDE + 1;
    localparam int WC     = W * C;                          // elements per row
    localparam int RING   = ROWS * WC;                      // elements in the ring
    localparam int DEPTH  = (RING + PACK - 1) / PACK;       // RAM words
    localparam int WORD_W = PACK * DATA_W;
    localparam int AW     = clog2m1(DEPTH);
    localparam int EW     = clog2m1(RING);
    localparam int LW     = clog2m1(PACK);
    localparam int PIPE   = 2 + RAM_LATENCY;                // issue -> FIFO push latency
    localparam int SCW    = (STRIDE * C) / PACK;            // column-base step per output pixel,
    localparam int SCL    = (STRIDE * C) % PACK;            // as (words, lanes)
    // signed widths of the window coordinates (-PAD .. max(H, W) + K) and of ix0 * C
    localparam int IW     = $clog2((H > W ? H : W) + 2 * K + 2) + 1;
    localparam int CBW    = $clog2(WC + 2 * K * C + 2) + 1;


    initial begin
        assert (ROWS >= K && STRIDE <= ROWS) else $fatal(1, "axis_line_buffer: need ROWS >= K and STRIDE <= ROWS");
        assert (WC >= PACK) else $fatal(1, "axis_line_buffer: a row must hold at least PACK elements");
        assert (FIFO_DEPTH > PIPE && (FIFO_DEPTH & (FIFO_DEPTH - 1)) == 0)
            else $fatal(1, "axis_line_buffer: FIFO_DEPTH must be a power of two > %0d", PIPE);
        assert (PACK * DATA_W <= 72 || RAM_STYLE != "ultra")
            else $warning("axis_line_buffer: word wider than one URAM column");
    end

    // -------------------------------------------------------------- write side state
    logic [clog2m1(WC)-1:0]   wr_e;       // element index inside the current row
    logic [clog2m1(H)-1:0]    wr_row;     // row being written
    logic [1:0]               wr_frm;     // frame counter of the writer (mod 4)
    logic [EW-1:0]            ring_e;     // element index in the ring
    logic [AW-1:0]            wr_word;
    logic [LW-1:0]            wr_lane;
    logic [WORD_W-1:0]        gather, gather_nx;

    // -------------------------------------------------------------- read side state
    logic [clog2m1(C)-1:0]      rc;
    logic [clog2m1(K)-1:0]      rkx, rky;
    logic [clog2m1(GROUPS)-1:0] rg;
    logic [clog2m1(WO)-1:0]     rox;
    logic [clog2m1(HO)-1:0]     roy;
    logic [1:0]                 rd_frm;     // frame counter of the reader (mod 4)
    logic signed [IW-1:0]       iy0, ix0;       // top-left input row/column of the window
    logic signed [CBW-1:0]      colbase;        // ix0 * C, kept incrementally (no multiplier)
    logic signed [AW+1:0]       cbw;            // (ix0 + PAD) * C  as (word, lane) of the ring
    logic [LW:0]                cbl;
    logic signed [AW+1:0]       cur_w;          // (word, lane) of the next element inside a tap
    logic [LW:0]                cur_l;
    logic [clog2m1(ROWS)-1:0]   slot0;          // ring slot of input row iy0 (valid modulo ROWS)
    logic [clog2m1(ROWS)-1:0]   base_slot;      // ring slot of row 0 of the frame being read

    // -------------------------------------------------------------- write gating
    // the reader still needs rows >= first of its current output row
    localparam int RW = $clog2(2 * H + ROWS + 2) + 1;      // signed row numbers relative to the reader
    logic signed [RW-1:0] rd_first, wr_rel;
    logic [1:0] frm_diff;
    logic       w_same, w_ahead;
    assign frm_diff = wr_frm - rd_frm;
    assign w_same   = (frm_diff == 2'd0);
    assign w_ahead  = (frm_diff == 2'd1);
    always_comb begin
        rd_first = (iy0 < 0) ? '0 : RW'(iy0);
        // writer frame relative to the reader: same frame, one ahead, or one behind (the
        // reader may finish a frame before the writer when the last rows are not needed)
        wr_rel   = w_same ? RW'(wr_row) : (w_ahead ? RW'(wr_row) + RW'(H) : RW'(wr_row) - RW'(H));
    end
    assign s_in_tready = rst_n && (wr_rel < rd_first + RW'(ROWS));

    wire wr_fire   = s_in_tvalid & s_in_tready;
    wire ring_last = (ring_e == EW'(RING - 1));

    always_comb begin
        gather_nx = gather;
        gather_nx[wr_lane * DATA_W +: DATA_W] = s_in_tdata;
    end

    // Row boundaries inside a word ("straddle words"): the word holding the tail of the
    // row in slot s also holds the head of slot s+1, which may still be live.  Its
    // current content is kept in shadow[s] (captured when the head of slot s+1 finished
    // that word) and reloaded into the gather register before the tail of slot s is
    // written, so the write-through never clobbers live elements.
    localparam int NB = (ROWS > 1) ? ROWS - 1 : 1;
    function automatic int bword(input int s);  return ((s + 1) * WC) / PACK;       endfunction
    function automatic bit bstrad(input int s); return (((s + 1) * WC) % PACK) != 0; endfunction

    logic [clog2m1(ROWS)-1:0] wr_slot;
    logic [WORD_W-1:0]        shadow [NB];
    logic [AW-1:0]            nx_word;
    logic                     word_end, cap_hit, load_hit;
    int                       cap_idx, load_idx;
    always_comb begin
        word_end = (wr_lane == LW'(PACK - 1)) || ring_last;
        nx_word  = ring_last ? '0 : wr_word + 1'b1;
        cap_hit = 1'b0; cap_idx = 0; load_hit = 1'b0; load_idx = 0;
        for (int s = 0; s < ROWS - 1; s++) begin
            // finishing the straddle word between slots s and s+1 while writing slot s+1
            if (bstrad(s) && int'(wr_slot) == s + 1 && int'(wr_word) == bword(s)) begin
                cap_hit = 1'b1; cap_idx = s;
            end
            // the next word is the straddle word after slot s (it starts with slot s's tail)
            if (bstrad(s) && int'(nx_word) == bword(s)) begin
                load_hit = 1'b1; load_idx = s;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < NB; s++) shadow[s] <= '0;
        end else if (wr_fire && word_end && cap_hit) begin
            shadow[cap_idx] <= gather_nx;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_e <= '0; wr_row <= '0; wr_frm <= '0; wr_slot <= '0;
            ring_e <= '0; wr_word <= '0; wr_lane <= '0; gather <= '0;
        end else if (wr_fire) begin
            gather <= (word_end && load_hit) ? shadow[load_idx] : gather_nx;
            if (word_end) begin
                wr_lane <= '0;
                wr_word <= nx_word;
            end else begin
                wr_lane <= wr_lane + 1'b1;
            end
            if (wr_e == ($bits(wr_e))'(WC - 1))
                wr_slot <= (int'(wr_slot) == ROWS - 1) ? '0 : wr_slot + 1'b1;
            ring_e <= ring_last ? '0 : ring_e + 1'b1;
            if (wr_e == ($bits(wr_e))'(WC - 1)) begin
                wr_e <= '0;
                if (wr_row == ($bits(wr_row))'(H - 1)) begin
                    wr_row <= '0;
                    wr_frm <= wr_frm + 1'b1;
                end else begin
                    wr_row <= wr_row + 1'b1;
                end
            end else begin
                wr_e <= wr_e + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------- window readiness
    // A window needs its last input row complete up to column min(ix0+K-1, W-1)
    // (or entirely when it hangs over the bottom edge).
    logic data_ok;
    localparam int NEW = $clog2(WC + 1) + 1;
    logic signed [IW:0]    last_raw, last_row;
    logic signed [CBW:0]   ce;
    logic [NEW-1:0]        need_e;
    always_comb begin
        last_raw = (IW+1)'(iy0) + (IW+1)'(K - 1);
        ce       = (CBW+1)'(colbase) + (CBW+1)'(K * C);
        if (last_raw > (IW+1)'(H - 1)) begin
            last_row = (IW+1)'(H - 1);
            need_e   = NEW'(WC);                            // only satisfied after the row wraps
        end else begin
            last_row = last_raw;
            // (min(ix0+K-1, W-1) + 1) * C  ==  min(colbase + K*C, W*C)
            need_e   = (ce > (CBW+1)'(WC)) ? NEW'(WC) : NEW'(ce);
        end
        data_ok = w_ahead
               || (w_same && ((IW+1)'(wr_row) > last_row
                              || ((IW+1)'(wr_row) == last_row && NEW'(wr_e) >= need_e)));
    end

    // -------------------------------------------------------------- issue control
    logic [$clog2(FIFO_DEPTH):0] occ;           // FIFO entries + elements in flight
    wire  win_start = (rg == '0) && (rky == '0) && (rkx == '0) && (rc == '0);
    wire  pop       = m_out_tvalid & m_out_tready;
    // data_ok is registered (timing): within one window it can only turn from 0 to 1, so a
    // one-cycle-old value is safe; it is cleared when the window changes and re-evaluated.
    logic data_ok_r;
    wire  issue     = rst_n && (occ < FIFO_DEPTH) && (!win_start || data_ok_r);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) occ <= '0;
        else        occ <= occ + issue - pop;
    end

    // loop counters
    wire last_c  = (rc  == ($bits(rc))'(C - 1));
    wire last_kx = (rkx == ($bits(rkx))'(K - 1));
    wire last_ky = (rky == ($bits(rky))'(K - 1));
    wire last_g  = (rg  == ($bits(rg))'(GROUPS - 1));
    wire last_ox = (rox == ($bits(rox))'(WO - 1));
    wire last_oy = (roy == ($bits(roy))'(HO - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                               data_ok_r <= 1'b0;
        else if (issue && last_c && last_kx && last_ky && last_g) data_ok_r <= 1'b0;   // next window
        else                                                      data_ok_r <= data_ok;
    end

    function automatic logic [clog2m1(ROWS)-1:0] add_mod_rows(input int a, input int b);
        int s;
        s = (a + b) % ROWS;
        if (s < 0) s += ROWS;
        return s[clog2m1(ROWS)-1:0];
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rc <= '0; rkx <= '0; rky <= '0; rg <= '0; rox <= '0; roy <= '0; rd_frm <= '0;
            iy0 <= IW'(-PAD); ix0 <= IW'(-PAD); colbase <= CBW'(-PAD * C); cbw <= '0; cbl <= '0;
            base_slot <= '0;
            slot0 <= add_mod_rows(0, -PAD);
        end else if (issue) begin
            rc <= last_c ? '0 : rc + 1'b1;
            if (last_c) begin
                rkx <= last_kx ? '0 : rkx + 1'b1;
                if (last_kx) begin
                    rky <= last_ky ? '0 : rky + 1'b1;
                    if (last_ky) begin
                        rg <= last_g ? '0 : rg + 1'b1;
                        if (last_g) begin
                            if (last_ox) begin
                                rox <= '0;
                                ix0 <= IW'(-PAD);
                                colbase <= CBW'(-PAD * C);
                                cbw <= '0; cbl <= '0;
                                if (last_oy) begin                      // next frame
                                    roy <= '0;
                                    iy0 <= IW'(-PAD);
                                    rd_frm <= rd_frm + 1'b1;
                                    base_slot <= add_mod_rows(base_slot, H);
                                    slot0 <= add_mod_rows(base_slot, H - PAD);
                                end else begin
                                    roy <= roy + 1'b1;
                                    iy0 <= iy0 + IW'(STRIDE);
                                    slot0 <= add_mod_rows(slot0, STRIDE);
                                end
                            end else begin
                                rox <= rox + 1'b1;
                                ix0 <= ix0 + IW'(STRIDE);
                                colbase <= colbase + CBW'(STRIDE * C);
                                if (int'(cbl) + SCL >= PACK) begin
                                    cbw <= cbw + ($bits(cbw))'(SCW + 1); cbl <= ($bits(cbl))'(int'(cbl) + SCL - PACK);
                                end else begin
                                    cbw <= cbw + ($bits(cbw))'(SCW);     cbl <= ($bits(cbl))'(int'(cbl) + SCL);
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------- read pipeline
    // The RAM address of an element is kept as a (word, lane) pair, so no division by
    // PACK is needed: row-slot and kx offsets come from constant tables, the column base
    // is advanced with carry per output pixel, and channels step lane by lane inside a tap.
    function automatic int fdiv(input int a, input int b);        // floor division (constants)
        int q;
        q = a / b;
        if ((a % b != 0) && ((a < 0) != (b < 0))) q -= 1;
        return q;
    endfunction
    function automatic int fmod(input int a, input int b);
        return a - fdiv(a, b) * b;
    endfunction

    // stage A0 (registered at issue): table lookups and partial sums, kept apart as
    //   word part ww = slot*W*C/PACK + cbw + kx word offset
    //   lane part lw = slot*W*C%PACK + cbl + kx lane offset   (< 3*PACK)
    int   iy, ix, slot, ww, lw;
    always_comb begin
        iy   = int'(iy0) + int'(rky);
        ix   = int'(ix0) + int'(rkx);
        slot = int'(slot0) + int'(rky);
        if (slot >= ROWS) slot -= ROWS;
        ww = int'(cbw); lw = int'(cbl);
        for (int s = 0; s < ROWS; s++) if (slot == s) begin ww += (s * WC) / PACK; lw += (s * WC) % PACK; end
        for (int k = 0; k < K; k++) if (int'(rkx) == k) begin ww += fdiv((k - PAD) * C, PACK); lw += fmod((k - PAD) * C, PACK); end
    end

    logic                 a0_vld, a0_pad, a0_first;
    logic signed [AW+2:0] a0_ww;
    logic [LW+1:0]        a0_lw;
    logic [3:0]           a0_flg;                // {last_pixel, last_group, first, last}
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a0_vld <= 1'b0; a0_pad <= 1'b0; a0_first <= 1'b0; a0_ww <= '0; a0_lw <= '0; a0_flg <= '0;
        end else begin
            a0_vld <= issue;
            if (issue) begin
                a0_pad   <= (iy < 0) || (iy > H - 1) || (ix < 0) || (ix > W - 1);
                a0_first <= (rc == '0);
                a0_ww    <= ($bits(a0_ww))'(ww);
                a0_lw    <= ($bits(a0_lw))'(lw);
                a0_flg   <= {last_ox && last_oy, last_g, (rky == '0 && rkx == '0 && rc == '0),
                             last_ky && last_kx && last_c};
            end
        end
    end

    // stage A1: carry normalisation of the tap base, or previous element + 1 inside a tap
    int ew, el;
    always_comb begin
        if (a0_first) begin
            ew = int'(a0_ww); el = int'(a0_lw);
            if (el >= PACK) begin el -= PACK; ew += 1; end
            if (el >= PACK) begin el -= PACK; ew += 1; end
        end else begin
            ew = int'(cur_w); el = int'(cur_l);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_w <= '0; cur_l <= '0;
        end else if (a0_vld) begin
            if (el == PACK - 1) begin cur_w <= ($bits(cur_w))'(ew + 1); cur_l <= '0; end
            else                begin cur_w <= ($bits(cur_w))'(ew);     cur_l <= ($bits(cur_l))'(el + 1); end
        end
    end

    logic          b_vld, b_pad;
    logic [AW-1:0] b_word;
    logic [LW-1:0] b_lane;
    logic [3:0]    b_flg;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_vld <= 1'b0; b_pad <= 1'b0; b_word <= '0; b_lane <= '0; b_flg <= '0;
        end else begin
            b_vld <= a0_vld;
            if (a0_vld) begin
                b_pad  <= a0_pad;
                b_word <= AW'(ew);                       // don't care for padded taps
                b_lane <= LW'(el);
                b_flg  <= a0_flg;
            end
        end
    end

    // RAM
    logic [WORD_W-1:0] rd_word;
    sdp_ram #(
        .DEPTH       (DEPTH),
        .WIDTH       (WORD_W),
        .RAM_STYLE   (RAM_STYLE),
        .READ_LATENCY(RAM_LATENCY)
    ) u_ram (
        .clk  (clk),
        .we   (wr_fire),
        .waddr(wr_word),
        .wdata(gather_nx),
        .re   (b_vld & ~b_pad),
        .raddr(b_word),
        .rdata(rd_word)
    );

    // side-band delay matching the RAM read latency
    logic          d_vld [RAM_LATENCY];
    logic          d_pad [RAM_LATENCY];
    logic [LW-1:0] d_lane[RAM_LATENCY];
    logic [3:0]    d_flg [RAM_LATENCY];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < RAM_LATENCY; i++) begin
                d_vld[i] <= 1'b0; d_pad[i] <= 1'b0; d_lane[i] <= '0; d_flg[i] <= '0;
            end
        end else begin
            d_vld[0] <= b_vld; d_pad[0] <= b_pad; d_lane[0] <= b_lane; d_flg[0] <= b_flg;
            for (int i = 1; i < RAM_LATENCY; i++) begin
                d_vld[i] <= d_vld[i-1]; d_pad[i] <= d_pad[i-1]; d_lane[i] <= d_lane[i-1]; d_flg[i] <= d_flg[i-1];
            end
        end
    end

    // lane select + zero padding -> output FIFO
    localparam int L = RAM_LATENCY - 1;
    wire              push = d_vld[L];
    wire [DATA_W-1:0] push_data = d_pad[L] ? '0 : rd_word[d_lane[L] * DATA_W +: DATA_W];

    // -------------------------------------------------------------- output FIFO (FWFT)
    localparam int FAW = $clog2(FIFO_DEPTH);
    (* ram_style = "distributed" *) logic [DATA_W+3:0] fifo_mem [FIFO_DEPTH];
    logic [FAW:0] f_wp, f_rp;

    always_ff @(posedge clk) begin
        if (push) fifo_mem[f_wp[FAW-1:0]] <= {d_flg[L], push_data};
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_wp <= '0; f_rp <= '0;
        end else begin
            if (push) f_wp <= f_wp + 1'b1;
            if (pop)  f_rp <= f_rp + 1'b1;
        end
    end

    logic [DATA_W+3:0] f_head;
    assign f_head       = fifo_mem[f_rp[FAW-1:0]];
    assign m_out_tvalid = (f_wp != f_rp);
    assign m_out_tdata  = f_head[DATA_W-1:0];
    assign m_out_tlast  = f_head[DATA_W];
    assign m_out_tuser  = f_head[DATA_W+3:DATA_W+1];
endmodule
