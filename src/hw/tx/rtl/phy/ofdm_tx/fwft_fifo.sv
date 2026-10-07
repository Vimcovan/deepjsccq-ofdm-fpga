`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/11 12:02:37
// Design Name: 
// Module Name: fwft_fifo
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


module fwft_fifo#(
    parameter DEPTH = 256,
    parameter WIDTH = 16
)
(
    input logic                           clk         ,
    input logic                           rst_n       ,
    
    input logic[WIDTH-1:0]                din         ,
    output logic[WIDTH-1:0]               dout        ,
    input logic                           wr_en       ,
    input logic                           rd_en       ,
    output logic                          full        ,
    output logic                          empty       ,
    output logic[$clog2(DEPTH):0]         data_count
);
    //定义RAM
    localparam PDEPTH = 2**$clog2(DEPTH);
    (* ram_style = "auto" *)
    logic[WIDTH-1:0] ram[0:PDEPTH-1];
    logic ram_wr_en,ram_rd_en;
    logic[WIDTH-1:0] ram_dout;
    logic[$clog2(DEPTH):0] wr_ptr,rd_ptr;

    //RAM读写
    assign ram_wr_en = wr_en & (~full);
    always_ff@(posedge clk) begin
        if(ram_wr_en) ram[wr_ptr[$clog2(DEPTH)-1:0]] <= din;
        if(ram_rd_en) ram_dout <= ram[rd_ptr[$clog2(DEPTH)-1:0]];
    end

    //指针控制
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            wr_ptr <= 'd0;
            rd_ptr <= 'd0;
        end
        else begin
            if(ram_wr_en) wr_ptr <= wr_ptr + 1;
            if(ram_rd_en) rd_ptr <= rd_ptr + 1;
        end
    end

    //空满标志
    assign ram_empty = (wr_ptr == rd_ptr);
    assign ram_full = (wr_ptr == {~rd_ptr[$clog2(DEPTH)],rd_ptr[$clog2(DEPTH)-1:0]});
    
    //预取寄存器控制
    logic reg_rd_en;
    logic reg_empty;
    assign reg_rd_en = (~reg_empty) & rd_en;
    assign dout = ram_dout;
    assign ram_rd_en = (reg_empty|reg_rd_en) & (~ram_empty);
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) reg_empty <= 1'b1;
        else begin
            if(ram_rd_en) reg_empty <= 1'b0;
            else if(ram_empty & reg_rd_en) reg_empty <= 1'b1;
        end
    end

    assign full = ram_full;
    assign empty = reg_empty;

    //数据计数
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) data_count <= 'd0;
        else begin
            if(wr_en & rd_en) data_count <= data_count;
            else if(wr_en) data_count <= data_count + 1;
            else if(rd_en) data_count <= data_count - 1;
        end
    end
endmodule
