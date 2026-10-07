`timescale 1ns/1ps

// Parameterized regression for the XPM-backed AXI-Stream CDC FIFO.
// The cases are elaborated separately so the same scoreboard covers the
// actual bridge configurations as well as a minimum-depth stress case.
module tb_axis_async_fifo_sweep #(
    parameter int DATA_W     = 24,
    parameter int USER_W     = 1,
    parameter int DEPTH      = 1024,
    parameter int FRAME_BEATS = 1024,
    parameter int NFRAMES    = 4,
    parameter int READY_MODE = 0
);
    localparam int TOTAL_BEATS = FRAME_BEATS * NFRAMES;

    logic s_clk = 1'b0;
    logic m_clk = 1'b0;
    always #5 s_clk = ~s_clk;  // 100 MHz write side
    always #7 m_clk = ~m_clk;  // about 71 MHz read side

    logic rst_n = 1'b0;
    logic [DATA_W-1:0] s_tdata;
    logic s_tvalid, s_tready, s_tlast;
    logic [USER_W-1:0] s_tuser;
    logic [DATA_W-1:0] m_tdata;
    logic m_tvalid, m_tready, m_tlast;
    logic [USER_W-1:0] m_tuser;

    int out_count = 0;
    int errors = 0;
    int ready_phase = 0;

    axis_async_fifo #(
        .DATA_W(DATA_W), .USER_W(USER_W), .DEPTH(DEPTH), .RAM_STYLE("auto")
    ) dut (
        .s_clk, .rst_n, .s_tdata, .s_tvalid, .s_tready, .s_tlast, .s_tuser,
        .m_clk, .m_tdata, .m_tvalid, .m_tready, .m_tlast, .m_tuser
    );

    initial begin
        s_tdata = '0;
        s_tvalid = 1'b0;
        s_tlast = 1'b0;
        s_tuser = '0;
        m_tready = 1'b0;
        #500 rst_n = 1'b1;
    end

    always @(negedge m_clk) begin
        if (!rst_n) begin
            m_tready <= 1'b0;
        end else begin
            case (READY_MODE)
                0: m_tready <= ($urandom_range(0, 99) < 70);
                1: m_tready <= ((ready_phase % 32) >= 24); // long periodic stalls
                default: m_tready <= 1'b1;
            endcase
            ready_phase++;
        end
    end

    always @(posedge m_clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            if (m_tdata !== out_count[DATA_W-1:0]) begin
                $display("MISMATCH index=%0d got=%h expected=%h", out_count,
                         m_tdata, out_count[DATA_W-1:0]);
                errors++;
            end
            if (m_tlast !== ((out_count % FRAME_BEATS) == FRAME_BEATS-1) ||
                m_tuser[0] !== ((out_count % FRAME_BEATS) == FRAME_BEATS-1)) begin
                $display("MARKER_MISMATCH index=%0d last=%b user=%b", out_count,
                         m_tlast, m_tuser[0]);
                errors++;
            end
            out_count++;
        end
    end

    initial begin : producer
        int i;
        wait (rst_n);
        for (i = 0; i < TOTAL_BEATS; i++) begin
            @(negedge s_clk);
            s_tdata <= i[DATA_W-1:0];
            s_tlast <= ((i % FRAME_BEATS) == FRAME_BEATS-1);
            s_tuser[0] <= ((i % FRAME_BEATS) == FRAME_BEATS-1);
            s_tvalid <= 1'b1;
            do @(posedge s_clk); while (!s_tready);
            @(negedge s_clk);
            s_tvalid <= 1'b0;
        end
    end

    initial begin
        wait (out_count == TOTAL_BEATS);
        repeat (4) @(posedge m_clk);
        if (errors == 0)
            $display("PASS sweep DATA_W=%0d DEPTH=%0d FRAMES=%0d BEATS=%0d READY_MODE=%0d",
                     DATA_W, DEPTH, NFRAMES, FRAME_BEATS, READY_MODE);
        else
            $display("FAIL sweep DATA_W=%0d DEPTH=%0d errors=%0d",
                     DATA_W, DEPTH, errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT sweep DATA_W=%0d DEPTH=%0d out_count=%0d/%0d errors=%0d",
                 DATA_W, DEPTH, out_count, TOTAL_BEATS, errors);
        $finish;
    end
endmodule
