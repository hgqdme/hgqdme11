// eth_top_full.v : Dual-PHY RGMII top (Full-duplex only).
// - RXC delayed by PHY (RXID); TXC delay to be added by IO constraints/IODELAY.
// - MDIO Clause-22 polling for link (PHY1=1, PHY2=2).
// - RX CRC32 includes FCS; residual compared to 32'h2144_DF1C.
// - TX adds preamble/SFD and CRC32 FCS via eth_crc32_stream_add + mac_rgmii_tx.
// External SBX IPs required: rgmii_pll_core, mac_fifo_2048_dc, fifo_2048_sc, crc32_lut.

module eth_top_full(
    input  wire        FPGA_CLK,      // 25MHz ref
    input  wire        rest,          // active-high reset
    output wire [2:0]  FPGA_LED,
    output wire [31:0] OUT,

    // -------- PHY1 RGMII --------
    output wire [3:0]  PHY1_TXD,
    output wire        PHY1_TX_CTL,
    output wire        PHY1_TX_CLK,
    input  wire [3:0]  PHY1_RXD,
    input  wire        PHY1_RX_CTL,
    input  wire        PHY1_RX_CLK,
    output wire        PHY1_MDC,
    inout  wire        PHY1_MDIO,

    // -------- PHY2 RGMII --------
    output wire [3:0]  PHY2_TXD,
    output wire        PHY2_TX_CTL,
    output wire        PHY2_TX_CLK,
    input  wire [3:0]  PHY2_RXD,
    input  wire        PHY2_RX_CTL,
    input  wire        PHY2_RX_CLK
);

    // ========= clocks & reset =========
    wire clk_125m, clk_125m_90, clk_25m;
    wire pll_lock;

    rgmii_pll_core u_pll (
        .CLKI   (FPGA_CLK),    // 25MHz
        .RST    (rest),        // active-high
        .CLKOP  (clk_125m),    // 125MHz
        .CLKOS  (clk_125m_90), // 125MHz +90° (not used for TXC delay here)
        .CLKOS2 (clk_25m),     // 25MHz
        .LOCK   (pll_lock)
    );

    // Generate synchronous system reset (active-low): release after PLL lock stable + few cycles
    reg [2:0] lock_sync;
    always @(posedge clk_125m or posedge rest) begin
        if (rest) lock_sync <= 3'b000;
        else      lock_sync <= {lock_sync[1:0], pll_lock};
    end
    reg [7:0] rst_cnt;
    wire lock_ok = &lock_sync;
    always @(posedge clk_125m or posedge rest) begin
        if (rest)                   rst_cnt <= 8'h00;
        else if (lock_ok && rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 8'h01;
    end
    wire sys_rst_n = lock_ok & (rst_cnt == 8'hFF);

    // ---------------- MDIO Clause-22 poll (PHY1=1, PHY2=2) ----------------
    wire [1:0] link_up;
    mdio_c22_poll #(.PHY_ADDR0(5'd1), .PHY_ADDR1(5'd2)) u_mdio (
        .clk_25m (clk_25m),
        .rst_n   (sys_rst_n),
        .mdc     (PHY1_MDC),
        .mdio    (PHY1_MDIO),
        .link_up (link_up)
    );

    // ---------------- RX clock domain: RGMII -> byte stream ----------------
    // PHY1 RX
    wire        p1_rx_byte_vld;
    wire [7:0]  p1_rx_byte;
    wire        p1_rx_sof, p1_rx_eof;  // after SFD; eof asserted when RX_CTL drops after FCS
    mac_rgmii_rx u_rx1 (
        .rx_clk      (PHY1_RX_CLK),
        .rst_n       (sys_rst_n),
        .rgmii_rxd   (PHY1_RXD),
        .rgmii_rx_ctl(PHY1_RX_CTL),
        .byte_vld    (p1_rx_byte_vld),
        .byte_data   (p1_rx_byte),
        .sof         (p1_rx_sof),
        .eof         (p1_rx_eof)
    );
    // PHY2 RX
    wire        p2_rx_byte_vld;
    wire [7:0]  p2_rx_byte;
    wire        p2_rx_sof, p2_rx_eof;
    mac_rgmii_rx u_rx2 (
        .rx_clk      (PHY2_RX_CLK),
        .rst_n       (sys_rst_n),
        .rgmii_rxd   (PHY2_RXD),
        .rgmii_rx_ctl(PHY2_RX_CTL),
        .byte_vld    (p2_rx_byte_vld),
        .byte_data   (p2_rx_byte),
        .sof         (p2_rx_sof),
        .eof         (p2_rx_eof)
    );

    // ---------------- Dual-clock RX FIFOs (to 125MHz domain) ----------------
    wire [7:0]  p1_fifo_rx_dout;
    wire        p1_fifo_rx_empty, p1_fifo_rx_full;
    wire        p1_fifo_rx_re;
    mac_fifo_2048_dc u_p1_rx_fifo (
        .Data        (p1_rx_byte),
        .WrClock     (PHY1_RX_CLK),
        .RdClock     (clk_125m),
        .WrEn        (p1_rx_byte_vld),
        .RdEn        (p1_fifo_rx_re),
        .Reset       (~sys_rst_n),
        .RPReset     (1'b0),
        .Q           (p1_fifo_rx_dout),
        .Empty       (p1_fifo_rx_empty),
        .Full        (p1_fifo_rx_full),
        .AlmostEmpty (/*unused*/),
        .AlmostFull  (/*unused*/)
    );

    wire [7:0]  p2_fifo_rx_dout;
    wire        p2_fifo_rx_empty, p2_fifo_rx_full;
    wire        p2_fifo_rx_re;
    mac_fifo_2048_dc u_p2_rx_fifo (
        .Data        (p2_rx_byte),
        .WrClock     (PHY2_RX_CLK),
        .RdClock     (clk_125m),
        .WrEn        (p2_rx_byte_vld),
        .RdEn        (p2_fifo_rx_re),
        .Reset       (~sys_rst_n),
        .RPReset     (1'b0),
        .Q           (p2_fifo_rx_dout),
        .Empty       (p2_fifo_rx_empty),
        .Full        (p2_fifo_rx_full),
        .AlmostEmpty (/*unused*/),
        .AlmostFull  (/*unused*/)
    );

    // ---------------- RX CRC32 checkers ----------------
    wire p1_crc_ok_pulse, p1_crc_err_pulse;
    wire p2_crc_ok_pulse, p2_crc_err_pulse;

    eth_crc32_stream_chk u_crc1 (
        .clk          (clk_125m),
        .rst_n        (sys_rst_n),
        .fifo_dout    (p1_fifo_rx_dout),
        .fifo_empty   (p1_fifo_rx_empty),
        .fifo_re      (p1_fifo_rx_re),
        .frame_done   (p1_rx_eof),      // from MAC RX (end-of-frame detection, after FCS)
        .crc_ok_pulse (p1_crc_ok_pulse),
        .crc_err_pulse(p1_crc_err_pulse)
    );
    eth_crc32_stream_chk u_crc2 (
        .clk          (clk_125m),
        .rst_n        (sys_rst_n),
        .fifo_dout    (p2_fifo_rx_dout),
        .fifo_empty   (p2_fifo_rx_empty),
        .fifo_re      (p2_fifo_rx_re),
        .frame_done   (p2_rx_eof),
        .crc_ok_pulse (p2_crc_ok_pulse),
        .crc_err_pulse(p2_crc_err_pulse)
    );

    // ---------------- PHY1 IP path demo: L2->IP shim -> user FIFO ----------------
    wire [7:0]  ip_user_din;
    wire        ip_user_we;
    l2_to_ip_shim u_l2 (
        .clk         (clk_125m),
        .rst_n       (sys_rst_n),
        .in_dout     (p1_fifo_rx_dout),
        .in_empty    (p1_fifo_rx_empty),
        .crc_ok_pulse(p1_crc_ok_pulse),
        .out_data    (ip_user_din),
        .out_we      (ip_user_we)
    );

    // user RX FIFO (single-clock)
    wire [7:0] user_q_rx;
    wire       user_empty_rx, user_full_rx;
    reg        user_rd_rx;
    fifo_2048_sc u_user_rx_fifo (
        .Data        (ip_user_din),
        .Clock       (clk_125m),
        .WrEn        (ip_user_we),
        .RdEn        (user_rd_rx),
        .Reset       (~sys_rst_n),
        .Q           (user_q_rx),
        .Empty       (user_empty_rx),
        .Full        (user_full_rx),
        .AlmostEmpty (/*unused*/),
        .AlmostFull  (/*unused*/)
    );
    always @(posedge clk_125m or negedge sys_rst_n) begin
        if(!sys_rst_n) user_rd_rx <= 1'b0;
        else           user_rd_rx <= ~user_empty_rx; // demo: consume
    end

    // ---------------- TX chains (PHY1 + PHY2), each with CRC add + MAC TX ----------------
    // Simple pattern generators as application sources (replace later)
    wire s1_sof,s1_vld,s1_eof,s1_rdy; wire [7:0] s1_data;
    wire s2_sof,s2_vld,s2_eof,s2_rdy; wire [7:0] s2_data;

    udp_tx_fixed #(.PERIOD_CYC(125_000_000)) u_udp_gen1 (
        .clk (clk_125m), .rst_n(sys_rst_n), .enable(link_up[0]),
        .sof (s1_sof), .vld(s1_vld), .data(s1_data), .eof(s1_eof), .ready(s1_rdy)
    );
    udp_tx_fixed #(.PERIOD_CYC(125_000_000)) u_udp_gen2 (
        .clk (clk_125m), .rst_n(sys_rst_n), .enable(link_up[1]),
        .sof (s2_sof), .vld(s2_vld), .data(s2_data), .eof(s2_eof), .ready(s2_rdy)
    );

    // CRC adders
    wire c1_sof,c1_vld,c1_eof,c1_rdy; wire [7:0] c1_data;
    wire c2_sof,c2_vld,c2_eof,c2_rdy; wire [7:0] c2_data;
    eth_crc32_stream_add u_crc_add1 (
        .clk(clk_125m), .rst_n(sys_rst_n),
        .in_sof(s1_sof), .in_vld(s1_vld), .in_data(s1_data), .in_eof(s1_eof), .in_rdy(s1_rdy),
        .out_sof(c1_sof), .out_vld(c1_vld), .out_data(c1_data), .out_eof(c1_eof), .out_rdy(c1_rdy)
    );
    eth_crc32_stream_add u_crc_add2 (
        .clk(clk_125m), .rst_n(sys_rst_n),
        .in_sof(s2_sof), .in_vld(s2_vld), .in_data(s2_data), .in_eof(s2_eof), .in_rdy(s2_rdy),
        .out_sof(c2_sof), .out_vld(c2_vld), .out_data(c2_data), .out_eof(c2_eof), .out_rdy(c2_rdy)
    );

    // MAC TX -> pins
    mac_rgmii_tx u_tx1 (
        .tx_clk     (clk_125m), .rst_n(sys_rst_n),
        .tx_sof     (c1_sof), .tx_vld(c1_vld), .tx_data(c1_data), .tx_eof(c1_eof), .tx_rdy(c1_rdy),
        .rgmii_txd  (PHY1_TXD), .rgmii_tx_ctl(PHY1_TX_CTL), .rgmii_txc(PHY1_TX_CLK)
    );
    mac_rgmii_tx u_tx2 (
        .tx_clk     (clk_125m), .rst_n(sys_rst_n),
        .tx_sof     (c2_sof), .tx_vld(c2_vld), .tx_data(c2_data), .tx_eof(c2_eof), .tx_rdy(c2_rdy),
        .rgmii_txd  (PHY2_TXD), .rgmii_tx_ctl(PHY2_TX_CTL), .rgmii_txc(PHY2_TX_CLK)
    );

    // ---------------- Status LEDs ----------------
    // LED0=any TX, LED1=any RX, LED2=any CRC error sticky
    reg led_tx, led_rx; reg led_crc_sticky;
    always @(posedge clk_125m or negedge sys_rst_n) begin
        if(!sys_rst_n) begin led_tx<=0; led_rx<=0; led_crc_sticky<=0; end
        else begin
            if(c1_sof | c2_sof) led_tx <= ~led_tx;
            if(p1_crc_ok_pulse | p2_crc_ok_pulse) led_rx <= ~led_rx;
            if(p1_crc_err_pulse | p2_crc_err_pulse) led_crc_sticky <= 1'b1;
        end
    end
    assign FPGA_LED[0]=led_tx;
    assign FPGA_LED[1]=led_rx;
    assign FPGA_LED[2]=led_crc_sticky;

    // RXC speed detect (rough 1G/100M) for OUTs
    wire p1_rxc_fast, p2_rxc_fast;
    rxclk_speed_detect u_spd1(.clk_ref(clk_25m), .rx_clk(PHY1_RX_CLK), .is_1g(p1_rxc_fast));
    rxclk_speed_detect u_spd2(.clk_ref(clk_25m), .rx_clk(PHY2_RX_CLK), .is_1g(p2_rxc_fast));

    // Debug OUTs
    assign OUT[0]  = pll_lock;
    assign OUT[1]  = ~p1_fifo_rx_empty;
    assign OUT[2]  = ~p2_fifo_rx_empty;
    assign OUT[3]  = link_up[0];
    assign OUT[4]  = p1_rxc_fast;
    assign OUT[5]  = p2_rxc_fast;
    assign OUT[6]  = p1_crc_ok_pulse;
    assign OUT[7]  = p2_crc_ok_pulse;
    assign OUT[8]  = p1_crc_err_pulse;
    assign OUT[9]  = p2_crc_err_pulse;
    assign OUT[10] = led_crc_sticky;
    assign OUT[31:11] = 21'h0;

endmodule
