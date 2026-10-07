`timescale 1ns / 1ps
// Attention gate, bit-exact with golden_np:  y = sat( rsr(x*MA + rsr(a*g, 16)*MB, SH) )
//   x : block input (identity path), a : trunk branch output, g : sigmoid (Q0.16, 17 bit)
// a*g uses the radix-4 serial LUT multiplier (9 cycles); MA, MB are constant LUT multipliers.
// One element every ~14 cycles.  Side band is taken from a.
module axis_gate #(
    parameter int X_W = 12,
    parameter int Y_W = 12,
    parameter int MA  = 65536,
    parameter int MB  = 65536,
    parameter int SH  = 16,
    parameter int U_W = 1
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic signed [X_W-1:0] x_tdata,
    input  logic                  x_tvalid,
    output logic                  x_tready,
    input  logic signed [X_W-1:0] a_tdata,
    input  logic                  a_tvalid,
    output logic                  a_tready,
    input  logic                  a_tlast,
    input  logic [U_W-1:0]        a_tuser,
    input  logic [16:0]           g_tdata,
    input  logic                  g_tvalid,
    output logic                  g_tready,
    output logic signed [Y_W-1:0] m_tdata,
    output logic                  m_tvalid,
    input  logic                  m_tready,
    output logic                  m_tlast,
    output logic [U_W-1:0]        m_tuser
);
    typedef enum logic [2:0] {S_IDLE, S_WAIT, S_T, S_MUL, S_SUM, S_OUT} st_t;
    st_t st;
    wire fire = (st == S_IDLE) && x_tvalid && a_tvalid && g_tvalid;
    assign x_tready = fire;
    assign a_tready = fire;
    assign g_tready = fire;
    assign m_tvalid = (st == S_OUT);

    logic                     m_busy, m_done;
    logic signed [X_W+17:0]   m_p;
    mul_serial #(.AW(X_W), .BW(17)) u_mul (
        .clk(clk), .rst_n(rst_n), .start(fire), .a(a_tdata), .b(g_tdata),
        .busy(m_busy), .done(m_done), .p(m_p)
    );

    logic signed [X_W-1:0]  xr;
    logic signed [X_W+1:0]  t;
    (* use_dsp = "no" *) logic signed [X_W+18:0] px, pt;
    logic signed [X_W+19:0] s;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else case (st)
            S_IDLE: if (fire) st <= S_WAIT;
            S_WAIT: if (m_done) st <= S_T;
            S_T:    st <= S_MUL;
            S_MUL:  st <= S_SUM;
            S_SUM:  st <= S_OUT;
            S_OUT:  if (m_tready) st <= S_IDLE;
            default: st <= S_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        case (st)
            S_IDLE: if (fire) begin xr <= x_tdata; m_tlast <= a_tlast; m_tuser <= a_tuser; end
            S_WAIT: if (m_done) t <= (X_W+2)'((m_p + (1 <<< 15)) >>> 16);
            S_T:    begin px <= xr * (X_W+19)'(MA); pt <= t * (X_W+19)'(MB); end
            S_MUL:  s <= (X_W+20)'(px) + (X_W+20)'(pt);
            S_SUM: begin
                logic signed [X_W+19:0] y;
                y = (s + ((X_W+20)'(1) <<< (SH - 1))) >>> SH;
                if (y > (1 <<< (Y_W - 1)) - 1)   m_tdata <= Y_W'((1 <<< (Y_W - 1)) - 1);
                else if (y < -(1 <<< (Y_W - 1))) m_tdata <= Y_W'(-(1 <<< (Y_W - 1)));
                else                             m_tdata <= Y_W'(y);
            end
            default: ;
        endcase
    end
endmodule
