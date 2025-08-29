// mac_rgmii_tx.v : RGMII TX backend for ECP5 (ODDRX1F).
// - Adds preamble (7*0x55) + SFD (0xD5) before tx stream.
// - Outputs DDR data via ODDRX1F; forwards TXC using ODDRX1F square wave.
// - TX_CTL encodes TX_EN on both edges (TX_ER=0).

module mac_rgmii_tx(
    input  wire       tx_clk,   // 125MHz (or 25MHz)
    input  wire       rst_n,
    input  wire       tx_sof,
    input  wire       tx_vld,
    input  wire [7:0] tx_data,
    input  wire       tx_eof,
    output wire       tx_rdy,   // always ready (no backpressure)

    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc
);
    assign tx_rdy = 1'b1;

    // Simple preamble inserter
    localparam T_IDLE=2'd0, T_PREAM=2'd1, T_DATA=2'd2, T_GAP=2'd3;
    reg [1:0] st;
    reg [2:0] pre_cnt;
    reg [7:0] cur_byte;
    reg       en_now;

    always @(posedge tx_clk or negedge rst_n) begin
        if(!rst_n) begin
            st<=T_IDLE; pre_cnt<=3'd0; cur_byte<=8'h00; en_now<=1'b0;
        end else begin
            case(st)
                T_IDLE: begin
                    en_now <= 1'b0;
                    if(tx_sof) begin st<=T_PREAM; pre_cnt<=3'd0; end
                end
                T_PREAM: begin
                    en_now   <= 1'b1;
                    cur_byte <= (pre_cnt==3'd7) ? 8'hD5 : 8'h55;
                    if(pre_cnt==3'd7) st<=T_DATA;
                    pre_cnt <= pre_cnt + 3'd1;
                end
                T_DATA: begin
                    en_now   <= tx_vld;
                    cur_byte <= tx_data;
                    if(tx_vld && tx_eof) st<=T_GAP;
                end
                T_GAP: begin
                    en_now <= 1'b0;
                    st <= T_IDLE;
                end
            endcase
        end
    end

    // Drive ODDRX1F for 4 data bits + TX_CTL and TXC
    // Map: rising edge -> lower nibble, falling -> upper nibble
    wire [3:0] d0 = cur_byte[3:0];
    wire [3:0] d1 = cur_byte[7:4];
    wire       tx_en = en_now;

    genvar i;
    generate
        for(i=0;i<4;i=i+1) begin: G_ODDR_D
            ODDRX1F oddr_d (
                .SCLK(tx_clk),
                .RST (~rst_n),
                .D0  (d0[i]),
                .D1  (d1[i]),
                .Q   (rgmii_txd[i])
            );
        end
    endgenerate

    // TX_CTL: TX_EN on both edges (TX_ER=0 => XOR same)
    ODDRX1F oddr_ctl (
        .SCLK(tx_clk),
        .RST (~rst_n),
        .D0  (tx_en),
        .D1  (tx_en),
        .Q   (rgmii_tx_ctl)
    );

    // Forwarded TXC
    ODDRX1F oddr_txc (
        .SCLK(tx_clk),
        .RST (~rst_n),
        .D0  (1'b1),
        .D1  (1'b0),
        .Q   (rgmii_txc)
    );

endmodule
