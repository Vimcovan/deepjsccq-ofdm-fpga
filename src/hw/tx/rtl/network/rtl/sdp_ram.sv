// Simple dual-port RAM (1 write port, 1 read port, one clock) written for inference.
//
// RAM_STYLE selects the primitive through the Vivado ram_style attribute:
//   "block"       -> RAMB18/RAMB36
//   "ultra"       -> URAM288
//   "distributed" -> LUTRAM
//   "auto"        -> left to the tool
// READ_LATENCY = 1: registered read;  2: plus output register (use at 250 MHz).
// A read of an address written in the same cycle returns the old data; data written
// at clock edge t is visible to reads whose address is sampled at edge t+1 or later.
module sdp_ram #(
    parameter int    DEPTH        = 1024,
    parameter int    WIDTH        = 72,
    parameter string RAM_STYLE    = "block",
    parameter int    READ_LATENCY = 2
) (
    input  logic                             clk,
    input  logic                             we,
    input  logic [$clog2(DEPTH > 1 ? DEPTH : 2)-1:0] waddr,
    input  logic [WIDTH-1:0]                 wdata,
    input  logic                             re,
    input  logic [$clog2(DEPTH > 1 ? DEPTH : 2)-1:0] raddr,
    output logic [WIDTH-1:0]                 rdata
);
    logic [WIDTH-1:0] rd_q, rd_qq;

    // One generate branch per style: the attribute value must be a literal string.
`define SDP_RAM_BODY                                         \
        always_ff @(posedge clk) begin                       \
            if (we) mem[waddr] <= wdata;                     \
        end                                                  \
        always_ff @(posedge clk) begin                       \
            if (re) rd_q <= mem[raddr];                      \
        end

    generate
        if (RAM_STYLE == "ultra") begin : g_ultra
            (* ram_style = "ultra" *) logic [WIDTH-1:0] mem [DEPTH];
            `SDP_RAM_BODY
        end else if (RAM_STYLE == "distributed") begin : g_dist
            (* ram_style = "distributed" *) logic [WIDTH-1:0] mem [DEPTH];
            `SDP_RAM_BODY
        end else if (RAM_STYLE == "block") begin : g_block
            (* ram_style = "block" *) logic [WIDTH-1:0] mem [DEPTH];
            `SDP_RAM_BODY
        end else begin : g_auto
            logic [WIDTH-1:0] mem [DEPTH];
            `SDP_RAM_BODY
        end
    endgenerate
`undef SDP_RAM_BODY

    // Output register enabled by the delayed read enable: this is the form Vivado
    // absorbs into the URAM/BRAM output pipeline register.
    logic re_q;
    always_ff @(posedge clk) begin
        re_q <= re;
        if (re_q) rd_qq <= rd_q;
    end

    assign rdata = (READ_LATENCY >= 2) ? rd_qq : rd_q;

    initial begin
        assert (READ_LATENCY == 1 || READ_LATENCY == 2)
            else $fatal(1, "sdp_ram: READ_LATENCY must be 1 or 2");
    end
endmodule
