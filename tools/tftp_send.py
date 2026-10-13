#!/usr/bin/env python3
"""Minimal one-file TFTP server for flashing the TL-WR940N v6 recovery image.

Usage:  sudo python3 tftp_send.py ~/Downloads/openwrt-...-squashfs-factory-eu.bin [interface]
        (interface defaults to en4; replies are forced out of that adapter)
Serves that file under any requested name (the router asks for wr940nv6_tp_recovery.bin),
prints progress, and exits after one complete transfer.
"""
import os
import socket
import struct
import sys
import time

BLOCK = 512
IFACE = "en4"
IP_BOUND_IF = 25  # macOS: pin a socket to one network interface


def pin(sock):
    if sys.platform == "darwin" and IFACE:
        try:
            sock.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, socket.if_nametoindex(IFACE))
        except OSError as e:
            sys.exit(f"Cannot use interface {IFACE}: {e}. Check the name with: ifconfig")


def sendto_retry(sock, pkt, client):
    # macOS reports 'No route to host' while it is still looking up the router's address
    for _ in range(50):
        try:
            sock.sendto(pkt, client)
            return
        except OSError:
            time.sleep(0.1)
    sock.sendto(pkt, client)
RRQ, DATA, ACK, ERROR, OACK = 1, 3, 4, 5, 6


def serve(path, port=69, bind="0.0.0.0"):
    data = open(path, "rb").read()
    total = (len(data) // BLOCK) + 1
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    pin(srv)
    srv.bind((bind, port))
    print(f"Serving {os.path.basename(path)} ({len(data)} bytes) on UDP port {port}.")
    print("Now power on the router while holding Reset...")
    while True:
        pkt, client = srv.recvfrom(1500)
        if len(pkt) < 4 or struct.unpack("!H", pkt[:2])[0] != RRQ:
            continue
        name = pkt[2:].split(b"\0")[0].decode(errors="replace")
        print(f"Request from {client[0]} for '{name}' - sending...")
        if send(data, total, client):
            print("\nTransfer complete. Wait 3 minutes for the router to flash and reboot.")
            return
        print("\nTransfer failed, waiting for the router to ask again...")


def send(data, total, client):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    pin(s)
    s.bind(("0.0.0.0", 0))
    s.settimeout(1.0)
    block = 1
    start = time.time()
    while block <= total:
        chunk = data[(block - 1) * BLOCK: block * BLOCK]
        pkt = struct.pack("!HH", DATA, block & 0xFFFF) + chunk
        for _ in range(10):
            sendto_retry(s, pkt, client)
            try:
                while True:
                    resp, addr = s.recvfrom(1500)
                    if addr != client or len(resp) < 4:
                        continue
                    op, num = struct.unpack("!HH", resp[:4])
                    if op == ERROR:
                        print(f"\nRouter reported an error: {resp[4:].decode(errors='replace')}")
                        return False
                    if op == ACK and num == (block & 0xFFFF):
                        break
                break
            except socket.timeout:
                continue
        else:
            return False
        if block % 256 == 0 or block == total:
            pct = block * 100 // total
            sys.stdout.write(f"\r  {pct:3d}%  ({block}/{total} blocks, {time.time() - start:.0f}s)")
            sys.stdout.flush()
        block += 1
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
        sys.exit("usage: sudo python3 tftp_send.py <factory-eu.bin>")
    if len(sys.argv) > 2:
        IFACE = sys.argv[2]
    print(f"Using network interface {IFACE}")
    serve(sys.argv[1], int(os.environ.get("TFTP_PORT", "69")))
