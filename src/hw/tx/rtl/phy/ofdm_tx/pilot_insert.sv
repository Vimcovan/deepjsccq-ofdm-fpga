`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/11 12:37:12
// Design Name: 
// Module Name: pilot_insert
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


module pilot_insert(
    input logic               clk             ,
    input logic               rst_n           ,
    input logic[23:0]         s_in_tdata      ,
    input logic               s_in_tvalid     ,
    output logic              s_in_tready     ,
    output logic[23:0]        m_out_tdata     ,
    output logic              m_out_tvalid    ,
    input logic               m_out_tready
    );
    logic[5:0] symbol_cnt;
    logic[23:0] symbol_data;
    logic symbol_valid;
    logic symbol_ready;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) symbol_cnt <= 'd0;
        else if(symbol_valid & symbol_ready) symbol_cnt <= symbol_cnt + 1;
    end
    logic[1:0] select;
    always_comb begin
        select = 'd0;
        if(symbol_cnt inside {[0:5],32,[59:63]})
            select = 'd1;
        else if(symbol_cnt inside {11,25,39,53})
            select = 'd2;
    end
    always_comb begin
        case(select)
            0:begin
                symbol_data = s_in_tdata;
                symbol_valid = s_in_tvalid;
                s_in_tready = symbol_ready;
            end
            1:begin
                symbol_data = 'd0;
                symbol_valid = 1'b1;
                s_in_tready = 1'b0;
            end
            2:begin
                symbol_data = (symbol_cnt==53)?({12'd0,-12'd1024}):{12'd0,12'd1024};
                symbol_valid = 1'b1;
                s_in_tready = 1'b0;
            end
            default:begin
                symbol_data = 'd0;
                symbol_valid = 1'b0;
                s_in_tready = 1'b0;
            end
        endcase
    end
    axis_forward_register # (
        .WIDTH(24)
    )
    u_reg (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(symbol_data),
        .s_in_tvalid(symbol_valid),
        .s_in_tready(symbol_ready),
        .m_out_tdata(m_out_tdata),
        .m_out_tvalid(m_out_tvalid),
        .m_out_tready(m_out_tready)
    );

endmodule
