`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/13 12:10:34
// Design Name: 
// Module Name: axis_packet_repeat
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


module axis_packet_repeat#(
    parameter WIDTH = 32,
    parameter LENGTH = 64,
    parameter TIMES = 20   
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
    logic in_fire,out_fire;
    assign in_fire = s_in_tvalid & s_in_tready;
    assign out_fire = m_out_tvalid & m_out_tready;
    logic[$clog2(LENGTH)-1:0] beat_cnt;
    logic[$clog2(TIMES)-1:0] packet_cnt;
    typedef enum logic { 
        WRITE = 1'b0,
        READ = 1'b1
    } state_t;
    state_t state_c,state_n;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) state_c <= WRITE;
        else state_c <= state_n;
    end
    always_comb begin
        state_n = state_c;
        case(state_c)
            WRITE: if(in_fire&&(beat_cnt == LENGTH-1)) state_n = READ;
            READ: if(out_fire&&(beat_cnt == LENGTH-1)&&(packet_cnt == TIMES-1)) state_n = WRITE;
        endcase
    end
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            beat_cnt <= 'd0;
            packet_cnt <= 'd0;
        end
        else begin
            case(state_c)
                WRITE: begin
                    if(in_fire) begin
                        if(beat_cnt == LENGTH-1) beat_cnt <= 'd0;
                        else beat_cnt <= beat_cnt + 1;
                    end
                end
                READ: begin
                    if(out_fire) begin
                        if(beat_cnt == LENGTH-1) begin
                            beat_cnt <= 'd0;
                            if(packet_cnt == TIMES-1) packet_cnt <= 'd0;
                            else packet_cnt <= packet_cnt + 1;
                        end
                        else beat_cnt <= beat_cnt + 1;
                    end
                end
            endcase
        end
    end
    (*ram_style="distributed"*)
    logic[WIDTH-1:0] mem[0:LENGTH-1];
    always_ff@(posedge clk) begin
        if(in_fire) mem[beat_cnt] <= s_in_tdata;
    end
    always_comb begin
        m_out_tdata = mem[beat_cnt];
        m_out_tvalid = (state_c == READ);
        s_in_tready = (state_c == WRITE);
    end
endmodule
