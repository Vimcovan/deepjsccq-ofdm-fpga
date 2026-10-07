`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// adc_capture (100 MHz): raw ADC IQ capture for the PS (DMA S2MM). Every ADC sample handed to the RX
//   baseband (fire = valid & ready) is written into a PRE-deep ring; the captured stream is the ring output,
//   i.e. delayed by PRE samples, so a capture starts PRE samples before its trigger.
//   arm (pulse) + trig_mode: 0 = immediately, 1 = at the next PHY frame start (first symbol out of the RX PHY,
//   ~ a few hundred samples after the STF -> PRE = 2048 covers the whole preamble).
//   Output: len samples, {8'h0, Q[11:0], I[11:0]} per 32-bit word, tlast on the last one. The source is real
//   time: a sample that finds the output busy is lost and counted in ovf_cnt (the DMA normally keeps up).
//////////////////////////////////////////////////////////////////////////////////
module adc_capture #(
    parameter int PRE = 2048
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] adc_data,          // {Q, I}
    input  logic        adc_fire,
    input  logic        frame_start,        // pulse
    input  logic        arm,                // pulse
    input  logic [1:0]  trig_mode,
    input  logic [31:0] len,
    output logic        busy,               // armed or capturing
    output logic [31:0] ovf_cnt,
    output logic [31:0] m_tdata,
    output logic        m_tlast,
    output logic        m_tvalid,
    input  logic        m_tready
);
    localparam int AW = $clog2(PRE);
    (* ram_style = "block" *) logic [23:0] ring [0:PRE-1];
    logic [AW-1:0] wptr;
    logic [23:0]   dly;
    logic          dly_v;
    always_ff @(posedge clk) begin
        if (adc_fire) begin
            dly <= ring[wptr];                 // read-first: the sample written PRE fires ago
            ring[wptr] <= adc_data;
        end
    end
    logic armed, cap;
    logic [31:0] cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= '0; dly_v <= 1'b0; armed <= 1'b0; cap <= 1'b0; cnt <= '0; ovf_cnt <= '0;
            m_tvalid <= 1'b0; m_tdata <= '0; m_tlast <= 1'b0;
        end
        else begin
            dly_v <= adc_fire;
            if (adc_fire) wptr <= wptr + 1'b1;
            if (m_tvalid & m_tready) m_tvalid <= 1'b0;
            if (arm) begin armed <= 1'b1; cnt <= '0; end
            if (armed && !cap && (trig_mode == 2'd0 || frame_start)) begin cap <= 1'b1; armed <= 1'b0; end
            if (cap && dly_v) begin
                if (!m_tvalid || m_tready) begin
                    m_tvalid <= 1'b1;
                    m_tdata  <= {8'h00, dly};
                    m_tlast  <= (cnt == len - 1);
                end
                else ovf_cnt <= ovf_cnt + 1'b1;
                cnt <= cnt + 1'b1;
                if (cnt == len - 1) cap <= 1'b0;
            end
        end
    end
    assign busy = armed | cap;
endmodule
