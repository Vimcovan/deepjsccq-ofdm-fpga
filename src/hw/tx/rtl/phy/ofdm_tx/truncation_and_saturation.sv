`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/11 14:14:49
// Design Name: 
// Module Name: truncation_and_saturation
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


module truncation_and_saturation#(
        parameter bit ROUND_HALF_UP = 1'b1
    )
    (
        input logic clk,
        input logic rst_n,
        input logic[47:0] s_in_tdata,
        input logic s_in_tvalid,
        output logic s_in_tready,
        output logic[23:0] m_out_tdata,
        output logic m_out_tvalid,
        input logic m_out_tready
    );
        // >>4 instead of >>3: data rms ~322/axis, peak <= ~1300, leaves ~4 dB headroom for OFDM PAPR
        // (with >>3 the rms was 643/axis, only 10 dB below full scale, and peaks up to 2565 were clipped)
        localparam logic[18:0] HALF_LSB = 19'd8;

        logic[18:0] ifft_i_raw,ifft_q_raw;
        logic[18:0] ifft_i_rnd,ifft_q_rnd;
        logic signed[14:0] ifft_q,ifft_i;
        logic[11:0] ifft_i_saturated,ifft_q_saturated;
        always_comb begin
            ifft_i_raw = s_in_tdata[18: 0];
            ifft_q_raw = s_in_tdata[42:24];
            ifft_i_rnd = ROUND_HALF_UP ? (ifft_i_raw + HALF_LSB) : ifft_i_raw;
            ifft_q_rnd = ROUND_HALF_UP ? (ifft_q_raw + HALF_LSB) : ifft_q_raw;
            {ifft_q,ifft_i} = {ifft_q_rnd[18:4],ifft_i_rnd[18:4]};

            if(ifft_i < $signed(-15'd2048) ) ifft_i_saturated = -12'd2048;
            else if(ifft_i > $signed(15'd2047) ) ifft_i_saturated = 12'd2047;
            else ifft_i_saturated = ifft_i[11:0];

            if(ifft_q < $signed(-15'd2048) ) ifft_q_saturated = -12'd2048;
            else if(ifft_q > $signed(15'd2047) ) ifft_q_saturated = 12'd2047;
            else ifft_q_saturated = ifft_q[11:0];

            m_out_tdata = {ifft_q_saturated,ifft_i_saturated};
            m_out_tvalid = s_in_tvalid;
            s_in_tready = m_out_tready;
        end
endmodule
