// mdio_c22_poll.v : Simple Clause-22 MDIO read-only poller for BMSR (reg1).
// Polls PHY_ADDR0 and PHY_ADDR1 alternately. Outputs link_up[1:0].
// MDC ~2.5MHz from 25MHz clk. MDIO sampled on rising edge of MDC.

module mdio_c22_poll #(
    parameter [4:0] PHY_ADDR0 = 5'd1,
    parameter [4:0] PHY_ADDR1 = 5'd2
)(
    input  wire clk_25m,
    input  wire rst_n,
    output wire mdc,
    inout  wire mdio,
    output reg [1:0] link_up
);
    // MDC generator: 25MHz / 10 = 2.5MHz (50/50)
    reg [3:0] div;
    always @(posedge clk_25m or negedge rst_n) begin
        if(!rst_n) div <= 4'd0;
        else       div <= div + 4'd1;
    end
    assign mdc = div[3]; // 2.5MHz

    // MDIO tri-state
    reg mdio_oe, mdio_out;
    wire mdio_in;
    assign mdio    = mdio_oe ? mdio_out : 1'bz;
    assign mdio_in = mdio;

    // C22 frame fields
    // Preamble: 32x '1'
    // Start: 01, Op: 10 (read), PhyAddr[4:0], RegAddr[4:0], TA: Z0, Data[15:0]
    localparam REG_BMSR = 5'd1;
    localparam PRE_BITS = 6'd32;

    reg [4:0] phy_sel; // current phy addr
    reg [5:0] pre_cnt;
    reg [5:0] bit_cnt; // counts bits inside frame
    reg [15:0] data_shift;
    reg [4:0] reg_addr;
    reg [1:0] state;

    localparam S_IDLE=2'd0, S_PREAM=2'd1, S_CMD=2'd2, S_DATA=2'd3;

    // sample on MDC rising, drive on falling
    reg mdc_d;
    wire mdc_rise = (mdc==1'b1 && mdc_d==1'b0);
    wire mdc_fall = (mdc==1'b0 && mdc_d==1'b1);
    always @(posedge clk_25m or negedge rst_n) begin
        if(!rst_n) mdc_d <= 1'b0;
        else       mdc_d <= mdc;
    end

    // Simple round-robin PHY0->PHY1
    reg which;
    always @(posedge clk_25m or negedge rst_n) begin
        if(!rst_n) which <= 1'b0;
        else if(state==S_IDLE && mdc_rise) which <= ~which;
    end
    always @(*) begin
        phy_sel = which ? PHY_ADDR1 : PHY_ADDR0;
    end

    // Command stream shift (precomputed constant bits)
    reg [4:0] phy_bits;
    reg [4:0] reg_bits;
    reg [1:0] op_bits;
    reg [1:0] st_bits;
    always @(*) begin
        phy_bits = phy_sel;
        reg_bits = REG_BMSR;
        op_bits  = 2'b10; // READ
        st_bits  = 2'b01;
    end

    // Main FSM
    always @(posedge clk_25m or negedge rst_n) begin
        if(!rst_n) begin
            state<=S_IDLE; mdio_oe<=1'b0; mdio_out<=1'b1;
            pre_cnt<=6'd0; bit_cnt<=6'd0;
            data_shift<=16'h0000; reg_addr<=REG_BMSR;
            link_up<=2'b00;
        end else begin
            case(state)
            S_IDLE: begin
                // start preamble
                if(mdc_rise) begin
                    pre_cnt <= 6'd0;
                    mdio_oe <= 1'b1;  // drive '1's
                    mdio_out<= 1'b1;
                    state   <= S_PREAM;
                end
            end
            S_PREAM: begin
                if(mdc_rise) begin
                    if(pre_cnt==PRE_BITS-1) begin
                        pre_cnt<=6'd0;
                        bit_cnt<=6'd0;
                        state  <= S_CMD;
                    end else begin
                        pre_cnt<=pre_cnt+6'd1;
                    end
                end
            end
            S_CMD: begin
                // Drive start(01), op(10), phy(5), reg(5), TA(Z0)
                if(mdc_fall) begin
                    // drive next bit on falling edges
                    if(bit_cnt<2) begin
                        mdio_oe  <= 1'b1;
                        mdio_out <= st_bits[1-bit_cnt];
                    end else if(bit_cnt<4) begin
                        mdio_oe  <= 1'b1;
                        mdio_out <= op_bits[3-bit_cnt]; // 10
                    end else if(bit_cnt<9) begin
                        mdio_oe  <= 1'b1;
                        mdio_out <= phy_bits[8-bit_cnt]; // MSB first
                    end else if(bit_cnt<14) begin
                        mdio_oe  <= 1'b1;
                        mdio_out <= reg_bits[13-bit_cnt];
                    end else if(bit_cnt==14) begin
                        // TA: Z
                        mdio_oe  <= 1'b0; // release
                    end else if(bit_cnt==15) begin
                        // TA: 0 (by PHY)
                        mdio_oe  <= 1'b0;
                    end else begin
                        // then read data
                        mdio_oe  <= 1'b0;
                    end
                end
                if(mdc_rise) begin
                    bit_cnt <= bit_cnt + 6'd1;
                    if(bit_cnt==15) begin
                        state <= S_DATA;
                        bit_cnt <= 6'd0;
                    end
                end
            end
            S_DATA: begin
                // sample 16 bits
                if(mdc_rise) begin
                    data_shift <= {data_shift[14:0], mdio_in};
                    bit_cnt <= bit_cnt + 6'd1;
                    if(bit_cnt==6'd15) begin
                        // latch link bit (bit2 of BMSR) into correct lane
                        if(which==1'b0) link_up[0] <= data_shift[1]; // bit2 arrives last; use previous bit1 then next
                        else            link_up[1] <= data_shift[1];
                        state <= S_IDLE;
                        bit_cnt <= 6'd0;
                        mdio_oe <= 1'b0;
                    end
                end
            end
            endcase
        end
    end

endmodule
