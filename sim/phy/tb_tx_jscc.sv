`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_tx_jscc: OFDM_TX_JSCC baseband (PRBS 64-QAM IQ source) with long frames (NSYM data symbols), read out like top_module does
//   (one sample per 5 clocks = 20 MSPS at 100 MHz, burst per frame). Checks that a started frame never
//   underruns (cut-through packet FIFO) and dumps the frames ({I Q} per line, signed) for the RX simulation.
// Sim-only.
//////////////////////////////////////////////////////////////////////////////////
module tb_tx_jscc;
    localparam int NSYM      = 683;
    localparam int FRAME_LEN = 320 + 80*NSYM;
    localparam int NFRAMES   = 2;
    localparam string OUT    = "sim_data/tx_jscc.txt";

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;
    initial #200 rst_n = 1'b1;

    logic [23:0] sd; logic sl, su, sv, sr;
    logic [23:0] bb_d; logic bb_v, bb_l, bb_r, terr; logic [31:0] nbuf;
    iq_prbs_source #(.FRAME_SYMS(32768)) u_src (.clk(clk), .rst_n(rst_n),
        .m_tdata(sd), .m_tlast(sl), .m_tuser(su), .m_tvalid(sv), .m_tready(sr));
    tx_baseband_jscc #(.NSYM(NSYM), .FRAME_SYMS(32768)) dut (.clk(clk), .rst_n(rst_n),
        .s_in_tdata(sd), .s_in_tlast(sl), .s_in_tvalid(sv), .s_in_tready(sr),
        .m_out_tdata(bb_d), .m_out_tvalid(bb_v), .m_out_tlast(bb_l), .m_out_tready(bb_r),
        .tlast_err(terr), .frames_buffered(nbuf));
    always @(posedge clk) if (terr) $display("%t ERROR tx framer tlast", $time);

    // reader: like top_module (20 MSPS tick while sending a frame)
    int tick = 0, cnt = 0, frames = 0, underrun = 0, lastmis = 0, wait_clk = 0;
    int fo;
    logic sending = 1'b0;
    assign bb_r = rst_n && (tick == 4);
    initial fo = $fopen(OUT, "w");
    always @(posedge clk) if (rst_n) begin
        tick <= (tick == 4) ? 0 : tick + 1;
        if (tick == 4) begin
            if (bb_v) begin
                $fdisplay(fo, "%0d %0d", $signed(bb_d[11:0]), $signed(bb_d[23:12]));
                if (cnt == 0) $display("%t frame %0d starts (waited %0d clk)", $time, frames, wait_clk);
                if (bb_l != (cnt == FRAME_LEN-1)) begin $display("%t ERROR tlast at sample %0d", $time, cnt); lastmis++; end
                if (cnt == FRAME_LEN-1) begin cnt <= 0; frames <= frames + 1; end
                else cnt <= cnt + 1;
            end
            else if (cnt != 0) begin underrun <= underrun + 1; if (underrun < 5) $display("%t UNDERRUN at sample %0d", $time, cnt); end
            else wait_clk <= wait_clk + 5;
        end
    end
    // max FIFO level
    int maxlvl = 0;
    always @(posedge clk) if (dut.u_frame_fifo.used > maxlvl) maxlvl <= dut.u_frame_fifo.used;
    initial begin
        wait (frames == NFRAMES);
        $fclose(fo);
        $display("TB END: %0d frames x %0d samples, underruns %0d, tlast errors %0d, max FIFO level %0d", NFRAMES, FRAME_LEN, underrun, lastmis, maxlvl);
        $finish;
    end
endmodule
