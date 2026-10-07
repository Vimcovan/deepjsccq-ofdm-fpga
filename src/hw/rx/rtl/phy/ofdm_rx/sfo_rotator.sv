`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sfo_rotator: tracking SFO compensation, rotation part (sits BEFORE CPE_compensation).
//
//   Each data symbol is rotated by exp(-j*k*A_pred), k = -32..31 (fftshift order), where
//     A_pred = A + R                       predicted phase slope (rad/subcarrier) of this symbol
//   and the loop is closed by sfo_residual (after CPE), which measures the residual slope e of the
//   symbol that was just rotated (LS weights -21/-7/+7/+21 on Im(pilot), small angle is fine because
//   the residual is small) and returns it through e_valid/e_data:
//     R <= R + e/256                       (second order: slope increment per symbol = SFO)
//     A <= A_pred + e/8                    (first order)
//   The next symbol is only started after the residual of the previous one is back (token), i.e. the
//   residual of symbol n is applied from symbol n+1 on (same as PHY_80211a.m, SFO_MODE='track').
//   A and R restart from 0 at every frame (first data symbol after the LTF): the LTF channel estimate
//   is the timing reference of the frame.
//
// Units: A, R, A_pred and the phase accumulator are pi-scaled radians with 29 fraction bits
//   (value 2^29 = pi rad). e_data is the raw LS sum L = sum(w*Im(p)) with pilot amplitude 1024 after
//   CPE, slope[rad] = L/(980*1024)  ->  L * 2^29/(980*1024*pi) = L * 170.29 ~= L*(128+32+8+2) (-0.17%),
//   shift-add only. The CORDIC input (pi-scaled Q3.13) is taken from bits [29:16] of the accumulator,
//   so the phase wraps at +-pi for free (two's complement) and the drift may exceed one sample.
// Multipliers: CORDIC + one complex multiplier, reused from the old SFO_compensation (no new DSP).
//////////////////////////////////////////////////////////////////////////////////
module sfo_rotator#(
    parameter NSYM = 20             // data OFDM symbols per frame
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] s_in_tdata,
    input  logic        s_in_tvalid,
    output logic        s_in_tready,
    output logic [23:0] m_out_tdata,
    output logic        m_out_tvalid,
    input  logic        m_out_tready,
    // residual slope of the last rotated symbol (from sfo_residual)
    input  logic        e_valid,
    input  logic [17:0] e_data
);
    /* ---------------- tracking loop ---------------- */
    logic signed [31:0] A, R, A_pred;
    logic signed [31:0] e_q;
    logic signed [31:0] e_s;
    assign e_s = {{14{e_data[17]}}, e_data};
    assign e_q = (e_s <<< 7) + (e_s <<< 5) + (e_s <<< 3) + (e_s <<< 1);    // L * 170

    logic                      tok;          // residual of the previous symbol is back -> may start the next one
    logic [$clog2(NSYM)-1:0]   sym_cnt;      // data symbol index in the frame (of the next symbol to start)
    logic [5:0]                phase_cnt;
    logic signed [31:0]        ph;           // -k*A_pred, k = phase_cnt-32
    logic                      phase_valid_o;
    logic                      phase_ready_o;
    logic                      start;
    assign start = tok & ~phase_valid_o;
    wire phase_out_fire = phase_valid_o & phase_ready_o;
    wire signed [31:0] a_pred_n = (sym_cnt == 0) ? 32'sd0 : (A + R);

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            A <= '0; R <= '0; A_pred <= '0; tok <= 1'b1; sym_cnt <= '0;
            phase_valid_o <= 1'b0; phase_cnt <= '0; ph <= '0;
        end
        else begin
            if (start) begin
                tok           <= 1'b0;
                A_pred        <= a_pred_n;
                if (sym_cnt == 0) R <= '0;                       // new frame: restart the loop
                sym_cnt       <= (sym_cnt == NSYM-1) ? '0 : sym_cnt + 1'b1;
                ph            <= a_pred_n <<< 5;                  // k = -32: -k*A_pred = 32*A_pred
                phase_cnt     <= '0;
                phase_valid_o <= 1'b1;
            end
            else if (phase_out_fire) begin
                ph <= ph - A_pred;
                if (phase_cnt == 63) phase_valid_o <= 1'b0;
                phase_cnt <= phase_cnt + 1'b1;
            end
            if (e_valid) begin                                  // never in the same cycle as start (tok = 0)
                R   <= R + (e_q >>> 8);
                A   <= A_pred + (e_q >>> 3);
                tok <= 1'b1;
            end
        end
    end

    /* ---------------- CORDIC: rotation factors ---------------- */
    logic [31:0] rot_data_o;
    logic        rot_valid_o;
    logic        rot_ready_o;
    cordic_sin_cos u_sin_cos (
        .aclk(clk),
        .aresetn(rst_n),
        .s_axis_phase_tvalid(phase_valid_o),
        .s_axis_phase_tready(phase_ready_o),
        .s_axis_phase_tdata({{2{ph[29]}}, ph[29:16]}),      // pi-scaled Q3.13, wrapped to [-1,1)
        .m_axis_dout_tvalid(rot_valid_o),
        .m_axis_dout_tready(rot_ready_o),
        .m_axis_dout_tdata(rot_data_o)
    );

    /* ---------------- data path ---------------- */
    logic [23:0] fifo_data_o;
    logic        fifo_valid_o;
    logic        fifo_ready_o;
    axis_fifo # (
        .DEPTH(64),
        .WIDTH(24)
    )
    axis_fifo_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(s_in_tdata),
        .s_in_tvalid(s_in_tvalid),
        .s_in_tready(s_in_tready),
        .m_out_tdata(fifo_data_o),
        .m_out_tvalid(fifo_valid_o),
        .m_out_tready(fifo_ready_o)
    );
    // same output scaling / saturation as the old SFO_compensation
    logic [49:0] cmpy_data_o;
    logic signed [13:0] spi_wide, spq_wide;
    logic signed [11:0] spi_sat,  spq_sat;
    assign spi_wide = cmpy_data_o[23:10];
    assign spq_wide = cmpy_data_o[48:35];
    assign spi_sat  = (spi_wide >  14'sd2047) ?  12'sd2047 :
                      (spi_wide < -14'sd2048) ? -12'sd2048 :  spi_wide[11:0];
    assign spq_sat  = (spq_wide >  14'sd2047) ?  12'sd2047 :
                      (spq_wide < -14'sd2048) ? -12'sd2048 :  spq_wide[11:0];
    assign m_out_tdata = {spq_sat, spi_sat};
    complex_multiplier # (
        .A_W(12),
        .B_W(12)
    )
    u_cmpy (
        .clk(clk),
        .rst_n(rst_n),
        .s_a_tdata({rot_data_o[27:16], rot_data_o[11:0]}),
        .s_a_tvalid(rot_valid_o),
        .s_a_tready(rot_ready_o),
        .s_b_tdata(fifo_data_o),
        .s_b_tvalid(fifo_valid_o),
        .s_b_tready(fifo_ready_o),
        .m_p_tdata(cmpy_data_o),
        .m_p_tvalid(m_out_tvalid),
        .m_p_tready(m_out_tready)
    );
endmodule
