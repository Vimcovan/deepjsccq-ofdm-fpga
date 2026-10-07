`timescale 1ns / 1ps
// AXI-Stream FIFO storing PACK elements per RAM word (e.g. 6 x 12 bit in 72 bit).
// Used for the skip-path delay of residual blocks.
//   * write: element by element, the whole word is rewritten from a gather register
//     (write-through, no read-modify-write).  A word is only written once every old
//     element of it has been read, so the usable capacity is DEPTH_W*PACK - (PACK-1).
//   * read : one RAM read per element (word, lane), credit based output FIFO, so
//     m_tready may drop at any time; throughput one element per cycle.
module axis_fifo_packed #(
    parameter int    DATA_W      = 12,
    parameter int    PACK        = 3,
    parameter int    DEPTH_W     = 2048,          // RAM words
    parameter string RAM_STYLE   = "block",
    parameter int    RAM_LATENCY = 2,
    parameter int    OFIFO       = 8              // output FIFO depth (power of two)
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic [DATA_W-1:0] s_tdata,
    input  logic              s_tvalid,
    output logic              s_tready,
    output logic [DATA_W-1:0] m_tdata,
    output logic              m_tvalid,
    input  logic              m_tready
);
    function automatic int clog2m1(input int x);
        return (x <= 2) ? 1 : $clog2(x);
    endfunction
    localparam int CAP  = DEPTH_W * PACK;
    localparam int AW   = clog2m1(DEPTH_W);
    localparam int LW   = clog2m1(PACK);
    localparam int CW   = $clog2(CAP + 1) + 1;          // element counters (wrap safe difference)

    initial assert (OFIFO > RAM_LATENCY + 1 && (OFIFO & (OFIFO - 1)) == 0)
        else $fatal(1, "axis_fifo_packed: OFIFO must be a power of two > RAM_LATENCY + 1");

    generate if (PACK == 1 && RAM_STYLE == "distributed") begin : g_simple
    // ---------------------------------------------------------------- small FIFO: plain LUTRAM ring
    (* ram_style = "distributed" *) logic [DATA_W-1:0] mem [DEPTH_W];
    logic [AW:0] wp, rp;
    wire  [AW:0] used = wp - rp;
    assign s_tready = rst_n && (int'(used) < DEPTH_W);
    assign m_tvalid = (used != '0);
    assign m_tdata  = mem[rp[AW-1:0]];
    always_ff @(posedge clk) if (s_tvalid && s_tready) mem[wp[AW-1:0]] <= s_tdata;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wp <= '0; rp <= '0; end
        else begin
            if (s_tvalid && s_tready) wp <= wp + 1'b1;
            if (m_tvalid && m_tready) rp <= rp + 1'b1;
        end
    end
    // synthesis translate_off
    int peak = 0;
    always @(posedge clk) if (int'(used) > peak) peak = int'(used);
    final $display("FIFO_PEAK %m %0d of %0d", peak, DEPTH_W);
    // synthesis translate_on
    end else begin : g_packed

    // ---------------------------------------------------------------- write side
    logic [CW-1:0]           n_wr, n_iss;               // elements written / read-issued
    logic [AW-1:0]           w_word, r_word;
    logic [LW-1:0]           w_lane, r_lane;
    logic [PACK*DATA_W-1:0]  gather, gather_nx;
    wire  [CW-1:0]           used = n_wr - n_iss;
    assign s_tready = rst_n && (int'(used) < CAP - PACK + 1);
    wire  wr_fire = s_tvalid && s_tready;

    always_comb begin
        gather_nx = gather;
        gather_nx[w_lane * DATA_W +: DATA_W] = s_tdata;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_wr <= '0; w_word <= '0; w_lane <= '0; gather <= '0;
        end else if (wr_fire) begin
            n_wr   <= n_wr + 1'b1;
            gather <= gather_nx;
            if (int'(w_lane) == PACK - 1) begin
                w_lane <= '0;
                w_word <= (int'(w_word) == DEPTH_W - 1) ? '0 : w_word + 1'b1;
            end else begin
                w_lane <= w_lane + 1'b1;
            end
        end
    end

    // elements visible to the reader: written at least one clock edge ago
    logic [CW-1:0] n_vis;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) n_vis <= '0;
        else        n_vis <= n_wr;
    end

    // ---------------------------------------------------------------- read side
    localparam int FAW = $clog2(OFIFO);
    logic [$clog2(OFIFO):0] occ;                        // output FIFO entries + reads in flight
    wire  pop   = m_tvalid && m_tready;
    // no read of the word being written in the same cycle (BRAM SDP address collision)
    wire  issue = rst_n && (n_vis != n_iss) && (occ < OFIFO) && !(wr_fire && r_word == w_word);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n_iss <= '0; r_word <= '0; r_lane <= '0; occ <= '0;
        end else begin
            occ <= occ + issue - pop;
            if (issue) begin
                n_iss <= n_iss + 1'b1;
                if (int'(r_lane) == PACK - 1) begin
                    r_lane <= '0;
                    r_word <= (int'(r_word) == DEPTH_W - 1) ? '0 : r_word + 1'b1;
                end else begin
                    r_lane <= r_lane + 1'b1;
                end
            end
        end
    end

    logic [PACK*DATA_W-1:0] rd_word;
    sdp_ram #(
        .DEPTH(DEPTH_W), .WIDTH(PACK * DATA_W), .RAM_STYLE(RAM_STYLE), .READ_LATENCY(RAM_LATENCY)
    ) u_ram (
        .clk(clk), .we(wr_fire), .waddr(w_word), .wdata(gather_nx),
        .re(issue), .raddr(r_word), .rdata(rd_word)
    );

    logic          d_vld  [RAM_LATENCY];
    logic [LW-1:0] d_lane [RAM_LATENCY];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < RAM_LATENCY; i++) begin d_vld[i] <= 1'b0; d_lane[i] <= '0; end
        end else begin
            d_vld[0] <= issue; d_lane[0] <= r_lane;
            for (int i = 1; i < RAM_LATENCY; i++) begin d_vld[i] <= d_vld[i-1]; d_lane[i] <= d_lane[i-1]; end
        end
    end

    (* ram_style = "distributed" *) logic [DATA_W-1:0] ofifo [OFIFO];
    logic [FAW:0] o_wp, o_rp;
    wire push = d_vld[RAM_LATENCY-1];
    always_ff @(posedge clk) if (push) ofifo[o_wp[FAW-1:0]] <= rd_word[d_lane[RAM_LATENCY-1] * DATA_W +: DATA_W];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_wp <= '0; o_rp <= '0;
        end else begin
            if (push) o_wp <= o_wp + 1'b1;
            if (pop)  o_rp <= o_rp + 1'b1;
        end
    end
    assign m_tvalid = (o_wp != o_rp);
    assign m_tdata  = ofifo[o_rp[FAW-1:0]];

    // synthesis translate_off
    int peak = 0;
    always @(posedge clk) if (int'(used) > peak) peak = int'(used);
    final $display("FIFO_PEAK %m %0d of %0d", peak, CAP - PACK + 1);
    // synthesis translate_on
    end endgenerate
endmodule
