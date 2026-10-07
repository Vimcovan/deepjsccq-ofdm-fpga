`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/17 18:42:12
// Design Name: 
// Module Name: slide_win_sum
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


module slide_win_sum#(
    parameter WIDTH = 12,
    parameter LENGTH = 64   
)
(
    input logic clk,
    input logic rst_n,
    input logic[WIDTH-1:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[WIDTH+$clog2(LENGTH)-1:0] m_out_tdata,
    output logic m_out_tvalid,
    input logic m_out_tready
);
    /* 直通和延迟 */
    //直通
    logic[WIDTH-1:0] thru_data;
    logic thru_valid;
    logic thru_ready;
    //延迟
    logic[WIDTH-1:0] srl_data_i;
    logic srl_valid_i;
    logic srl_ready_i;
    logic[WIDTH-1:0] srl_data_o;
    logic srl_valid_o;
    logic srl_ready_o;
    axis_ram_srl # (
        .LENGTH(LENGTH),
        .WIDTH(WIDTH)
    )
    axis_ram_srl_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(srl_data_i),
        .s_in_tvalid(srl_valid_i),
        .s_in_tready(srl_ready_i),
        .m_out_tdata(srl_data_o),
        .m_out_tvalid(srl_valid_o),
        .m_out_tready(srl_ready_o)
    );
    //互连
    always_comb begin
        thru_data = s_in_tdata;
        srl_data_i = s_in_tdata;
        thru_valid = s_in_tvalid & srl_ready_i;
        srl_valid_i = s_in_tvalid & thru_valid;
        s_in_tready = thru_ready & srl_ready_i;
    end

    /* 累加 */
    //计数器
    logic sum_valid_i;
    logic sum_ready_i;
    logic sum_in_fire;
    assign sum_in_fire = sum_valid_i & sum_ready_i;
    logic[$clog2(LENGTH):0] fill_cnt;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) fill_cnt <= 'd0;
        else if(sum_in_fire) begin
            if(fill_cnt < LENGTH) fill_cnt <= fill_cnt + 1;
        end
    end
    //输出data
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) m_out_tdata <= 'd0;
        else if(sum_in_fire) begin
            if(~fill_cnt[$clog2(LENGTH)])
                m_out_tdata <= m_out_tdata + 
                                {{$clog2(LENGTH){thru_data[WIDTH-1]}},thru_data};
            else
                m_out_tdata <= m_out_tdata + 
                                {{$clog2(LENGTH){thru_data[WIDTH-1]}},thru_data} -
                                {{$clog2(LENGTH){srl_data_o[WIDTH-1]}},srl_data_o};
        end
    end
    //输出valid
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) m_out_tvalid <= 1'b0;
        else begin
            if(sum_in_fire&(fill_cnt>=LENGTH-1)) m_out_tvalid <= 1'b1;
            else if(m_out_tvalid&m_out_tready) m_out_tvalid <= 1'b0;
        end
    end
    //互连
    always_comb begin
        sum_ready_i = ~m_out_tvalid|m_out_tready;
        if(~fill_cnt[$clog2(LENGTH)]) begin
            sum_valid_i = thru_valid;
            thru_ready = sum_ready_i;
            srl_ready_o = 1'b1;
        end
        else begin
            sum_valid_i = srl_valid_o;
            thru_ready = 1'b1;
            srl_ready_o = sum_ready_i;
        end
    end
endmodule
