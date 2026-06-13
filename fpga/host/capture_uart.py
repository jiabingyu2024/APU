#!/usr/bin/env python3
"""Capture the PL UART and return success only after the complete firmware log."""

import argparse
import sys
import time

import serial


EXPECTED = (
    "HELLO RISCV APU SOC",
    "RAM BYTE/HALF/WORD PASS",
    "RV32IM PASS",
    "TIMER PASS",
    "DEFAULT SLAVE PASS",
    "APU FULL NETWORK PASS",
    "APU ZERO CONV PASS",
    "APU MMIO BRIDGE PASS",
    "SOC PREBOARD PASS",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", help="Serial port, for example /dev/ttyUSB0 or COM5")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    deadline = time.monotonic() + args.timeout
    received = ""
    with serial.Serial(args.port, args.baud, timeout=0.1) as uart:
        print("UART capture active. Program PL or press/release BTN0 now.")
        while time.monotonic() < deadline:
            chunk = uart.read(uart.in_waiting or 1)
            if not chunk:
                continue
            text = chunk.decode("ascii", errors="replace")
            received += text
            print(text, end="", flush=True)
            if "FAIL code=" in received:
                print("\nBOARD VERIFY FAIL: firmware reported failure", file=sys.stderr)
                return 1
            if "SOC PREBOARD PASS" in received:
                missing = [token for token in EXPECTED if token not in received]
                if missing:
                    print(f"\nBOARD VERIFY FAIL: missing log tokens: {missing}", file=sys.stderr)
                    return 1
                print("\nBOARD VERIFY PASS")
                return 0

    print("\nBOARD VERIFY FAIL: UART timeout", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
