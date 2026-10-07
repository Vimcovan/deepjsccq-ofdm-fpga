`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/11 10:36:44
// Design Name: 
// Module Name: preamble_insert
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


module preamble_insert#(
    parameter PREAMBLE_LENGTH = 320,
    parameter DATA_LENGTH = 1600
)
(
    input logic               clk             ,
    input logic               rst_n           ,
    input logic[23:0]         s_in_tdata      ,
    input logic               s_in_tvalid     ,
    output logic              s_in_tready     ,
    output logic[23:0]        m_out_tdata     ,
    output logic              m_out_tvalid    ,
    output logic              m_out_tlast     ,
    input logic               m_out_tready
    );
    // �洢ǰ���벢Ԥȡ
    (* rom_style = "block" *)
    logic[23:0] preamble_rom[0:PREAMBLE_LENGTH-1];
    initial $readmemh("preamble.mem",preamble_rom);
    logic[$clog2(PREAMBLE_LENGTH)-1:0] preamble_addr;
    logic preamble_ready_i;
    logic[23:0] preamble_data_o;
    logic preamble_valid_o;
    logic preamble_ready_o;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) preamble_addr <= 'd0;
        else if(preamble_ready_i) begin
            if(preamble_addr == PREAMBLE_LENGTH-1) preamble_addr <= 'd0;
            else preamble_addr <= preamble_addr + 1;
        end
    end
    axis_forward_register # (
        .WIDTH(24)
    )
    u_preamble_prefetch (
        .clk(clk),
        .rst_n(rst_n),
        // halve the preamble to match the data scaling in truncation_and_saturation (>>4)
        .s_in_tdata({$signed(preamble_rom[preamble_addr][23:12]) >>> 1, $signed(preamble_rom[preamble_addr][11:0]) >>> 1}),
        .s_in_tvalid(1'b1),
        .s_in_tready(preamble_ready_i),
        .m_out_tdata(preamble_data_o),
        .m_out_tvalid(preamble_valid_o),
        .m_out_tready(preamble_ready_o)
    );

    // ��·ѡ����
    logic[$clog2(PREAMBLE_LENGTH+DATA_LENGTH)-1:0] sample_cnt;
    logic select;
    logic[23:0] sample_data;
    logic sample_valid;
    logic sample_ready;
    logic sample_last;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) sample_cnt <= 'd0;
        else if(sample_valid&sample_ready) begin
            if(sample_cnt==(PREAMBLE_LENGTH+DATA_LENGTH-1)) sample_cnt <= 'd0;
            else sample_cnt <= sample_cnt + 1;
        end
    end
    always_comb begin
        select =(sample_cnt<PREAMBLE_LENGTH)?1'b0:1'b1;
        sample_last = (sample_cnt==(PREAMBLE_LENGTH+DATA_LENGTH-1));
        if(select==1'b0) begin
            sample_data = preamble_data_o;
            sample_valid = preamble_valid_o;
            preamble_ready_o = sample_ready;
            s_in_tready = 1'b0;
        end
        else begin
            sample_data = s_in_tdata;
            sample_valid = s_in_tvalid;
            s_in_tready = sample_ready;
            preamble_ready_o = 1'b0;
        end
    end
    axis_forward_register # (
        .WIDTH(25)
    )
    u_reg (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata({sample_last,sample_data}),
        .s_in_tvalid(sample_valid),
        .s_in_tready(sample_ready),
        .m_out_tdata({m_out_tlast,m_out_tdata}),
        .m_out_tvalid(m_out_tvalid),
        .m_out_tready(m_out_tready)
    );
endmodule
