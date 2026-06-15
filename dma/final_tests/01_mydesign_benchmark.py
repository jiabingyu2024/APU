#!/usr/bin/env python3
import os
import runpy
import shutil
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
runpy.run_path(os.path.join(ROOT, "dma", "benchmark", "benchmark_mmio.py"), run_name="__main__")

source = os.path.join(ROOT, "dma", "reports", "raw", "mmio_transfer_summary.json")
target_dir = os.path.join(ROOT, "dma", "reports", "final")
os.makedirs(target_dir, exist_ok=True)
target = os.path.join(target_dir, "01_mydesign_benchmark.json")
shutil.copyfile(source, target)
print("汇报结果文件: %s" % target)
