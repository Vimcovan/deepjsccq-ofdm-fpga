`timescale 1ns / 1ps
// ROM split along the depth into banks of BANK_DEPTH words, one rom instance per bank.
// Fixes the depth decomposition chosen in docs/memory_plan.md (e.g. 512-deep banks of
// 512x72 BRAM columns) instead of leaving it to the tool, which may pick 1Kx36 + a
// half-empty remainder block.  BANK_DEPTH = 0 (or >= DEPTH) gives a single rom.
//
// Init files: BANK_DEPTH = 0: <INIT_PREFIX>.mem;  otherwise <INIT_PREFIX>_b<i>.mem
// (i = 0..9).  Same latency and interface as rom.
module rom_banked #(
    parameter int    DEPTH        = 1440,
    parameter int    WIDTH        = 72,
    parameter int    BANK_DEPTH   = 512,
    parameter string INIT_PREFIX  = "",
    parameter string RAM_STYLE    = "block",
    parameter int    READ_LATENCY = 2
) (
    input  logic                                     clk,
    input  logic                                     re,
    input  logic [$clog2(DEPTH > 1 ? DEPTH : 2)-1:0] addr,
    output logic [WIDTH-1:0]                         dout
);
    localparam int AW     = $clog2(DEPTH > 1 ? DEPTH : 2);
    localparam bit BANKED = (BANK_DEPTH > 0) && (BANK_DEPTH < DEPTH);
    localparam int NB     = BANKED ? (DEPTH + BANK_DEPTH - 1) / BANK_DEPTH : 1;
    localparam int BAW    = $clog2(BANK_DEPTH > 1 ? BANK_DEPTH : 2);

    initial begin
        assert (!BANKED || (BANK_DEPTH & (BANK_DEPTH - 1)) == 0) else $fatal(1, "rom_banked: BANK_DEPTH must be a power of two");
        assert (NB <= 10) else $fatal(1, "rom_banked: at most 10 banks");
    end

    generate
        if (!BANKED) begin : g_single
            rom #(
                .DEPTH(DEPTH), .WIDTH(WIDTH), .INIT_FILE(INIT_PREFIX == "" ? "" : {INIT_PREFIX, ".mem"}),
                .RAM_STYLE(RAM_STYLE), .READ_LATENCY(READ_LATENCY)
            ) u_rom (.clk(clk), .re(re), .addr(addr), .dout(dout));
        end else begin : g_banks
            logic [WIDTH-1:0] bank_dout [NB];
            wire  [AW-BAW-1:0] sel = addr[AW-1:BAW];
            for (genvar b = 0; b < NB; b++) begin : g_bank
                localparam int    BD = (b == NB - 1) ? DEPTH - b * BANK_DEPTH : BANK_DEPTH;
                localparam string BS = (b == 0) ? "0" : (b == 1) ? "1" : (b == 2) ? "2" : (b == 3) ? "3" :
                                       (b == 4) ? "4" : (b == 5) ? "5" : (b == 6) ? "6" : (b == 7) ? "7" :
                                       (b == 8) ? "8" : "9";
                rom #(
                    .DEPTH(BD), .WIDTH(WIDTH),
                    .INIT_FILE(INIT_PREFIX == "" ? "" : {INIT_PREFIX, "_b", BS, ".mem"}),
                    .RAM_STYLE(RAM_STYLE), .READ_LATENCY(READ_LATENCY)
                ) u_rom (
                    .clk(clk), .re(re && sel == b), .addr(addr[$clog2(BD > 1 ? BD : 2)-1:0]), .dout(bank_dout[b])
                );
            end
            // bank select delayed by the read latency
            logic [AW-BAW-1:0] sel_d [READ_LATENCY];
            always_ff @(posedge clk) begin
                if (re) sel_d[0] <= sel;
                for (int i = 1; i < READ_LATENCY; i++) sel_d[i] <= sel_d[i-1];
            end
            assign dout = bank_dout[sel_d[READ_LATENCY-1]];
        end
    endgenerate
endmodule
