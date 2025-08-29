// rxclk_speed_detect.v : detect if rx_clk is ~125MHz (1G) or ~25MHz (100M) using 25MHz reference
module rxclk_speed_detect(
    input  wire clk_ref,  // 25MHz
    input  wire rx_clk,
    output reg  is_1g
);
    // count rx_clk edges within ref window (~1ms)
    reg [15:0] ref_cnt;
    reg        rx_d, rx_dd;
    reg [15:0] edge_cnt;
    always @(posedge clk_ref) begin
        rx_d  <= rx_clk;
        rx_dd <= rx_d;
    end
    wire rx_edge = rx_d & ~rx_dd;

    always @(posedge clk_ref) begin
        if(ref_cnt==16'd24999) begin // 1ms window @25MHz
            ref_cnt  <= 16'd0;
            is_1g    <= (edge_cnt > 16'd60000); // >~62.5k edges in 1ms means ~125MHz
            edge_cnt <= 16'd0;
        end else begin
            ref_cnt <= ref_cnt + 16'd1;
            if(rx_edge) edge_cnt <= edge_cnt + 16'd1;
        end
    end
endmodule
