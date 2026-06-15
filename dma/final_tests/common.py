#!/usr/bin/env python3
"""Shared runner for the six final MMIO/DMA report tests."""

import argparse
import importlib
import json
import os
import sys
import time

import numpy as np
import torch
import torchvision
import torchvision.transforms as transforms
from PIL import Image
from torch.utils.data import DataLoader, Subset


CLASSES = ("plane", "car", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck")


class FlatCIFAR10(torchvision.datasets.CIFAR10):
    base_folder = ""


def repo_paths():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", ".."))
    return root, os.path.join(root, "apuYjb"), os.path.join(root, "dma")


def load_cifar10(root, transform):
    root = os.path.abspath(root)
    standard = os.path.join(root, torchvision.datasets.CIFAR10.base_folder)
    if os.path.isfile(os.path.join(standard, "test_batch")):
        return torchvision.datasets.CIFAR10(root=root, train=False, download=False, transform=transform)
    if os.path.isfile(os.path.join(root, "test_batch")):
        return FlatCIFAR10(root=root, train=False, download=False, transform=transform)
    raise SystemExit("CIFAR-10 not found under %s (standard or flat layout)" % root)


def select_driver(transport, apu_dir, dma_dir):
    for name in ("resnet_binary_ps", "apu_driver"):
        sys.modules.pop(name, None)
    sys.path.insert(0, apu_dir)
    if transport == "dma":
        pynq_dir = os.path.join(dma_dir, "pynq")
        sys.path.insert(0, pynq_dir)
        sys.modules["apu_driver"] = importlib.import_module("apu_driver_dma")
    return importlib.import_module("resnet_binary_ps").resnet_binary_cifar10_hybrid


class LegacyTransferMonitor:
    def __init__(self, driver):
        self.driver = driver
        self.ps_to_pl_bytes = 0
        self.pl_to_ps_bytes = 0
        self.last_transfer_metrics = None
        self._wrap_io()
        self._wrap_execute()

    def _wrap_io(self):
        write_single = self.driver._ahb_write_single_reg_py
        write_burst = self.driver._ahb_write_burst_py
        read_single = self.driver._ahb_read_single_reg_py
        read_burst = self.driver._ahb_read_burst_py

        def counted_write_single(*args, **kwargs):
            self.ps_to_pl_bytes += 4
            return write_single(*args, **kwargs)

        def counted_write_burst(address, data, *args, **kwargs):
            self.ps_to_pl_bytes += 4 * len(data)
            return write_burst(address, data, *args, **kwargs)

        def counted_read_single(*args, **kwargs):
            self.pl_to_ps_bytes += 4
            return read_single(*args, **kwargs)

        def counted_read_burst(address, count, *args, **kwargs):
            self.pl_to_ps_bytes += 4 * int(count)
            return read_burst(address, count, *args, **kwargs)

        self.driver._ahb_write_single_reg_py = counted_write_single
        self.driver._ahb_write_burst_py = counted_write_burst
        self.driver._ahb_read_single_reg_py = counted_read_single
        self.driver._ahb_read_burst_py = counted_read_burst

    def _wrap_execute(self):
        execute = self.driver.execute_apu_network

        def measured(*args, **kwargs):
            self.ps_to_pl_bytes = 0
            self.pl_to_ps_bytes = 0
            wall_start = time.perf_counter()
            cpu_start = time.process_time()
            result = execute(*args, **kwargs)
            cpu_seconds = time.process_time() - cpu_start
            wall_seconds = time.perf_counter() - wall_start
            total = self.ps_to_pl_bytes + self.pl_to_ps_bytes
            self.last_transfer_metrics = {
                "transport": "legacy_mmio_ahb",
                "wait_mode": "polling",
                "ps_to_pl_bytes": self.ps_to_pl_bytes,
                "pl_to_ps_bytes": self.pl_to_ps_bytes,
                "total_bytes": total,
                "wall_seconds": wall_seconds,
                "cpu_seconds": cpu_seconds,
                "cpu_percent": 100.0 * cpu_seconds / wall_seconds if wall_seconds else 0.0,
                "wall_mbps": total / wall_seconds / 1e6 if wall_seconds else 0.0,
            }
            self.driver.last_transfer_metrics = self.last_transfer_metrics
            return result

        self.driver.execute_apu_network = measured


def build_model(transport):
    root, apu_dir, dma_dir = repo_paths()
    factory = select_driver(transport, apu_dir, dma_dir)
    bitstream = (
        os.path.join(apu_dir, "myDesign.bit")
        if transport == "mmio"
        else os.path.join(dma_dir, "overlay", "apu_dma.bit")
    )
    model = factory(
        num_classes=10,
        bitstream_file=bitstream,
        apu_ip_name="APU_0" if transport == "mmio" else "apu_dma_0",
        param_file_dir=os.path.join(apu_dir, "param"),
        model_weights_path=os.path.join(apu_dir, "model_best.pth.tar"),
        debug_dir_real=os.path.join(dma_dir, "reports", "raw", transport + "_debug"),
        use_mock_apu_flag=False,
    )
    if transport == "mmio":
        LegacyTransferMonitor(model.apu_driver)
    model.eval()
    return model, root, apu_dir, dma_dir


def metrics(driver):
    value = getattr(driver, "last_transfer_metrics", None)
    if not value:
        raise RuntimeError("Driver did not publish transfer metrics")
    return dict(value)


def print_transfer_result(value):
    print("\n--- 增量传输带宽测试结果 ---")
    print("传输方式: %s" % value["transport"])
    print("等待方式: %s" % value["wait_mode"])
    print("PS->PL 字节数: %d" % value["ps_to_pl_bytes"])
    print("PL->PS 字节数: %d" % value["pl_to_ps_bytes"])
    print("传输总字节数: %d" % value["total_bytes"])
    print("传输墙钟时间: %.6f s" % value["wall_seconds"])
    print("端到端传输带宽: %.3f MB/s" % value["wall_mbps"])
    if "hardware_mbps" in value:
        print("硬件计数器带宽: %.3f MB/s" % value["hardware_mbps"])
    print("CPU占用率: %.2f%%" % value["cpu_percent"])


def save_summary(dma_dir, name, payload):
    output_dir = os.path.join(dma_dir, "reports", "final")
    os.makedirs(output_dir, exist_ok=True)
    path = os.path.join(output_dir, name + ".json")
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print("汇报结果文件: %s" % path)


def single_image_main(transport):
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default=None)
    args = parser.parse_args()
    print("正在PYNQ上运行 (使用%s驱动)..." % ("旧MMIO" if transport == "mmio" else "APU DMA"))
    print("注意: 调试文件生成已禁用。")
    print("初始化混合ResNet模型...")
    model, _, apu_dir, dma_dir = build_model(transport)
    image_path = os.path.abspath(args.image or os.path.join(apu_dir, "image", "cifar10_test_image.jpg"))
    print("加载图像: %s" % image_path)
    preprocess = transforms.Compose([
        transforms.Resize(32),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
    ])
    input_batch = preprocess(Image.open(image_path).convert("RGB")).unsqueeze(0)
    print("预处理图像...")
    print("运行推理 (模式: 真实)...")
    try:
        with torch.no_grad():
            start = time.time()
            output = model(input_batch)
            elapsed_ms = (time.time() - start) * 1000.0
        print("推理时间: %.3f ms" % elapsed_ms)
        predicted = int(torch.argmax(output, 1).item())
        print("原始输出 (LogSoftmax): %s" % output)
        print("预测类别索引: %d (类别: %s)" % (predicted, CLASSES[predicted]))
        transfer = metrics(model.apu_driver)
        print_transfer_result(transfer)
        save_summary(dma_dir, "02_mmio_inference" if transport == "mmio" else "05_dma_inference", {
            "prediction": predicted,
            "class": CLASSES[predicted],
            "inference_ms": elapsed_ms,
            "transfer": transfer,
        })
    finally:
        model.apu_driver.cleanup()
        print("单张图片推理脚本执行完毕。")


