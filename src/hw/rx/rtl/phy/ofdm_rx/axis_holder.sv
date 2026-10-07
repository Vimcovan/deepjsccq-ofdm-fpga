`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/12 20:08:05
// Design Name: 
// Module Name: axis_holder
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


module axis_holder#(
        parameter WIDTH = 24,
        parameter N = 64   
    )
    (
        input logic clk,
        input logic rst_n,
        input logic[WIDTH-1:0] s_in_tdata,
        input logic s_in_tvalid,
        output logic s_in_tready,
        output logic[WIDTH-1:0] m_out_tdata,
        output logic m_out_tvalid,
        input logic m_out_tready
    );
    logic[$clog2(N)-1:0] out_cnt;
    assign s_in_tready = ~m_out_tvalid | (m_out_tready & (out_cnt == N-1));
    assign in_fire = s_in_tvalid & s_in_tready;
    assign out_fire = m_out_tvalid & m_out_tready;
    //计数器维护（该计数器计数的是输出的拍数，因此必须和out_fire绑定）
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) out_cnt <= 'd0;
        else begin
            if(out_fire) begin
                if(out_cnt == N-1) out_cnt <= 'd0;
                else out_cnt <= out_cnt + 1;
            end
        end
    end
    //m_out_tvalid控制
    always_ff@(posedge clk or negedge rst_n) begin
        if (~rst_n) m_out_tvalid <= 1'b0;
        else begin
            if(in_fire) m_out_tvalid <= 1'b1;
            else if(out_fire&(out_cnt==N-1)) m_out_tvalid <= 1'b0;
        end
    end
    
    //保持
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n)  m_out_tdata <= 'd0;
        else if(in_fire|out_fire) begin
            m_out_tdata <= (in_fire)?s_in_tdata:m_out_tdata;
        end
    end
endmodule
