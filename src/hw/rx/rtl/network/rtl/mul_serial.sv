`timescale 1ns / 1ps
// Multi-cycle signed x unsigned multiplier in fabric logic (no DSP).
// Radix-4, LSB first: one 2-bit digit of b per cycle is added to the high part of the
// running product, and the two finished low bits are shifted out into a plain register,
// so the adder is only AW+3 bits wide (not AW+BW).  Value after step i: acc*4^i + lo.
// start is accepted when idle; p is valid in the cycle done = 1, ND = ceil(BW/2) cycles
// later, and stays valid until the next start.
module mul_serial #(
    parameter int AW = 27,               // signed multiplicand width
    parameter int BW = 17                // unsigned multiplier width
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    start,
    input  logic signed [AW-1:0]    a,
    input  logic        [BW-1:0]    b,
    output logic                    busy,
    output logic                    done,
    output logic signed [AW+BW:0]   p
);
    localparam int ND = (BW + 1) / 2;                     // radix-4 digits
    localparam int SW = AW + 3;                           // |acc + 3a| < 2^(AW+2)

    (* use_dsp = "no" *) logic signed [SW-1:0] acc;
    logic signed [SW-1:0]  a1, a3;                        // a and 3a
    logic [2*ND-1:0]       bsh;                           // remaining digits, LSB first
    logic [2*ND-1:0]       lo;                            // finished low product bits
    logic [$clog2(ND+1)-1:0] cnt;

    logic signed [SW-1:0] addend, s;
    always_comb begin
        unique case (bsh[1:0])
            2'd0: addend = '0;
            2'd1: addend = a1;
            2'd2: addend = a1 <<< 1;
            default: addend = a3;
        endcase
        s = acc + addend;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; cnt <= '0; acc <= '0; lo <= '0; bsh <= '0; a1 <= '0; a3 <= '0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                cnt  <= ($bits(cnt))'(ND);
                acc  <= '0;
                a1   <= SW'(a);
                a3   <= SW'(a) + (SW'(a) <<< 1);
                bsh  <= (2*ND)'(b);
            end else if (busy) begin
                acc <= s >>> 2;
                lo  <= {s[1:0], lo[2*ND-1:2]};
                bsh <= bsh >> 2;
                cnt <= cnt - 1'b1;
                if (cnt == 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
    assign p = (AW+BW+1)'({acc, lo});
endmodule
