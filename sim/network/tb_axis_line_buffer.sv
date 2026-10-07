`timescale 1ns / 1ps
// Self-checking testbench for axis_line_buffer.
// Random frames in, random valid on the input and random ready on the output
// (backpressure on both sides); every output beat is compared with a reference
// window sequence computed here, including zero padding and tlast/tuser flags.
module tb_axis_line_buffer;
    parameter int    DATA_W      = 12;
    parameter int    C           = 8;
    parameter int    W           = 16;
    parameter int    H           = 10;
    parameter int    K           = 3;
    parameter int    STRIDE      = 1;
    parameter int    PAD         = 1;
    parameter int    GROUPS      = 2;
    parameter int    PACK        = 3;
    parameter string RAM_STYLE   = "block";
    parameter int    RAM_LATENCY = 2;
    parameter int    FRAMES      = 3;
    parameter int    VALID_PCT   = 70;      // probability of s_in_tvalid per cycle
    parameter int    READY_PCT   = 60;      // probability of m_out_tready per cycle
    parameter int    SEED        = 1;

    localparam int ROWS = (K > STRIDE) ? K : STRIDE;
    localparam int HO = (H + 2 * PAD - K) / STRIDE + 1;
    localparam int WO = (W + 2 * PAD - K) / STRIDE + 1;
    localparam int N_IN  = FRAMES * H * W * C;
    localparam int N_OUT = FRAMES * HO * WO * GROUPS * K * K * C;

    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;                   // 250 MHz

    logic [DATA_W-1:0] s_tdata;  logic s_tvalid, s_tready;
    logic [DATA_W-1:0] m_tdata;  logic m_tvalid, m_tready, m_tlast;  logic [2:0] m_tuser;

    axis_line_buffer #(
        .DATA_W(DATA_W), .C(C), .W(W), .H(H), .K(K), .STRIDE(STRIDE), .PAD(PAD), .ROWS(ROWS), .GROUPS(GROUPS),
        .PACK(PACK), .RAM_STYLE(RAM_STYLE), .RAM_LATENCY(RAM_LATENCY)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_in_tdata(s_tdata), .s_in_tvalid(s_tvalid), .s_in_tready(s_tready),
        .m_out_tdata(m_tdata), .m_out_tvalid(m_tvalid), .m_out_tready(m_tready),
        .m_out_tlast(m_tlast), .m_out_tuser(m_tuser)
    );

    // stimulus and reference -------------------------------------------------------
    logic [DATA_W-1:0] img [];              // FRAMES*H*W*C, NHWC per frame
    logic [DATA_W+3:0] exp_q [$];           // {last_pixel, last_group, first, last, data}

    function automatic logic [DATA_W-1:0] pix(int f, int y, int x, int c);
        return img[((f * H + y) * W + x) * C + c];
    endfunction

    initial begin
        process::self().srandom(SEED);
        img = new[N_IN];
        foreach (img[i]) img[i] = DATA_W'($urandom());
        for (int f = 0; f < FRAMES; f++)
          for (int oy = 0; oy < HO; oy++)
            for (int ox = 0; ox < WO; ox++)
              for (int g = 0; g < GROUPS; g++)
                for (int ky = 0; ky < K; ky++)
                  for (int kx = 0; kx < K; kx++)
                    for (int c = 0; c < C; c++) begin
                        int iy, ix; logic [DATA_W-1:0] v;
                        iy = oy * STRIDE - PAD + ky;
                        ix = ox * STRIDE - PAD + kx;
                        v  = (iy < 0 || iy >= H || ix < 0 || ix >= W) ? '0 : pix(f, iy, ix, c);
                        exp_q.push_back({ox == WO - 1 && oy == HO - 1, g == GROUPS - 1,
                                         ky == 0 && kx == 0 && c == 0,
                                         ky == K - 1 && kx == K - 1 && c == C - 1, v});
                    end
    end

    // input driver
    int in_idx = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_tvalid <= 1'b0;
        end else begin
            if (s_tvalid && s_tready) in_idx = in_idx + 1;
            if (!s_tvalid || s_tready) begin                  // data must stay stable while stalled
                if (in_idx < N_IN && $urandom_range(99) < VALID_PCT) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= img[in_idx];
                end else begin
                    s_tvalid <= 1'b0;
                end
            end
        end
    end

    // output checker
    int out_idx = 0, errors = 0, stall_in = 0, stall_out = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_tready <= 1'b0;
        end else begin
            if (s_tvalid && !s_tready) stall_in++;
            if (m_tvalid && !m_tready) stall_out++;
            if (m_tvalid && m_tready) begin
                logic [DATA_W+3:0] e;
                e = exp_q.pop_front();
                if ({m_tuser, m_tlast, m_tdata} !== e) begin
                    if (errors < 10)
                        $display("MISMATCH at beat %0d: got data=%h last=%b user=%b, expected data=%h last=%b user=%b",
                                 out_idx, m_tdata, m_tlast, m_tuser, e[DATA_W-1:0], e[DATA_W], e[DATA_W+3:DATA_W+1]);
                    errors++;
                end
                out_idx++;
            end
            m_tready <= ($urandom_range(99) < READY_PCT);
        end
    end

    initial begin
        s_tvalid = 0; s_tdata = '0; m_tready = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        fork
            wait (out_idx == N_OUT);
            begin
                repeat (N_OUT * 8 + N_IN * 8 + 10000) @(posedge clk);
                $display("TIMEOUT: in %0d/%0d, out %0d/%0d", in_idx, N_IN, out_idx, N_OUT);
            end
        join_any
        repeat (20) @(posedge clk);
        if (m_tvalid) begin $display("ERROR: extra output beats"); errors++; end
        if (out_idx == N_OUT && errors == 0)
            $display("PASS  C=%0d W=%0d H=%0d K=%0d S=%0d G=%0d PACK=%0d %s: %0d in, %0d out beats, input stalled %0d cycles by backpressure, output stalled %0d",
                     C, W, H, K, STRIDE, GROUPS, PACK, RAM_STYLE, N_IN, N_OUT, stall_in, stall_out);
        else
            $display("FAIL  C=%0d W=%0d H=%0d PACK=%0d: %0d errors, %0d/%0d beats", C, W, H, PACK, errors, out_idx, N_OUT);
        $finish;
    end
endmodule
