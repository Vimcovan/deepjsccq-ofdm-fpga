`timescale 1ns / 1ps
// axis_gdn against the golden vectors: golden input tensor streamed in NHWC with random
// valid, output taken with random ready, every element and flag compared.
module tb_gdn;
    parameter int    H        = 128;
    parameter int    W        = 128;
    parameter int    C        = 32;
    parameter int    LANES    = 3;
    parameter int    INVERSE  = 0;
    parameter int    X2_SHIFT = 0;
    parameter int    LSH      = 14;
    parameter int    F        = 32;
    parameter int    QW       = 25;
    parameter int    DW       = 46;
    parameter int    NUNITS   = 5;
    parameter int    PRE      = 0;
    parameter int    M        = 65536;
    parameter int    SH       = 16;
    parameter string INIT_DIR = "";
    parameter string IN_FILE  = "";
    parameter string OUT_FILE = "";
    parameter int    VALID_PCT = 90;
    parameter int    READY_PCT = 80;
    parameter int    SEED      = 7;

    localparam int N = H * W * C;
    localparam longint MAX_CYCLES = longint'(N) * 64 + 100000;
    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;

    logic [11:0] in_mem [N];
    logic [11:0] exp_mem [N];
    initial begin $readmemh(IN_FILE, in_mem); $readmemh(OUT_FILE, exp_mem); end

    logic [11:0] s_tdata; logic s_tvalid, s_tready, s_tlast; logic [0:0] s_tuser;
    logic [11:0] m_tdata; logic m_tvalid, m_tready, m_tlast; logic [0:0] m_tuser;

    axis_gdn #(
        .C(C), .LANES(LANES), .INVERSE(INVERSE), .X2_SHIFT(X2_SHIFT), .LSH(LSH), .F(F), .QW(QW),
        .DW(DW), .NUNITS(NUNITS), .PRE(PRE), .M(M), .SH(SH),
        .GAMMA_FILE({INIT_DIR, "/gamma.mem"}), .BETA_FILE({INIT_DIR, "/beta.mem"})
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast), .s_tuser(s_tuser),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast), .m_tuser(m_tuser)
    );

    int in_idx = 0;
    always @(posedge clk) begin
        if (!rst_n) s_tvalid <= 1'b0;
        else begin
            if (s_tvalid && s_tready) in_idx = in_idx + 1;
            if (!s_tvalid || s_tready) begin
                if (in_idx < N && $urandom_range(99) < VALID_PCT) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= in_mem[in_idx];
                    s_tlast  <= (in_idx % C == C - 1);
                    s_tuser  <= (in_idx == N - 1);
                end else s_tvalid <= 1'b0;
            end
        end
    end

    int out_idx = 0, errors = 0, flag_errors = 0;
    longint cycles = 0;
    always @(posedge clk) begin
        if (!rst_n) m_tready <= 1'b0;
        else begin
            cycles++;
            if (m_tvalid && m_tready) begin
                if (out_idx >= N || m_tdata !== exp_mem[out_idx]) begin
                    if (errors < 10)
                        $display("MISMATCH pixel %0d ch %0d: in %h got %h expected %h", out_idx / C, out_idx % C,
                                 in_mem[out_idx], m_tdata, exp_mem[out_idx]);
                    errors++;
                end
                if (m_tlast !== (out_idx % C == C - 1) || m_tuser[0] !== (out_idx == N - 1)) flag_errors++;
                out_idx++;
            end
            m_tready <= ($urandom_range(99) < READY_PCT);
        end
    end

    initial begin
        process::self().srandom(SEED);
        s_tvalid = 0; s_tdata = '0; s_tlast = 0; s_tuser = 0; m_tready = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        while (out_idx < N && cycles < MAX_CYCLES) @(posedge clk);
        repeat (100) @(posedge clk);
        if (m_tvalid) begin $display("ERROR: extra output beats"); errors++; end
        if (out_idx == N && errors == 0 && flag_errors == 0)
            $display("PASS  %0dx%0dx%0d %s: %0d outputs bit-exact, %0d cycles (%.3f cycles/pixel)",
                     H, W, C, INVERSE ? "IGDN" : "GDN", N, cycles, real'(cycles) / (H * W));
        else
            $display("FAIL  %0d data errors, %0d flag errors, %0d/%0d outputs, %0d cycles", errors, flag_errors, out_idx, N, cycles);
        $finish;
    end
endmodule
