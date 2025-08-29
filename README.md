# V18 Full RTL (No SBX IP, No LDF)

> ECP5 LFE5U-25F-6BG256C RGMII (RXC by PHY delay; TXC by FPGA delay) — Dual PHY, full-duplex only.
> This bundle includes **pure RTL** + docs only. **SBX IPs** and **.ldf project** are *not* included.

## What’s inside
- `src/eth_top_full.v` — Top-level. Two PHYs (PHY1/PHY2), RX/TX, MDIO polling (link only), CRC add/check wiring, status LEDs/OUT pins.
- `src/mac_rgmii_rx.v` — RGMII RX front-end (IDDRX1F + optional DELAYG=0). Builds bytes (8-bit) from DDR nibbles. **Filters preamble + SFD**; exports `byte_vld/byte_data/sof/eof`.
- `src/mac_rgmii_tx.v` — RGMII TX back-end (ODDRX1F). Adds (7×0x55)+0xD5 preamble+SFD then forwards data. TXC is forwarded clock via ODDRX1F (2ns delay to be added by constraints/IODELAY).
- `src/eth_crc32_stream_add.v` — Ethernet CRC32 appender (LUT-based; **instantiates SBX ROM `crc32_lut`**). In: `in_*` payload; Out: adds 4B FCS.
- `src/eth_crc32_stream_chk.v` — RX CRC checker (LUT-based; **instantiates SBX ROM `crc32_lut`**). **Computes over bytes including FCS** and checks **residual `32'h2144_DF1C`**. Interface uses `frame_done` from RX to avoid “guess end by empty”. 
- `src/udp_tx_fixed.v` — Simple data source for bring-up. Replace with your application layer later.
- `src/l2_to_ip_shim.v` — Thin shim from L2 to IP. At this stage: pass-through; real IP trims FCS/any padding per IP Total Length.
- `src/mdio_c22_poll.v` — Clause-22 MDIO master (read-only). Polls BMSR (reg1) for **link_up**; PHY0 address=1, PHY1 address=2.
- `src/rxclk_speed_detect.v` — 25MHz-ref based detector of RXC≈125/25MHz → `is_1g` (1/0).
- `doc/engineering_notes.md` — Design decisions agreed in chat, captured as a spec.

## External IPs you must add yourself (SBX):
- `rgmii_pll_core` (ports: `.CLKI, .RST, .CLKOP, .CLKOS, .CLKOS2, .LOCK`)
- `crc32_lut` (ports: `.Address[7:0], .OutClock, .OutClockEn, .Reset, .Q[31:0]`)
- `mac_fifo_2048_dc` (ports: `.Data[7:0], .WrClock, .RdClock, .WrEn, .RdEn, .Reset, .RPReset, .Q[7:0], .Empty, .Full, .AlmostEmpty, .AlmostFull`)
- `fifo_2048_sc` (ports: `.Data[7:0], .Clock, .WrEn, .RdEn, .Reset, .Q[7:0], .Empty, .Full, .AlmostEmpty, .AlmostFull`)

> **No module name collisions** with your SBX: we only **instantiate** them; we do **not** provide same-named RTL.

## Key agreements implemented
- **RX pipeline alignment:** *100M and 1000M both* — byte assembly **does not add** an extra stage.  
  - The **same enable** drives MAC RX FIFO write and CRC32 enable (internally the CRC LUT has 1-cycle latency; we compensate inside the CRC module without changing the external enable).
- **CRC32 coverage:** **includes FCS** on RX; residual must equal `32'h2144_DF1C`. TX appends FCS after payload (standard init/final XOR).
- **Preamble/SFD:** MAC RX filters `7×0x55 + 0xD5` (never enters any FIFO). MAC TX automatically adds them before payload.
- **Length trim:** Per agreement, trimming FCS/padding is handled in **IP layer** using IP Total Length. MAC layer keeps the frame bytes intact after SFD (including FCS toward the RX checker & L2).
- **Speed handling:** Full-duplex only; negotiation speed read not required — we **detect RXC** ≈125/25MHz for 1G/100M. TXC 2ns delay via constraints/IODELAY (not by PLL 90°).

## Hookup notes
- Connect your SBX IPs and `.lpf/.ldf`. Example top ports are stable:
  - `FPGA_CLK`: 25MHz ref
  - `rest`: active-high reset
  - RGMII groups for PHY1/PHY2, plus MDC/MDIO for PHY1 (addr=1), PHY2 (addr=2)
- Tie your `crc32_lut` IP clock to `clk_125m`. `OutClockEn=1'b1`, `Reset=~rst_n` (low-active reset internally).

## Next steps
1. Add your SBX directories to the project (no renames required) and your `.lpf/.ldf`.
2. If warnings mention unconstrained clocks (ROM/FIFO), add `FREQUENCY NET` on the nets:
   - `clk_125m` = 125MHz, `clk_25m` = 25MHz, `PHYx_RX_CLK` = 125/25MHz (both).
3. Replace `udp_tx_fixed` with your real application producer as needed.
