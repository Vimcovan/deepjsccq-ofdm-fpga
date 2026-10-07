`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/11 12:05:48
// Design Name: 
// Module Name: fft_ifft_shift
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


module fft_ifft_shift#(
    parameter FFT_LENGTH = 64
)
(
    input logic clk,
    input logic rst_n,
    input logic[23:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[23:0] m_out_tdata,
    output logic m_out_tvalid,
    input logic m_out_tready
    );
    localparam FIFO_DEPTH = FFT_LENGTH/2;
    //FIFO
    logic[23:0] fifo_data_i;
    logic fifo_valid_i;
    logic fifo_ready_i;
    logic[23:0] fifo_data_o;
    logic fifo_valid_o;
    logic fifo_ready_o;
    axis_fifo # (
        .DEPTH(FIFO_DEPTH),
        .WIDTH(24)
    )
    u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(fifo_data_i),
        .s_in_tvalid(fifo_valid_i),
        .s_in_tready(fifo_ready_i),
        .m_out_tdata(fifo_data_o),
        .m_out_tvalid(fifo_valid_o),
        .m_out_tready(fifo_ready_o)
    );
    //ֱͨ
    logic[23:0] through_data_i;
    logic through_valid_i;
    logic through_ready_i;
    logic[23:0] through_data_o;
    logic through_valid_o;
    logic through_ready_o;
    always_comb begin
        through_data_o = through_data_i;
        through_valid_o = through_valid_i;
        through_ready_i = through_ready_o;
    end

    //DEMUX
    logic[$clog2(FIFO_DEPTH)-1:0] demux_cnt;
    logic demux_select;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            demux_cnt <= 'd0;
            demux_select <= 1'b0;
        end
        else if(s_in_tvalid&s_in_tready) begin
            if(demux_cnt==FIFO_DEPTH-1) begin
                demux_cnt <= 'd0;
                demux_select <= ~demux_select;
            end
            else demux_cnt <= demux_cnt + 1;
        end
    end
    always_comb begin
        fifo_data_i = s_in_tdata;
        through_data_i = s_in_tdata;
        if(demux_select==0) begin
            fifo_valid_i = s_in_tvalid;
            s_in_tready = fifo_ready_i;
            through_valid_i = 1'b0;
        end
        else begin
            through_valid_i = s_in_tvalid;
            s_in_tready = through_ready_i;
            fifo_valid_i = 1'b0;
        end
    end

    //MUX
    logic[$clog2(FIFO_DEPTH)-1:0] mux_cnt;
    logic mux_select;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            mux_cnt <= 'd0;
            mux_select <= 1'b1;
        end
        else if(m_out_tvalid&m_out_tready) begin
            if(mux_cnt==FIFO_DEPTH-1) begin
                mux_cnt <= 'd0;
                mux_select <= ~mux_select;
            end
            else mux_cnt <= mux_cnt + 1;
        end
    end
    always_comb begin
        if(mux_select==0) begin
            m_out_tdata = fifo_data_o;
            m_out_tvalid = fifo_valid_o;
            fifo_ready_o = m_out_tready;
            through_ready_o = 1'b0;
        end
        else begin
            m_out_tdata = through_data_o;
            m_out_tvalid = through_valid_o;
            through_ready_o = m_out_tready;
            fifo_ready_o = 1'b0;
        end
    end

endmodule
