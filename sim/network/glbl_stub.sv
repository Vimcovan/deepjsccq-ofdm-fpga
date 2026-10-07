// Minimal global-signal stub for standalone XPM simulation. Vivado project
// simulation normally supplies the vendor glbl module automatically.
module glbl;
    wire GSR = 1'b0;
    wire GTS = 1'b0;
    wire GWE = 1'b1;
    wire PRLD = 1'b0;
    wire GRESTORE = 1'b0;
    wire GTS_USR = 1'b0;
    wire GWE_USR = 1'b1;
    wire PLL_LOCKG = 1'b1;
endmodule
