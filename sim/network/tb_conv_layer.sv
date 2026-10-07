`timescale 1ns / 1ps
// Layer-level check of axis_line_buffer -> conv_engine against the exported golden vectors.
// The golden input tensor (NHWC) is streamed in with random valid, the output is taken with
// random ready and every element is compared with the golden output tensor of the layer.
module tb_conv_layer;
    parameter int    H          = 64;
    parameter int    W          = 64;
    parameter int    CIN        = 32;
    parameter int    COUT       = 32;
    parameter int    K          = 3;
    parameter int    STRIDE     = 1;
    parameter int    PAD        = 1;
    parameter int    P          = 8;
    parameter string ACT        = "none";
    parameter string ACT2       = "none";
    parameter int    ACT_SPLIT  = COUT;
    parameter string WROM_STYLE = "block";
    parameter int    WROM_BANK_DEPTH = 0;
    parameter string RQ_MUL     = "dsp";
    parameter string WROM_MODE  = "direct";
    parameter int    WG_NCOL    = 1;
    parameter int    PRE        = 0;
    parameter int    SH_MIN     = 1;
    parameter int    SH_BITS    = 4;
    parameter string INIT_DIR   = "";       // <export>/rtl_init/<engine>
    parameter string IN_FILE    = "";       // golden input tensor (NHWC)
    parameter string OUT_FILE   = "";       // golden output tensor (NHWC)
    parameter string OUT_FILE2  = "";       // merged engines: golden tensor of channels >= ACT_SPLIT
    parameter int    LB_PACK    = 3;
    parameter int    VALID_PCT  = 90;
    parameter int    READY_PCT  = 80;
    parameter int    SEED       = 7;

    localparam int GROUPS = (COUT + P - 1) / P;
    localparam int HO     = (H + 2 * PAD - K) / STRIDE + 1;
    localparam int WO     = (W + 2 * PAD - K) / STRIDE + 1;
    localparam int N_IN   = H * W * CIN;
    localparam int N_OUT  = HO * WO * COUT;
    localparam int ROWS   = (K > STRIDE) ? K : STRIDE;
    localparam longint MAX_CYCLES = 64'(HO) * WO * GROUPS * K * K * CIN * 4 + 64'(N_IN) * 4 + 200000;

    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;

    logic [11:0] in_mem  [N_IN];
    localparam int C1 = (OUT_FILE2 == "") ? COUT : ACT_SPLIT;   // channels in OUT_FILE
    localparam int C2 = COUT - C1;                               // channels in OUT_FILE2
    logic [11:0] exp1 [HO * WO * C1];
    logic [11:0] exp2 [HO * WO * (C2 > 0 ? C2 : 1)];
    initial begin
        $readmemh(IN_FILE, in_mem);
        $readmemh(OUT_FILE, exp1);
        if (C2 > 0) $readmemh(OUT_FILE2, exp2);
    end
    function automatic logic [11:0] expected(int pix, int co);
        return (co < C1) ? exp1[pix * C1 + co] : exp2[pix * C2 + co - C1];
    endfunction

    // DUT: line buffer -> conv engine
    logic [11:0] s_tdata;  logic s_tvalid, s_tready;
    logic [11:0] w_tdata;  logic w_tvalid, w_tready, w_tlast;  logic [2:0] w_tuser;
    logic [11:0] m_tdata;  logic m_tvalid, m_tready, m_tlast;  logic [0:0] m_tuser;

    axis_line_buffer #(
        .DATA_W(12), .C(CIN), .W(W), .H(H), .K(K), .STRIDE(STRIDE), .PAD(PAD), .ROWS(ROWS),
        .GROUPS(GROUPS), .PACK(LB_PACK), .RAM_STYLE("block")
    ) u_lb (
        .clk(clk), .rst_n(rst_n),
        .s_in_tdata(s_tdata), .s_in_tvalid(s_tvalid), .s_in_tready(s_tready),
        .m_out_tdata(w_tdata), .m_out_tvalid(w_tvalid), .m_out_tready(w_tready),
        .m_out_tlast(w_tlast), .m_out_tuser(w_tuser)
    );

    conv_engine #(
        .CIN(CIN), .COUT(COUT), .K(K), .P(P), .ACT(ACT), .ACT2(ACT2), .ACT_SPLIT(ACT_SPLIT),
        .WROM_PREFIX({INIT_DIR, "/wrom"}), .WROM_STYLE(WROM_STYLE), .WROM_BANK_DEPTH(WROM_BANK_DEPTH), .RQ_MUL(RQ_MUL), .WROM_MODE(WROM_MODE), .WG_NCOL(WG_NCOL), .PRE(PRE), .SH_MIN(SH_MIN), .SH_BITS(SH_BITS),
        .BIAS_FILE({INIT_DIR, "/bias.mem"}), .PRE_FILE({INIT_DIR, "/pre.mem"}),
        .M_FILE({INIT_DIR, "/M.mem"}), .SH_FILE({INIT_DIR, "/sh.mem"})
    ) u_conv (
        .clk(clk), .rst_n(rst_n),
        .s_in_tdata(w_tdata), .s_in_tvalid(w_tvalid), .s_in_tready(w_tready),
        .s_in_tlast(w_tlast), .s_in_tuser(w_tuser),
        .m_out_tdata(m_tdata), .m_out_tvalid(m_tvalid), .m_out_tready(m_tready),
        .m_out_tlast(m_tlast), .m_out_tuser(m_tuser)
    );

    // input driver
    int in_idx = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_tvalid <= 1'b0;
        end else begin
            if (s_tvalid && s_tready) in_idx = in_idx + 1;
            if (!s_tvalid || s_tready) begin
                if (in_idx < N_IN && $urandom_range(99) < VALID_PCT) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= in_mem[in_idx];
                end else begin
                    s_tvalid <= 1'b0;
                end
            end
        end
    end

    // output checker
    int out_idx = 0, errors = 0, flag_errors = 0;
    longint cycles = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_tready <= 1'b0;
        end else begin
            cycles++;
            if (m_tvalid && m_tready) begin
                int co, pix;
                co  = out_idx % COUT;
                pix = out_idx / COUT;
                if (pix >= HO * WO || m_tdata !== expected(pix, co)) begin
                    if (errors < 10)
                        $display("MISMATCH pixel (%0d,%0d) ch %0d: got %h expected %h",
                                 pix / WO, pix % WO, co, m_tdata, expected(pix, co));
                    errors++;
                end
                if (m_tlast !== (co == COUT - 1) || m_tuser[0] !== (co == COUT - 1 && pix == HO * WO - 1))
                    flag_errors++;
                out_idx++;
            end
            m_tready <= ($urandom_range(99) < READY_PCT);
        end
    end

    initial begin
        process::self().srandom(SEED);
        $display("TB params: ACT=[%s] (len %0d) WROM_STYLE=[%s] INIT_DIR=[%s]", ACT, ACT.len(), WROM_STYLE, INIT_DIR);
        s_tvalid = 0; s_tdata = '0; m_tready = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        // generous bound: every output pixel needs GROUPS*K*K*CIN cycles at full rate
        while (out_idx < N_OUT && cycles < MAX_CYCLES) @(posedge clk);
        if (out_idx < N_OUT)
            $display("TIMEOUT after %0d cycles: in %0d/%0d, out %0d/%0d", cycles, in_idx, N_IN, out_idx, N_OUT);
        repeat (50) @(posedge clk);
        if (m_tvalid) begin $display("ERROR: extra output beats"); errors++; end
        if (out_idx == N_OUT && errors == 0 && flag_errors == 0)
            $display("PASS  %0dx%0dx%0d -> %0dx%0dx%0d K=%0d S=%0d P=%0d %s: %0d outputs bit-exact, %0d cycles (%.2f outputs/cycle)",
                     H, W, CIN, HO, WO, COUT, K, STRIDE, P, ACT, N_OUT, cycles, real'(N_OUT) / cycles);
        else
            $display("FAIL  %0d data errors, %0d flag errors, %0d/%0d outputs", errors, flag_errors, out_idx, N_OUT);
        $finish;
    end
endmodule
