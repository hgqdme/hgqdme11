// eth_crc32_stream_chk.v : RX CRC checker using ROM LUT (crc32_lut).
// - Computes over bytes **including FCS**; at frame_done, residual must equal 32'h2144_DF1C.
// - Reads from RX FIFO by asserting fifo_re while not empty (simple stream).
// - frame_done should be a pulse that occurs **after FCS** (RX_CTL dropped).

module eth_crc32_stream_chk(
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] fifo_dout,
    input  wire       fifo_empty,
    output reg        fifo_re,

    input  wire       frame_done,     // 1-cycle pulse after FCS enters FIFO

    output reg        crc_ok_pulse,
    output reg        crc_err_pulse
);
    // CRC pipeline
    reg  [31:0] crc;
    wire [7:0]  lut_addr = (crc[7:0] ^ fifo_dout);
    wire [31:0] lut_q;
    reg         do_update_d;  // aligns with ROM latency

    crc32_lut u_rom (
        .Address    (lut_addr),
        .OutClock   (clk),
        .OutClockEn (1'b1),
        .Reset      (~rst_n),
        .Q          (lut_q)
    );

    // Simple reader
    reg run;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            run <= 1'b0;
        end else begin
            // start whenever data exists
            if(!fifo_empty) run <= 1'b1;
            else if(frame_done) run <= 1'b0;
        end
    end

    // residual constant when including FCS
    localparam [31:0] RESID = 32'h2144_DF1C;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            fifo_re <= 1'b0; crc <= 32'hFFFF_FFFF; do_update_d<=1'b0;
            crc_ok_pulse<=1'b0; crc_err_pulse<=1'b0;
        end else begin
            crc_ok_pulse<=1'b0; crc_err_pulse<=1'b0;
            fifo_re <= run & ~fifo_empty; // read while data available

            // apply CRC update for previous cycle
            if(do_update_d) crc <= (crc >> 8) ^ lut_q;

            // capture that we will update on this byte
            do_update_d <= fifo_re & ~fifo_empty;

            // handle frame boundary
            if(frame_done) begin
                // Check residual (crc after consuming all bytes including FCS)
                if(crc == RESID) crc_ok_pulse <= 1'b1;
                else              crc_err_pulse<= 1'b1;
                // Prepare for next
                crc <= 32'hFFFF_FFFF;
            end
        end
    end
endmodule
