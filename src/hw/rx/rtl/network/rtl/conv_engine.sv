`timescale 1ns / 1ps
// ---------------------------------------------------------------------------------
// conv_engine
//
// P-lane KxK convolution with W8A12 integer arithmetic, bit-exact with int_ref.py /
// golden_np.py:
//     acc  = sum x*w + bias                     (bias at accumulator scale)
//     relu : acc = max(acc, 0)      leaky : acc = acc < 0 ? rsr(acc, 7) : acc
//     y    = satY( rsr( sat27( rsr(acc, pre[c]) ) * M[c], sh[c] ) )
//     rsr(v,k) = k>0 ? (v + 2^(k-1)) >>> k : (k==0 ? v : v << -k)
//
// s_in  : window stream from axis_line_buffer (one activation per beat):
//         per output pixel, GROUPS passes of K*K*CIN elements (ky, kx, ci order).
//         Every beat is broadcast to the P lanes; lane p of pass g accumulates output
//         channel g*P + p with its weight from a P*W_W-bit wide ROM word.
// m_out : output feature map, NHWC, one element per beat (channels 0..COUT-1 of a
//         pixel, then the next pixel).  m_out_tlast = last channel of a pixel,
//         m_out_tuser[0] = last pixel of the frame.
//
// After a pass the P sums are copied to a result bank and serialised through one
// requantisation unit (one DSP for *M).  The input stalls only if a pass ends while
// the previous bank is still being drained (happens only when P > K*K*CIN or under
// output backpressure).  Output reads are credit based, so m_out_tready may drop at
// any time.
// ---------------------------------------------------------------------------------
module conv_engine #(
    parameter int    CIN          = 32,
    parameter int    COUT         = 32,
    parameter int    K            = 3,
    parameter int    P            = 8,
    parameter string ACT          = "none",     // "none" | "relu" | "leaky", channels < ACT_SPLIT
    parameter string ACT2         = "none",     // activation of channels >= ACT_SPLIT (merged engines)
    parameter int    ACT_SPLIT    = COUT,
    parameter int    X_W          = 12,         // activation width (signed)
    parameter int    W_W          = 8,          // weight width (signed)
    parameter int    Y_W          = 12,         // output width (signed)
    parameter string WROM_PREFIX  = "",         // slice i is read from <WROM_PREFIX>_s<i>.mem
    parameter int    SLICE_LANES  = 9,          // lanes per ROM slice (9 x 8 bit = one 72-bit BRAM column)
    parameter int    WROM_BANK_DEPTH = 0,       // >0: split each slice into banks of this depth (<prefix>_s<i>_b<j>.mem)
    parameter string WROM_MODE    = "direct",   // "direct": P*W_W-wide ROM (slices/banks), fixed latency
                                                // "gear"  : packed 32-bit columns + byte gearbox (weight_stream)
    parameter int    WG_NCOL      = 1,          // gear mode: number of 32-bit ROM columns (<prefix>_g_c<i>.mem)
    parameter string WROM_STYLE   = "block",    // "block" | "distributed" | "auto"
    parameter int    WROM_LATENCY = 2,
    parameter string BIAS_FILE    = "",         // COUT x 48-bit two's complement
    parameter string PRE_FILE     = "",         // unused (kept for compatibility): PRE is a layer constant
    parameter int    PRE          = 0,          // requant pre-shift (the same for every channel of a layer)
    parameter string M_FILE       = "",         // COUT x 17-bit unsigned
    parameter string SH_FILE      = "",         // COUT x 8-bit two's complement
    parameter int    SH_MIN       = 0,          // smallest per-channel shift of the layer (>= 1, must be set)
    parameter int    SH_BITS      = 3,          // per-channel shift = SH_MIN + d, d < 2^SH_BITS
    parameter string RQ_MUL       = "dsp",      // requant *M: "dsp" (1 DSP48E2) or "lut" (radix-4 serial,
                                                // one result per SER_II cycles; needs P*SER_II <= K*K*CIN)
    parameter int    FIFO_DEPTH   = 16
) (
    input  logic              clk,
    input  logic              rst_n,

    input  logic [X_W-1:0]    s_in_tdata,
    input  logic              s_in_tvalid,
    output logic              s_in_tready,
    input  logic              s_in_tlast,       // last element of a pass (checked in simulation)
    input  logic [2:0]        s_in_tuser,       // [0] first of pass, [1] last group, [2] last pixel of frame

    output logic [Y_W-1:0]    m_out_tdata,
    output logic              m_out_tvalid,
    input  logic              m_out_tready,
    output logic              m_out_tlast,
    output logic [0:0]        m_out_tuser
);
    function automatic int clog2m1(input int x);
        return (x <= 2) ? 1 : $clog2(x);
    endfunction

    localparam int GROUPS = (COUT + P - 1) / P;
    localparam int KKC    = K * K * CIN;
    localparam int DEPTH  = GROUPS * KKC;
    localparam int PROD_W = X_W + W_W;
    localparam int ACC_W  = PROD_W + $clog2(KKC) + 1;
    localparam int RQ_PIPE = 9;                              // drain issue -> FIFO push (DSP multiplier)
    localparam bit RQ_LUT  = (RQ_MUL == "lut");
    localparam int SER_II  = 10;                             // issue spacing with the serial multiplier

    initial begin
        assert (ACT == "none" || ACT == "relu" || ACT == "leaky") else $fatal(1, "conv_engine: bad ACT [%s] len %0d", ACT, ACT.len());
        assert (ACT2 == "none" || ACT2 == "relu" || ACT2 == "leaky") else $fatal(1, "conv_engine: bad ACT2");
        assert ((P + SLICE_LANES - 1) / SLICE_LANES <= 10) else $fatal(1, "conv_engine: at most 10 ROM slices");
        assert (FIFO_DEPTH > RQ_PIPE && (FIFO_DEPTH & (FIFO_DEPTH - 1)) == 0)
            else $fatal(1, "conv_engine: FIFO_DEPTH must be a power of two > %0d", RQ_PIPE);
    end

    // ============================================================== input / weight fetch
    logic [clog2m1(KKC)-1:0]   e_in;         // element index inside the current pass
    logic [clog2m1(DEPTH)-1:0] waddr;        // weight ROM address (sequential per pixel)
    logic                      bank_pending; // a pass end was accepted and its bank is not drained yet
    logic                      drain_done;

    localparam bit GEAR   = (WROM_MODE == "gear");
    localparam int SB_LEN = GEAR ? 1 : WROM_LATENCY;     // input -> operand register latency
    logic w_valid;                                       // gear mode: a weight vector is available

    wire in_last  = (e_in == ($bits(e_in))'(KKC - 1));
    assign s_in_tready = rst_n && !(in_last && bank_pending) && w_valid;
    wire in_fire  = s_in_tvalid && s_in_tready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_in <= '0; waddr <= '0; bank_pending <= 1'b0;
        end else begin
            if (in_fire) begin
                e_in  <= in_last ? '0 : e_in + 1'b1;
                waddr <= (waddr == ($bits(waddr))'(DEPTH - 1)) ? '0 : waddr + 1'b1;
            end
            if (in_fire && in_last) bank_pending <= 1'b1;
            else if (drain_done)    bank_pending <= 1'b0;
        end
    end

    logic [P*W_W-1:0] wword;
    generate
        if (GEAR) begin : g_gear
            // packed ROM + byte gearbox: one vector per accepted input element
            logic [P*W_W-1:0] ws_data;
            weight_stream #(
                .P(P), .NVEC(DEPTH), .NCOL(WG_NCOL),
                .INIT_PREFIX((WROM_PREFIX == "") ? "" : {WROM_PREFIX, "_g"}), .ROM_LATENCY(WROM_LATENCY)
            ) u_ws (
                .clk(clk), .rst_n(rst_n), .m_tdata(ws_data), .m_tvalid(w_valid), .m_tready(in_fire)
            );
            always_ff @(posedge clk) if (in_fire) wword <= ws_data;
        end else begin : g_direct
            // Weight ROM cut into column slices of SLICE_LANES lanes: every slice is its own
            // instance, so a very wide ROM maps to 512x72 BRAM columns instead of whatever
            // aspect ratio the tool would choose for the full width.
            localparam int NSLICE = (P + SLICE_LANES - 1) / SLICE_LANES;
            assign w_valid = 1'b1;
            for (genvar s = 0; s < NSLICE; s++) begin : g_wrom
                localparam int L0 = s * SLICE_LANES;
                localparam int NL = (P - L0 < SLICE_LANES) ? P - L0 : SLICE_LANES;
                // "<prefix>_s<i>.mem" by concatenation (Vivado synthesis truncates %s in $sformatf)
                localparam string SD = (s == 0) ? "0" : (s == 1) ? "1" : (s == 2) ? "2" : (s == 3) ? "3" :
                                       (s == 4) ? "4" : (s == 5) ? "5" : (s == 6) ? "6" : (s == 7) ? "7" :
                                       (s == 8) ? "8" : "9";
                rom_banked #(
                    .DEPTH(DEPTH), .WIDTH(NL * W_W), .BANK_DEPTH(WROM_BANK_DEPTH),
                    .INIT_PREFIX((WROM_PREFIX == "") ? "" : {WROM_PREFIX, "_s", SD}),
                    .RAM_STYLE(WROM_STYLE), .READ_LATENCY(WROM_LATENCY)
                ) u_wrom (
                    .clk(clk), .re(in_fire), .addr(waddr), .dout(wword[L0*W_W +: NL*W_W])
                );
            end
        end
    endgenerate

    // side band delayed to meet the ROM data: {valid, first, last, frame_last, x}
    localparam int SB_W = 4 + X_W;
    logic [SB_W-1:0] sb [SB_LEN];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SB_LEN; i++) sb[i] <= '0;
        end else begin
            sb[0] <= {in_fire, e_in == '0, in_last, s_in_tuser[2] & s_in_tuser[1], s_in_tdata};
            for (int i = 1; i < SB_LEN; i++) sb[i] <= sb[i-1];
        end
    end
    wire                  f_vld   = sb[SB_LEN-1][SB_W-1];
    wire                  f_first = sb[SB_LEN-1][SB_W-2];
    wire                  f_last  = sb[SB_LEN-1][SB_W-3];
    wire                  f_frame = sb[SB_LEN-1][SB_W-4];
    wire signed [X_W-1:0] f_x     = sb[SB_LEN-1][X_W-1:0];

    // ============================================================== P MAC lanes (DSP48E2)
    // M0: operand registers, M1: product, M2: accumulate (DSP A/B, M and P registers)
    logic                     v1, first1, last1, frame1, v2, first2, last2, frame2, cap, cap_frame;
    logic signed [X_W-1:0]    a_r;
    logic signed [ACC_W-1:0]  bank [P];      // driven by the lanes (one register per lane)
    logic                     bank_frame;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; v2 <= 1'b0; cap <= 1'b0;
            first1 <= 1'b0; last1 <= 1'b0; frame1 <= 1'b0;
            first2 <= 1'b0; last2 <= 1'b0; frame2 <= 1'b0; cap_frame <= 1'b0;
        end else begin
            v1 <= f_vld;  first1 <= f_first; last1 <= f_last; frame1 <= f_frame;
            v2 <= v1;     first2 <= first1;  last2 <= last1;  frame2 <= frame1;
            cap <= v2 & last2; cap_frame <= frame2;
        end
    end
    always_ff @(posedge clk) if (f_vld) a_r <= f_x;

    generate
        for (genvar p = 0; p < P; p++) begin : g_lane
            logic signed [W_W-1:0]    b_r;
            logic signed [PROD_W-1:0] m_r;
            logic signed [ACC_W-1:0]  p_r, bank_r;
            always_ff @(posedge clk) begin
                if (f_vld) b_r <= wword[p*W_W +: W_W];
                if (v1)    m_r <= a_r * b_r;
                if (v2)    p_r <= first2 ? ACC_W'(m_r) : p_r + ACC_W'(m_r);
                if (cap)   bank_r <= p_r;
            end
            assign bank[p] = bank_r;
        end
    endgenerate
    always_ff @(posedge clk) if (cap) bank_frame <= cap_frame;

    initial assert (SH_MIN >= 1 && SH_BITS >= 0 && SH_BITS <= 4)
        else $fatal(1, "conv_engine: SH_MIN must be >= 1 (set SH_MIN/SH_BITS from engine.json)");

    // ============================================================== per-channel parameters
    // small per-channel tables: distributed ROM (read once per output channel)
    (* rom_style = "distributed" *) logic [47:0] bias_mem [COUT];
    (* rom_style = "distributed" *) logic [16:0] m_mem    [COUT];
    (* rom_style = "distributed" *) logic [7:0]  sh_mem   [COUT];
    initial begin
        if (BIAS_FILE != "") $readmemh(BIAS_FILE, bias_mem);
        if (M_FILE    != "") $readmemh(M_FILE,    m_mem);
        if (SH_FILE   != "") $readmemh(SH_FILE,   sh_mem);
    end

    // ============================================================== drain + requantisation
    logic                          bank_valid;
    logic [clog2m1(P)-1:0]         dp;
    logic [clog2m1(GROUPS)-1:0]    dg;
    logic [$clog2(FIFO_DEPTH):0]   occ;
    logic [3:0]                    gap;          // serial multiplier: cycles until the next issue
    wire                           pop = m_out_tvalid & m_out_tready;
    int                            co;
    logic                          co_ok, issue, advance, last_lane;
    always_comb begin
        co        = int'(dg) * P + int'(dp);
        co_ok     = co < COUT;
        issue     = bank_valid && co_ok && (occ < FIFO_DEPTH) && (gap == '0);
        advance   = issue || (bank_valid && !co_ok);
        last_lane = (int'(dp) == P - 1) || (co >= COUT - 1);
        drain_done = advance && last_lane;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_valid <= 1'b0; dp <= '0; dg <= '0; occ <= '0; gap <= '0;
        end else begin
            occ <= occ + issue - pop;
            if (issue && RQ_LUT) gap <= 4'(SER_II - 1);
            else if (gap != '0)  gap <= gap - 1'b1;
            if (cap) bank_valid <= 1'b1;
            else if (drain_done) bank_valid <= 1'b0;
            if (advance) begin
                if (last_lane) begin
                    dp <= '0;
                    dg <= (int'(dg) == GROUPS - 1) ? '0 : dg + 1'b1;
                end else begin
                    dp <= dp + 1'b1;
                end
            end
        end
    end

    function automatic logic signed [63:0] rsr(input logic signed [63:0] v, input int k);
        if (k > 0)       return (v + (64'sd1 <<< (k - 1))) >>> k;
        else if (k == 0) return v;
        else             return v <<< (-k);
    endfunction

    function automatic logic signed [63:0] sat(input logic signed [63:0] v, input int bits);
        logic signed [63:0] hi, lo;
        hi = (64'sd1 <<< (bits - 1)) - 1;
        lo = -(64'sd1 <<< (bits - 1));
        return (v > hi) ? hi : ((v < lo) ? lo : v);
    endfunction

    // activation codes: 0 none, 1 relu, 2 leaky (1/128)
    localparam int ACT_C  = (ACT  == "relu") ? 1 : (ACT  == "leaky") ? 2 : 0;
    localparam int ACT2_C = (ACT2 == "relu") ? 1 : (ACT2 == "leaky") ? 2 : 0;
    function automatic logic signed [47:0] activate(input logic signed [47:0] v, input int kind);
        if (kind == 1)      return (v < 0) ? 48'sd0 : v;
        else if (kind == 2) return (v < 0) ? 48'(rsr(64'(v), 7)) : v;
        else                return v;
    endfunction

    // R1: operands + parameters
    logic               r1_v, r1_last, r1_frame, r1_act2;
    logic signed [47:0] r1_acc, r1_bias;
    localparam int DW_SH = (SH_BITS > 0) ? SH_BITS : 1;
    logic [16:0]        r1_m;
    logic [DW_SH-1:0]   r1_sh;                    // shift - SH_MIN
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) r1_v <= 1'b0;
        else        r1_v <= issue;
    end
    always_ff @(posedge clk) begin
        if (issue) begin
            r1_acc   <= 48'(bank[dp]);
            r1_bias  <= bias_mem[co];
            r1_m     <= m_mem[co];
            r1_sh    <= DW_SH'(int'($signed(sh_mem[co])) - SH_MIN);
            r1_last  <= (co == COUT - 1);
            r1_frame <= (co == COUT - 1) && bank_frame;
            r1_act2  <= (co >= ACT_SPLIT);
        end
    end

    // R2: + bias,  R3: activation,  R4: rsr(pre) + sat27
    logic               r2_v, r3_v, r4_v, r2_last, r3_last, r4_last, r2_frame, r3_frame, r4_frame, r2_act2;
    logic signed [47:0] r2_sum, r3_act;
    logic [16:0]        r2_m, r3_m, r4_m;
    logic [DW_SH-1:0]   r2_sh, r3_sh, r4_sh;
    logic signed [26:0] r4_t;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_v <= 1'b0; r3_v <= 1'b0; r4_v <= 1'b0;
        end else begin
            r2_v <= r1_v; r3_v <= r2_v; r4_v <= r3_v;
        end
    end
    always_ff @(posedge clk) begin
        r2_sum <= r1_acc + r1_bias;
        r2_m <= r1_m; r2_sh <= r1_sh; r2_last <= r1_last; r2_frame <= r1_frame;
        r2_act2 <= r1_act2;

        r3_act <= activate(r2_sum, r2_act2 ? ACT2_C : ACT_C);
        r3_m <= r2_m; r3_sh <= r2_sh; r3_last <= r2_last; r3_frame <= r2_frame;

        r4_t   <= 27'(sat(rsr(64'(r3_act), PRE), 27));          // constant shift
        r4_m   <= r3_m; r4_sh <= r3_sh; r4_last <= r3_last; r4_frame <= r3_frame;
    end

    // R5..R7: M multiply.  "dsp": one DSP48E2 (A/B, M, P registers), fixed 3 cycles.
    //          "lut": radix-4 serial multiplier in fabric, 10 cycles, issues spaced by SER_II.
    logic               r7_v, r7_last, r7_frame;
    logic signed [44:0] r7_mul;
    logic [DW_SH-1:0]   r7_sh;
    generate
        if (!RQ_LUT) begin : g_mul_dsp
            logic               r5_v, r6_v, r5_last, r6_last, r5_frame, r6_frame;
            logic signed [26:0] r5_a;
            logic signed [17:0] r5_b;
            logic signed [44:0] r6_mul;
            logic [DW_SH-1:0]   r5_sh, r6_sh;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    r5_v <= 1'b0; r6_v <= 1'b0; r7_v <= 1'b0;
                end else begin
                    r5_v <= r4_v; r6_v <= r5_v; r7_v <= r6_v;
                end
            end
            always_ff @(posedge clk) begin
                r5_a   <= r4_t;
                r5_b   <= {1'b0, r4_m};
                r6_mul <= r5_a * r5_b;
                r7_mul <= r6_mul;
                r5_sh <= r4_sh; r6_sh <= r5_sh; r7_sh <= r6_sh;
                r5_last <= r4_last; r6_last <= r5_last; r7_last <= r6_last;
                r5_frame <= r4_frame; r6_frame <= r5_frame; r7_frame <= r6_frame;
            end
        end else begin : g_mul_lut
            logic ser_busy;
            mul_serial #(.AW(27), .BW(17)) u_mul (
                .clk(clk), .rst_n(rst_n), .start(r4_v), .a(r4_t), .b(r4_m),
                .busy(ser_busy), .done(r7_v), .p(r7_mul)
            );
            always_ff @(posedge clk) begin
                if (r4_v) begin
                    r7_sh <= r4_sh; r7_last <= r4_last; r7_frame <= r4_frame;
                end
            end
`ifndef SYNTHESIS
            always_ff @(posedge clk) if (rst_n && r4_v && ser_busy) $error("conv_engine: serial multiplier overrun");
