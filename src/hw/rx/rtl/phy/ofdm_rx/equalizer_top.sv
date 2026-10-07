`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/13 14:53:51
// Design Name: 
// Module Name: equalizer_top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module equalizer_top#(
    parameter NSYM = 20         // data OFDM symbols per frame
)
(
    input logic clk,
    input logic rst_n,
    input logic[23:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[23:0] m_out_tdata,
    output logic m_out_tvalid,
    input logic m_out_tready,
    // read-only debug taps (telemetry): {Q,I} + handshake fire of each equalizer stage
    output logic[23:0] dbg_pre_data,    // fft_ifft_shift output (pre-EQ, (NSYM+2) sym x 64 per frame: LTF1, LTF2, data)
    output logic       dbg_pre_fire,
    output logic[23:0] dbg_ce_data,     // channel_equalization output (NSYM sym x 64)
    output logic       dbg_ce_fire,
    output logic[23:0] dbg_cpe_data,    // CPE_compensation output = final equalizer output (NSYM sym x 64)
    output logic       dbg_cpe_fire,
    output logic[23:0] dbg_sfo_data,    // sfo_rotator output (after SFO rotation, before CPE; NSYM sym x 64)
    output logic       dbg_sfo_fire
    );
    logic[47:0] fft_data_o;
    logic fft_valid_o;
    logic fft_ready_o;
    fft u_fft (
        .aclk(clk),                                                // input wire aclk
        .aresetn(rst_n),                                     // input wire aresetn
        .s_axis_config_tdata({7'd0,1'b1}),                  // input wire [7 : 0] s_axis_config_tdata
        .s_axis_config_tvalid(1'b1),                // input wire s_axis_config_tvalid
        .s_axis_data_tdata({4'd0,s_in_tdata[23:12],4'd0,s_in_tdata[11:0]}),                      // input wire [31 : 0] s_axis_data_tdata
        .s_axis_data_tvalid(s_in_tvalid),                    // input wire s_axis_data_tvalid
        .s_axis_data_tready(s_in_tready),                    // output wire s_axis_data_tready
        .s_axis_data_tlast(1'b1),                      // input wire s_axis_data_tlast
        .m_axis_data_tdata(fft_data_o),                      // output wire [47 : 0] m_axis_data_tdata
        .m_axis_data_tvalid(fft_valid_o),                    // output wire m_axis_data_tvalid
        .m_axis_data_tready(fft_ready_o)                    // input wire m_axis_data_tready
    );
    logic[23:0] shift_data_o;
    logic shift_valid_o;
    logic shift_ready_o;
    fft_ifft_shift # (
        .FFT_LENGTH(64)
    )
    u_shift (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata({fft_data_o[38:27],fft_data_o[14:3]}),
        .s_in_tvalid(fft_valid_o),
        .s_in_tready(fft_ready_o),
        .m_out_tdata(shift_data_o),
        .m_out_tvalid(shift_valid_o),
        .m_out_tready(shift_ready_o)
    );
    logic[23:0] ce_data_o;
    logic ce_valid_o;
    logic ce_ready_o;
    channel_equalization # (.NSYM(NSYM)) u_ce (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(shift_data_o),
        .s_in_tvalid(shift_valid_o),
        .s_in_tready(shift_ready_o),
        .m_out_tdata(ce_data_o),
        .m_out_tvalid(ce_valid_o),
        .m_out_tready(ce_ready_o)
    );
    // tracking SFO: CE -> sfo_rotator (rotate by predicted slope) -> CPE -> sfo_residual (measure residual slope,
    // fed back to the rotator for the next symbol). Rotation before CPE: a large slope would shrink / flip the CPE
    // pilot sum (-6 dB at 0.71 sample drift, sign flip at 1.15).
    logic[23:0] rot_data_o;
    logic rot_valid_o;
    logic rot_ready_o;
    logic       sfo_e_valid;
    logic[17:0] sfo_e_data;
    sfo_rotator # (.NSYM(NSYM)) u_sfo_rot (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(ce_data_o),
        .s_in_tvalid(ce_valid_o),
        .s_in_tready(ce_ready_o),
        .m_out_tdata(rot_data_o),
        .m_out_tvalid(rot_valid_o),
        .m_out_tready(rot_ready_o),
        .e_valid(sfo_e_valid),
        .e_data(sfo_e_data)
    );
    logic[23:0] cpe_data_o;
    logic cpe_valid_o;
    logic cpe_ready_o;
    CPE_compensation  u_cpe (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(rot_data_o),
        .s_in_tvalid(rot_valid_o),
        .s_in_tready(rot_ready_o),
        .m_out_tdata(cpe_data_o),
        .m_out_tvalid(cpe_valid_o),
        .m_out_tready(cpe_ready_o)
    );
    logic[23:0] sfo_data_o;     // final equalizer stream (after CPE)
    logic sfo_valid_o;
    logic sfo_ready_o;
    sfo_residual u_sfo_res (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(cpe_data_o),
        .s_in_tvalid(cpe_valid_o),
        .s_in_tready(cpe_ready_o),
        .m_out_tdata(sfo_data_o),
        .m_out_tvalid(sfo_valid_o),
        .m_out_tready(sfo_ready_o),
        .e_valid(sfo_e_valid),
        .e_data(sfo_e_data)
    );
    assign dbg_pre_data = shift_data_o;  assign dbg_pre_fire = shift_valid_o & shift_ready_o;
    assign dbg_ce_data  = ce_data_o;     assign dbg_ce_fire  = ce_valid_o & ce_ready_o;
    assign dbg_cpe_data = cpe_data_o;    assign dbg_cpe_fire = cpe_valid_o & cpe_ready_o;   // final (after SFO rotation + CPE)
    assign dbg_sfo_data = rot_data_o;    assign dbg_sfo_fire = rot_valid_o & rot_ready_o;   // after SFO rotation, before CPE
    logic[5:0] sample_cnt;   
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) sample_cnt <= 6'd0;
        else if(sfo_valid_o & sfo_ready_o) sample_cnt <= sample_cnt + 1;
    end
    always_comb begin
        m_out_tdata = sfo_data_o;
        if(sample_cnt inside {0,1,2,3,4,5,11,25,32,39,53,59,60,61,62,63}) begin
            m_out_tvalid = 1'b0;
            sfo_ready_o = 1'b1;
        end
        else begin
            m_out_tvalid = sfo_valid_o;
            sfo_ready_o = m_out_tready;
        end
    end
endmodule
