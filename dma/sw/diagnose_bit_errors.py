#!/usr/bin/env python3
"""Summarize APU output bit-error locations from final-test captures."""

import argparse
import json
from pathlib import Path

import numpy as np
import torch

from reference_model import ApuBinaryReference, load_binary_words


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--golden", type=Path, default=root / "dma/sw/output/ideal_apu_output.npy")
    parser.add_argument("--report-dir", type=Path, default=root / "dma/reports/final")
    args = parser.parse_args()
    golden = np.load(args.golden)
    ideal_input = np.load(args.golden.parent / "ideal_apu_input.npy")
    _, captured = ApuBinaryReference(root / "apuYjb/param").execute(
        torch.from_numpy(ideal_input), capture=True
    )
    accumulator = captured["layer3.1.conv2.accumulator"].numpy()[0]
    threshold = (
        load_binary_words(root / "apuYjb/param/layer3.1.bn3_combined.txt")
        & 0xFFF
    ).reshape(-1, 1, 1)
    threshold_distance = np.abs(accumulator - threshold)

    for name in ("02_mmio_inference", "05_dma_inference"):
        actual = np.load(args.report_dir / (name + "_apu_output.npy"))
        mismatch = (actual != golden)[0]
        words = mismatch.transpose(1, 2, 0).reshape(-1, 64).sum(axis=1)
        channel_counts = mismatch.sum(axis=(1, 2))
        pixel_counts = mismatch.sum(axis=0)
        bad_words = np.flatnonzero(words)
        result = {
            "test": name,
            "mismatch_bits": int(mismatch.sum()),
            "bad_64bit_words": int(bad_words.size),
            "first_bad_word_indices": bad_words[:20].tolist(),
            "last_bad_word_indices": bad_words[-20:].tolist(),
            "last_word_mismatch_bits": int(words[-1]),
            "max_mismatch_bits_per_word": int(words.max()),
            "affected_channels": int(np.count_nonzero(channel_counts)),
            "max_mismatch_per_channel": int(channel_counts.max()),
            "mismatch_threshold_distance_histogram": {
                str(int(value)): int(count)
                for value, count in zip(
                    *np.unique(threshold_distance[mismatch], return_counts=True)
                )
            },
            "pixel_mismatch_counts": pixel_counts.tolist(),
        }
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
