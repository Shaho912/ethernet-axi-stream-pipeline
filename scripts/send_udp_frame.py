#!/usr/bin/env python3
"""
send_udp_frame.py -- test traffic generator for the Arty Z7-20 UDP sniffer chain
(GEM0 -> lwIP -> DMA -> axis_sync_fifo -> udp_sniffer).

Usage:
    python send_udp_frame.py                       # one small test payload
    python send_udp_frame.py --size 68              # specific payload size
    python send_udp_frame.py --count 5 --size 68    # N frames back to back
    python send_udp_frame.py --dst-ip 192.168.1.10 --dst-port 1234
"""
import argparse
import socket
import time


def main():
    parser = argparse.ArgumentParser(description="Send test UDP frames to the Arty Z7-20 sniffer")
    parser.add_argument("--dst-ip", default="192.168.1.10", help="board's static IP")
    parser.add_argument("--dst-port", type=int, default=1234, help="UDP port udp_sniffer is filtering on")
    parser.add_argument("--size", type=int, default=4, help="UDP payload size in bytes")
    parser.add_argument("--count", type=int, default=1, help="number of frames to send")
    parser.add_argument("--interval", type=float, default=0.5, help="seconds between frames")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    for i in range(args.count):
        # incrementing byte pattern (0,1,2,3...) -- easy to recognize in the ILA
        # waveform when tracing dma_axis_tdata -> fifo_axis_tdata by eye
        payload = bytes([(i + j) % 256 for j in range(args.size)])
        sock.sendto(payload, (args.dst_ip, args.dst_port))
        print(f"Sent frame {i + 1}/{args.count}: {args.size} bytes -> {args.dst_ip}:{args.dst_port}")
        if args.count > 1 and i < args.count - 1:
            time.sleep(args.interval)

    sock.close()


if __name__ == "__main__":
    main()
