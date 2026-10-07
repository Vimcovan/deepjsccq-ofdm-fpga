`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_cap_2board: replay ILA-captured two-board RX samples (20 MSPS) into rx_baseband_top
//   - 100 MHz clk, one new ADC sample every 5 clocks pushed into a FIFO (models the AD9361 RX FIFO),
//     rx_baseband_top pulls from it with s_in_tready (same as hardware: rx_ready = s_in_tready)
//   - logs frame_detection / time_sync state changes and rx_statistic per-frame results,
//     each tagged with the index of the ADC sample being consumed (comparable to the ILA sample index)
// Sim-only: does not touch any synthesised RTL.
//////////////////////////////////////////////////////////////////////////////////
module tb_cap_2board;
    localparam string DATA_FILE = "sim_data/cap_2board.txt";
    localparam int    NMAX      = 60000;
    localparam int    NLIM      = 9500;    // replay only the first captured segment

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [23:0] mem [0:NMAX-1];
    int          nsamp;
    initial begin
        $readmemb(DATA_FILE, mem);
        nsamp = 0;
        while (nsamp < NMAX && nsamp < NLIM && !$isunknown(mem[nsamp])) nsamp++;
        $display("TB: %0d samples loaded", nsamp);
        #200 rst_n = 1'b1;
    end

    // ---- ADC side: one sample per 5 clocks into a FIFO ----
    logic [23:0] fifo [0:8191];
    int          wr_idx = 0, rd_idx = 0, tick = 0, qmax = 0;   // wr_idx/rd_idx = ADC samples pushed/consumed
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
    rx_baseband_top #(.NSYM(20)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_in_tdata(in_data), .s_in_tvalid(in_valid), .s_in_tready(in_ready),
        .m_out_tdata(bit_d), .m_out_tvalid(bit_v), .m_out_tready(1'b1),
        .dbg_pre_data(pre_d), .dbg_pre_fire(pre_f), .dbg_ce_data(ce_d), .dbg_ce_fire(ce_f),
        .dbg_cpe_data(cpe_d), .dbg_cpe_fire(cpe_f), .dbg_sfo_data(sfo_d), .dbg_sfo_fire(sfo_f)
    );
    logic [63:0] br, be, fr, fe;
    logic fdone, fbad; logic [11:0] fnerr;
    rx_statistic stat (
        .clk(clk), .rst_n(rst_n), .clr(1'b0), .rcvd_bit(bit_d), .bit_valid(bit_v),
        .bit_rcvd_cnt(br), .bit_err_cnt(be), .frame_rcvd_cnt(fr), .frame_err_cnt(fe),
        .frame_done(fdone), .frame_bad(fbad), .frame_bit_err(fnerr)
    );

    // ---- probes (hierarchical, read-only) ----
    wire fd_state = dut.synchronizer_top_inst.frame_detection_inst.current_state;
    wire [1:0] ts_state = dut.synchronizer_top_inst.time_sync_inst.current_state;
    logic fd_state_d; logic [1:0] ts_state_d;
    int fd_in_idx; // frame_detection input sample index (its own input handshakes)
    always @(posedge clk) if (!rst_n) fd_in_idx <= 0;
                          else if (in_valid && in_ready) fd_in_idx <= fd_in_idx + 1;
    always @(posedge clk) begin
        fd_state_d <= fd_state; ts_state_d <= ts_state;
        if (rst_n && fd_state != fd_state_d)
            $display("%t  ADC#%6d  frame_detection %s", $time, rd_idx, fd_state ? "HOLD->OUTPUT (detected)" : "OUTPUT->HOLD");
        if (rst_n && ts_state != ts_state_d)
            $display("%t  ADC#%6d  time_sync %0d->%0d (0=IDLE 1=FIRST_LTF 2=DATA)", $time, rd_idx, ts_state_d, ts_state);
        if (fdone)
            $display("%t  ADC#%6d  FRAME_DONE %s nerr=%0d  (total frames %0d, bad %0d)", $time, rd_idx, fbad ? "BAD" : "ok", fnerr, fr+1, fe + fbad);
    end

    // time_sync correlation metric in IDLE: synced = align_xcorr > align_energy>>>1 (i.e. ratio > 0.5)
    wire [24:0] ts_xc = dut.synchronizer_top_inst.time_sync_inst.align_xcorr;
    wire [24:0] ts_en = dut.synchronizer_top_inst.time_sync_inst.align_energy;
    wire        ts_af = dut.synchronizer_top_inst.time_sync_inst.align_fire;
    int ts_idx = 0;   // time_sync aligned-sample counter
    always @(posedge clk) if (rst_n && ts_af) begin
        ts_idx <= ts_idx + 1;
        if (ts_state == 2'd0 && $signed(ts_en) > 100 && ($signed(ts_xc) * 8 > $signed(ts_en)))
            $display("%t  ADC#%6d  TS#%6d  IDLE metric xcorr=%0d energy=%0d ratio=%0.3f%s", $time, rd_idx, ts_idx,
                     $signed(ts_xc), $signed(ts_en), real'($signed(ts_xc)) / real'($signed(ts_en)),
                     ($signed(ts_xc) > (($signed(ts_en) >>> 2) + ($signed(ts_en) >>> 3))) ? "  <-- synced" : "");
    end

    // ---- dump CPE / SFO outputs for offline EVM ----
    integer fcpe, fsfo, fpre;
    initial begin
        fcpe = $fopen("sim_data/sim_cpe.txt", "w");
        fsfo = $fopen("sim_data/sim_sfo.txt", "w");
        fpre = $fopen("sim_data/sim_pre.txt", "w");
    end
    always @(posedge clk) if (rst_n) begin
        if (cpe_f) $fdisplay(fcpe, "%h", cpe_d);
        if (sfo_f) $fdisplay(fsfo, "%h", sfo_d);
        if (pre_f) $fdisplay(fpre, "%h", pre_d);
    end

    // ---- per-frame tap counts (between frame_done events) ----
    int c_pre=0, c_ce=0, c_cpe=0, c_sfo=0;
    always @(posedge clk) if (rst_n) begin
        if (fdone) begin
            $display("%t  ADC#%6d  taps since last frame_done: pre %0d ce %0d cpe %0d sfo %0d", $time, rd_idx, c_pre, c_ce, c_cpe, c_sfo);
            c_pre <= pre_f; c_ce <= ce_f; c_cpe <= cpe_f; c_sfo <= sfo_f;
        end else begin
            c_pre <= c_pre + pre_f; c_ce <= c_ce + ce_f; c_cpe <= c_cpe + cpe_f; c_sfo <= c_sfo + sfo_f;
        end
    end

    // ---- telemetry (sim: CLK_HZ scaled so 1 "ms" = 1000 clocks) ----
    logic [31:0] ar_addr = '0; logic [7:0] ar_len = '0; logic ar_valid = 1'b0; logic ar_ready;
    logic [31:0] r_data; logic r_last, r_valid; logic [1:0] r_resp;
    telemetry #(.CLK_HZ(1_000_000), .PERIOD_MS0(20), .TIMEOUT_MS(40)) tel (
        .clk(clk), .rst_n(rst_n),
        .pre_data(pre_d), .pre_fire(pre_f), .ce_data(ce_d), .ce_fire(ce_f),
        .cpe_data(cpe_d), .cpe_fire(cpe_f), .sfo_data(sfo_d), .sfo_fire(sfo_f),
        .frame_done(fdone), .frame_bad(fbad), .frame_bit_err(fnerr),
        .bit_rcvd_cnt(br), .bit_err_cnt(be), .frame_rcvd_cnt(fr), .frame_err_cnt(fe), .agc_ctrl(8'h29),
        .s_axi_awaddr('0), .s_axi_awlen('0), .s_axi_awvalid(1'b0), .s_axi_awready(),
        .s_axi_wdata('0), .s_axi_wlast(1'b0), .s_axi_wvalid(1'b0), .s_axi_wready(),
        .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
        .s_axi_araddr(ar_addr), .s_axi_arlen(ar_len), .s_axi_arvalid(ar_valid), .s_axi_arready(ar_ready),
        .s_axi_rdata(r_data), .s_axi_rresp(r_resp), .s_axi_rlast(r_last), .s_axi_rvalid(r_valid), .s_axi_rready(1'b1)
    );
    // AXI read helper
    task automatic axi_rd(input int word, input int n, output logic [31:0] buf_o [0:255]);
        int k = 0;
        @(posedge clk); ar_addr <= word*4; ar_len <= n-1; ar_valid <= 1'b1;
        do @(posedge clk); while (!ar_ready);
        ar_valid <= 1'b0;
        while (k < n) begin @(posedge clk); if (r_valid) begin buf_o[k] = r_data; k++; end end
    endtask
    logic [31:0] rb [0:255];
    logic [31:0] last_seq = 0;
    always @(posedge clk) if (rst_n && tel.seq != last_seq) begin
        last_seq <= tel.seq;
        $display("%t  ADC#%6d  TELEMETRY commit seq=%0d buf=%0d timeouts=%0d  sfo_idx=%0d fd_frames=%0d nerr=%0d", $time, rd_idx, tel.seq, tel.last_buf, tel.timeouts, tel.sfo_idx, tel.fd_frames, tel.cap_nerr);
    end
    initial begin
        wait (tel.seq == 2);
        repeat (10) @(posedge clk);
        axi_rd(0, 8, rb);
        $display("AXI global: magic=%h seq=%0d last_buf=%0d period=%0d timeouts=%0d en=%0d ver=%0d", rb[0], rb[1], rb[2], rb[3], rb[4], rb[5], rb[6]);
        axi_rd(64 + 64*rb[2], 16, rb);
        $display("AXI header: seq=%0d nerr=%0d bad=%0d agc=%h bits=%0d biterr=%0d frames=%0d frerr=%0d n=%0d/%0d/%0d/%0d",
                 rb[0], rb[1], rb[2], rb[3], rb[4], rb[6], rb[8], rb[10], rb[12], rb[13], rb[14], rb[15]);
    end

    initial begin
        wait (rst_n);
        wait (wr_idx >= nsamp && rd_idx == wr_idx);
        #200000;   // drain pipeline
        $fclose(fcpe); $fclose(fsfo); $fclose(fpre);
        $display("TB END: frames %0d bad %0d bits %0d biterr %0d  max RX-FIFO depth %0d", fr, fe, br, be, qmax);
        $finish;
    end
endmodule
