`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_rx_long: long frames (NSYM data symbols) with tracking SFO + FFT window back-off.
//   Stimulus (tools/make_long_stim.py): two RTL-TX frames, frame 0 at +SFO, frame 1 at -SFO, CFO, multipath,
//   AWGN. 100 MHz clk, one ADC sample every 5 clocks into a FIFO (as in hardware), rx_baseband_top pulls
//   with s_in_tready.
//   Logs frame_done / bit errors, the rotator's predicted slope per symbol and the final equalizer output
//   (after SFO rotation + CPE) for offline EVM, the max RX FIFO depth (throughput with the SFO token loop)
//   and the telemetry commits.
// Sim-only.
//////////////////////////////////////////////////////////////////////////////////
module tb_rx_jscc;
    localparam string DATA_FILE = "sim_data/jscc_stim.txt";
    localparam int    NSYM      = 683;
    localparam int    NMAX      = 131072;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [23:0] mem [0:NMAX-1];
    int          nsamp;
    initial begin
        $readmemb(DATA_FILE, mem);
        nsamp = 0;
        while (nsamp < NMAX && !$isunknown(mem[nsamp])) nsamp++;
        $display("TB: %0d samples loaded", nsamp);
        #200 rst_n = 1'b1;
    end

    // ---- ADC side: one sample per 5 clocks into a FIFO ----
    logic [23:0] fifo [0:8191];
    int          wr_idx = 0, rd_idx = 0, tick = 0, qmax = 0;
    logic        in_valid, in_ready;
    logic [23:0] in_data;
    assign in_valid = (wr_idx != rd_idx);
    assign in_data  = fifo[rd_idx % 8192];
    always @(posedge clk) if (rst_n) begin
        if (in_valid && in_ready) rd_idx <= rd_idx + 1;
        tick <= (tick == 4) ? 0 : tick + 1;
        if (tick == 4 && wr_idx < nsamp) begin fifo[wr_idx % 8192] <= mem[wr_idx]; wr_idx <= wr_idx + 1; end
        if (wr_idx - rd_idx > qmax) qmax <= wr_idx - rd_idx;
    end

    // ---- DUT ----
    logic [23:0] pd, fd; logic pl, pu, pv, pr, fl, fu, fv, fr;
    logic [23:0] pre_d, ce_d, cpe_d, sfo_d; logic pre_f, ce_f, cpe_f, sfo_f;
    rx_baseband_top #(.NSYM(NSYM), .FRAME_SYMS(32768)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_in_tdata(in_data), .s_in_tvalid(in_valid), .s_in_tready(in_ready),
        .m_out_tdata(pd), .m_out_tlast(pl), .m_out_tuser(pu), .m_out_tvalid(pv), .m_out_tready(pr),
        .dbg_pre_data(pre_d), .dbg_pre_fire(pre_f), .dbg_ce_data(ce_d), .dbg_ce_fire(ce_f),
        .dbg_cpe_data(cpe_d), .dbg_cpe_fire(cpe_f), .dbg_sfo_data(sfo_d), .dbg_sfo_fire(sfo_f)
    );
    logic [31:0] fin, fdrop;
    uram_frame_fifo #(.FRAME_LEN(32768), .DEPTH_WORDS(24576), .PACKET_MODE(0)) fbuf (.clk(clk), .rst_n(rst_n),
        .s_tdata(pd), .s_tvalid(pv), .s_tready(pr), .m_tdata(fd), .m_tlast(fl), .m_tuser(fu), .m_tvalid(fv), .m_tready(fr),
        .frames_in(fin), .dropped_frames(fdrop));
    logic [25:0] cd; logic cv, cr;
    axis_async_fifo #(.WIDTH(26)) cdc (.s_clk(clk), .s_rst_n(rst_n), .s_tdata({fu, fl, fd}), .s_tvalid(fv), .s_tready(fr),
        .m_clk(clk), .m_rst_n(rst_n), .m_tdata(cd), .m_tvalid(cv), .m_tready(cr));
    localparam int NERR_W = 18;
    logic [63:0] br, be, fr_c, fe; logic fdone, fbad; logic [NERR_W-1:0] fnerr; logic [31:0] lerr;
    rx_iq_checker #(.FRAME_SYMS(32768), .NERR_W(NERR_W)) chk (.clk(clk), .rst_n(rst_n), .clr(1'b0), .throttle(16'd0),
        .s_tdata(cd[23:0]), .s_tlast(cd[24]), .s_tvalid(cv), .s_tready(cr),
        .bit_rcvd_cnt(br), .bit_err_cnt(be), .frame_rcvd_cnt(fr_c), .frame_err_cnt(fe),
        .frame_done(fdone), .frame_bad(fbad), .frame_bit_err(fnerr), .len_err_cnt(lerr));

    // ---- probes ----
    wire [1:0] ts_state = dut.synchronizer_top_inst.time_sync_inst.current_state;
    logic [1:0] ts_state_d;
    always @(posedge clk) begin
        ts_state_d <= ts_state;
        if (rst_n && ts_state != ts_state_d)
            $display("%t  ADC#%6d  time_sync %0d->%0d (0=IDLE 1=FIRST_LTF 2=DATA)", $time, rd_idx, ts_state_d, ts_state);
        if (fdone)
            $display("%t  ADC#%6d  FRAME_DONE %s uncoded 64QAM bit errors=%0d  (frames %0d, bad %0d, bits %0d, biterr %0d, len err %0d, fb in %0d dropped %0d)",
                     $time, rd_idx, fbad ? "BAD" : "ok", fnerr, fr_c+1, fe + fbad, br, be, lerr, fin, fdrop);
    end

    // rotator: predicted slope of every symbol (pi-scaled rad, 2^29 = pi) -> samples of drift = A_pred*32/2^29
    integer fslope, fout;
    initial begin
        fslope = $fopen("sim_data/jscc_slope.txt", "w");
        fout   = $fopen("sim_data/jscc_out.txt", "w");
    end
    wire rot_start = dut.equalizer_top_inst.u_sfo_rot.start;
    always @(posedge clk) if (rst_n) begin
        if (rot_start) $fdisplay(fslope, "%0d", $signed(dut.equalizer_top_inst.u_sfo_rot.a_pred_n));
        if (cpe_f) $fdisplay(fout, "%h", cpe_d);
    end

    initial begin
        wait (rst_n);
        wait (wr_idx >= nsamp && rd_idx == wr_idx);
        #300000;   // drain pipeline
        $fclose(fslope); $fclose(fout);
        $display("TB END: frames %0d bad %0d bits %0d biterr %0d len err %0d fb in %0d dropped %0d  max RX-FIFO depth %0d", fr_c, fe, br, be, lerr, fin, fdrop, qmax);
        $finish;
    end
endmodule
