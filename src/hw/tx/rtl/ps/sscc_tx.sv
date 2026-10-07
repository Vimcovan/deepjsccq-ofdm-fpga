`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// SSCC baseline TX (separate source / channel coding), the classic counterpart of the DeepJSCC encoder:
//   PS bytes (JPEG packet, PAY_BYTES per frame)
//     -> sscc_tx_bits     MSB first, 802.11 scrambler (x^7 + x^4 + 1, restarted every frame), then
//                         FRAME_BITS - 8*PAY_BYTES zero tail bits (trellis back to state 0)
//     -> conv_enc_k7      K = 7, (171, 133) octal, rate 1/2 (same code as the Viterbi IP)
//     -> sscc_interleaver 802.11a two-step permutation, N_CBPS = 384 (64 symbols), s = 3
//     -> qam64_map        Gray 64-QAM, levels 158 * {+-1, +-3, +-5, +-7} = the JSCC / PRBS constellation
//   = FRAME_SYMS 24-bit {Q[11:0], I[11:0]} symbols per frame with tlast, the same contract as the encoder output.
//   FRAME_BITS = FRAME_SYMS * 6 / 2 = 98304 info bits = 512 interleaver blocks per frame.
//////////////////////////////////////////////////////////////////////////////////
module sscc_tx #(
    parameter int PAY_BYTES  = 12272,
    parameter int FRAME_SYMS = 32768
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  s_tdata,
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [23:0] m_tdata,
    output logic        m_tlast,
    output logic        m_tvalid,
    input  logic        m_tready
);
    localparam int FRAME_BITS = FRAME_SYMS * 3;
    logic b_tdata, b_tlast, b_tvalid, b_tready;
    sscc_tx_bits #(.PAY_BYTES(PAY_BYTES), .FRAME_BITS(FRAME_BITS)) u_bits (
        .clk, .rst_n, .s_tdata, .s_tvalid, .s_tready,
        .m_tdata(b_tdata), .m_tlast(b_tlast), .m_tvalid(b_tvalid), .m_tready(b_tready));
    logic [1:0] c_tdata; logic c_tlast, c_tvalid, c_tready;
    conv_enc_k7 u_conv (
        .clk, .rst_n, .s_tdata(b_tdata), .s_tlast(b_tlast), .s_tvalid(b_tvalid), .s_tready(b_tready),
        .m_tdata(c_tdata), .m_tlast(c_tlast), .m_tvalid(c_tvalid), .m_tready(c_tready));
    logic [5:0] i_tdata; logic i_tlast, i_tvalid, i_tready;
    sscc_interleaver u_il (
        .clk, .rst_n, .s_tdata(c_tdata), .s_tlast(c_tlast), .s_tvalid(c_tvalid), .s_tready(c_tready),
        .m_tdata(i_tdata), .m_tlast(i_tlast), .m_tvalid(i_tvalid), .m_tready(i_tready));
    qam64_map u_map (
        .clk, .rst_n, .s_tdata(i_tdata), .s_tlast(i_tlast), .s_tvalid(i_tvalid), .s_tready(i_tready),
        .m_tdata, .m_tlast, .m_tvalid, .m_tready);
endmodule


// bytes -> scrambled bits (MSB first) + zero tail; one bit per beat, tlast on the last bit of a frame
module sscc_tx_bits #(
    parameter int PAY_BYTES  = 12272,
    parameter int FRAME_BITS = 98304,
    parameter logic [6:0] SEED = 7'b1011101          // same seed as the original OFDM scrambler
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] s_tdata,
    input  logic       s_tvalid,
    output logic       s_tready,
    output logic       m_tdata,
    output logic       m_tlast,
    output logic       m_tvalid,
    input  logic       m_tready
);
    localparam int PAY_BITS = PAY_BYTES * 8;
    logic [$clog2(FRAME_BITS)-1:0] bcnt;
    logic [2:0] bidx;                                  // bit of the current byte, 7 first
    logic [6:0] st;
    wire in_pay = (bcnt < PAY_BITS);
    wire fb     = st[6] ^ st[3];
    assign m_tvalid = in_pay ? s_tvalid : 1'b1;
    assign m_tdata  = in_pay & (s_tdata[bidx] ^ fb);
    assign m_tlast  = (bcnt == FRAME_BITS - 1);
    assign s_tready = in_pay & m_tready & (bidx == 3'd0);  // a byte is consumed with its last bit
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin bcnt <= '0; bidx <= 3'd7; st <= SEED; end
        else if (m_tvalid & m_tready) begin
            if (m_tlast) begin bcnt <= '0; bidx <= 3'd7; st <= SEED; end
            else begin
                bcnt <= bcnt + 1'b1;
                if (in_pay) begin st <= {st[5:0], fb}; bidx <= bidx - 1'b1; end
            end
        end
    end
endmodule


// K = 7 rate 1/2 convolutional encoder, codes 171 / 133 (MSB = current input); m_tdata[0] = code 171 (sent first)
module conv_enc_k7 (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       s_tdata,
    input  logic       s_tlast,
    input  logic       s_tvalid,
    output logic       s_tready,
    output logic [1:0] m_tdata,
    output logic       m_tlast,
    output logic       m_tvalid,
    input  logic       m_tready
);
    logic [5:0] sr;                                    // sr[5] = previous input, sr[0] = 6 inputs ago
    wire  [6:0] w  = {s_tdata, sr};                    // w[6] = input, w[5] = 1 delay, ..., w[0] = 6 delays
    wire        c0 = ^(w & 7'b1111001);               // 171
    wire        c1 = ^(w & 7'b1011011);               // 133
    assign s_tready = ~m_tvalid | m_tready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sr <= '0; m_tvalid <= 1'b0; m_tdata <= '0; m_tlast <= 1'b0; end
        else if (s_tvalid & s_tready) begin
            m_tdata <= {c1, c0}; m_tlast <= s_tlast; m_tvalid <= 1'b1;
            sr <= s_tlast ? 6'd0 : {s_tdata, sr[5:1]};  // every frame starts from state 0 (its tail is zero anyway)
        end
        else if (m_tready) m_tvalid <= 1'b0;
    end
endmodule


// 802.11a-style block interleaver, N coded bits per block, S = max(bits per QAM symbol / 2, 1):
//   k (coded bit index) -> i = (N/16)(k mod 16) + floor(k/16) -> j = S floor(i/S) + (i + N - floor(16 i / N)) mod S
// write 2 coded bits per beat (at positions P(2w), P(2w+1)), read 6 bits per beat (positions 6r .. 6r+5,
// m_tdata[0] = first). Double buffered; tlast marks the block that holds the frame's last bit.
module sscc_interleaver #(
    parameter int N = 384,
    parameter int S = 3
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic [1:0] s_tdata,
    input  logic       s_tlast,
    input  logic       s_tvalid,
    output logic       s_tready,
    output logic [5:0] m_tdata,
    output logic       m_tlast,
    output logic       m_tvalid,
    input  logic       m_tready
);
    function automatic int perm(input int k);
        int i;
        i = (N / 16) * (k % 16) + k / 16;
        return S * (i / S) + (i + N - (16 * i) / N) % S;
    endfunction
    logic [$clog2(N)-1:0] P [0:N-1];
    initial for (int k = 0; k < N; k++) P[k] = perm(k);

    logic buffer [0:1][0:N-1];
    logic [$clog2(N/2)-1:0] wr_cnt;
    logic [$clog2(N/6)-1:0] rd_cnt;
    logic wr_id, rd_id;
    logic full [0:1], last [0:1];
    wire  wr_en = s_tvalid & s_tready;
    wire  rd_en = m_tvalid & m_tready;
    assign s_tready = ~full[wr_id];
    assign m_tvalid = full[rd_id];
    assign m_tlast  = last[rd_id] & (rd_cnt == N/6 - 1);
    always_comb for (int b = 0; b < 6; b++) m_tdata[b] = buffer[rd_id][6 * rd_cnt + b];
    always_ff @(posedge clk) if (wr_en) begin
        buffer[wr_id][P[2 * wr_cnt]]     <= s_tdata[0];
        buffer[wr_id][P[2 * wr_cnt + 1]] <= s_tdata[1];
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt <= '0; rd_cnt <= '0; wr_id <= 1'b0; rd_id <= 1'b0;
            full[0] <= 1'b0; full[1] <= 1'b0; last[0] <= 1'b0; last[1] <= 1'b0;
        end else begin
            if (wr_en) begin
                if (wr_cnt == N/2 - 1 || s_tlast) begin           // a frame end closes a (partial) block
                    wr_cnt <= '0; wr_id <= ~wr_id; full[wr_id] <= 1'b1; last[wr_id] <= s_tlast;
                end else wr_cnt <= wr_cnt + 1'b1;
            end
            if (rd_en) begin
                if (rd_cnt == N/6 - 1) begin rd_cnt <= '0; rd_id <= ~rd_id; full[rd_id] <= 1'b0; end
                else rd_cnt <= rd_cnt + 1'b1;
            end
        end
    end
endmodule


// Gray 64-QAM: I from bits {0,1,2}, Q from bits {3,4,5} (bit 0 first = MSB of the Gray label),
// level 158 * (2k - 7), k = binary of the Gray label (same mapping as iq_prbs_source)
module qam64_map (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [5:0]  s_tdata,
    input  logic        s_tlast,
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [23:0] m_tdata,
    output logic        m_tlast,
    output logic        m_tvalid,
    input  logic        m_tready
);
    function automatic logic [11:0] lvl(input logic [2:0] g);
        logic [2:0] k;
        k[2] = g[2]; k[1] = g[2] ^ g[1]; k[0] = g[2] ^ g[1] ^ g[0];
        return 12'($signed({1'b0, k, 1'b0}) - 7) * 12'sd158;
    endfunction
    assign s_tready = ~m_tvalid | m_tready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin m_tvalid <= 1'b0; m_tdata <= '0; m_tlast <= 1'b0; end
        else if (s_tvalid & s_tready) begin
            m_tdata  <= {lvl({s_tdata[3], s_tdata[4], s_tdata[5]}), lvl({s_tdata[0], s_tdata[1], s_tdata[2]})};
            m_tlast  <= s_tlast; m_tvalid <= 1'b1;
        end
        else if (m_tready) m_tvalid <= 1'b0;
    end
endmodule
