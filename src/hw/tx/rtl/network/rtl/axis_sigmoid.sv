`timescale 1ns / 1ps
// Piecewise-linear sigmoid (no BRAM table, no DSP), bit-exact with golden_np.sigmoid_q16:
//   u = |z|,  v = rsr(u * M312, SH312)                      (Q3.12, constant multiplier in LUT)
//   big = v >= 2^15,  v = min(v, 2^15 - 1),  seg = v >> OB,  off = v & (2^OB - 1)
//   g = clip(c0[seg] + rsr(c1[seg] * off, SHIFT), 0, 65536);  g = big ? 65536 : g
//   g = z < 0 ? 65536 - g : g                                (Q0.16, 17 bit unsigned)
// OUT8 = 1 (network output): y = clamp(rsr(g * 255, 16), 0, 255), 8 bit.
// c1*off uses the radix-4 serial LUT multiplier; one element every ~12 cycles.
module axis_sigmoid #(
    parameter int    X_W     = 12,
    parameter int    M312    = 65536,
    parameter int    SH312   = 12,
    parameter int    NSEG    = 32,
    parameter int    OB      = 10,             // offset bits
    parameter int    SHIFT   = 15,
    parameter string C0_FILE = "c0.mem",       // NSEG x 17 bit unsigned
    parameter string C1_FILE = "c1.mem",       // NSEG x 17 bit unsigned
    parameter bit    OUT8    = 1'b0,
    parameter int    U_W     = 1,
    localparam int   Y_W     = OUT8 ? 8 : 17
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic signed [X_W-1:0] s_tdata,
    input  logic                 s_tvalid,
    output logic                 s_tready,
    input  logic                 s_tlast,
    input  logic [U_W-1:0]       s_tuser,
    output logic [Y_W-1:0]       m_tdata,
    output logic                 m_tvalid,
    input  logic                 m_tready,
    output logic                 m_tlast,
    output logic [U_W-1:0]       m_tuser
);
    localparam int SW = $clog2(NSEG);
    (* rom_style = "distributed" *) logic [16:0] c0rom [NSEG];
    (* rom_style = "distributed" *) logic [16:0] c1rom [NSEG];
    initial begin $readmemh(C0_FILE, c0rom); $readmemh(C1_FILE, c1rom); end

    typedef enum logic [2:0] {S_IDLE, S_MUL, S_SEG, S_ROM, S_WAIT, S_SUM, S_OUT} st_t;
    st_t st;
    logic                 neg, big;
    logic [X_W-1:0]       u;
    (* use_dsp = "no" *) logic [X_W+17-1:0] v1;
    logic [SW-1:0]        seg;
    logic [OB-1:0]        off;
    logic [16:0]          c0r;
    logic signed [18:0]   gq;
    logic                 m_start, m_busy, m_done;
    logic signed [17+OB+1:0] m_p;

    mul_serial #(.AW(18), .BW(OB)) u_mul (
        .clk(clk), .rst_n(rst_n), .start(m_start), .a(18'(c1rom[seg])), .b(off),
        .busy(m_busy), .done(m_done), .p(m_p)
    );
    assign m_start  = (st == S_ROM);
    assign s_tready = rst_n && (st == S_IDLE);
    assign m_tvalid = (st == S_OUT);

    // v = rsr(v1, SH312)
    wire [X_W+17-1:0] v   = (SH312 > 0) ? ((v1 + ((X_W+17)'(1) << (SH312 - 1))) >> SH312) : v1;
    wire              vbg = (v >= (X_W+17)'(1 << 15));
    wire [14:0]       vc  = vbg ? 15'h7FFF : v[14:0];
    wire signed [19:0] gfull = (gq < 0) ? 20'sd0 : (gq > 19'sd65536) ? 20'sd65536 : 20'(gq);
    wire [16:0]       g0   = big ? 17'd65536 : 17'(gfull);
    wire [16:0]       g    = neg ? 17'(17'd65536 - g0) : g0;
    wire [25:0]       g255 = (26'(g) << 8) - 26'(g) + 26'd32768;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else case (st)
            S_IDLE: if (s_tvalid) st <= S_MUL;
            S_MUL:  st <= S_SEG;
            S_SEG:  st <= S_ROM;
            S_ROM:  st <= S_WAIT;
            S_WAIT: if (m_done) st <= S_SUM;
            S_SUM:  st <= S_OUT;
            S_OUT:  if (m_tready) st <= S_IDLE;
            default: st <= S_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        case (st)
            S_IDLE: if (s_tvalid) begin
                neg <= s_tdata[X_W-1];
                u   <= s_tdata[X_W-1] ? X_W'(-s_tdata) : X_W'(s_tdata);
                m_tlast <= s_tlast; m_tuser <= s_tuser;
            end
            S_MUL:  v1 <= (X_W+17)'(u) * (X_W+17)'(M312);
            S_SEG:  begin big <= vbg; seg <= SW'(vc >> OB); off <= vc[OB-1:0]; end
            S_ROM:  c0r <= c0rom[seg];
            S_WAIT: if (m_done)
                        gq <= 19'($signed({1'b0, c0r})) + 19'((m_p + (1 <<< (SHIFT - 1))) >>> SHIFT);
            S_SUM:  m_tdata <= OUT8 ? Y_W'(g255 >> 16) : Y_W'(g);
            default: ;
        endcase
    end
endmodule
