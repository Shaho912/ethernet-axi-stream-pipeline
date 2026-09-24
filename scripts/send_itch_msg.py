#!/usr/bin/env python3
"""
Sends a single synthetic Nasdaq ITCH 5.0 message as a raw UDP payload to the
board, so itch_parser actually has real ITCH-shaped bytes to parse (instead
of "hello board", which itch_parser will happily run its FSM over but can't
meaningfully parse, since it isn't a valid message type).

No MoldUDP64 wrapper -- itch_parser (v1) expects a raw back-to-back ITCH
message stream directly, so this just puts the message bytes straight into
the UDP payload, same as the testbench does over AXI-Stream.

Field layout mirrors itch_parser_tb.sv's build_msg() task exactly, so if this
parses correctly on hardware, you can trust it against the same message
shapes already verified in simulation.
"""

import socket
import struct
import sys

BOARD_IP = "192.168.1.10"
BOARD_PORT = 1234


def build_add_order(stock_locate, order_ref, buy_sell, shares, price):
    """Builds a 36-byte ITCH 'A' (Add Order, no MPID) message.

    Layout (big-endian, matches itch_parser_tb.sv build_msg()):
        type(1) + stock_locate(2) + tracking_number(2, dummy) +
        timestamp(6, dummy) + order_ref(8) + buy_sell(1) + shares(4) +
        stock ticker(8, dummy) + price(4)
    """
    msg = b""
    msg += b"A"                                   # message type
    msg += struct.pack(">H", stock_locate)        # stock locate
    msg += struct.pack(">H", 0x0000)               # tracking number (dummy)
    msg += struct.pack(">I", 0x00000000)           # timestamp hi (dummy)
    msg += struct.pack(">H", 0x0000)               # timestamp lo (dummy)
    msg += struct.pack(">Q", order_ref)            # order reference number
    msg += b"B" if buy_sell else b"S"              # buy/sell indicator
    msg += struct.pack(">I", shares)               # shares
    msg += b"T" * 8                                # stock ticker (dummy, unparsed)
    msg += struct.pack(">I", price)                # price
    assert len(msg) == 36, f"expected 36 bytes, got {len(msg)}"
    return msg


def build_order_delete(stock_locate, order_ref):
    """Builds a 19-byte ITCH 'D' (Order Delete) message."""
    msg = b""
    msg += b"D"
    msg += struct.pack(">H", stock_locate)
    msg += struct.pack(">H", 0x0000)
    msg += struct.pack(">I", 0x00000000)
    msg += struct.pack(">H", 0x0000)
    msg += struct.pack(">Q", order_ref)
    assert len(msg) == 19, f"expected 19 bytes, got {len(msg)}"
    return msg


def send(payload, ip=BOARD_IP, port=BOARD_PORT):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.sendto(payload, (ip, port))
    s.close()
    print(f"sent {len(payload)} bytes to {ip}:{port} -> {payload.hex()}")


if __name__ == "__main__":
    # Same values as Test1(A) in itch_parser_tb.sv, so a hardware capture can
    # be compared directly against the already-verified simulation result:
    #   stock_locate=0x0007, order_ref=0x2A2A, buy_sell=Buy, shares=500,
    #   price=1012500 (i.e. $101.25 at ITCH's 4-decimal fixed point)
    msg = build_add_order(
        stock_locate=0x0007,
        order_ref=0x2A2A,
        buy_sell=True,
        shares=500,
        price=1012500,
    )
    send(msg)
