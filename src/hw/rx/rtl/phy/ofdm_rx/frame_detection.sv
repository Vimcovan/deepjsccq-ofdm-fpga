`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/09/18 15:10:59
// Design Name: 
// Module Name: frame_detection
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


module frame_detection#(
    // STF 16-sample energy gate: sum(|x|^2/1024) > ENERGY_THRESH. was 1000 (rms>253); 250 -> rms>126 (AGC lock-level headroom)
    parameter ENERGY_THRESH = 250,
    parameter SYMBOL_PER_FRAME = 20
)
(
    input logic           clk                 ,
    input logic           rst_n               ,
    input logic[23:0]     s_in_tdata          ,
    input logic           s_in_tvalid         ,
    output logic          s_in_tready         ,
    output logic[23:0]    m_out_tdata         ,
    output logic          m_out_tvalid        ,
    input logic           m_out_tready
    );
    //FIFO缓存输入数据
    logic[23:0] fifo_data_i;
    logic fifo_valid_i;
    logic fifo_ready_i;
    logic[23:0] fifo_data_o;
    logic fifo_valid_o;
    logic fifo_ready_o;
    axis_fifo # (
        .DEPTH(128),
        .WIDTH(24)
    )
    u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(fifo_data_i),
        .s_in_tvalid(fifo_valid_i),
        .s_in_tready(fifo_ready_i),
        .m_out_tdata(fifo_data_o),
        .m_out_tvalid(fifo_valid_o),
        .m_out_tready(fifo_ready_o)
    );
    //输入延迟16采样点
    logic[23:0] delayer_data_i;
    logic delayer_valid_i;
    logic delayer_ready_i;
    logic[23:0] delayer_data_o;
    logic delayer_valid_o;
    logic delayer_ready_o;
    axis_ram_srl # (
        .LENGTH(16),
        .WIDTH(24)
    )
    u_delayer (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(delayer_data_i),
        .s_in_tvalid(delayer_valid_i),
        .s_in_tready(delayer_ready_i),
        .m_out_tdata(delayer_data_o),
        .m_out_tvalid(delayer_valid_o),
        .m_out_tready(delayer_ready_o)
    );
    /* 互连 */
    //输入广播至能量/相关计算、FIFO
    axis_broadcast # (
        .WIDTH(24),
        .CHANNEL(2)
    )
    u_broadcast (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(s_in_tdata),
        .s_in_tvalid(s_in_tvalid),
        .s_in_tready(s_in_tready),
        .m_out_tdata({delayer_data_i,fifo_data_i}),
        .m_out_tvalid({delayer_valid_i,fifo_valid_i}),
        .m_out_tready({delayer_ready_i,fifo_ready_i})
    );
    //计算瞬时功率与共轭乘积
    logic[49:0] cmpy_product_o;
    logic[49:0] cmpy_power_o;
    logic cmpy_valid_o;
    logic cmpy_ready_o;
    complex_multiplier # (
        .A_W(12),
        .B_W(12)
    )
    u_product (
        .clk(clk),
        .rst_n(rst_n),
        .s_a_tdata({-delayer_data_o[23:12],delayer_data_o[11:0]}),
        .s_a_tvalid(delayer_valid_o),
        .s_a_tready(delayer_ready_o),
        .s_b_tdata(delayer_data_i),
        .s_b_tvalid(delayer_valid_o),
        .s_b_tready(),
        .m_p_tdata(cmpy_product_o),
        .m_p_tvalid(cmpy_valid_o),
        .m_p_tready(cmpy_ready_o)
    );
    complex_multiplier # (
        .A_W(12),
        .B_W(12)
    )
    u_power (
        .clk(clk),
        .rst_n(rst_n),
        .s_a_tdata({-delayer_data_o[23:12],delayer_data_o[11:0]}),
        .s_a_tvalid(delayer_valid_o),
        .s_a_tready(),
        .s_b_tdata(delayer_data_o),
        .s_b_tvalid(delayer_valid_o),
        .s_b_tready(),
        .m_p_tdata(cmpy_power_o),
        .m_p_tvalid(),
        .m_p_tready(cmpy_ready_o)
    );
    //滑动累加计算相关和能量
    logic[17:0] sum_corr_real_o,sum_corr_imag_o,sum_energy_o;
    logic sum_valid_o;
    logic sum_ready_o;
    slide_win_sum # (
        .WIDTH(14),
        .LENGTH(16)
    )
    u_corr_real (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(cmpy_product_o[23:10]),
        .s_in_tvalid(cmpy_valid_o),
        .s_in_tready(cmpy_ready_o),
        .m_out_tdata(sum_corr_real_o),
        .m_out_tvalid(sum_valid_o),
        .m_out_tready(sum_ready_o)
    );
    slide_win_sum # (
        .WIDTH(14),
        .LENGTH(16)
    )
    u_corr_imag (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(cmpy_product_o[48:35]),
        .s_in_tvalid(cmpy_valid_o),
        .s_in_tready(),
        .m_out_tdata(sum_corr_imag_o),
        .m_out_tvalid(),
        .m_out_tready(sum_ready_o)
    );
    slide_win_sum # (
        .WIDTH(14),
        .LENGTH(16)
    )
    u_energy (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(cmpy_power_o[23:10]),
        .s_in_tvalid(cmpy_valid_o),
        .s_in_tready(),
        .m_out_tdata(sum_energy_o),
        .m_out_tvalid(),
        .m_out_tready(sum_ready_o)
    );
    //缓冲energy
    logic energy_valid_i;
    logic energy_ready_i;
    logic[17:0] energy_data_o;
    logic energy_valid_o;
    logic energy_ready_o;
    axis_forward_register # (
        .STAGE(8),
        .WIDTH(18)
    )
    u_energy_reg (
        .clk(clk),
        .rst_n(rst_n),
        .s_in_tdata(sum_energy_o),
        .s_in_tvalid(energy_valid_i),
        .s_in_tready(energy_ready_i),
        .m_out_tdata(energy_data_o),
        .m_out_tvalid(energy_valid_o),
        .m_out_tready(energy_ready_o)
    );
    //计算CORDIC
    logic cordic_valid_i;
    logic cordic_ready_i;
    logic[47:0] cordic_data_o;
    logic[17:0] cordic_phase,cordic_magnitude;
    logic cordic_valid_o;
    logic cordic_ready_o;
    assign cordic_phase = cordic_data_o[41:24];
    assign cordic_magnitude = cordic_data_o[17:0];
    cordic_block u_cordic (
        .aclk(clk),                                        // input wire aclk
        .aresetn(rst_n),                             // input wire aresetn
        .s_axis_cartesian_tvalid(cordic_valid_i),  // input wire s_axis_cartesian_tvalid
        .s_axis_cartesian_tready(cordic_ready_i),  // output wire s_axis_cartesian_tready
        .s_axis_cartesian_tdata({24'(sum_corr_imag_o),24'(sum_corr_real_o)}),    // input wire [47 : 0] s_axis_cartesian_tdata
        .m_axis_dout_tvalid(cordic_valid_o),            // output wire m_axis_dout_tvalid
        .m_axis_dout_tready(cordic_ready_o),            // input wire m_axis_dout_tready
        .m_axis_dout_tdata(cordic_data_o)              // output wire [47 : 0] m_axis_dout_tdata
    );
    always_comb begin
        sum_ready_o = energy_ready_i & cordic_ready_i;
        energy_valid_i = sum_valid_o & cordic_ready_i;
        cordic_valid_i = sum_valid_o & energy_ready_i;
    end
    //对齐cordic、energy、fifo
    logic align_valid;
    logic align_ready;
    logic align_fire;
    assign align_fire = align_valid & align_ready;
    always_comb begin
        align_valid = energy_valid_o & cordic_valid_o & fifo_valid_o;
        energy_ready_o = align_ready & cordic_valid_o & fifo_valid_o;
        cordic_ready_o = align_ready & energy_valid_o & fifo_valid_o;
        fifo_ready_o = align_ready & energy_valid_o & cordic_valid_o;
    end
    //控制输出
    logic[23:0] sync_data_o;
    logic sync_valid_o;
    logic sync_ready_o;
    localparam DATA_LENGTH = 320 + 80*SYMBOL_PER_FRAME + 100;   // frame + margin (SFO drift, pipeline)
    logic[$clog2(DATA_LENGTH)-1:0] sample_cnt;
    logic synced;
    assign synced = (($signed(cordic_magnitude) > ($signed(energy_data_o)>>>1)) &
                    ($signed(energy_data_o) > ENERGY_THRESH));
    typedef enum logic { 
        HOLD = 1'b0,
        OUTPUT = 1'b1
    } state_t;
    state_t current_state,next_state;
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) current_state <= HOLD;
        else current_state <= next_state;
    end
    always_comb begin
        next_state = current_state;
        case(next_state)
            HOLD:
                if(align_fire&&(sample_cnt==63)) next_state = OUTPUT;
            OUTPUT:
                if(align_fire&&(sample_cnt==DATA_LENGTH-1)) next_state = HOLD;
        endcase
    end
    always_ff@(posedge clk or negedge rst_n) begin
        if(~rst_n) sample_cnt <= 'd0;
        else if(align_fire) begin
            if(current_state == HOLD) begin
                if(synced) sample_cnt <= sample_cnt + 1;
                else sample_cnt <= 'd0;
            end
            else begin
                if(sample_cnt==DATA_LENGTH-1) sample_cnt <= 'd0;
                else sample_cnt <= sample_cnt + 1;
            end
        end
    end
    always_comb begin
        if(current_state == HOLD) begin
            sync_data_o = 'd0;
            sync_valid_o = 1'b0;
            align_ready = 1'b1;
        end
        else begin
            sync_data_o = fifo_data_o[23:0];
            sync_valid_o = align_valid;
            align_ready = sync_ready_o;
        end
    end
    //频偏纠正
    logic dds_valid_i;
    logic dds_ready_i;
    logic[31:0] dds_data_o;
    logic dds_valid_o;
    logic dds_ready_o;
    assign dds_valid_i = align_fire&&(sample_cnt==63);
    dds_freq_correct u_dds (
        .aclk(clk),                                  // input wire aclk
        .aresetn(rst_n),                             // input wire aresetn
        .s_axis_config_tvalid(dds_valid_i),  // input wire s_axis_config_tvalid
        .s_axis_config_tready(dds_ready_i),  // output wire s_axis_config_tready
        .s_axis_config_tdata(($signed(-cordic_phase[15:0])>>>4)),    // input wire [15 : 0] s_axis_config_tdata
        .m_axis_data_tvalid(dds_valid_o),      // output wire m_axis_data_tvalid
        .m_axis_data_tready(dds_ready_o),      // input wire m_axis_data_tready
        .m_axis_data_tdata(dds_data_o)        // output wire [31 : 0] m_axis_data_tdata
    );
    logic[49:0] freq_correct_data_o;
    // 25 位乘积直接切 12 位在满量程附近会"回绕"(符号翻转)：
    // 实测样点 -2022 乘相位因子后真值 -2048.2，直接切片得到 +2047；
    // 该样点经 FFT 后使整个 OFDM 符号产生 ICI（约每 15 帧复现一次，51 个译码比特出错）。
    // 改为先取 14 位"宽值"(= 乘积/2048 的真值)，再饱和钳到 12 位有符号范围。
    logic signed[13:0] fc_i_wide, fc_q_wide;
    logic signed[11:0] fc_i_sat,  fc_q_sat;
    assign fc_i_wide = freq_correct_data_o[24:11];
    assign fc_q_wide = freq_correct_data_o[49:36];
    assign fc_i_sat  = (fc_i_wide >  14'sd2047) ?  12'sd2047 :
                       (fc_i_wide < -14'sd2048) ? -12'sd2048 :  fc_i_wide[11:0];
    assign fc_q_sat  = (fc_q_wide >  14'sd2047) ?  12'sd2047 :
                       (fc_q_wide < -14'sd2048) ? -12'sd2048 :  fc_q_wide[11:0];
    assign m_out_tdata = {fc_q_sat, fc_i_sat};
    complex_multiplier # (
        .A_W(12),
        .B_W(12)
    )
    u_cmpy_freq_correct (
        .clk(clk),
        .rst_n(rst_n),
        .s_a_tdata(sync_data_o),
        .s_a_tvalid(sync_valid_o),
        .s_a_tready(sync_ready_o),
        .s_b_tdata({dds_data_o[27:16],dds_data_o[11:0]}),
        .s_b_tvalid(dds_valid_o),
        .s_b_tready(dds_ready_o),
        .m_p_tdata(freq_correct_data_o),
        .m_p_tvalid(m_out_tvalid),
        .m_p_tready(m_out_tready)
    );



endmodule
