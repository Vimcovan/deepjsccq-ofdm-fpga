`timescale 1ns / 1ps
module tb_phy_interface;
    localparam int C = 4, H = 1, W = 2, NFR = 2;
    localparam int TX_IN_N = H * W * C * NFR;
    localparam int TX_OUT_N = TX_IN_N / 2;
    localparam int RX_IN_N = H * W * C / 2 * NFR;
    localparam int RX_OUT_N = RX_IN_N * 2;
    logic clk=0, rst_n=0; always #2 clk=~clk;

    logic signed [11:0] tx_s_data; logic tx_s_valid, tx_s_ready, tx_s_last; logic [0:0] tx_s_user;
    logic [23:0] tx_m_data; logic tx_m_valid, tx_m_ready, tx_m_last; logic [0:0] tx_m_user;
    logic [23:0] rx_s_data; logic rx_s_valid, rx_s_ready, rx_s_last; logic [0:0] rx_s_user;
    logic signed [11:0] rx_m_data; logic rx_m_valid, rx_m_ready, rx_m_last; logic [0:0] rx_m_user;

    qam_tx #(.X_W(12), .C(C)) u_tx (
        .clk(clk), .rst_n(rst_n), .s_tdata(tx_s_data), .s_tvalid(tx_s_valid), .s_tready(tx_s_ready),
        .s_tlast(tx_s_last), .s_tuser(tx_s_user), .m_tdata(tx_m_data), .m_tvalid(tx_m_valid),
        .m_tready(tx_m_ready), .m_tlast(tx_m_last), .m_tuser(tx_m_user));
    rx_frame #(.X_W(12), .H(H), .W(W), .C(C)) u_rx (
        .clk(clk), .rst_n(rst_n), .s_tdata(rx_s_data), .s_tvalid(rx_s_valid), .s_tready(rx_s_ready),
        .s_tlast(rx_s_last), .s_tuser(rx_s_user), .m_tdata(rx_m_data), .m_tvalid(rx_m_valid),
        .m_tready(rx_m_ready), .m_tlast(rx_m_last), .m_tuser(rx_m_user));

    logic signed [11:0] tx_in [TX_IN_N];
    logic [23:0] rx_in [RX_IN_N];
    initial begin
        tx_in[0]=-12'sd1200; tx_in[1]=-12'sd500; tx_in[2]=-12'sd100;  tx_in[3]=12'sd100;
        tx_in[4]=12'sd500;  tx_in[5]=12'sd800;  tx_in[6]=12'sd1100; tx_in[7]=12'sd0;
        tx_in[8]=12'sd1100; tx_in[9]=12'sd500;  tx_in[10]=-12'sd800; tx_in[11]=-12'sd158;
        tx_in[12]=-12'sd158; tx_in[13]=12'sd158; tx_in[14]=12'sd474; tx_in[15]=12'sd790;
        rx_in[0]={12'sd474, -12'sd790}; rx_in[1]={-12'sd158, 12'sd1106};
        rx_in[2]={-12'sd1106, 12'sd158}; rx_in[3]={12'sd790, -12'sd474};
        rx_in[4]={12'sd158, 12'sd158}; rx_in[5]={-12'sd474, -12'sd474};
        rx_in[6]={12'sd1106, -12'sd1106}; rx_in[7]={12'sd0, 12'sd0};
    end

    function automatic int qlevel(input integer x);
        if(x > -343 && x <= -229) qlevel=1;
        else if(x > -229 && x <= -115) qlevel=2;
        else if(x > -115 && x <= 0) qlevel=3;
        else if(x > 0 && x <= 114) qlevel=4;
        else if(x > 114 && x <= 228) qlevel=5;
        else if(x > 228 && x <= 342) qlevel=6;
        else if(x > 342) qlevel=7;
        else qlevel=0;
    endfunction
    function automatic logic signed [11:0] q10(input int l);
        case(l) 0:q10=-1106; 1:q10=-790; 2:q10=-474; 3:q10=-158;
                4:q10=158; 5:q10=474; 6:q10=790; default:q10=1106; endcase
    endfunction

    int tx_in_idx=0, tx_out_idx=0, rx_in_idx=0, rx_out_idx=0;
    int errors=0, flag_errors=0, cycles=0;
    always @(posedge clk) begin
        if(!rst_n) begin tx_s_valid<=0; tx_s_data<='0; tx_s_last<=0; tx_s_user<='0; end
        else begin
            if(tx_s_valid && tx_s_ready) tx_in_idx=tx_in_idx+1;
            if(!tx_s_valid || tx_s_ready) begin
                if(tx_in_idx<TX_IN_N && $urandom_range(99)<75) begin
                    tx_s_valid<=1; tx_s_data<=tx_in[tx_in_idx];
                    tx_s_last <= ((tx_in_idx%C)==C-1);
                    tx_s_user <= ((tx_in_idx%(H*W*C))==H*W*C-1);
                end else tx_s_valid<=0;
            end
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin rx_s_valid<=0; rx_s_data<='0; rx_s_last<=0; rx_s_user<='0; end
        else begin
            if(rx_s_valid && rx_s_ready) begin rx_in_idx=rx_in_idx+1; end
            if(!rx_s_valid || rx_s_ready) begin
                if(rx_in_idx<RX_IN_N && $urandom_range(99)<75) begin
                    rx_s_valid<=1; rx_s_data<=rx_in[rx_in_idx];
                    rx_s_last<=((rx_in_idx%(H*W))==H*W-1);
                    rx_s_user<=((rx_in_idx%(H*W*C/2))==H*W*C/2-1);
                end else rx_s_valid<=0;
            end
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin tx_m_ready<=0; rx_m_ready<=0; end
        else begin tx_m_ready<=($urandom_range(99)<70); rx_m_ready<=($urandom_range(99)<70); end
    end
    always @(posedge clk) begin
        if(!rst_n) begin tx_out_idx=0; rx_out_idx=0; end
        else begin
            cycles=cycles+1;
            if(tx_m_valid && tx_m_ready) begin
                if(tx_out_idx>=TX_OUT_N || tx_m_data !== {q10(qlevel(tx_in[2*tx_out_idx+1])),q10(qlevel(tx_in[2*tx_out_idx]))}) begin if(errors<10) $display("TX mismatch %0d got %h",tx_out_idx,tx_m_data); errors=errors+1; end
                if(tx_m_last !== ((tx_out_idx%(H*W*C/2))==(H*W*C/2)-1) || tx_m_user[0] !== ((tx_out_idx%(H*W*C/2))==(H*W*C/2)-1)) begin $display("TX flag mismatch %0d last=%b user=%b",tx_out_idx,tx_m_last,tx_m_user[0]); flag_errors=flag_errors+1; end
                tx_out_idx=tx_out_idx+1;
            end
            if(rx_m_valid && rx_m_ready) begin
                int rp, rc;
                rp=rx_out_idx/2; rc=rx_out_idx%2;
                if(rx_out_idx>=RX_OUT_N || rx_m_data !== (rc==0 ? $signed(rx_in[rp][11:0]) : $signed(rx_in[rp][23:12]))) begin if(errors<10) $display("RX mismatch %0d got %h expected %h",rx_out_idx,rx_m_data,(rc==0 ? $signed(rx_in[rp][11:0]) : $signed(rx_in[rp][23:12]))); errors=errors+1; end
                if(rx_m_last !== ((rx_out_idx%C)==C-1) || rx_m_user[0] !== (((rx_out_idx%C)==C-1) && (((rx_out_idx/C)%(H*W))==H*W-1))) begin $display("RX flag mismatch %0d last=%b user=%b",rx_out_idx,rx_m_last,rx_m_user[0]); flag_errors=flag_errors+1; end
                rx_out_idx=rx_out_idx+1;
            end
        end
    end
    initial begin
        tx_s_valid=0; tx_s_data='0; tx_s_last=0; tx_s_user='0; rx_s_valid=0; rx_s_data='0; rx_s_last=0; rx_s_user='0; tx_m_ready=0; rx_m_ready=0;
        repeat(5) @(posedge clk); rst_n=1;
        while((tx_out_idx<TX_OUT_N || rx_out_idx<RX_OUT_N) && cycles<200000) @(posedge clk);
        if(tx_out_idx!=TX_OUT_N || rx_out_idx!=RX_OUT_N) begin $display("TIMEOUT tx %0d/%0d rx %0d/%0d",tx_out_idx,TX_OUT_N,rx_out_idx,RX_OUT_N); errors=errors+1; end
        if(errors==0 && flag_errors==0) $display("PASS PHY tx=%0d rx=%0d cycles=%0d",tx_out_idx,rx_out_idx,cycles);
        else $display("FAIL errors=%0d flag_errors=%0d tx=%0d/%0d rx=%0d/%0d",errors,flag_errors,tx_out_idx,TX_OUT_N,rx_out_idx,RX_OUT_N);
        $finish;
    end
endmodule



