`timescale 1ns / 1ps
// Check of a generated block top (gen_rtl_top.py, module name given by +define+BLK=<module>)
// against the golden vectors: input tensor streamed with random valid, output taken with
// random ready, every element and flag compared.  Frames are streamed back to back
// (NFRAMES) to check that the pipeline also works across frame boundaries.
`ifndef BLK
`define BLK blk_enc_3
`endif
module tb_top;
    parameter int    H = 64, W = 64, CIN = 32, HO = 64, WO = 64, COUT = 32, OUT_W = 12, IN_W = 12;
    parameter int    IN_ELEMS = 0, OUT_ELEMS = 0;
    parameter string IN_FILE = "", OUT_FILE = "";
    parameter int    VALID_PCT = 90, READY_PCT = 80, SEED = 7, NFRAMES = 1;
    parameter longint MAX_CYCLES = 64'd60_000_000;

    localparam int N_IN = (IN_ELEMS > 0) ? IN_ELEMS : H * W * CIN;
    localparam int N_OUT = (OUT_ELEMS > 0) ? OUT_ELEMS : HO * WO * COUT;
    localparam bit IN_SYMBOL = (IN_W == 24);
    localparam bit OUT_SYMBOL = (OUT_W == 24);
    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;

    logic [IN_W-1:0] in_mem  [N_IN];
    logic [OUT_W-1:0] exp_mem [N_OUT];
    initial begin
        $readmemh(IN_FILE, in_mem);
        $readmemh(OUT_FILE, exp_mem);
    end

    logic [IN_W-1:0] s_tdata; logic s_tvalid, s_tready, s_tlast; logic [0:0] s_tuser;
    logic [OUT_W-1:0] m_tdata; logic m_tvalid, m_tready, m_tlast; logic [0:0] m_tuser;

    `BLK dut (
        .clk(clk), .rst_n(rst_n),
        .s_in_tdata(s_tdata), .s_in_tvalid(s_tvalid), .s_in_tready(s_tready),
        .s_in_tlast(s_tlast), .s_in_tuser(s_tuser),
        .m_out_tdata(m_tdata), .m_out_tvalid(m_tvalid), .m_out_tready(m_tready),
        .m_out_tlast(m_tlast), .m_out_tuser(m_tuser)
    );

    int in_idx = 0;
    always @(posedge clk) begin
        if (!rst_n) s_tvalid <= 1'b0;
        else begin
            if (s_tvalid && s_tready) in_idx = in_idx + 1;
            if (!s_tvalid || s_tready) begin
                if (in_idx < N_IN * NFRAMES && $urandom_range(99) < VALID_PCT) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= in_mem[in_idx % N_IN];
                    s_tlast  <= IN_SYMBOL && ((in_idx % N_IN) == N_IN - 1);
                    s_tuser  <= IN_SYMBOL && ((in_idx % N_IN) == N_IN - 1);
                end else s_tvalid <= 1'b0;
            end
        end
    end

    int out_idx = 0, errors = 0, flag_errors = 0;
    longint cycles = 0, frame_end[NFRAMES];
    always @(posedge clk) begin
        if (!rst_n) m_tready <= 1'b0;
        else begin
            cycles++;
            if (m_tvalid && m_tready) begin
                int k;
                bit exp_last, exp_user;
                k = out_idx % N_OUT;
                exp_last = OUT_SYMBOL ? (k == N_OUT - 1) : (k % COUT == COUT - 1);
                exp_user = (k == N_OUT - 1);
                if (out_idx >= N_OUT * NFRAMES || m_tdata !== exp_mem[k][OUT_W-1:0]) begin
                    if (errors < 10)
                        $display("MISMATCH frame %0d pixel (%0d,%0d) ch %0d: got %h expected %h", out_idx / N_OUT,
                                 k / COUT / WO, k / COUT % WO, k % COUT, m_tdata, exp_mem[k][OUT_W-1:0]);
                    errors++;
                end
                if (m_tlast !== exp_last || m_tuser[0] !== exp_user) flag_errors++;
                if (k == N_OUT - 1) frame_end[out_idx / N_OUT] = cycles;
                out_idx++;
            end
            m_tready <= ($urandom_range(99) < READY_PCT);
        end
    end

    // Sample after posedge counters have settled; avoid races in progress reporting.
    always @(negedge clk)
        if (rst_n && cycles % 100_000 == 0 && cycles > 0)
            $display("  %0d cycles: in %0d/%0d out %0d/%0d", cycles, in_idx, N_IN * NFRAMES, out_idx, N_OUT * NFRAMES);

    initial begin
        process::self().srandom(SEED);
        s_tvalid = 0; s_tdata = '0; s_tlast = 0; s_tuser = '0; m_tready = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        while (out_idx < N_OUT * NFRAMES && cycles < MAX_CYCLES) @(posedge clk);
        if (out_idx < N_OUT * NFRAMES)
            $display("TIMEOUT after %0d cycles: in %0d/%0d, out %0d/%0d", cycles, in_idx, N_IN * NFRAMES,
                     out_idx, N_OUT * NFRAMES);
        repeat (200) @(posedge clk);
        if (m_tvalid) begin $display("ERROR: extra output beats"); errors++; end
        for (int f = 0; f < NFRAMES; f++) $display("frame %0d done at cycle %0d", f, frame_end[f]);
        if (out_idx == N_OUT * NFRAMES && errors == 0 && flag_errors == 0)
            $display("PASS  %0dx%0dx%0d -> %0dx%0dx%0d: %0d frame(s) bit-exact, %0d cycles",
                     H, W, CIN, HO, WO, COUT, NFRAMES, cycles);
        else
            $display("FAIL  %0d data errors, %0d flag errors, %0d/%0d outputs", errors, flag_errors,
                     out_idx, N_OUT * NFRAMES);
        $finish;
    end

endmodule

