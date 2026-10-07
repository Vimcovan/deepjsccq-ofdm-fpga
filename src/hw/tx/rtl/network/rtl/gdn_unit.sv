`timescale 1ns / 1ps
// Iterative GDN / IGDN post-processing unit (no DSP, no table):
//     r = isqrt(D)                          restoring square root, 2 bits per cycle
//     GDN : t = sign(x) * floor(|x| * 2^F / r)   restoring division, QW quotient bits
//     IGDN: t = x * r                             shift-add, XW cycles
// Latency: 1 + DW/2 + (INVERSE ? XW : QW) cycles, then the result is held (done = 1)
// until take.  idle is high when a new start is accepted.
module gdn_unit #(
    parameter int DW      = 48,          // D width (even)
    parameter int XW      = 12,          // x width (signed); |x| <= 2^(XW-1) fits in XW bits
    parameter bit INVERSE = 1'b0,
    parameter int F       = 32,          // GDN numerator shift
    parameter int QW      = 26,          // GDN quotient bits: |x|*2^F / r < 2^QW guaranteed
    parameter int MW      = 2,           // meta width carried with the job
    localparam int RB     = DW / 2,      // root bits
    localparam int TW     = INVERSE ? (XW + RB + 1) : (QW + 1)
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 start,
    input  logic [DW-1:0]        d,
    input  logic signed [XW-1:0] x,
    input  logic [MW-1:0]        meta_in,
    output logic                 idle,
    output logic                 done,
    input  logic                 take,
    output logic signed [TW-1:0] t,
    output logic [MW-1:0]        meta_out
);
    localparam int NW  = XW + F;                         // numerator width (GDN)
    localparam int CNW = $clog2(RB + QW + XW + 2);

    typedef enum logic [1:0] {S_IDLE, S_SQRT, S_POST, S_DONE} st_t;
    st_t            st;
    logic [CNW-1:0] cnt;
    logic [DW-1:0]  dsh;                                 // radicand, consumed 2 bits per cycle
    logic [RB:0]    rem;                                 // sqrt remainder (<= 2*root)
    logic [RB-1:0]  root;
    logic           neg;
    logic [XW-1:0]  xa;                                  // |x|

    assign idle = (st == S_IDLE);
    assign done = (st == S_DONE);

    // square-root step
    wire  [RB+2:0] s_rem2  = {rem, dsh[DW-1 -: 2]};
    wire  [RB+2:0] s_trial = {1'b0, root, 2'b01};
    wire           s_ge    = (s_rem2 >= s_trial);
    wire  [RB+2:0] s_diff  = s_rem2 - s_trial;

    generate if (!INVERSE) begin : g_div
        // restoring division of |x| << F by root; quotient bits QW
        logic [RB:0]    drem;                            // < root
        logic [QW-1:0]  nsh;                             // low QW numerator bits, MSB first
        logic [QW-1:0]  q;
        wire  [RB+1:0]  d_rem2 = {drem, nsh[QW-1]};
        wire            d_ge   = (d_rem2 >= {2'b00, root});
        wire  [RB+1:0]  d_diff = d_rem2 - {2'b00, root};
        wire  [NW-1:0]  num    = NW'(xa) << F;
        always_ff @(posedge clk) begin
            if (st == S_SQRT && int'(cnt) == RB - 1) begin
                drem <= (RB + 1)'(num >> QW);
                nsh  <= num[QW-1:0];
            end else if (st == S_POST) begin
                drem <= d_ge ? d_diff[RB:0] : d_rem2[RB:0];
                nsh  <= nsh << 1;
                q    <= {q[QW-2:0], d_ge};
            end
        end
        assign t = neg ? -$signed({1'b0, q}) : $signed({1'b0, q});
    end else begin : g_mul
        // |x| * root, MSB first shift-add
        logic [XW+RB-1:0] acc;
        logic [XW-1:0]    xsh;
        always_ff @(posedge clk) begin
            if (st == S_SQRT && int'(cnt) == RB - 1) begin
                acc <= '0;
                xsh <= xa;
            end else if (st == S_POST) begin
                acc <= (acc << 1) + (xsh[XW-1] ? (XW + RB)'(root) : '0);
                xsh <= xsh << 1;
            end
        end
        assign t = neg ? -$signed({1'b0, acc}) : $signed({1'b0, acc});
    end endgenerate

    localparam int NPOST = INVERSE ? XW : QW;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; cnt <= '0;
        end else begin
            case (st)
                S_IDLE: if (start) begin st <= S_SQRT; cnt <= '0; end
                S_SQRT: if (int'(cnt) == RB - 1) begin st <= S_POST; cnt <= '0; end
                        else cnt <= cnt + 1'b1;
                S_POST: if (int'(cnt) == NPOST - 1) st <= S_DONE;
                        else cnt <= cnt + 1'b1;
                S_DONE: if (take) st <= S_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (st == S_IDLE && start) begin
            dsh      <= d;
            rem      <= '0;
            root     <= '0;
            neg      <= x[XW-1];
            xa       <= x[XW-1] ? XW'(-x) : XW'(x);
            meta_out <= meta_in;
        end else if (st == S_SQRT) begin
            dsh  <= dsh << 2;
            rem  <= s_ge ? s_diff[RB:0] : s_rem2[RB:0];
            root <= {root[RB-2:0], s_ge};
        end
    end

    // synthesis translate_off
`ifndef DISABLE_GDN_ASSERT
    always_ff @(posedge clk)
        if (!INVERSE && st == S_SQRT && int'(cnt) == RB - 1)
            assert (((NW'(xa) << F) >> QW) < {root[RB-2:0], s_ge})
                else $error("gdn_unit: quotient exceeds QW bits");
`endif
    // synthesis translate_on
endmodule