`endif
        end
    endgenerate

    // R8: rsr(sh) + saturation -> output FIFO
    logic                  r8_v, r8_last, r8_frame;
    logic signed [Y_W-1:0] r8_y;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) r8_v <= 1'b0;
        else        r8_v <= r7_v;
    end
    // rsr(v, SH_MIN + d) = ((v + 2^(SH_MIN+d-1)) >>> SH_MIN) >>> d : constant shift plus a
    // 2^SH_BITS-position shifter, on the 45-bit product only
    logic signed [45:0] r8_t;
    logic signed [45:0] r8_s;
    always_comb begin
        r8_t = 46'(r7_mul) + (46'sd1 <<< (SH_MIN - 1 + ((SH_BITS > 0) ? int'(r7_sh) : 0)));
        r8_s = (r8_t >>> SH_MIN) >>> ((SH_BITS > 0) ? int'(r7_sh) : 0);
    end
    always_ff @(posedge clk) begin
        r8_y     <= (r8_s > 46'sd0 + ((46'sd1 <<< (Y_W - 1)) - 1)) ? Y_W'((1 <<< (Y_W - 1)) - 1) :
                    (r8_s < -(46'sd1 <<< (Y_W - 1)))              ? Y_W'(-(1 <<< (Y_W - 1))) : Y_W'(r8_s);
        r8_last  <= r7_last;
        r8_frame <= r7_frame;
    end

    // ============================================================== output FIFO (FWFT)
    localparam int FAW = $clog2(FIFO_DEPTH);
    (* ram_style = "distributed" *) logic [Y_W+1:0] fifo_mem [FIFO_DEPTH];
    logic [FAW:0] f_wp, f_rp;
    always_ff @(posedge clk) if (r8_v) fifo_mem[f_wp[FAW-1:0]] <= {r8_frame, r8_last, r8_y};
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_wp <= '0; f_rp <= '0;
        end else begin
            if (r8_v) f_wp <= f_wp + 1'b1;
            if (pop)  f_rp <= f_rp + 1'b1;
        end
    end
    logic [Y_W+1:0] f_head;
    assign f_head         = fifo_mem[f_rp[FAW-1:0]];
    assign m_out_tvalid   = (f_wp != f_rp);
    assign m_out_tdata    = f_head[Y_W-1:0];
    assign m_out_tlast    = f_head[Y_W];
    assign m_out_tuser[0] = f_head[Y_W+1];

`ifndef SYNTHESIS
    // the window stream must agree with the engine's pass counter
    always_ff @(posedge clk) begin
        if (rst_n && in_fire && (s_in_tlast !== in_last || s_in_tuser[0] !== (e_in == '0)))
            $error("conv_engine: pass framing mismatch (e_in=%0d tlast=%b tuser=%b)", e_in, s_in_tlast, s_in_tuser);
    end
`endif
endmodule
