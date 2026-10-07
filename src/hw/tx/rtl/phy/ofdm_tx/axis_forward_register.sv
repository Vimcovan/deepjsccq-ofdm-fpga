`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/11 10:28:21
// Design Name: 
// Module Name: axis_forward_register
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


module axis_forward_register#(
    parameter STAGE = 1,
    parameter WIDTH = 16
)
(
    input clk,
    input rst_n,
    input logic[WIDTH-1:0] s_in_tdata,
    input logic s_in_tvalid,
    output logic s_in_tready,
    output logic[WIDTH-1:0] m_out_tdata,
    output logic m_out_tvalid,
    input logic m_out_tready
);
    logic [WIDTH-1:0] data_d[0:STAGE-1];
    logic valid_d[0:STAGE-1];
    logic ready_d[0:STAGE-1];
    logic [WIDTH-1:0] data_q[0:STAGE-1];
    logic valid_q[0:STAGE-1];
    logic ready_q[0:STAGE-1];
    always_comb begin
        data_d[0] = s_in_tdata;
        valid_d[0] = s_in_tvalid;
        s_in_tready = ready_d[0];
        m_out_tdata = data_q[STAGE-1];
        m_out_tvalid = valid_q[STAGE-1];
        ready_q[STAGE-1] = m_out_tready;
    end
    generate for(genvar i=0;i<STAGE;i++) begin
            assign ready_d[i] = ~valid_q[i]|ready_q[i];
            always_ff@(posedge clk or negedge rst_n) begin
                if(~rst_n) valid_q[i] <= 1'b0;
                else if(ready_d[i]) valid_q[i] <= valid_d[i];
            end
            always_ff@(posedge clk) begin
                if(valid_d[i] & ready_d[i]) data_q[i] <= data_d[i];
            end
            if(i>0) begin
                always_comb begin
                    data_d[i] = data_q[i-1];
                    valid_d[i] = valid_q[i-1];
                    ready_q[i-1] = ready_d[i];
                end
            end
        end
    endgenerate
endmodule
