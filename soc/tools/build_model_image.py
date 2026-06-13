#!/usr/bin/env python3
"""Pack the verified APU text parameters into a 32-bit model ROM image."""

from argparse import ArgumentParser
from pathlib import Path


FILES = (
    ("INPUT", "data/param_files/input_binary.txt"),
    ("L10_CONV1", "data/param_files/layer1.0.conv1.txt"),
    ("L10_BN1", "data/param_files/layer1.0.bn1_combined.txt"),
    ("L10_CONV2", "data/param_files/layer1.0.conv2.txt"),
    ("L10_BN3", "data/param_files/layer1.0.bn3_combined.txt"),
    ("L11_CONV1", "data/param_files/layer1.1.conv1.txt"),
    ("L11_BN1", "data/param_files/layer1.1.bn1_combined.txt"),
    ("L11_CONV2", "data/param_files/layer1.1.conv2.txt"),
    ("L11_BN3", "data/param_files/layer1.1.bn3_combined.txt"),
    ("L20_CONV1", "data/param_files/layer2.0.conv1.txt"),
    ("L20_BN1", "data/param_files/layer2.0.bn1_combined.txt"),
    ("L20_RESIDUAL", "data/param_files/layer2.0.conv2_combined.txt"),
    ("L20_BN3", "data/param_files/layer2.0.bn3_combined.txt"),
    ("L21_CONV1", "data/param_files/layer2.1.conv1.txt"),
    ("L21_BN1", "data/param_files/layer2.1.bn1_combined.txt"),
    ("L21_CONV2", "data/param_files/layer2.1.conv2.txt"),
    ("L21_BN3", "data/param_files/layer2.1.bn3_combined.txt"),
    ("L30_CONV1", "data/param_files/layer3.0.conv1.txt"),
    ("L30_BN1", "data/param_files/layer3.0.bn1_combined.txt"),
    ("L30_RESIDUAL", "data/param_files/layer3.0.conv2_combined.txt"),
    ("L30_BN3", "data/param_files/layer3.0.bn3_combined.txt"),
    ("L31_CONV1", "data/param_files/layer3.1.conv1.txt"),
    ("L31_BN1", "data/param_files/layer3.1.bn1_combined.txt"),
    ("L31_CONV2", "data/param_files/layer3.1.conv2.txt"),
    ("L31_BN3", "data/param_files/layer3.1.bn3_combined.txt"),
    ("FINAL_GOLDEN", "data/data_flow/layer3.1_bn3_output.txt"),
)


def read_words(path: Path) -> list[int]:
    words = []
    for line_number, raw_line in enumerate(path.read_text().splitlines(), 1):
        bits = "".join(raw_line.split())
        if not bits:
            continue
        if len(bits) != 32 or set(bits) - {"0", "1"}:
            raise ValueError(f"{path}:{line_number}: expected one 32-bit binary word")
        words.append(int(bits, 2))
    return words


def main() -> None:
    parser = ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--hex", type=Path, required=True)
    parser.add_argument("--header", type=Path, required=True)
    args = parser.parse_args()

    image: list[int] = []
    layout: list[tuple[str, int, int]] = []
    for name, relative_path in FILES:
        words = read_words(args.root / relative_path)
        layout.append((name, len(image), len(words)))
        image.extend(words)

    if len(image) > 128 * 1024:
        raise ValueError(f"model image has {len(image)} words; 512 KiB window overflow")

    args.hex.parent.mkdir(parents=True, exist_ok=True)
    args.header.parent.mkdir(parents=True, exist_ok=True)
    args.hex.write_text("".join(f"{word:08x}\n" for word in image))

    header = [
        "#ifndef MODEL_LAYOUT_H",
        "#define MODEL_LAYOUT_H",
        "",
    ]
    for name, offset, count in layout:
        header.append(f"#define MODEL_{name}_OFFSET {offset}u")
        header.append(f"#define MODEL_{name}_WORDS {count}u")
    header.extend(("", f"#define MODEL_TOTAL_WORDS {len(image)}u", "", "#endif", ""))
    args.header.write_text("\n".join(header))

    print(f"MODEL IMAGE PASS words={len(image)} bytes={len(image) * 4}")


if __name__ == "__main__":
    main()
