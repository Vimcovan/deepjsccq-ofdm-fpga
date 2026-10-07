`timescale 1ns / 1ps
////////////////////////////////////////////////////////////////////////////////
// axis_async_fifo: AXI-Stream clock domain crossing built on the AMD XPM
// xpm_fifo_axis primitive (independent clocks, FWFT, no packet mode).
//
// One beat = {tdata, tlast, tuser}: tlast and tuser are part of the beat, so the
// frame boundary crosses the domain boundary with the data.
//
//   DEPTH     number of beats, must be a power of two and >= 16 (XPM requirement)
//   RAM_STYLE "auto" / "block" / "distributed" / "ultra"
//
// xpm_fifo_axis has ONE asynchronous reset (s_aresetn, active low) that resets both
// sides, so rst_n must be released only after BOTH clock domains are out of reset
// (wr_rst_busy/rd_rst_busy are handled inside the primitive).
////////////////////////////////////////////////////////////////////////////////
module axis_async_fifo #(
    parameter int    DATA_W    = 24,
    parameter int    USER_W    = 1,
    parameter int    DEPTH     = 32,
    parameter string RAM_STYLE = "distributed"
)(
    input  logic                 rst_n,

    input  logic                 s_clk,
    input  logic [DATA_W-1:0]    s_tdata,
    input  logic                 s_tlast,
    input  logic [USER_W-1:0]    s_tuser,
    input  logic                 s_tvalid,
    output logic                 s_tready,

    input  logic                 m_clk,
    output logic [DATA_W-1:0]    m_tdata,
    output logic                 m_tlast,
    output logic [USER_W-1:0]    m_tuser,
    output logic                 m_tvalid,
    input  logic                 m_tready
);

    xpm_fifo_axis #(
        .CASCADE_HEIGHT       (0),
        .CDC_SYNC_STAGES      (2),
        .CLOCKING_MODE        ("independent_clock"),
        .ECC_MODE             ("no_ecc"),
        .EN_SIM_ASSERT_ERR    ("warning"),
        .FIFO_DEPTH           (DEPTH),
        .FIFO_MEMORY_TYPE     (RAM_STYLE),
        .PACKET_FIFO          ("false"),
        .PROG_EMPTY_THRESH    (5),
        .PROG_FULL_THRESH     (8),
        .RD_DATA_COUNT_WIDTH  ($clog2(DEPTH) + 1),
        .RELATED_CLOCKS       (0),
        .SIM_ASSERT_CHK       (0),
        .TDATA_WIDTH          (DATA_W),
        .TDEST_WIDTH          (1),
        .TID_WIDTH            (1),
        .TUSER_WIDTH          (USER_W),
        .USE_ADV_FEATURES     ("0000"),
        .WR_DATA_COUNT_WIDTH  ($clog2(DEPTH) + 1)
    ) u_xpm_fifo_axis (
        .s_aclk             (s_clk),
        .s_aresetn          (rst_n),
        .s_axis_tdata       (s_tdata),
        .s_axis_tlast       (s_tlast),
        .s_axis_tuser       (s_tuser),
        .s_axis_tvalid      (s_tvalid),
        .s_axis_tready      (s_tready),
        .s_axis_tkeep       ('1),
        .s_axis_tstrb       ('1),
        .s_axis_tdest       ('0),
        .s_axis_tid         ('0),

        .m_aclk             (m_clk),
        .m_axis_tdata       (m_tdata),
        .m_axis_tlast       (m_tlast),
        .m_axis_tuser       (m_tuser),
        .m_axis_tvalid      (m_tvalid),
        .m_axis_tready      (m_tready),

        .almost_empty_axis  (),
        .almost_full_axis   (),
        .dbiterr_axis       (),
        .prog_empty_axis    (),
        .prog_full_axis     (),
        .rd_data_count_axis (),
        .wr_data_count_axis (),
        .sbiterr_axis       (),
        .injectdbiterr_axis (1'b0),
        .injectsbiterr_axis (1'b0)
    );

endmodule
