`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// img_pack32 (250 MHz): decoder image stream (uint8 per beat, tuser[0] on the last byte of a frame) ->
//   32-bit words for the PS DMA (byte k of the frame in bits [8*(k%4) +: 8], little endian, tlast on the
//   last word of the frame; 196608 bytes = 49152 words).
//   Frames are forwarded only on request: one-shot (arm, forwards the next complete frame) or continuous.
//   Frames that are not requested are consumed and discarded, so the decoder never stalls on the PS.
//   Control inputs come from the 100 MHz register block (arm_toggle: toggles once per request; continuous:
//   level), synchronised here.
//////////////////////////////////////////////////////////////////////////////////
module img_pack32 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  s_tdata,
    input  logic        s_tuser,            // last byte of a frame
    input  logic        s_tvalid,
    output logic        s_tready,
    output logic [31:0] m_tdata,
    output logic        m_tlast,
    output logic        m_tvalid,
    input  logic        m_tready,
    input  logic        arm_toggle,         // async (100 MHz domain)
    input  logic        continuous,         // async (100 MHz domain)
    output logic        frame_toggle,       // toggles at the end of every decoder frame
    output logic        sent_toggle,        // toggles at the end of every forwarded frame
    output logic        pending             // a one-shot request is waiting for the next frame
);
    (* ASYNC_REG = "TRUE" *) logic [2:0] arm_s;
    (* ASYNC_REG = "TRUE" *) logic [1:0] cont_s;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin arm_s <= '0; cont_s <= '0; end
        else begin arm_s <= {arm_s[1:0], arm_toggle}; cont_s <= {cont_s[0], continuous}; end
    wire arm_req = arm_s[2] ^ arm_s[1];

    logic at_start, fwd, ovalid;
    logic [1:0]  bidx;
    logic [23:0] acc;
    wire take_now = at_start ? (cont_s[1] | pending | arm_req) : fwd;   // forward the frame starting with this byte
    // forwarding: accept a byte when the output register is free (or being emptied)
    wire out_free = ~ovalid | m_tready;
    assign s_tready = take_now ? out_free : 1'b1;
    wire fire = s_tvalid & s_tready;
    assign m_tvalid = ovalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            at_start <= 1'b1; fwd <= 1'b0; pending <= 1'b0; bidx <= '0; acc <= '0;
            ovalid <= 1'b0; m_tdata <= '0; m_tlast <= 1'b0; frame_toggle <= 1'b0; sent_toggle <= 1'b0;
        end
        else begin
            if (arm_req) pending <= 1'b1;
            if (ovalid & m_tready) ovalid <= 1'b0;
            if (fire) begin
                if (at_start) begin
                    fwd <= take_now;
                    if (take_now & ~cont_s[1]) pending <= 1'b0;
                end
                at_start <= s_tuser;
                if (s_tuser) frame_toggle <= ~frame_toggle;
                if (take_now) begin
                    if (bidx == 2'd3 || s_tuser) begin
                        m_tdata <= {s_tdata, acc};
                        m_tlast <= s_tuser;
                        ovalid  <= 1'b1;
                        bidx    <= '0;
                        if (s_tuser) sent_toggle <= ~sent_toggle;
                    end
                    else begin
                        acc[8*bidx +: 8] <= s_tdata;
                        bidx <= bidx + 1'b1;
                    end
                end
            end
        end
    end
endmodule
