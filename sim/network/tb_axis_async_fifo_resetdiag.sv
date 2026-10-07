`timescale 1ns/1ps
module tb_axis_async_fifo_resetdiag;
    logic s_clk = 0, m_clk = 0;
    always #5 s_clk = ~s_clk;
    always #7 m_clk = ~m_clk;

    logic rst_n = 1;
    logic [23:0] s_tdata;
    logic s_tvalid, s_tready, s_tlast;
    logic [0:0] s_tuser;
    logic [23:0] m_tdata;
    logic m_tvalid, m_tready, m_tlast;
    logic [0:0] m_tuser;
    int out_count = 0;
    int errors = 0;

    axis_async_fifo #(.DATA_W(24), .USER_W(1), .DEPTH(64), .RAM_STYLE("distributed")) dut (
        .s_clk, .rst_n, .s_tdata, .s_tvalid, .s_tready, .s_tlast, .s_tuser,
        .m_clk, .m_tdata, .m_tvalid, .m_tready, .m_tlast, .m_tuser
    );

    initial begin
        s_tdata = '0; s_tvalid = 0; s_tlast = 0; s_tuser = '0; m_tready = 0;
        #1 rst_n = 0; #500 rst_n = 1;
    end

    always @(negedge m_clk) begin
        if (rst_n) m_tready <= ($urandom_range(0, 99) < 70);
        else m_tready <= 1'b0;
    end

    always @(posedge m_clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            if (m_tdata !== out_count[23:0]) begin
                $display("MISMATCH index=%0d got=%h expected=%h", out_count, m_tdata, out_count[23:0]);
                errors++;
            end
            if (m_tlast !== (out_count == 199) || m_tuser[0] !== (out_count == 199)) begin
                $display("MARKER_MISMATCH index=%0d last=%b user=%b", out_count, m_tlast, m_tuser[0]);
                errors++;
            end
            out_count++;
        end
    end

    initial begin : producer
        int i;
        wait (rst_n);
        for (i = 0; i < 200; i++) begin
            @(negedge s_clk);
            s_tdata <= i[23:0];
            s_tlast <= (i == 199);
            s_tuser[0] <= (i == 199);
            s_tvalid <= 1'b1;
            do @(posedge s_clk); while (!s_tready);
            @(negedge s_clk);
            s_tvalid <= 1'b0;
            repeat ($urandom_range(0, 3)) @(negedge s_clk);
        end
    end

    initial begin
        wait (out_count == 200);
        repeat (4) @(posedge m_clk);
        if (errors == 0) $display("PASS xpm_fifo_axis: 200 beats ordered with CDC and backpressure");
        else $display("FAIL xpm_fifo_axis: %0d errors", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT xpm_fifo_axis: out_count=%0d errors=%0d", out_count, errors);
        $finish;
    end
endmodule

