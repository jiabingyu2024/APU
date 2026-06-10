#!/usr/bin/env python3
from pathlib import Path


CASES = (
    ("layer1.1_tanh3", "build/sim/layer1.1_tanh3_hw.txt",
     "data/data_flow/layer1.1_tanh3_output.txt"),
    ("layer2.1_tanh3", "build/sim/layer2.1_tanh3_hw.txt",
     "data/data_flow/layer2.1_tanh3_output.txt"),
    ("layer3.0_tanh1", "build/sim/layer3.0_tanh1_hw.txt",
     "data/data_flow/layer3.0_tanh1_output.txt"),
    ("layer3.0_tanh3", "build/sim/layer3.0_tanh3_hw.txt",
     "data/data_flow/layer3.0_tanh3_output.txt"),
    ("layer3.1_tanh1", "build/sim/layer3.1_tanh1_hw.txt",
     "data/data_flow/layer3.1_tanh1_output.txt"),
    ("layer3.1_bn3", "build/sim/data_out.txt",
     "data/data_flow/layer3.1_bn3_output.txt"),
)


def read_bits(path: str) -> list[str]:
    lines = ["".join(line.split()) for line in Path(path).read_text().splitlines()
             if line.strip()]
    if any(len(line) != 32 or set(line) - {"0", "1"} for line in lines):
        raise ValueError(f"{path}: expected one 32-bit binary word per line")
    return lines


def main() -> int:
    failed = False
    for name, actual_path, golden_path in CASES:
        actual = read_bits(actual_path)
        golden = read_bits(golden_path)
        common = min(len(actual), len(golden))
        bit_mismatches = sum(
            left != right
            for actual_word, golden_word in zip(actual[:common], golden[:common])
            for left, right in zip(actual_word, golden_word)
        )
        bit_mismatches += 32 * abs(len(actual) - len(golden))
        line_mismatches = sum(
            actual_word != golden_word
            for actual_word, golden_word in zip(actual[:common], golden[:common])
        ) + abs(len(actual) - len(golden))
        status = "PASS" if bit_mismatches == 0 else "FAIL"
        print(f"{status:4} {name:18} bits={bit_mismatches:5} "
              f"lines={line_mismatches:4}/{max(len(actual), len(golden))}")
        failed |= bit_mismatches != 0
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
