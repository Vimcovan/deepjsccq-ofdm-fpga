`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// sfo_residual: tracking SFO compensation, measurement part (sits AFTER CPE_compensation).
//   Data passes straight through (no buffering). On the pilots of every symbol it forms the LS slope
//     L = -21*Im(p11) - 7*Im(p25) + 7*Im(p39) - 21*Im(p53)
//   (pilot sequence [1 1 1 -1] folded into the signs; 21 = 16+4+1, 7 = 8-1 -> shift-add only)
//   and hands it to sfo_rotator as a one-cycle pulse when pilot 53 goes by.  |L| <= 56*2048 -> 18 bits.
//////////////////////////////////////////////////////////////////////////////////
module sfo_residual(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [23:0] s_in_tdata,
    input  logic        s_in_tvalid,
    output logic        s_in_tready,
    output logic [23:0] m_out_tdata,
    output logic        m_out_tvalid,
    input  logic        m_out_tready,
    output logic        e_valid,
    output logic [17:0] e_data
);
    assign m_out_tdata  = s_in_tdata;
    assign m_out_tvalid = s_in_tvalid;
    assign s_in_tready  = m_out_tready;
    wire fire = s_in_tvalid & m_out_tready;

    logic signed [17:0] pim, pim_x21, pim_x7, acc;
    assign pim     = {{6{s_in_tdata[23]}}, s_in_tdata[23:12]};
    assign pim_x21 = (pim <<< 4) + (pim <<< 2) + pim;
    assign pim_x7  = (pim <<< 3) - pim;
    logic [5:0] cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin cnt <= '0; acc <= '0; e_valid <= 1'b0; e_data <= '0; end
        else begin
            e_valid <= 1'b0;
            if (fire) begin
                cnt <= cnt + 1'b1;
                case (cnt)
                    6'd11: acc <= -pim_x21;
                    6'd25: acc <= acc - pim_x7;
                    6'd39: acc <= acc + pim_x7;
                    6'd53: begin e_data <= acc - pim_x21; e_valid <= 1'b1; end
                    default: ;
                endcase
            end
        end
    end
endmodule
