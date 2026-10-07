`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// axis_unpack8: 32-bit words from the PS DMA -> one byte per beat (byte 0 = bits [7:0] first, little endian,
//   i.e. the order of a numpy uint8 array). tlast of the DMA transfer is ignored (the encoder frames itself).
//////////////////////////////////////////////////////////////////////////////////
module axis_unpack8 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] s_tdata,
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [7:0]  m_tdata,
    output logic        m_tvalid,
    input  logic        m_tready
);
    logic [31:0] w;
    logic [1:0]  idx;
    logic        full;
    assign s_tready = ~full | (m_tready & (idx == 2'd3));
    assign m_tvalid = full;
    assign m_tdata  = w[8*idx +: 8];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin w <= '0; idx <= '0; full <= 1'b0; end
        else begin
            if (full & m_tready) begin
                idx <= idx + 1'b1;
                if (idx == 2'd3) full <= 1'b0;
            end
            if (s_tvalid & s_tready) begin w <= s_tdata; full <= 1'b1; idx <= '0; end
        end
    end
endmodule