def evaluate_main(transport):
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--dataset-root", default=None)
    parser.add_argument("--progress-every", type=int, default=10)
    args = parser.parse_args()
    if args.samples <= 0 or args.start_index < 0:
        raise SystemExit("--samples must be positive and --start-index non-negative")
    print("正在PYNQ上运行CIFAR-10评估 (使用%s驱动)..." % ("旧MMIO" if transport == "mmio" else "APU DMA"))
    print("初始化混合ResNet模型进行评估...")
    model, _, apu_dir, dma_dir = build_model(transport)
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
    ])
    dataset_root = os.path.abspath(args.dataset_root or os.path.join(apu_dir, "CIFAR10"))
    print("加载CIFAR-10验证集从 '%s'..." % dataset_root)
    full_dataset = load_cifar10(dataset_root, transform)
    stop = min(args.start_index + args.samples, len(full_dataset))
    if args.start_index >= stop:
        raise SystemExit("Requested sample range is outside CIFAR-10")
    dataset = Subset(full_dataset, range(args.start_index, stop))
    loader = DataLoader(dataset, batch_size=1, shuffle=False, num_workers=0)
    print("CIFAR-10验证集包含 %d 张图片。" % len(full_dataset))
    print("本次限制评估样本数: %d 张，范围 [%d, %d)。" % (len(dataset), args.start_index, stop))
    print("开始在CIFAR-10验证集上评估 (模式: 真实)...")
    top1_correct = 0
    top5_correct = 0
    inference_times = []
    transfer_rows = []
    try:
        with torch.no_grad():
            for offset, (images, labels) in enumerate(loader):
                start = time.time()
                outputs = model(images)
                inference_times.append(time.time() - start)
                predicted_top1 = outputs.data.argmax(1)
                top1_correct += int((predicted_top1 == labels).sum().item())
                predicted_top5 = outputs.topk(5, 1, True, True).indices.t()
                top5_correct += int(predicted_top5.eq(labels.view(1, -1).expand_as(predicted_top5)).reshape(-1).float().sum().item())
                transfer_rows.append(metrics(model.apu_driver))
                done = offset + 1
                if args.progress_every > 0 and (done % args.progress_every == 0 or done == len(dataset)):
                    recent = inference_times[-min(args.progress_every, len(inference_times)):]
                    print("已处理 [%d/%d] 张图片. 当前Top-1: %.2f%%, 当前Top-5: %.2f%%. 最近%d张平均耗时: %.2f ms/图片" % (
                        done, len(dataset), 100.0 * top1_correct / done, 100.0 * top5_correct / done,
                        len(recent), 1000.0 * sum(recent) / len(recent)))
        total = len(dataset)
        avg_ms = 1000.0 * sum(inference_times) / total
        print("\n--- CIFAR-10 验证集评估结果 ---")
        print("总样本数: %d" % total)
        print("Top-1 正确数: %d" % top1_correct)
        print("Top-5 正确数: %d" % top5_correct)
        print("Top-1 准确率: %.2f%%" % (100.0 * top1_correct / total))
        print("Top-5 准确率: %.2f%%" % (100.0 * top5_correct / total))
        print("平均单张图片推理时间: %.3f ms" % avg_ms)
        aggregate = {
            "transport": transfer_rows[0]["transport"],
            "wait_mode": transfer_rows[0]["wait_mode"],
            "ps_to_pl_bytes": sum(row["ps_to_pl_bytes"] for row in transfer_rows),
            "pl_to_ps_bytes": sum(row["pl_to_ps_bytes"] for row in transfer_rows),
            "total_bytes": sum(row["total_bytes"] for row in transfer_rows),
            "wall_seconds": sum(row["wall_seconds"] for row in transfer_rows),
            "cpu_seconds": sum(row["cpu_seconds"] for row in transfer_rows),
        }
        aggregate["wall_mbps"] = aggregate["total_bytes"] / aggregate["wall_seconds"] / 1e6
        aggregate["cpu_percent"] = 100.0 * aggregate["cpu_seconds"] / aggregate["wall_seconds"]
        if "hardware_mbps" in transfer_rows[0]:
            aggregate["hardware_mbps"] = float(np.mean([row["hardware_mbps"] for row in transfer_rows]))
        print_transfer_result(aggregate)
        name = "03_mmio_evaluate" if transport == "mmio" else "06_dma_evaluate"
        save_summary(dma_dir, name, {
            "start_index": args.start_index,
            "samples": total,
            "top1_correct": top1_correct,
            "top5_correct": top5_correct,
            "top1_percent": 100.0 * top1_correct / total,
            "top5_percent": 100.0 * top5_correct / total,
            "average_inference_ms": avg_ms,
            "transfer": aggregate,
        })
    finally:
        model.apu_driver.cleanup()
        print("CIFAR-10评估脚本执行完毕。")
