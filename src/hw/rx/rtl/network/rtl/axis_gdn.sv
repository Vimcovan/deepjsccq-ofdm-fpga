`timescale 1ns / 1ps
// GDN / IGDN layer, NHWC stream in, NHWC stream out (same order).
//   D_i = (beta_i + sum_j gamma_ij * rsr(x_j^2, X2_SHIFT)) << LSH,  r_i = isqrt(D_i)
//   GDN : t_i = sign(x_i) * floor(|x_i| * 2^F / r_i)     IGDN: t_i = x_i * r_i
//   y_i = sat(rsr(sat27(rsr(t_i, PRE)) * M, SH))
// Structure
//   * input: ping-pong pixel buffer (LUTRAM) holding x and x^2 (squarer in LUT, 2 stages)
//   * MAC  : LANES DSP lanes, lane l of pass g computes D for channel g*LANES+l,
//            reading x^2[j] for j = 0..C-1 (one read per cycle, gamma ROM lane packed,
//            sequential addresses), x_i is latched on the fly when j == i
//   * bank : LANES accumulators handed to the dispatcher (MAC stalls on the last beat of
//            a pass while the bank is still occupied)
//   * NUNITS iterative gdn_units served round robin; results collected in the same
//            round-robin order, so the output keeps the channel order
//   * requant: constant multiplier M in LUT; stall pipeline driven by m_tready
// Side band: m_tlast = last channel of a pixel, m_tuser[0] = last beat of the frame
// (input s_tuser[0] must mark the last beat of the frame, like conv_engine).
module axis_gdn #(
    parameter int    C          = 32,
    parameter int    LANES      = 3,
    parameter bit    INVERSE    = 1'b0,
    parameter int    X2_SHIFT   = 0,
    parameter int    LSH        = 14,
    parameter int    F          = 32,
    parameter int    QW         = 26,
    parameter int    DW         = 48,
    parameter int    NUNITS     = 5,
    parameter int    PRE        = 0,
    parameter int    M          = 65536,
    parameter int    SH         = 16,
    parameter int    X_W        = 12,
    parameter int    Y_W        = 12,
    parameter string GAMMA_FILE = "gamma.mem",       // (ceil(C/LANES)*C) words of LANES*8 bit
    parameter string BETA_FILE  = "beta.mem"         // C words, 48 bit signed hex
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic [X_W-1:0]        s_tdata,
    input  logic                  s_tvalid,
    output logic                  s_tready,
    input  logic                  s_tlast,
    input  logic [0:0]            s_tuser,
    output logic [Y_W-1:0]        m_tdata,
    output logic                  m_tvalid,
    input  logic                  m_tready,
    output logic                  m_tlast,
    output logic [0:0]            m_tuser
);
    function automatic int clog2m1(input int v);
        return (v <= 2) ? 1 : $clog2(v);
    endfunction
    localparam int G    = (C + LANES - 1) / LANES;      // passes per pixel
    localparam int CW   = clog2m1(C);
    localparam int CP   = 1 << CW;                      // slot stride in the pixel buffer
    localparam int SQW  = 2 * X_W - 1;                  // x^2 width (|x| <= 2^(X_W-1))
    localparam int AW_G = clog2m1(G * C);
    localparam int ACCW = SQW + 8 + CW + 1;
    localparam int RB   = DW / 2;
    localparam int TW   = INVERSE ? (X_W + RB + 1) : (QW + 1);
    localparam int UW   = clog2m1(NUNITS);

    // ================================================================ input + squarer
    logic [X_W-1:0]  xbuf  [2*CP];
    logic [SQW-1:0]  x2buf [2*CP];
    logic [1:0]      full;                               // slot holds a complete pixel
    logic [1:0]      flast;                              // slot is the last pixel of the frame
    logic            in_slot;
    logic [CW-1:0]   in_cnt;
    wire             in_fire = s_tvalid && s_tready;
    assign s_tready = rst_n && !full[in_slot];

    // squarer pipeline: i1 split |x| = a*64 + b, i2 partial products, i3 write
    logic               i1_v, i2_v, i1_last, i2_last, i1_fl, i2_fl, i1_slot, i2_slot;
    logic [CW-1:0]      i1_idx, i2_idx;
    logic [X_W-1:0]     i1_x, i2_x;
    logic [X_W-1:0]     i1_a;
    (* use_dsp = "no" *) logic [2*X_W-1:0] i2_hh, i2_hl, i2_ll;
    localparam int HB = X_W / 2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i1_v <= 1'b0; i2_v <= 1'b0; in_slot <= 1'b0; in_cnt <= '0;
        end else begin
            i1_v <= in_fire; i2_v <= i1_v;
            if (in_fire) begin
                if (int'(in_cnt) == C - 1) begin in_cnt <= '0; in_slot <= ~in_slot; end
                else in_cnt <= in_cnt + 1'b1;
            end
        end
    end
    always_ff @(posedge clk) begin
        i1_x <= s_tdata; i1_idx <= in_cnt; i1_slot <= in_slot;
        i1_last <= (int'(in_cnt) == C - 1); i1_fl <= s_tuser[0];
        i1_a <= s_tdata[X_W-1] ? X_W'(-$signed(s_tdata)) : s_tdata;
        i2_x <= i1_x; i2_idx <= i1_idx; i2_slot <= i1_slot; i2_last <= i1_last; i2_fl <= i1_fl;
        i2_hh <= (2*X_W)'(i1_a[X_W-1:HB]) * (2*X_W)'(i1_a[X_W-1:HB]);
        i2_hl <= (2*X_W)'(i1_a[X_W-1:HB]) * (2*X_W)'(i1_a[HB-1:0]);
        i2_ll <= (2*X_W)'(i1_a[HB-1:0])   * (2*X_W)'(i1_a[HB-1:0]);
    end
    wire [2*X_W:0] i2_sq  = ((2*X_W+1)'(i2_hh) << (2*HB)) + ((2*X_W+1)'(i2_hl) << (HB+1)) + (2*X_W+1)'(i2_ll);
    wire [2*X_W:0] i2_sqs = (X2_SHIFT > 0) ? ((i2_sq + ((2*X_W+1)'(1) << (X2_SHIFT-1))) >> X2_SHIFT) : i2_sq;
    always_ff @(posedge clk) begin
        if (i2_v) begin
            xbuf [{i2_slot, i2_idx}] <= i2_x;
            x2buf[{i2_slot, i2_idx}] <= SQW'(i2_sqs);
        end
    end

    // ================================================================ MAC
    (* rom_style = "distributed" *) logic [LANES*8-1:0] grom [G*C];
    initial $readmemh(GAMMA_FILE, grom);

    logic              mac_slot;
    logic [CW-1:0]     mj;
    logic [CW-1:0]     mbase;                            // g * LANES
    logic [AW_G-1:0]   ga;
    logic              bank_valid;
    logic              s1_v, s2_v, s3_last_v;
    logic              s1_first, s2_first, s1_last, s2_last;
    logic              s1_par, s2_par, s3_par;
    logic              s1_fl, s2_fl, s3_fl;
    logic [CW-1:0]     s1_j, s1_base, s2_base, s3_base;
    wire               m_last   = (int'(mj) == C - 1);
    wire               inflight = (s1_v && s1_last) || (s2_v && s2_last) || s3_last_v;
    wire               issue    = full[mac_slot] && !(m_last && (bank_valid || inflight));
    wire               pix_end  = issue && m_last && (int'(mbase) + LANES >= C);
    logic              mpar;                             // pass parity (x latch double buffer)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_slot <= 1'b0; mj <= '0; mbase <= '0; ga <= '0; mpar <= 1'b0;
            full <= 2'b00;
        end else begin
            if (issue) begin
                ga <= pix_end ? '0 : ga + 1'b1;
                if (m_last) begin
                    mj <= '0; mpar <= ~mpar;
                    mbase <= pix_end ? '0 : mbase + CW'(LANES);
                    if (pix_end) mac_slot <= ~mac_slot;
                end else begin
                    mj <= mj + 1'b1;
                end
            end
            for (int s = 0; s < 2; s++) begin
                if (i2_v && i2_last && i2_slot == 1'(s)) full[s] <= 1'b1;
                else if (pix_end && mac_slot == 1'(s))   full[s] <= 1'b0;
            end
        end
    end
    always_ff @(posedge clk) if (i2_v && i2_last) flast[i2_slot] <= i2_fl;

    // s1: memory reads
    logic [SQW-1:0]     s1_x2;
    logic [X_W-1:0]     s1_x;
    logic [LANES*8-1:0] s1_g;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) s1_v <= 1'b0;
        else        s1_v <= issue;
    end
    always_ff @(posedge clk) begin
        s1_x2 <= x2buf[{mac_slot, mj}];
        s1_x  <= xbuf [{mac_slot, mj}];
        s1_g  <= grom[ga];
        s1_first <= (mj == '0); s1_last <= m_last; s1_j <= mj; s1_base <= mbase;
        s1_par <= mpar; s1_fl <= flast[mac_slot] && (int'(mbase) + LANES >= C);
    end

    // x latch (double buffered by pass parity)
    logic signed [X_W-1:0] xl [2][LANES];
    always_ff @(posedge clk)
        if (s1_v)
            for (int l = 0; l < LANES; l++)
                if (s1_j == s1_base + CW'(l)) xl[s1_par][l] <= s1_x;

    // s2: products (DSP M register), s3: accumulators (DSP P register)
    logic [SQW+7:0]  s2_p  [LANES];
    logic [ACCW-1:0] acc   [LANES];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s2_v <= 1'b0; s3_last_v <= 1'b0; end
        else begin s2_v <= s1_v; s3_last_v <= s2_v && s2_last; end
    end
    always_ff @(posedge clk) begin
        s2_first <= s1_first; s2_last <= s1_last; s2_base <= s1_base; s2_par <= s1_par; s2_fl <= s1_fl;
        s3_base <= s2_base; s3_par <= s2_par; s3_fl <= s2_fl;
        for (int l = 0; l < LANES; l++) begin
            s2_p[l] <= s1_g[l*8 +: 8] * s1_x2;
            if (s2_v) acc[l] <= s2_first ? ACCW'(s2_p[l]) : acc[l] + ACCW'(s2_p[l]);
        end
    end

    // ================================================================ bank + dispatch
    logic [ACCW-1:0]       bank_acc [LANES];
    logic signed [X_W-1:0] bank_x   [LANES];
    logic [CW-1:0]         bank_base;
    logic                  bank_fl;
    logic [$clog2(LANES+1)-1:0] dp;
    (* rom_style = "distributed" *) logic [47:0] brom [C];
    initial $readmemh(BETA_FILE, brom);

    logic                  jv;
    logic [DW-1:0]         jd;
    logic signed [X_W-1:0] jx;
    logic [1:0]            jmeta;                        // {frame last, channel last}
    logic [UW-1:0]         ru, rc;
    logic [NUNITS-1:0]     u_idle, u_done, u_start, u_take;
    wire                   jtake = jv && u_idle[ru];
    wire [CW:0]            dch   = (CW+1)'(bank_base) + (CW+1)'(dp);
    wire                   dlast = (int'(dp) == LANES - 1) || (int'(dch) == C - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_valid <= 1'b0; dp <= '0; jv <= 1'b0; ru <= '0;
        end else begin
            if (s3_last_v) bank_valid <= 1'b1;
            else if (bank_valid && (!jv || jtake) && dlast) bank_valid <= 1'b0;
            if (bank_valid && (!jv || jtake)) dp <= dlast ? '0 : dp + 1'b1;
            if (bank_valid && (!jv || jtake)) jv <= 1'b1;
            else if (jtake)                   jv <= 1'b0;
            if (jtake) ru <= (int'(ru) == NUNITS - 1) ? '0 : ru + 1'b1;
        end
    end
    always_ff @(posedge clk) begin
        if (s3_last_v) begin
            for (int l = 0; l < LANES; l++) begin
                bank_acc[l] <= acc[l];
                bank_x[l]   <= xl[s3_par][l];
            end
            bank_base <= s3_base; bank_fl <= s3_fl;
        end
        if (bank_valid && (!jv || jtake)) begin
            jd    <= DW'((64'(bank_acc[dp]) + 64'($signed(brom[dch[CW-1:0]]))) << LSH);
            jx    <= bank_x[dp];
            jmeta <= {bank_fl && (int'(dch) == C - 1), int'(dch) == C - 1};
        end
    end

    // ================================================================ iterative units
    logic signed [TW-1:0] u_t    [NUNITS];
    logic [1:0]           u_meta [NUNITS];
    for (genvar u = 0; u < NUNITS; u++) begin : g_unit
        assign u_start[u] = jtake && (int'(ru) == u);
        gdn_unit #(
            .DW(DW), .XW(X_W), .INVERSE(INVERSE), .F(F), .QW(QW), .MW(2)
        ) u_unit (
            .clk(clk), .rst_n(rst_n), .start(u_start[u]), .d(jd), .x(jx), .meta_in(jmeta),
            .idle(u_idle[u]), .done(u_done[u]), .take(u_take[u]), .t(u_t[u]), .meta_out(u_meta[u])
        );
    end

    // ================================================================ collect + requant
    logic                 q1_v, q2_v, q3_v;
    logic [1:0]           q1_m, q2_m, q3_m;
    logic signed [26:0]   q1_a;
    (* use_dsp = "no" *) logic signed [44:0] q2_p;
    logic signed [44:0]   q3_p;
    wire  ce      = !m_tvalid || m_tready;
    wire  collect = ce && u_done[rc];
    for (genvar u = 0; u < NUNITS; u++) begin : g_take
        assign u_take[u] = collect && (int'(rc) == u);
    end

    function automatic logic signed [63:0] rsr(input logic signed [63:0] v, input int k);
        if (k > 0)       return (v + (64'sd1 <<< (k - 1))) >>> k;
        else if (k == 0) return v;
        else             return v <<< (-k);
    endfunction
    function automatic logic signed [63:0] satv(input logic signed [63:0] v, input int b);
        if (v > (64'sd1 <<< (b - 1)) - 1) return (64'sd1 <<< (b - 1)) - 1;
        if (v < -(64'sd1 <<< (b - 1)))    return -(64'sd1 <<< (b - 1));
        return v;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rc <= '0; q1_v <= 1'b0; q2_v <= 1'b0; q3_v <= 1'b0; m_tvalid <= 1'b0;
        end else if (ce) begin
            if (collect) rc <= (int'(rc) == NUNITS - 1) ? '0 : rc + 1'b1;
            q1_v <= collect; q2_v <= q1_v; q3_v <= q2_v; m_tvalid <= q3_v;
        end
    end
    always_ff @(posedge clk) begin
        if (ce) begin
            q1_a <= 27'(satv(rsr(64'(u_t[rc]), PRE), 27));
            q1_m <= u_meta[rc];
            q2_p <= q1_a * 45'(M);
            q2_m <= q1_m;
            q3_p <= q2_p; q3_m <= q2_m;
            m_tdata <= Y_W'(satv(rsr(64'(q3_p), SH), Y_W));
            m_tlast <= q3_m[0];
            m_tuser <= q3_m[1];
        end
    end
endmodule
