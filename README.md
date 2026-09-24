# FPGA Ethernet Frame Processer

A SystemVerilog AXI-Stream pipeline that ingests raw Ethernet frames on a Zynq-7000 SoC (Digilent Arty Z7-20), classifies and routes them by UDP destination port, extracts UDP payloads, and decodes a real binary market-data protocol (Nasdaq TotalView-ITCH 5.0) out of the matched traffic.

Data communications used: Ethernet, IPv4, and UDP for the network side, parsed in hand-written RTL rather than an offload IP. AXI-Stream (with AXI DMA) as the on-chip interconnect tying the FIFO, demux, sniffer, and parser together. Nasdaq TotalView-ITCH 5.0 as the binary application-layer protocol being decoded.

Every module here has its own self-checking testbench (Icarus Verilog / Vivado XSIM), and the core pipeline (buffering → routing → payload extraction) has been validated on real hardware via ILA against live network traffic, not just simulation.

## Pipeline

```
PS (Zynq) ── GEM0 + lwIP ── AXI DMA (M_AXIS_MM2S_0)
                                   │
                                   ▼
                          axis_sync_fifo            (rate-decoupling FIFO)
                                   │
                                   ▼
                           axis_demux                (classify + route by UDP dst port)
                            │            │
                     matched (1234)   unmatched
                            │            └─ sunk (no consumer yet)
                            ▼
                        udp_sniffer                  (strip Eth/IP/UDP headers, emit payload)
                            │
                            ▼
                        itch_parser                  (decode ITCH 5.0 messages from the payload)
```

`eth_capture_bridge_top.sv` wires all of this together on the Arty Z7-20's PL side, downstream of the PS-forwarded DMA stream.

## Modules

| Module | What it does | Verification |
|---|---|---|
| `axis_sync_fifo.sv` | Parameterized (`DATA_WIDTH`, `DEPTH`) synchronous AXI-Stream FIFO, first-word-fall-through read. Decouples the DMA's timing from the rest of the pipeline. | 48-check self-checking testbench (Vivado XSIM), 0 errors. Hardware-validated: FIFO write→read data integrity confirmed via ILA against live traffic. |
| `axis_demux.sv` | Classifies each incoming frame (EtherType → IP protocol → UDP dst port) and routes the *entire* frame, headers included, to a "matched" or "unmatched" AXI-Stream output. Cut-through with bounded classification latency, using an internal `axis_sync_fifo` instance as the latency buffer. | `tb/axis_demux_tb.sv`, 6 scenarios / 23 checks, 0 errors. Hardware-validated via ILA: correct classification of a real UDP-to-port-1234 packet, including wrongly-typed/wrong-port traffic being routed away correctly. |
| `udp_sniffer.sv` | Parses Ethernet/IPv4/UDP headers on the matched stream and emits only the UDP payload bytes (`m_axis_tvalid` gated to the `PAYLOAD` state). | Hardware-validated via ILA (payload correctly isolated from real captured frames). |
| `itch_parser.sv` | Single-FSM parser for Nasdaq TotalView-ITCH 5.0. Decodes 5 message types (Add Order, Add Order w/ MPID, Order Executed, Order Cancel, Order Delete) from a raw back-to-back ITCH byte stream into a flat output bus with a single-cycle `msg_valid` pulse per message. | `tb/itch_parser_tb.sv`, 7 scenarios / 33 checks, 0 errors. Hardware-tested against one synthetic ITCH message injected over UDP (`scripts/send_itch_msg.py`): correct `msg_type`/`order_ref` capture and correctly-timed `tlast`/`msg_valid` confirmed via ILA. See **Known issues** below — an anomaly in sustained/back-to-back hardware traffic is still under investigation. |
| `eth_capture_bridge_top.sv` | Top-level integration on the Arty Z7-20 — wires DMA → FIFO → demux → sniffer → ITCH parser, with `mark_debug` nets throughout for ILA visibility. | Compiles clean (`iverilog -g2012`) against port-matched stub modules for the Vivado-generated PS block design (`eth_block_wrapper`). |

## ITCH 5.0 scope (v1)

This is a deliberately scoped-down v1, not a complete ITCH implementation:

- No MoldUDP64 session/sequencing wrapper — the parser consumes a raw stream of back-to-back ITCH messages directly.
- Message types covered: `A`, `F`, `E`, `X`, `D`. Order Replace (`U`) is not yet implemented.
- Output is "FPGA-native": a flat bus of typed output ports (`msg_type`, `stock_locate`, `order_ref`, `buy_sell`, `shares`, `price`, `match_num`) plus a `msg_valid` strobe — not a re-serialized byte stream.
- No `stock` (ASCII ticker) output — only the numeric `stock_locate` ID. A real Stock Directory (`R`) lookup table (`stock_locate → ticker`) is future work.

Field layouts are taken directly from Nasdaq's published [ITCH 5.0 specification](https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHSpecification_5.0.pdf).

## Repo layout

```
rtl/      synthesizable SystemVerilog sources
tb/       self-checking testbenches (Icarus Verilog / Vivado XSIM)
scripts/  Python UDP test-traffic generators used for hardware validation
```

`axis_sync_fifo.sv`'s original 48-check testbench was built and run interactively in Vivado's XSIM and isn't included here as a standalone file — the check counts above are reported from that session, not reproducible from this repo alone. `axis_demux_tb.sv` and `itch_parser_tb.sv` are both included and runnable as-is.

## Running the testbenches

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`-g2012` for SystemVerilog support):

```bash
# axis_demux
iverilog -g2012 -o /tmp/demux_tb.out rtl/axis_sync_fifo.sv rtl/axis_demux.sv tb/axis_demux_tb.sv
vvp /tmp/demux_tb.out

# itch_parser
iverilog -g2012 -o /tmp/itch_tb.out rtl/itch_parser.sv tb/itch_parser_tb.sv
vvp /tmp/itch_tb.out
```

Both should print `TOTAL CHECKS: N   ERRORS: 0`.

## Hardware test traffic

`scripts/send_udp_frame.py` sends generic UDP test payloads (used to validate the FIFO/demux/sniffer chain against real network traffic). `scripts/send_itch_msg.py` builds and sends a real, byte-accurate ITCH 5.0 `A`/`D` message as a UDP payload, so `itch_parser` has genuine ITCH-shaped bytes to parse on hardware instead of arbitrary test data.

```bash
python3 scripts/send_itch_msg.py   # sends one Add Order ('A') message to 192.168.1.10:1234
```

## Known issues

- **`itch_parser`/`axis_demux` hardware anomaly, unresolved**: in one ILA capture, after a real ITCH message was correctly parsed (confirmed via a correctly-timed `tlast` and `msg_valid` pulse), `axis_demux`'s matched output was later observed frozen — presenting one stale byte indefinitely with `tvalid` held high and no further `tlast`, which in turn left `udp_sniffer`'s FSM stuck in its `DISCARD` state. Root cause not yet confirmed; leading hypothesis is a stall in `axis_demux`'s internal FIFO read-side draining rather than genuine incoming traffic (the frozen byte never varied, which is inconsistent with real network data). Not yet resolved or reproduced in simulation.
- `axis_demux`'s unmatched output has no downstream consumer yet (`tready` tied high, traffic sunk).
- Order Replace (`U`) and Stock Directory (`R`) parsing are not implemented.

## Hardware target

Digilent Arty Z7-20 (Zynq-7000, `xc7z020clg400-1`). PS side: GEM0 Ethernet MAC + lwIP, forwarding captured frames to the PL over AXI DMA. This repo covers the PL-side pipeline only.

## License

MIT — see [LICENSE](LICENSE).
