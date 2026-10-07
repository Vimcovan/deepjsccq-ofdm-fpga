`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/17 18:44:59
// Design Name: 
// Module Name: axis_ram_srl
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


module axis_ram_srl#(
    parameter LENGTH = 128,
    parameter WIDTH = 8
)
(
    input logic             clk                         ,
    input logic             rst_n                       ,
    input logic[WIDTH-1:0]  s_in_tdata                  ,
    input logic             s_in_tvalid                 ,
    output logic            s_in_tready                 ,

    output logic[WIDTH-1:0] m_out_tdata                 ,
    output logic            m_out_tvalid                ,
    input logic             m_out_tready
);
    logic[$clog2(LENGTH):0] data_count;
    logic wr_en,rd_en;
    logic empty,full;
    //FIFO例化
    fwft_fifo#(
        .DEPTH(LENGTH),
        .WIDTH(WIDTH)
    )
    u_fifo(
        .clk         (clk),
        .rst_n       (rst_n),
        .din         ({>>{s_in_tdata}}),
        .dout        ({>>{m_out_tdata}}),
        .wr_en       (wr_en),
        .rd_en       (rd_en),
        .full        (full),
        .empty       (empty),
        .data_count  (data_count)
    );
    // 说明：本模块是"成对前进"的延迟线(tandem)，不是普通 AXI 缓冲。
    // 输出 valid 被输入 valid 门控，只有上下游同一拍都成交才前进，任何一端停下就整体冻结。
    // 因此延迟输出永远与"当前这一拍输入"同时出现，第 n 拍配对天然成立
    //（frame_detection 里 conj(x[n-LENGTH])*x[n] 的相关配对正是靠这一点）。
    // 注意：下面的 &s_in_tvalid 是刻意的，不要为了"贴合 AXI 惯例"删掉——
    // 删掉后，在"输入停顿 + 下游 ready"那一拍会出现 rd_en=1 而 wr_en=0，
    // 延迟线会白读走一格，有效延迟从 LENGTH 悄悄退化成 LENGTH-1，
    // 且下游 B 侧会复用上一次的样本。代价是流结束时最后 LENGTH 个样本出不来。
    always_comb begin
        m_out_tvalid = (data_count == LENGTH)&s_in_tvalid;
        s_in_tready = (data_count < LENGTH)|((data_count == LENGTH)&m_out_tready);
        rd_en = m_out_tvalid & m_out_tready;
        wr_en = s_in_tvalid & s_in_tready;
    end
endmodule
