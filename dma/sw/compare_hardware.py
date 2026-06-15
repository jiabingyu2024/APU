#!/usr/bin/env python3
"""Compare final-test APU boundary captures with the software golden."""

import argparse
import json
from pathlib import Path

import numpy as np


def variants(output):
    grouped = output.reshape(1, 4, 64, 8, 8)
    return {
        "direct": output,
        "group_reverse": grouped[:, ::-1].reshape(1, 256, 8, 8),
        "lane_reverse": grouped[:, :, ::-1].reshape(1, 256, 8, 8),
        "group_and_lane_reverse": grouped[:, ::-1, ::-1].reshape(1, 256, 8, 8),
    }


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--golden-dir", type=Path, default=root / "dma/sw/output")
    parser.add_argument("--report-dir", type=Path, default=root / "dma/reports/final")
    args = parser.parse_args()

    ideal_input = np.load(args.golden_dir / "ideal_apu_input.npy")
    ideal_output = np.load(args.golden_dir / "ideal_apu_output.npy")
    for name in ("02_mmio_inference", "05_dma_inference"):
        report = json.loads((args.report_dir / (name + ".json")).read_text(encoding="utf-8"))
        actual_input = np.load(args.report_dir / (name + "_apu_input.npy"))
        actual_output = np.load(args.report_dir / (name + "_apu_output.npy"))
        result = {
            "test": name,
            "prediction": report["prediction"],
            "class": report["class"],
            "apu_input_mismatch_bits": int(np.count_nonzero(actual_input != ideal_input)),
            "apu_input_total_bits": int(ideal_input.size),
            "apu_output_mismatch_bits": {
                key: int(np.count_nonzero(value != ideal_output))
                for key, value in variants(actual_output).items()
            },
            "apu_output_total_bits": int(ideal_output.size),
        }
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
