#!/usr/bin/env python3
"""Download the pure-PL SoC bitstream from a running PYNQ Linux image."""

import argparse
from pathlib import Path

from pynq import Bitstream


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bitstream", type=Path, help="Path to riscv_apu_pynq_z2.bit")
    args = parser.parse_args()

    bitstream = args.bitstream.expanduser().resolve()
    if not bitstream.is_file():
        raise SystemExit(f"bitstream not found: {bitstream}")

    print(f"Downloading {bitstream} ...")
    Bitstream(str(bitstream)).download()
    print("PL configured.")
    print("The PicoRV32 program starts inside PL; Python does not execute the C program.")
    print("Observe LED0/LED1/LED2 and the PMODB-pin-1 UART output.")
    print("If UART capture started late, press and release BTN0 to rerun the firmware.")
    print("Development mode only: ARM/Linux is still active after this command.")
    print("For final acceptance, run fpga/xsct/disable_arm_cores.tcl over JTAG.")


if __name__ == "__main__":
    main()
