`timescale 1ns / 1ps
// Random + corner test of mul_serial for the widths used in the design.
module mul_check #(parameter int AW = 27, parameter int BW = 17) (input logic clk, input logic rst_n,
                                                                 output int errors, output logic fin);
    logic start = 0, busy, done;
    logic signed [AW-1:0] a;
    logic [BW-1:0] b;
    logic signed [AW+BW:0] p;
    mul_serial #(.AW(AW), .BW(BW)) u (.*);
    initial begin
        errors = 0; fin = 0;
        wait (rst_n);
        for (int k = 0; k < 3000; k++) begin
            logic signed [AW-1:0] ta; logic [BW-1:0] tb;
            ta = (k == 0) ? -(1 <<< (AW - 1)) : (k == 1) ? (1 <<< (AW - 1)) - 1 : AW'($urandom());
            tb = (k < 3) ? '1 : (k == 3) ? '0 : BW'($urandom());
            @(posedge clk); a <= ta; b <= tb; start <= 1;
            @(posedge clk); start <= 0;
            do @(posedge clk); while (!done);
            if (p !== (AW+BW+1)'(64'(ta) * 64'(tb))) begin
                if (errors < 5) $display("ERR AW=%0d BW=%0d a=%0d b=%0d p=%0d", AW, BW, ta, tb, p);
                errors++;
            end
        end
        fin = 1;
    end
endmodule

module tb_mul_serial;
    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;
    int e0, e1, e2, e3; logic f0, f1, f2, f3;
    mul_check #(27, 17) c0 (clk, rst_n, e0, f0);
    mul_check #(18, 10) c1 (clk, rst_n, e1, f1);
    mul_check #(12, 17) c2 (clk, rst_n, e2, f2);
    mul_check #(5, 3)   c3 (clk, rst_n, e3, f3);
    initial begin
        repeat (3) @(posedge clk); rst_n = 1;
        wait (f0 && f1 && f2 && f3);
        $display("%s mul_serial: %0d errors", (e0 + e1 + e2 + e3) ? "FAIL" : "PASS", e0 + e1 + e2 + e3);
        $finish;
    end
endmodule
