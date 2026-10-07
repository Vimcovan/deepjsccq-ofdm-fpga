`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tx_baseband_jscc: OFDM TX for DeepJSCC IQ symbols (bit chain removed): framer + PN -> pilot insert ->
//   ifftshift -> IFFT/CP -> truncation -> preamble -> URAM frame buffer (packet mode) -> DAC side.
//////////////////////////////////////////////////////////////////////////////////
module tx_baseband_jscc#(
        parameter NSYM       = 683,         // OFDM data symbols per frame
        parameter FRAME_SYMS = 32768        // DeepJSCC symbols per frame (padded to NSYM*48 with zeros)
    )
    (
        input  logic        clk,
        input  logic        rst_n,
        // DeepJSCC IQ symbols (PHY_INTERFACE.md): {Q[11:0], I[11:0]} Q10, tlast on the last symbol of a frame
        input  logic [23:0] s_in_tdata,
        input  logic        s_in_tlast,
        input  logic        s_in_tvalid,
        output logic        s_in_tready,
        output logic [23:0] m_out_tdata,
        output logic        m_out_tvalid,
        output logic        m_out_tlast,
        input  logic        m_out_tready,
        output logic        tlast_err,      // input tlast not on symbol FRAME_SYMS-1
        output logic [31:0] frames_buffered
    );
    // symbols -> PN sign scrambling -> 48 data subcarriers per OFDM symbol (+ zero padding of the last one)
    logic[23:0] qam_odata;
    logic qam_ovalid;
    logic qam_oready;
    tx_jscc_framer # (.FRAME_SYMS(FRAME_SYMS), .PAD(NSYM*48-FRAME_SYMS)) u_framer (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_in_tdata), .s_tlast(s_in_tlast), .s_tvalid(s_in_tvalid), .s_tready(s_in_tready),
        .m_tdata(qam_odata), .m_tvalid(qam_ovalid), .m_tready(qam_oready), .tlast_err(tlast_err)
    );
    logic[23:0] pilot_odata;
    logic pilot_ovalid;
    logic pilot_oready;
    pilot_insert  u_pilot (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(qam_odata),
        .s_in_tvalid(qam_ovalid),
        .s_in_tready(qam_oready),
        .m_out_tdata(pilot_odata),
        .m_out_tvalid(pilot_ovalid),
        .m_out_tready(pilot_oready)
    );
    logic[23:0] shift_odata;
    logic shift_ovalid;
    logic shift_oready;
    fft_ifft_shift  ifftshift_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(pilot_odata),
        .s_in_tvalid(pilot_ovalid),
        .s_in_tready(pilot_oready),
        .m_out_tdata(shift_odata),
        .m_out_tvalid(shift_ovalid),
        .m_out_tready(shift_oready)
    );
    logic[47:0] ifft_odata;
    logic ifft_ovalid;
    logic ifft_oready;
    ifft u_ifft (
        .aclk(clk),                                                // input logic aclk
        .aresetn(rst_n),                                           // input logic aresetn (ACTIVE LOW)
        .s_axis_config_tdata({7'd0,1'b0,8'd16}),                  // input logic [15 : 0] s_axis_config_tdata
        .s_axis_config_tvalid(1'b1),                // input logic s_axis_config_tvalid
        .s_axis_config_tready(),                // output logic s_axis_config_tready
        .s_axis_data_tdata({4'd0,shift_odata[23:12],4'd0,shift_odata[11:0]}),                      // input logic [31 : 0] s_axis_data_tdata
        .s_axis_data_tvalid(shift_ovalid),                    // input logic s_axis_data_tvalid
        .s_axis_data_tready(shift_oready),                    // output logic s_axis_data_tready
        .s_axis_data_tlast(1'b0),                      // input logic s_axis_data_tlast
        .m_axis_data_tdata(ifft_odata),                      // output logic [47 : 0] m_axis_data_tdata
        .m_axis_data_tvalid(ifft_ovalid),                    // output logic m_axis_data_tvalid
        .m_axis_data_tready(ifft_oready),                    // input logic m_axis_data_tready
        .m_axis_data_tlast(),                      // output logic m_axis_data_tlast
        .event_frame_started(),                  // output logic event_frame_started
        .event_tlast_unexpected(),            // output logic event_tlast_unexpected
        .event_tlast_missing(),                  // output logic event_tlast_missing
        .event_status_channel_halt(),      // output logic event_status_channel_halt
        .event_data_in_channel_halt(),    // output logic event_data_in_channel_halt
        .event_data_out_channel_halt()  // output logic event_data_out_channel_halt
    );
    logic[23:0] trunc_odata;
    logic trunc_ovalid;
    logic trunc_oready;
    truncation_and_saturation  truncation_and_saturation_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(ifft_odata),
        .s_in_tvalid(ifft_ovalid),
        .s_in_tready(ifft_oready),
        .m_out_tdata(trunc_odata),
        .m_out_tvalid(trunc_ovalid),
        .m_out_tready(trunc_oready)
    );
    logic[23:0] preamble_odata;
    logic preamble_olast;
    logic preamble_ovalid;
    logic preamble_oready;
    preamble_insert # (.DATA_LENGTH(80*NSYM)) preamble_insert_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(trunc_odata),
        .s_in_tvalid(trunc_ovalid),
        .s_in_tready(trunc_oready),
        .m_out_tdata(preamble_odata),
        .m_out_tvalid(preamble_ovalid),
        .m_out_tlast(preamble_olast),
        .m_out_tready(preamble_oready)
    );
    // frame buffer in front of the DAC: the only buffer of the TX chain (everything upstream is back-pressured).
    // A frame is released only when complete, so the 20 MSPS reader never underruns. 54960 samples = 18320
    // words of 3 samples; 6 URAM (24576 words = 1.34 frames).
    uram_frame_fifo # (
        .FRAME_LEN(320 + 80*NSYM),
        .DEPTH_WORDS(24576),
        .PACKET_MODE(1)
    )
    u_frame_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .s_tdata(preamble_odata),
        .s_tvalid(preamble_ovalid),
        .s_tready(preamble_oready),
        .m_tdata(m_out_tdata),
        .m_tlast(m_out_tlast),
        .m_tuser(),
        .m_tvalid(m_out_tvalid),
        .m_tready(m_out_tready),
        .frames_in(frames_buffered),
        .dropped_frames()
    );
endmodule
