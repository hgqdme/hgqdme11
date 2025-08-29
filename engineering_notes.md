
# ECP5 双 PHY RGMII 工程文档（V18 / Full-Duplex Only）

> 目标：做“最完整的 RGMII 与 MAC 层”，应用层（ARP/UDP/IP 等）随时可换。工程不包含 SBX/LPF/LDF，请自行合入；所有 IP（`crc32_lut`、`mac_fifo_2048_dc`、`fifo_2048_sc`、`rgmii_pll_core`）**只例化，不提供同名 .v**。

---

## 1. 顶层与模块关系

- **eth_top_full.v**：顶层，双 PHY（RTL8211/KSZ9031 皆可），RX/TX 各自独立并行。
- **mac_rgmii_rx.v**：RGMII → 字节流（8bit）。
  - `IDDRX1F` 采样 `RXD[3:0]` 与 `RX_CTL`，组装高/低半字，**统一打一拍**后输出 `byte_data/byte_vld`；
  - 过滤 `(7×0x55)+0xD5`（前导码 + SFD）**不进任何 FIFO**；
  - **FCS 4B 随数据进入 MAC RX FIFO**（因未知帧长）；
  - `eof_pulse` 来自打拍后的 `RX_CTL` 下降沿。
- **mac_rgmii_tx.v**：字节流 → RGMII。
  - 自动添加 `(7×0x55)+0xD5`；尾部追加 FCS（见 §3）；
  - `ODDRX1F` 送 `TXD/TXCTL/TXC`；**TXC 的 2ns 延时走 I/O 延时/约束**，不使用 90° PLL。
- **eth_crc32_stream_add.v**：发送端 CRC32 **追加 FCS**，查表 ROM `crc32_lut`（IP）。
- **eth_crc32_stream_chk.v**：接收端 CRC32 **含 FCS** 计算与残差判定（见 §3）。
- **mdio_c22_poll.v**：Clause-22 轮询 BMSR（地址：PHY1=1，PHY2=2），只关心 1000M/100M，固定 Full-Duplex。
- **rxclk_speed_detect.v**：以 25MHz 参考判断 RXC 约为 125/25MHz。
- **上层占位**：`udp_tx_fixed.v`（可替换为应用层）。
- **FIFOs（IP 提供）**：
  - `mac_fifo_2048_dc` ×4：P1 RX、P1 TX、P2 RX、P2 TX（跨时钟）；
  - `fifo_2048_sc` ×2：用户侧 RX/TX（同时钟）。

> 约定：**应用层**向 IP 提供“纯用户字节流”，IP 负责按协议封装与 `Total Length` 控制。MAC 层只做以太头/尾与线侧时序。

---

## 2. RGMII 时序与原语

### 2.1 接收（PHY → FPGA）
- PHY 端 **RXC 已延时 2ns**（RGMII-RXID 模式）；FPGA 直接用此 RXC。
- `IDDRX1F` 双沿采样 `RXD[3:0]`、`RX_CTL`；拼 8bit 后**打一拍**再输出（1000M/100M **一致**）。
- `byte_vld` 与 CRC 使能 `crc_en` 使用**同一根打拍后的使能**（§3.2）。

### 2.2 发送（FPGA → PHY）
- `ODDRX1F` 送 `TXD/TXCTL/TXC`；TXC 的 **2ns 延时**经 I/O 延时（LPF/约束）或 IODELAY 实现，**不用 90° PLL**。
- 百兆/千兆均同样处理，避免相位偏差过大（25MHz 的 90°=10ns，远大于 2ns）。

---

## 3. CRC32（以太网）

### 3.1 发送端（Add FCS）
- 输入：应用层/上层封装出的 L2 帧（**不含前导码/SFD/FCS**）。
- `eth_crc32_stream_add` 通过 `crc32_lut`（IP）查表流式累加，帧尾在数据后**追加 4B FCS**。
- 线侧由 `mac_rgmii_tx` 自动添加 `(7×0x55)+0xD5`。

### 3.2 接收端（含 FCS 计算 + 残差判定）
- `eth_crc32_stream_chk` 的输入为**去掉前导码/SFD但**包含 payload + **FCS** 的字节流；
- `data_we`（写 MAC RX FIFO 的写使能）与 `crc_en` **完全相同且同步打拍**，确保“写进 FIFO 的是什么，CRC 就计算什么”；
- 模块内部缓存**末尾 4 字节**为 FCS，同时 CRC 的累加输入**仍包括** FCS；
- 帧尾用 `RX_CTL` 的下降沿触发，在这个时刻，CRC 累加器若**包含 FCS**应落在固定残差：  
  **`32'h2144_DF1C`** → 判为 `crc_ok`；否则 `crc_err`；
- 不在 MAC 层丢弃 FCS，后续由 IP 层依据 IPv4 `Total Length` 切用户负载，顺带丢弃 FCS/填充。

---

## 4. 帧界定与过滤

