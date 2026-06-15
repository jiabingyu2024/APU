#!/usr/bin/env python3
"""Measure legacy Overlay end-to-end inference on selected CIFAR-10 samples."""

import argparse
import csv
import hashlib
import json
import os
import sys
import time

import numpy as np
import torch
import torchvision
import torchvision.transforms as transforms


class FlatCIFAR10(torchvision.datasets.CIFAR10):
    """CIFAR-10 extracted with batch files directly under the given root."""

    base_folder = ""


def load_cifar10(root, transform):
    root = os.path.abspath(root)
    standard_dir = os.path.join(root, torchvision.datasets.CIFAR10.base_folder)
    if os.path.isfile(os.path.join(standard_dir, "test_batch")):
        return torchvision.datasets.CIFAR10(
            root=root, train=False, download=False, transform=transform
        )
    if os.path.isfile(os.path.join(root, "test_batch")):
        return FlatCIFAR10(
            root=root, train=False, download=False, transform=transform
        )
    raise SystemExit(
        "CIFAR-10 test set not found. Expected either %s or %s. "
        "Pass --dataset-root if the dataset is stored elsewhere."
        % (os.path.join(standard_dir, "test_batch"), os.path.join(root, "test_batch"))
    )


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    default_apu_dir = os.path.join(repo_root, "apuYjb")
    default_output_dir = os.path.join(repo_root, "dma", "reports", "raw")

    parser = argparse.ArgumentParser()
    parser.add_argument("--apu-dir", default=default_apu_dir)
    parser.add_argument(
        "--dataset-root",
        default=None,
        help="CIFAR-10 root; supports standard cifar-10-batches-py or flat layout",
    )
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--warmup", type=int, default=1)
    parser.add_argument("--output-dir", default=default_output_dir)
    args = parser.parse_args()

    apu_dir = os.path.abspath(args.apu_dir)
    output_dir = os.path.abspath(args.output_dir)
    debug_dir = os.path.join(output_dir, "mmio_debug")
    os.makedirs(debug_dir, exist_ok=True)
    sys.path.insert(0, apu_dir)

    try:
        from resnet_binary_ps import resnet_binary_cifar10_hybrid
    except ImportError as error:
        raise SystemExit("Unable to import the legacy inference stack: %s" % error)

    transform = transforms.Compose(
        [
            transforms.ToTensor(),
            transforms.Normalize(
                mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]
            ),
        ]
    )
    dataset_root = args.dataset_root or os.path.join(apu_dir, "CIFAR10")
    dataset = load_cifar10(dataset_root, transform)
    if args.start_index < 0 or args.start_index + args.samples > len(dataset):
        raise SystemExit("Requested sample range is outside the CIFAR-10 test set")

    model = resnet_binary_cifar10_hybrid(
        num_classes=10,
        bitstream_file=os.path.join(apu_dir, "myDesign.bit"),
        apu_ip_name="APU_0",
        param_file_dir=os.path.join(apu_dir, "param"),
        model_weights_path=os.path.join(apu_dir, "model_best.pth.tar"),
        debug_dir_real=debug_dir,
        use_mock_apu_flag=False,
    )
    model.eval()

    with torch.no_grad():
        warmup_image, _ = dataset[args.start_index]
        for _ in range(args.warmup):
            model(warmup_image.unsqueeze(0))

        rows = []
        top1_correct = 0
        top5_correct = 0
        for offset in range(args.samples):
            sample_index = args.start_index + offset
            image, label = dataset[sample_index]
            save_debug = offset == 0
            raw_filename = "sample_%05d_apu_raw.txt" % sample_index

            wall_start = time.perf_counter()
            cpu_start = time.process_time()
            output = model(
                image.unsqueeze(0),
                save_input_debug_file=save_debug,
                input_debug_filename="sample_%05d_input.txt" % sample_index,
                save_output_debug_files_for_real=save_debug,
                output_raw_filename_for_real=raw_filename,
                output_unpacked_filename_for_real=(
                    "sample_%05d_apu_unpacked.txt" % sample_index
                ),
            )
            cpu_seconds = time.process_time() - cpu_start
            wall_seconds = time.perf_counter() - wall_start

            top1 = int(torch.argmax(output, dim=1).item())
            top5 = [int(value) for value in torch.topk(output, 5, dim=1).indices[0]]
            top1_correct += int(top1 == label)
            top5_correct += int(label in top5)
            row = {
                "sample_index": sample_index,
                "label": int(label),
                "top1": top1,
                "top5": " ".join(str(value) for value in top5),
                "top1_correct": int(top1 == label),
                "top5_correct": int(label in top5),
                "wall_seconds": wall_seconds,
                "cpu_seconds": cpu_seconds,
                "cpu_percent": 100.0 * cpu_seconds / wall_seconds,
            }
            if save_debug:
                raw_path = os.path.join(debug_dir, raw_filename)
                row["apu_raw_sha256"] = sha256_file(raw_path)
            else:
                row["apu_raw_sha256"] = ""
            rows.append(row)

    if hasattr(model, "apu_driver") and hasattr(model.apu_driver, "cleanup"):
        model.apu_driver.cleanup()

    csv_path = os.path.join(output_dir, "mmio_e2e_samples.csv")
    json_path = os.path.join(output_dir, "mmio_e2e_summary.json")
    with open(csv_path, "w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    wall = np.asarray([row["wall_seconds"] for row in rows])
    cpu = np.asarray([row["cpu_percent"] for row in rows])
    summary = {
        "schema_version": 1,
        "transport": "legacy_mmio_ahb",
        "start_index": args.start_index,
        "samples": args.samples,
        "warmup": args.warmup,
        "top1_percent": 100.0 * top1_correct / args.samples,
        "top5_percent": 100.0 * top5_correct / args.samples,
        "latency_ms_mean": float(np.mean(wall) * 1000.0),
        "latency_ms_p50": float(np.percentile(wall, 50) * 1000.0),
        "latency_ms_p95": float(np.percentile(wall, 95) * 1000.0),
        "cpu_percent_mean": float(np.mean(cpu)),
        "first_apu_raw_sha256": rows[0]["apu_raw_sha256"],
    }
    with open(json_path, "w", encoding="utf-8") as stream:
        json.dump(summary, stream, indent=2, sort_keys=True)
        stream.write("\n")

    print(json.dumps(summary, indent=2, sort_keys=True))
    print(csv_path)
    print(json_path)


if __name__ == "__main__":
    main()

