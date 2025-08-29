// mac_rgmii_rx.v : RGMII RX front-end for ECP5 (IDDRX1F).
// - Optional DELAYG=0 is inserted for each data/ctl input (explicit zero delay).
// - Builds byte from DDR nibbles: byte = {fall_nibble, rise_nibble} per RXC cycle.
// - Filters preamble (7*0x55) + SFD (0xD5).
// - Exports sof/eof pulses aligned to the first byte after SFD and end (RX_CTL falling after FCS).

module mac_rgmii_rx(
    input  wire       rx_clk,        // RGMII RXC (already delayed by PHY in RXID mode)
    input  wire       rst_n,
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,

    output reg        byte_vld,
    output reg [7:0]  byte_data,
    output reg        sof,
    output reg        eof
);
    // Optional input delay primitives with DELAYG = 0 (explicit zero delay)
    wire [3:0] d_del;
    wire       ctl_del;
    genvar i;
    generate
        for(i=0;i<4;i=i+1) begin: G_DLY
            // DELAYG with user-defined 0 steps (pass-through but locks the path to DELAY resource)
            (* syn_keep = 1 *) DELAYG udel_datain (.A(rgmii_rxd[i]), .Z(d_del[i]));
            defparam udel_datain.DEL_MODE = "USER_DEFINED";
            defparam udel_datain.DEL_VALUE = 0;
        end
    endgenerate
    (* syn_keep = 1 *) DELAYG udel_ctl (.A(rgmii_rx_ctl), .Z(ctl_del));
    defparam udel_ctl.DEL_MODE = "USER_DEFINED";
    defparam udel_ctl.DEL_VALUE = 0;

    // DDR capture
    wire [3:0] d_rise, d_fall;
    wire       ctl_rise, ctl_fall;
    generate
        for(i=0;i<4;i=i+1) begin: G_IDDR
            IDDRX1F iddr_d (
                .D   (d_del[i]),
                .SCLK(rx_clk),
                .RST (~rst_n),
                .Q0  (d_rise[i]),   // posedge sample
                .Q1  (d_fall[i])    // negedge sample
            );
        end
    endgenerate
    IDDRX1F iddr_ctl (
        .D   (ctl_del),
        .SCLK(rx_clk),
        .RST (~rst_n),
        .Q0  (ctl_rise),
        .Q1  (ctl_fall)
    );

    // Combine nibbles to byte each cycle
    wire [7:0] byte_now = {d_fall, d_rise};
    wire       dv_now   = ctl_rise | ctl_fall;  // RGMII: RX_CTL high => data valid

    // Preamble/SFD filter
    localparam S_IDLE=2'd0, S_PREAM=2'd1, S_DATA=2'd2;
    reg [1:0] st;
    reg [2:0] pre_cnt; // count 0x55 seen
    always @(posedge rx_clk or negedge rst_n) begin
        if(!rst_n) begin
            st <= S_IDLE; pre_cnt <= 3'd0;
            byte_vld <= 1'b0; byte_data <= 8'h00;
            sof <= 1'b0; eof <= 1'b0;
        end else begin
            sof <= 1'b0; eof <= 1'b0;  // pulses
            byte_vld <= 1'b0;

            if(dv_now) begin
                case(st)
                    S_IDLE: begin
                        // wait for 0x55 preamble sequence
                        if(byte_now==8'h55) begin
                            pre_cnt <= 3'd1;
                            st <= S_PREAM;
                        end
                    end
                    S_PREAM: begin
                        if(byte_now==8'h55) begin
                            if(pre_cnt!=3'd7) pre_cnt <= pre_cnt + 3'd1;
                        end else if(byte_now==8'hD5 && pre_cnt>=3'd6) begin
                            // SFD detected
                            st <= S_DATA;
                            sof <= 1'b1;
                        end else begin
                            // unexpected, reset detection
                            st <= S_IDLE; pre_cnt <= 3'd0;
                        end
                    end
                    S_DATA: begin
                        // output data bytes (after SFD) while dv high
                        byte_data <= byte_now;
                        byte_vld  <= 1'b1;
                    end
                    default: st <= S_IDLE;
                endcase
            end else begin
                // dv low => end of frame (after FCS according to RGMII timing)
                if(st==S_DATA) begin
                    eof <= 1'b1;
                end
                st <= S_IDLE; pre_cnt <= 3'd0;
            end
        end
    end
endmodule