- **帧界定**：严格由 `RX_CTL`（`RX_DV ⊕ RX_ER`）打拍后的**下降沿**决定帧尾；
- **过滤**：`(7×0x55)+0xD5`（前导码+SFD）**不会进入任何 FIFO**；
- **FCS**：随数据进 FIFO，用于上层兼容；CRC 判定在 MAC 层完成。

---

## 5. MDIO 轮询（Clause-22）

- PHY 地址：**PHY1=1，PHY2=2**；
- 读取 BMSR，抽取 Link 与 Speed（1000M/100M），**固定 Full-Duplex**（不考虑半双工、不考虑 10M）；
- RTL8211 与 KSZ9031 均可用**通用寄存器**路径工作；扩展页不必访问。

---

## 6. 约束/集成提示（需自行合入）

- **SBX IP**：
  - `crc32_lut`（ROM），接口：`.Address() .OutClock() .OutClockEn() .Reset() .Q()`；
  - `mac_fifo_2048_dc`（2048×8，跨时钟）×4；
  - `fifo_2048_sc`（2048×8，单时钟）×2；
  - `rgmii_pll_core`：25→125/125_90/25。  
- **LPF**：添加 I/O 口绑定、IO_TYPE、PULLMODE；为 TXC 设置 **2ns 延时**策略（IODELAY/约束）。
- **LDF**：工程名建议 `ecp5_rgmii_v18`。

---

## 7. 实现修正记录（认错说明）

> **认错说明**：之前接收侧用“FIFO 瞬时为空就当帧结束”的做法是错误的、且不可靠。这个做法在背靠背小包、RX 抖动、以及异步跨时钟场景下都可能误判帧尾，是“笑话代码”。现已**彻底移除**。

**正确做法（已在当前版本实现）**
- **帧界定**：严格使用 RGMII 的 `RX_CTL`（`RX_DV ⊕ RX_ER`）表示“数据有效”，在 DDR→8bit 的同等打拍后，**以 `RX_CTL` 的下降沿作为帧尾**。不再观察 FIFO Empty。  
- **对齐关系**：千兆/百兆路径在“拼 8 位”处**各打一拍**，`data_we`（写 MAC RX FIFO 的写使能）与 CRC 的 `crc_en` 使用**同一个**打拍后的使能信号，保证进入 CRC 的字节与写入 FIFO 的字节**一一对应**。  
- **FCS 处理**：前导码 + SFD **被滤掉**不进任何 FIFO；FCS 4 字节**跟随数据一起进入** MAC RX FIFO（因为实时不知道帧长无法提前丢弃）。CRC 模块内部用移位寄存器缓存“最后 4 字节”作为 FCS，同时**CRC 输入仍包括 FCS**。  
- **CRC 判定**：在帧尾（`RX_CTL` 下降沿）到来时，以太网 CRC32 的**固定残差**进行判断，使用的比对常数为 **`32'h2144_DF1C`**（当 CRC 计算包括 FCS 时应得到该残差）。匹配则 `crc_ok_pulse`，否则 `crc_err_pulse`。  
- **完全移除“猜空”**：`eth_crc32_stream_chk` 内部**没有**任何“看 FIFO Empty 判帧”的逻辑；仅依赖 `RX_CTL` 边沿 + 末尾 4 字节缓存 + 残差判断这条正路。

**验证建议**
1. 在 125MHz 域观察 `rx_byte`、`data_we`、同步/打拍后的 `rx_ctl_b`、`eof_pulse`、`last4`、`crc_residual`。  
2. 背靠背帧（FIFO 始终非空）仍应正常产生 `eof_pulse` 与 `crc_ok_pulse`，证明逻辑**不依赖“空”**。  
3. 暂停 `RXC` 不会误产生帧尾。

---

## 8. 接口清单（外设端口）

- `FPGA_CLK`：25MHz 基准。
- `rest`：高有效板级复位（内部做锁相稳定延时释放）。
- **PHY1/PHY2 RGMII**：`TXD[3:0]`、`TX_CTL`、`TX_CLK`、`RXD[3:0]`、`RX_CTL`、`RX_CLK`。
- **MDIO（PHY1 共用）**：`MDC`、`MDIO`（双向）。
- `FPGA_LED[2:0]`：TX 翻转 / RX 翻转 / CRC 错锁存。
- `OUT[31:0]`：调试导出。

---

## 9. 版本与文件结构（本包不含 SBX/LPF/LDF）

```
src/
  eth_top_full.v
  mac_rgmii_rx.v
  mac_rgmii_tx.v
  eth_crc32_stream_add.v
  eth_crc32_stream_chk.v
  mdio_c22_poll.v
  rxclk_speed_detect.v
  udp_tx_fixed.v (可替换为你的应用层源)
doc/
  engineering_notes.md   <-- 本文件
  engineering_notes_addendum.md (若单独需要)
```

> 合包步骤：把你的 SBX 目录（`crc32_lut/ mac_fifo_2048_dc/ fifo_2048_sc/ rgmii_pll_core`）与 .lpf/.ldf 放入工程；若端口名不同，请一并告知以便我回传对齐版本。

