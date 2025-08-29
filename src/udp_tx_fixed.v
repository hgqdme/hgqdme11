// udp_tx_fixed.v : Very small source stream for bring-up.
// Not a real UDP stack; just emits a short payload periodically.

module udp_tx_fixed #(
    parameter integer PERIOD_CYC = 125_000_000  // 1s at 125MHz
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       enable,

    output reg        sof,
    output reg        vld,
    output reg [7:0]  data,
    output reg        eof,
    input  wire       ready
);
    reg [31:0] cnt;
    reg sending;
    reg [7:0]  idx;

    localparam LEN = 32;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            cnt<=32'd0; sending<=1'b0; idx<=8'd0;
            sof<=1'b0; vld<=1'b0; data<=8'h00; eof<=1'b0;
        end else begin
            sof<=1'b0; vld<=1'b0; eof<=1'b0;
            if(!sending) begin
                if(enable) begin
                    if(cnt==PERIOD_CYC-1) begin
                        cnt<=32'd0; sending<=1'b1; idx<=8'd0; sof<=1'b1;
                    end else cnt<=cnt+1;
                end else cnt<=32'd0;
            end else begin
                if(ready) begin
                    vld <= 1'b1;
                    data <= idx;
                    if(idx==LEN-1) begin
                        eof <= 1'b1;
                        sending<=1'b0;
                    end
                    idx <= idx + 8'd1;
                end
            end
        end
    end
endmodule
