`timescale 1ns / 1ps
// Read-only memory initialised from a hex file (one word per line).
//
// RAM_STYLE = "block": xpm_memory_sdpram with the write port tied off.  An inferred
//   ROM is single-port (RAMB36 at most 1Kx36) and its depth is rounded up to a power of
//   two; the simple-dual-port XPM maps to the actual depth and can use 512x72 columns,
//   which is what docs/memory_plan.md assumes.
// RAM_STYLE = "distributed" / "auto": inferred ROM ($readmemh), LUT based for "distributed".
// URAM cannot hold configuration-time contents, so "ultra" is not offered.
// READ_LATENCY = 1: registered read; 2: plus output register (use at 250 MHz).
module rom #(
    parameter int    DEPTH        = 512,
    parameter int    WIDTH        = 72,
    parameter string INIT_FILE    = "",
    parameter string RAM_STYLE    = "block",
    parameter int    READ_LATENCY = 2
) (
    input  logic                                     clk,
    input  logic                                     re,
    input  logic [$clog2(DEPTH > 1 ? DEPTH : 2)-1:0] addr,
    output logic [WIDTH-1:0]                         dout
);
    localparam int AW = $clog2(DEPTH > 1 ? DEPTH : 2);

    generate
`ifdef QUESTA_SIM
        // Questa regression uses the same inferred model as distributed ROMs;
        // Vivado/xsim keeps the XPM block-RAM implementation below.
        if (1'b0) begin : g_block
`else
        if (RAM_STYLE == "block") begin : g_block
`endif
            xpm_memory_sdpram #(
                .ADDR_WIDTH_A           (AW),
                .ADDR_WIDTH_B           (AW),
                .BYTE_WRITE_WIDTH_A     (WIDTH),
                .CLOCKING_MODE          ("common_clock"),
                .MEMORY_INIT_FILE       (INIT_FILE == "" ? "none" : INIT_FILE),
                .MEMORY_INIT_PARAM      ("0"),
                .MEMORY_OPTIMIZATION    ("true"),
                .MEMORY_PRIMITIVE       ("block"),
                .MEMORY_SIZE            (DEPTH * WIDTH),
                .READ_DATA_WIDTH_B      (WIDTH),
                .READ_LATENCY_B         (READ_LATENCY),
                .USE_MEM_INIT           (1),
                .WRITE_DATA_WIDTH_A     (WIDTH),
                .WRITE_MODE_B           ("read_first")
            ) u_xpm (
                .clka(clk), .ena(1'b0), .wea(1'b0), .addra('0), .dina('0),
                .clkb(clk), .enb(re), .addrb(addr), .doutb(dout),
                .regceb(1'b1), .rstb(1'b0),
                .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sleep(1'b0),
                .sbiterrb(), .dbiterrb()
            );
        end else begin : g_infer
            logic [WIDTH-1:0] rd_q, rd_qq;
            logic             re_q;
            if (RAM_STYLE == "distributed") begin : g_dist
                (* rom_style = "distributed" *) logic [WIDTH-1:0] mem [DEPTH];
                initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
                always_ff @(posedge clk) if (re) rd_q <= mem[addr];
            end else begin : g_auto
                logic [WIDTH-1:0] mem [DEPTH];
                initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
                always_ff @(posedge clk) if (re) rd_q <= mem[addr];
            end
            always_ff @(posedge clk) begin
                re_q <= re;
                if (re_q) rd_qq <= rd_q;
            end
            assign dout = (READ_LATENCY >= 2) ? rd_qq : rd_q;
        end
    endgenerate

    initial begin
        assert (READ_LATENCY == 1 || READ_LATENCY == 2) else $fatal(1, "rom: READ_LATENCY must be 1 or 2");
        assert (RAM_STYLE != "ultra") else $fatal(1, "rom: URAM cannot be initialised, use block/distributed");
    end
endmodule
