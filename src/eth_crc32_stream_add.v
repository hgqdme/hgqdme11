// eth_crc32_stream_add.v : Append Ethernet CRC32 FCS using ROM LUT (crc32_lut).
// - Standard Ethernet CRC (poly 0x04C11DB7), init 0xFFFF_FFFF, final XOR 0xFFFF_FFFF.
// - Pipeline: crc32_lut is synchronous 1-cycle; we align internally without changing upstream enables.

module eth_crc32_stream_add(
    input  wire       clk,
    input  wire       rst_n,

    // upstream (payload bytes)
    input  wire       in_sof,
    input  wire       in_vld,
    input  wire [7:0] in_data,
    input  wire       in_eof,
    output wire       in_rdy,

    // downstream (payload + 4B FCS appended)
    output reg        out_sof,
    output reg        out_vld,
    output reg [7:0]  out_data,
    output reg        out_eof,
    input  wire       out_rdy
);
    assign in_rdy = out_rdy;  // simple backpressure propagation

    // CRC update pipeline (1-cycle rom latency)
    reg  [31:0] crc;
    wire [7:0]  lut_addr = (crc[7:0] ^ in_data);
    wire [31:0] lut_q;
    reg         update_crc_d;  // in_vld registered for ROM latency

    // SBX ROM: 8->32 table
    crc32_lut u_rom (
        .Address    (lut_addr),
        .OutClock   (clk),
        .OutClockEn (1'b1),
        .Reset      (~rst_n),
        .Q          (lut_q)
    );

    // State for outputting FCS
    reg fcs_phase;
    reg [1:0] fcs_idx;
    wire [31:0] crc_final = ~crc;  // final xor
    wire [7:0]  fcs_byte =
        (fcs_idx==2'd0) ? crc_final[7:0]  :
        (fcs_idx==2'd1) ? crc_final[15:8] :
        (fcs_idx==2'd2) ? crc_final[23:16]:
                          crc_final[31:24]; // little-endian on the wire

    // SOF one-shot
    reg seen_sof;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            crc <= 32'hFFFF_FFFF;
            update_crc_d <= 1'b0;
            fcs_phase <= 1'b0; fcs_idx <= 2'd0;
            out_sof<=1'b0; out_vld<=1'b0; out_data<=8'h00; out_eof<=1'b0;
            seen_sof<=1'b0;
        end else begin
            out_sof<=1'b0; out_vld<=1'b0; out_eof<=1'b0;
            // CRC update from previous cycle
            if(update_crc_d) begin
                crc <= (crc >> 8) ^ lut_q;
            end

            if(in_sof && !seen_sof) begin
                seen_sof <= 1'b1;
                crc <= 32'hFFFF_FFFF;
                out_sof <= 1'b1;
            end
            if(in_vld && out_rdy && !fcs_phase) begin
                // pass-through payload
                out_vld  <= 1'b1;
                out_data <= in_data;
            end

            // register the update request (matches ROM latency)
            update_crc_d <= in_vld & out_rdy & ~fcs_phase;

            if(in_vld && in_eof && out_rdy && !fcs_phase) begin
                // switch to FCS appending next
                fcs_phase <= 1'b1;
                fcs_idx   <= 2'd0;
            end

            if(fcs_phase && out_rdy) begin
                out_vld  <= 1'b1;
                out_data <= fcs_byte;
                if(fcs_idx==2'd3) begin
                    out_eof   <= 1'b1;
                    fcs_phase <= 1'b0;
                    seen_sof  <= 1'b0;
                    // CRC will be reset by next SOF
                end
                fcs_idx <= fcs_idx + 2'd1;
            end
        end
    end
endmodule
