// l2_to_ip_shim.v : Thin shim layer. For now: when CRC OK pulse arrives, we pass data through.
// A real IP layer would parse headers and trim FCS/padding using IP Total Length.

module l2_to_ip_shim(
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] in_dout,
    input  wire       in_empty,
    input  wire       crc_ok_pulse,

    output reg [7:0]  out_data,
    output reg        out_we
);
    // For bring-up: just echo whenever CRC OK seen (one-shot).
    reg gating;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            gating <= 1'b0;
            out_we <= 1'b0;
            out_data <= 8'h00;
        end else begin
            out_we <= 1'b0;
            if(crc_ok_pulse) gating <= 1'b1;
            if(gating && !in_empty) begin
                out_we   <= 1'b1;
                out_data <= in_dout;
            end
        end
    end
endmodule
