`timescale 1ns / 1ps
// ---------------------------------------------------------------------------------
// weight_stream
//
// Endless sequential stream of P-byte weight vectors (vector v = lanes 0..P-1, lane 0 in
// the LSBs) read from a densely packed ROM through a byte gearbox.  The weight ROM of a
// conv engine is only ever read sequentially (address 0 .. NVEC-1, then again), so its
// storage shape is independent of P: bytes are packed back to back into NCOL columns of
// 32 bit (4 weights), one 512x32 block per column (a BRAM18 in 512x36 mode).
//
//   stream byte j  ->  word j / (4*NCOL), column (j % (4*NCOL)) / 4, byte j % 4
//   ND = ceil(NVEC*P / (4*NCOL)) words (<= 512); the tail of the last word is padding and
//   is dropped when vector NVEC-1 is emitted.
//
// Gearbox: ROM words enter a small word FIFO; a residue window (< P + WB bytes) appends
// a word only when it holds fewer than P bytes (P possible append offsets), the vector is
// always the first P bytes and the window then shifts by the constant P bytes.
// Requires WB = 4*NCOL >= P so that one vector per cycle can be sustained.
// Column files: <INIT_PREFIX>_c<i>.mem (i = 0..9), ND lines of 8 hex digits.
// ---------------------------------------------------------------------------------
module weight_stream #(
    parameter int    P           = 7,
    parameter int    NVEC        = 1440,      // vectors per stream period (GROUPS*K*K*CIN)
    parameter int    NCOL        = 5,         // 32-bit ROM columns
    parameter string INIT_PREFIX = "",
    parameter int    ROM_LATENCY = 2
) (
    input  logic             clk,
    input  logic             rst_n,
    output logic [P*8-1:0]   m_tdata,
    output logic             m_tvalid,
    input  logic             m_tready
);
    localparam int WB    = 4 * NCOL;                       // bytes per ROM word
    localparam int ND    = (NVEC * P + WB - 1) / WB;       // ROM words
    localparam int WINB  = P - 1 + WB;                      // residue window bytes
    localparam int FD    = 4;                               // word FIFO depth
    localparam int AWD   = $clog2(ND > 1 ? ND : 2);

    initial begin
        assert (WB >= P) else $fatal(1, "weight_stream: need 4*NCOL >= P");
        assert (ND <= 512) else $fatal(1, "weight_stream: more than 512 words per column");
        assert (NCOL <= 10) else $fatal(1, "weight_stream: at most 10 columns");
    end

    // ------------------------------------------------------------ ROM columns
    logic [AWD-1:0]    raddr;
    logic              rd_en;
    logic [WB*8-1:0]   rword;
    generate
        for (genvar c = 0; c < NCOL; c++) begin : g_col
            localparam string CD = (c == 0) ? "0" : (c == 1) ? "1" : (c == 2) ? "2" : (c == 3) ? "3" :
                                   (c == 4) ? "4" : (c == 5) ? "5" : (c == 6) ? "6" : (c == 7) ? "7" :
                                   (c == 8) ? "8" : "9";
            rom #(
                .DEPTH(ND), .WIDTH(32),
                .INIT_FILE(INIT_PREFIX == "" ? "" : {INIT_PREFIX, "_c", CD, ".mem"}),
                .RAM_STYLE("block"), .READ_LATENCY(ROM_LATENCY)
            ) u_col (.clk(clk), .re(rd_en), .addr(raddr), .dout(rword[c*32 +: 32]));
        end
    endgenerate

    // ------------------------------------------------------------ word FIFO with read credits
    logic [WB*8-1:0]      wf_mem [FD];
    logic [$clog2(FD):0]  wf_cnt, inflight;
    logic [$clog2(FD)-1:0] wf_wp, wf_rp;
    logic [ROM_LATENCY-1:0] rd_pipe;
    wire  word_arrive = rd_pipe[ROM_LATENCY-1];
    logic wf_pop;
    assign rd_en = (wf_cnt + inflight < FD) && rst_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raddr <= '0; rd_pipe <= '0; inflight <= '0; wf_cnt <= '0; wf_wp <= '0; wf_rp <= '0;
        end else begin
            if (rd_en) raddr <= (raddr == AWD'(ND - 1)) ? '0 : raddr + 1'b1;
            rd_pipe  <= {rd_pipe[ROM_LATENCY-2:0], rd_en};
            inflight <= inflight + rd_en - word_arrive;
            wf_cnt   <= wf_cnt + word_arrive - wf_pop;
            if (word_arrive) wf_wp <= wf_wp + 1'b1;
            if (wf_pop)      wf_rp <= wf_rp + 1'b1;
        end
    end
    always_ff @(posedge clk) if (word_arrive) wf_mem[wf_wp] <= rword;

    // ------------------------------------------------------------ gearbox
    logic [WINB*8-1:0]          win, win_app;
    logic [$clog2(WINB+1)-1:0]  res, res_app;             // valid bytes in the window
    logic [$clog2(NVEC)-1:0]    vcnt;
    logic                       app, can_emit, emit;

    always_comb begin
        app     = (res < P) && (wf_cnt != 0);              // append the next word at byte offset res
        win_app = win;
        res_app = res;
        if (app) begin
            // res < P here: explicit P-way offset mux instead of a full barrel shifter
            for (int r = 0; r < P; r++)
                if (res == r) win_app = win | ((WINB*8)'(wf_mem[wf_rp]) << (r * 8));
            res_app = res + WB;
        end
        can_emit = (res_app >= P);
        emit     = can_emit && (!m_tvalid || m_tready);
        wf_pop   = app && emit;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win <= '0; res <= '0; vcnt <= '0; m_tvalid <= 1'b0; m_tdata <= '0;
        end else begin
            if (emit) begin
                m_tdata  <= win_app[P*8-1:0];
                m_tvalid <= 1'b1;
                if (vcnt == ($bits(vcnt))'(NVEC - 1)) begin      // end of the period: drop padding
                    vcnt <= '0;
                    win  <= '0;
                    res  <= '0;
                end else begin
                    vcnt <= vcnt + 1'b1;
                    win  <= win_app >> (P * 8);
                    res  <= res_app - P;
                end
            end else if (m_tready) begin
                m_tvalid <= 1'b0;
            end
        end
    end
endmodule
