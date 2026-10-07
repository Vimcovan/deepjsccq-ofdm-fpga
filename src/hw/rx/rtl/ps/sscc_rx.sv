`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// SSCC baseline RX: equalized, PN-descrambled 64-QAM symbols of the PHY (32768 per frame, tlast) -> JPEG packet
//   -> sync FIFO           the PHY cannot be back-pressured (symbols arrive ~8 clocks apart, bursts of 48)
//   -> qam64_softdemap     simplified max-log LLRs, 5-bit signed magnitude (Viterbi IP Data_Format), 6 per symbol
//   -> sscc_deinterleaver  inverse of sscc_interleaver (N = 384, s = 3), pairs out
//   -> sscc_vit_feed       exactly FRAME_BITS pairs per frame (pads / drops if the PHY frame was not complete),
//                          then FLUSH strong-zero pairs so the decoder releases the frame's last bits at once
//   -> viterbi (IP)        K = 7, 171 / 133, traceback 48, soft 5 bit
//   -> sscc_rx_bits        descramble, bytes, double-buffered packet RAM (PAY_BYTES), seq / last_buf
//   The PS reads the packet RAM through the telemetry AXI slave (rd_addr / rd_q, one clock latency).
//////////////////////////////////////////////////////////////////////////////////
module sscc_rx #(
    parameter int PAY_BYTES  = 12272,
    parameter int FRAME_SYMS = 32768,
    parameter int FLUSH      = 512
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] s_tdata,             // tap of the PHY output (no back-pressure)
    input  logic        s_tlast,
    input  logic        s_fire,
    output logic [31:0] seq,                 // completed packets
    output logic        last_buf,            // buffer of the newest packet
    output logic [31:0] fifo_ovf,            // symbols lost at the input FIFO (should stay 0)
    input  logic [12:0] rd_addr,             // {buffer, word}
    output logic [31:0] rd_q
);
    localparam int FRAME_BITS = FRAME_SYMS * 3;
    // input FIFO
    logic [24:0] f_q; logic f_valid, f_ready;
    sscc_sync_fifo #(.W(25), .DEPTH(1024)) u_fifo (
        .clk, .rst_n, .wr_data({s_tlast, s_tdata}), .wr_en(s_fire), .ovf(fifo_ovf),
        .rd_data(f_q), .rd_valid(f_valid), .rd_ready(f_ready));
    logic [4:0] d_tdata; logic d_tlast, d_tvalid, d_tready;
    qam64_softdemap u_demap (
        .clk, .rst_n, .s_tdata(f_q[23:0]), .s_tlast(f_q[24]), .s_tvalid(f_valid), .s_tready(f_ready),
        .m_tdata(d_tdata), .m_tlast(d_tlast), .m_tvalid(d_tvalid), .m_tready(d_tready));
    logic [9:0] p_tdata; logic p_tlast, p_tvalid, p_tready;
    sscc_deinterleaver u_dil (
        .clk, .rst_n, .s_tdata(d_tdata), .s_tlast(d_tlast), .s_tvalid(d_tvalid), .s_tready(d_tready),
        .m_tdata(p_tdata), .m_tlast(p_tlast), .m_tvalid(p_tvalid), .m_tready(p_tready));
    logic [15:0] v_tdata; logic v_tvalid, v_tready;
    sscc_vit_feed #(.PAIRS(FRAME_BITS), .FLUSH(FLUSH)) u_feed (
        .clk, .rst_n, .s_tdata(p_tdata), .s_tlast(p_tlast), .s_tvalid(p_tvalid), .s_tready(p_tready),
        .m_tdata(v_tdata), .m_tvalid(v_tvalid), .m_tready(v_tready));
    logic [7:0] o_tdata; logic o_tvalid;
    viterbi u_viterbi (
        .aclk(clk), .aresetn(rst_n),
        .s_axis_data_tdata(v_tdata), .s_axis_data_tvalid(v_tvalid), .s_axis_data_tready(v_tready),
        .m_axis_data_tdata(o_tdata), .m_axis_data_tvalid(o_tvalid), .m_axis_data_tready(1'b1));
    sscc_rx_bits #(.PAY_BYTES(PAY_BYTES), .FRAME_OUT(FRAME_BITS + FLUSH)) u_bits (
        .clk, .rst_n, .s_bit(o_tdata[0]), .s_valid(o_tvalid), .seq, .last_buf, .rd_addr, .rd_q);
endmodule


// simple synchronous FIFO, writes are never refused (overflow counted), first-word-fall-through read side
module sscc_sync_fifo #(
    parameter int W = 25,
    parameter int DEPTH = 1024
)(
    input  logic         clk,
    input  logic         rst_n,
    input  logic [W-1:0] wr_data,
    input  logic         wr_en,
    output logic [31:0]  ovf,
    output logic [W-1:0] rd_data,
    output logic         rd_valid,
    input  logic         rd_ready
);
    localparam int AW = $clog2(DEPTH);
    (* ram_style = "block" *) logic [W-1:0] mem [0:DEPTH-1];
    logic [AW:0] wp, rp;
    wire  full  = (wp - rp) == DEPTH;
    wire  empty = (wp == rp);
    always_ff @(posedge clk) if (wr_en && !full) mem[wp[AW-1:0]] <= wr_data;
    // output register stage (FWFT): q holds mem[rp] once read
    logic q_valid;
    wire  rd_mem = !empty && (!q_valid || rd_ready);
    always_ff @(posedge clk) if (rd_mem) rd_data <= mem[rp[AW-1:0]];
    assign rd_valid = q_valid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wp <= '0; rp <= '0; q_valid <= 1'b0; ovf <= '0; end
        else begin
            if (wr_en) begin if (full) ovf <= ovf + 1'b1; else wp <= wp + 1'b1; end
            if (rd_mem) begin rp <= rp + 1'b1; q_valid <= 1'b1; end
            else if (rd_ready) q_valid <= 1'b0;
        end
    end
endmodule


// 64-QAM soft demapper (Gray, A = 158; levels A*{+-1,+-3,+-5,+-7}), per axis y:
//   b_msb: y,  b_mid: 4A - |y|,  b_lsb: 2A - ||y| - 4A|      (> 0 means bit 1, see qam64_map)
// 5-bit signed magnitude: sign = 1 for bit 1, magnitude = min(|L| >> SHIFT, 15).
// Out: 6 soft values per symbol, I bits {0,1,2} then Q bits {3,4,5}; tlast on the last one of a frame.
module qam64_softdemap #(
    parameter int SHIFT = 5
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] s_tdata,
    input  logic        s_tlast,
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [4:0]  m_tdata,
    output logic        m_tlast,
    output logic        m_tvalid,
    input  logic        m_tready
);
    localparam int A = 158;
    function automatic logic [4:0] sm(input logic signed [14:0] L);
        logic [14:0] a;
        a = L[14] ? 15'(-L) : 15'(L);
        a = a >> SHIFT;
`ifdef SSCC_HARD
        return {L > 0, 4'd15};                           // simulation check only: hard decisions
`else
        return {L > 0, (a > 15) ? 4'd15 : a[3:0]};
`endif
    endfunction
    function automatic logic [14:0] soft3(input logic signed [11:0] y);    // {msb, mid, lsb} soft values
        logic signed [14:0] ys, ay, l1, l2, t;
        ys = y; ay = (ys < 0) ? -ys : ys;
        l1 = 4 * A - ay;
        t  = ay - 4 * A; l2 = 2 * A - ((t < 0) ? -t : t);
        return {sm(ys), sm(l1), sm(l2)};
    endfunction
    logic [4:0] sv [0:5];
    logic       hold, hlast;
    logic [2:0] k;
    assign m_tvalid = hold;
    assign m_tdata  = sv[k];
    assign m_tlast  = hlast & (k == 3'd5);
    assign s_tready = ~hold | (m_tready & (k == 3'd5));
    logic [14:0] si, sq;
    assign si = soft3(s_tdata[11:0]);
    assign sq = soft3(s_tdata[23:12]);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin hold <= 1'b0; hlast <= 1'b0; k <= '0; end
        else begin
            if (hold & m_tready) begin
                if (k == 3'd5) begin hold <= 1'b0; k <= '0; end
                else k <= k + 1'b1;
            end
            if (s_tvalid & s_tready) begin
                hold <= 1'b1; k <= '0; hlast <= s_tlast;
                {sv[0], sv[1], sv[2]} <= si;
                {sv[3], sv[4], sv[5]} <= sq;
            end
        end
    end
endmodule


// inverse of sscc_interleaver: soft value at block position j is written to coded index k = P^-1(j),
// read back in coded order as pairs {soft(2m+1), soft(2m)} (code 133, code 171)
module sscc_deinterleaver #(
    parameter int N = 384,
    parameter int S = 3
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [4:0] s_tdata,
    input  logic       s_tlast,
    input  logic       s_tvalid,
    output logic       s_tready,
    output logic [9:0] m_tdata,
    output logic       m_tlast,
    output logic       m_tvalid,
    input  logic       m_tready
);
    function automatic int perm(input int k);
        int i;
        i = (N / 16) * (k % 16) + k / 16;
        return S * (i / S) + (i + N - (16 * i) / N) % S;
    endfunction
    logic [$clog2(N)-1:0] Q [0:N-1];
    initial for (int k = 0; k < N; k++) Q[perm(k)] = k;

    (* ram_style = "distributed" *) logic [4:0] mem [0:2*N-1];
    logic [$clog2(N)-1:0]   wr_cnt;
    logic [$clog2(N/2)-1:0] rd_cnt;
    logic wr_id, rd_id;
    logic full [0:1], last [0:1];
    wire  wr_en = s_tvalid & s_tready;
    wire  rd_en = m_tvalid & m_tready;
    assign s_tready = ~full[wr_id];
    assign m_tvalid = full[rd_id];
    assign m_tlast  = last[rd_id] & (rd_cnt == N/2 - 1);
    assign m_tdata  = {mem[rd_id * N + 2 * rd_cnt + 1], mem[rd_id * N + 2 * rd_cnt]};
    always_ff @(posedge clk) if (wr_en) mem[wr_id * N + Q[wr_cnt]] <= s_tdata;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt <= '0; rd_cnt <= '0; wr_id <= 1'b0; rd_id <= 1'b0;
            full[0] <= 1'b0; full[1] <= 1'b0; last[0] <= 1'b0; last[1] <= 1'b0;
        end else begin
            if (wr_en) begin
                if (wr_cnt == N - 1 || s_tlast) begin
                    wr_cnt <= '0; wr_id <= ~wr_id; full[wr_id] <= 1'b1; last[wr_id] <= s_tlast;
                end else wr_cnt <= wr_cnt + 1'b1;
            end
            if (rd_en) begin
                if (rd_cnt == N/2 - 1) begin rd_cnt <= '0; rd_id <= ~rd_id; full[rd_id] <= 1'b0; end
                else rd_cnt <= rd_cnt + 1'b1;
            end
        end
    end
endmodule


// Viterbi input: exactly PAIRS pairs per frame (erasures pad a short frame, extra pairs before tlast are dropped),
// then FLUSH strong-zero pairs (the TX tail is zero, the trellis stays in state 0).
// tdata = {3'b0, soft code 133, 3'b0, soft code 171}
module sscc_vit_feed #(
    parameter int PAIRS = 98304,
    parameter int FLUSH = 512
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [9:0]  s_tdata,
    input  logic        s_tlast,
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [15:0] m_tdata,
    output logic        m_tvalid,
    input  logic        m_tready
);
    localparam logic [4:0] ZERO_STRONG = 5'b01111, ERASE = 5'b00000;
    typedef enum logic [1:0] {PASS, PAD, DROP, FL} st_t;
    st_t st;
    logic [$clog2(PAIRS)-1:0] cnt;
    logic [$clog2(FLUSH)-1:0] fcnt;
    logic [9:0] pair;
    always_comb begin
        case (st)
            PASS:    begin pair = s_tdata;                    m_tvalid = s_tvalid; s_tready = m_tready; end
            PAD:     begin pair = {ERASE, ERASE};             m_tvalid = 1'b1;     s_tready = 1'b0;     end
            DROP:    begin pair = {ERASE, ERASE};             m_tvalid = 1'b0;     s_tready = 1'b1;     end
            default: begin pair = {ZERO_STRONG, ZERO_STRONG}; m_tvalid = 1'b1;     s_tready = 1'b0;     end
        endcase
        m_tdata = {3'b0, pair[9:5], 3'b0, pair[4:0]};
    end
    wire fire = m_tvalid & m_tready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st <= PASS; cnt <= '0; fcnt <= '0; end
        else case (st)
            PASS: if (fire) begin
                if (cnt == PAIRS - 1) begin cnt <= '0; st <= s_tlast ? FL : DROP; end
                else begin cnt <= cnt + 1'b1; if (s_tlast) st <= PAD; end
            end
            PAD: if (fire) begin
                if (cnt == PAIRS - 1) begin cnt <= '0; st <= FL; end
                else cnt <= cnt + 1'b1;
            end
            DROP: if (s_tvalid & s_tlast) st <= FL;
            default: if (fire) begin
                if (fcnt == FLUSH - 1) begin fcnt <= '0; st <= PASS; end
                else fcnt <= fcnt + 1'b1;
            end
        endcase
    end
endmodule


// decoded bits -> descramble -> bytes (MSB first) -> 32-bit words (byte 0 in [7:0]) -> packet RAM (2 buffers).
// FRAME_OUT decoder outputs per frame (pairs + flush); the first 8*PAY_BYTES are the packet, the rest is tail.
module sscc_rx_bits #(
    parameter int PAY_BYTES = 12272,
    parameter int FRAME_OUT = 98304 + 512,
    parameter logic [6:0] SEED = 7'b1011101
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_bit,
    input  logic        s_valid,
    output logic [31:0] seq,
    output logic        last_buf,
    input  logic [12:0] rd_addr,
    output logic [31:0] rd_q
);
    localparam int PAY_BITS = PAY_BYTES * 8;
    localparam int WORDS    = PAY_BYTES / 4;              // per buffer
    (* ram_style = "block" *) logic [31:0] ram [0:2*WORDS-1];
    logic [$clog2(FRAME_OUT)-1:0] obit;
    logic [6:0]  st;
    logic [31:0] word;
    logic [4:0]  wbit;                                    // bit within the word: byte (wbit[4:3]), bit 7..0
    logic [$clog2(WORDS)-1:0] widx;
    logic        wb;
    wire  fb  = st[6] ^ st[3];
    wire  pay = obit < PAY_BITS;
    wire  b   = s_bit ^ fb;
    logic        we;
    logic [31:0] wdata;
    logic [$clog2(2*WORDS)-1:0] waddr;
    always_ff @(posedge clk) begin
        if (we) ram[waddr] <= wdata;
        rd_q <= ram[(rd_addr[12] ? WORDS : 0) + rd_addr[11:0]];
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            obit <= '0; st <= SEED; word <= '0; wbit <= '0; widx <= '0; wb <= 1'b0;
            seq <= '0; last_buf <= 1'b0; we <= 1'b0;
        end else begin
            we <= 1'b0;
            if (s_valid) begin
                if (pay) begin
                    st <= {st[5:0], fb};
                    // byte n of the word lives in bits [8n+7 : 8n], its MSB arrives first
                    word[{wbit[4:3], 3'd7 - wbit[2:0]}] <= b;
                    wbit <= wbit + 1'b1;
                    if (wbit == 5'd31) begin
                        we <= 1'b1; waddr <= (wb ? WORDS : 0) + widx;
                        wdata <= word; wdata[{2'd3, 3'd0}] <= b;    // the last bit (byte 3, bit 0) of this word
                        widx <= widx + 1'b1;
                    end
                end
                // commit with the packet's last bit: the decoder keeps its last ~200 outputs until more input
                // arrives, so the flush pairs push the packet out but the flush outputs themselves wait for the
                // next frame (counting continues to FRAME_OUT for the frame alignment)
                if (obit == PAY_BITS - 1) begin last_buf <= wb; wb <= ~wb; seq <= seq + 1'b1; end
                if (obit == FRAME_OUT - 1) begin
                    obit <= '0; st <= SEED; wbit <= '0; widx <= '0;
                end else obit <= obit + 1'b1;
            end
        end
    end
endmodule
