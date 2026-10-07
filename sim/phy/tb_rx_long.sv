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
module tb_rx_long;
    localparam string DATA_FILE = "sim_data/long_stim.txt";
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
    logic bit_d, bit_v;
    logic [23:0] pre_d, ce_d, cpe_d, sfo_d; logic pre_f, ce_f, cpe_f, sfo_f;
    rx_baseband_top #(.NSYM(NSYM)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_in_tdata(in_data), .s_in_tvalid(in_valid), .s_in_tready(in_ready),
        .m_out_tdata(bit_d), .m_out_tvalid(bit_v), .m_out_tready(1'b1),
        .dbg_pre_data(pre_d), .dbg_pre_fire(pre_f), .dbg_ce_data(ce_d), .dbg_ce_fire(ce_f),
        .dbg_cpe_data(cpe_d), .dbg_cpe_fire(cpe_f), .dbg_sfo_data(sfo_d), .dbg_sfo_fire(sfo_f)
    );
    localparam int FRAME_BITS = NSYM*96-6;
    localparam int NERR_W = $clog2(FRAME_BITS+1);
    logic [63:0] br, be, fr, fe;
    logic fdone, fbad; logic [NERR_W-1:0] fnerr;
    rx_statistic #(.BITS_PER_FRAME(FRAME_BITS)) stat (
        .clk(clk), .rst_n(rst_n), .clr(1'b0), .rcvd_bit(bit_d), .bit_valid(bit_v),
        .bit_rcvd_cnt(br), .bit_err_cnt(be), .frame_rcvd_cnt(fr), .frame_err_cnt(fe),
        .frame_done(fdone), .frame_bad(fbad), .frame_bit_err(fnerr)
    );

    // ---- probes ----
    wire [1:0] ts_state = dut.synchronizer_top_inst.time_sync_inst.current_state;
    logic [1:0] ts_state_d;
    always @(posedge clk) begin
        ts_state_d <= ts_state;
        if (rst_n && ts_state != ts_state_d)
            $display("%t  ADC#%6d  time_sync %0d->%0d (0=IDLE 1=FIRST_LTF 2=DATA)", $time, rd_idx, ts_state_d, ts_state);
        if (fdone)
            $display("%t  ADC#%6d  FRAME_DONE %s nerr=%0d  (total frames %0d, bad %0d, bits %0d, biterr %0d)",
                     $time, rd_idx, fbad ? "BAD" : "ok", fnerr, fr+1, fe + fbad, br, be);
    end

    // rotator: predicted slope of every symbol (pi-scaled rad, 2^29 = pi) -> samples of drift = A_pred*32/2^29
    integer fslope, fout;
    initial begin
        fslope = $fopen("sim_data/long_slope.txt", "w");
        fout   = $fopen("sim_data/long_out.txt", "w");
    end
    wire rot_start = dut.equalizer_top_inst.u_sfo_rot.start;
    always @(posedge clk) if (rst_n) begin
        if (rot_start) $fdisplay(fslope, "%0d", $signed(dut.equalizer_top_inst.u_sfo_rot.a_pred_n));
        if (cpe_f) $fdisplay(fout, "%h", cpe_d);
    end

    // ---- telemetry (sim: CLK_HZ scaled so 1 "ms" = 1000 clocks) ----
    logic [31:0] last_seq = 0;
    telemetry #(.CLK_HZ(1_000_000), .PERIOD_MS0(200), .TIMEOUT_MS(400), .NSYM(NSYM), .NERR_W(NERR_W)) tel (
        .clk(clk), .rst_n(rst_n),
        .pre_data(pre_d), .pre_fire(pre_f), .ce_data(ce_d), .ce_fire(ce_f),
        .cpe_data(cpe_d), .cpe_fire(cpe_f), .sfo_data(sfo_d), .sfo_fire(sfo_f),
        .frame_done(fdone), .frame_bad(fbad), .frame_bit_err(fnerr),
        .bit_rcvd_cnt(br), .bit_err_cnt(be), .frame_rcvd_cnt(fr), .frame_err_cnt(fe), .agc_ctrl(8'h29),
        .s_axi_awaddr('0), .s_axi_awlen('0), .s_axi_awvalid(1'b0), .s_axi_awready(),
        .s_axi_wdata('0), .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_araddr('0), .s_axi_arlen('0), .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_rdata(), .s_axi_rresp(), .s_axi_rlast(), .s_axi_rvalid(), .s_axi_rready(1'b1)
    );
    always @(posedge clk) if (rst_n && tel.seq != last_seq) begin
        last_seq <= tel.seq;
        $display("%t  ADC#%6d  TELEMETRY commit seq=%0d timeouts=%0d n=%0d/%0d/%0d/%0d nerr=%0d", $time, rd_idx,
                 tel.seq, tel.timeouts, tel.n_pre, tel.n_ce, tel.n_cpe, tel.n_sfo, tel.cap_nerr);
    end

    initial begin
        wait (rst_n);
        wait (wr_idx >= nsamp && rd_idx == wr_idx);
        #300000;   // drain pipeline
        $fclose(fslope); $fclose(fout);
        $display("TB END: frames %0d bad %0d bits %0d biterr %0d  max RX-FIFO depth %0d", fr, fe, br, be, qmax);
        $finish;
    end
endmodule
