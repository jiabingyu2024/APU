#!/usr/bin/env python3
"""Record checksums and versions for the legacy MMIO/APU baseline."""

import argparse
import datetime
import hashlib
import json
import os
import platform
import subprocess


DEFAULT_ASSETS = (
    "apuYjb/myDesign.bit",
    "apuYjb/myDesign.hwh",
    "apuYjb/myDesign.tcl",
    "apuYjb/apu_driver.py",
    "apuYjb/resnet_binary_ps.py",
    "apuYjb/model_best.pth.tar",
)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_output(repo_root, *args):
    try:
        return subprocess.check_output(
            ("git",) + args,
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def collect_files(repo_root, relative_paths):
    records = []
    for relative_path in relative_paths:
        absolute_path = os.path.join(repo_root, relative_path)
        if not os.path.isfile(absolute_path):
            raise FileNotFoundError("Required baseline asset missing: " + relative_path)
        records.append(
            {
                "path": relative_path,
                "bytes": os.path.getsize(absolute_path),
                "sha256": sha256_file(absolute_path),
            }
        )
    return records


def collect_parameter_bundle(repo_root):
    parameter_root = os.path.join(repo_root, "apuYjb", "param")
    records = []
    for filename in sorted(os.listdir(parameter_root)):
        absolute_path = os.path.join(parameter_root, filename)
        if os.path.isfile(absolute_path):
            relative_path = os.path.relpath(absolute_path, repo_root)
            records.append(
                {
                    "path": relative_path,
                    "bytes": os.path.getsize(absolute_path),
                    "sha256": sha256_file(absolute_path),
                }
            )
    return records


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    default_output = os.path.join(
        default_root, "dma", "reports", "raw", "baseline_asset_manifest.json"
    )

    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=default_root)
    parser.add_argument("--output", default=default_output)
    args = parser.parse_args()

    repo_root = os.path.abspath(args.repo_root)
    output_path = os.path.abspath(args.output)
    manifest = {
        "schema_version": 1,
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "repo_root_basename": os.path.basename(repo_root),
        "git_commit": git_output(repo_root, "rev-parse", "HEAD"),
        "git_status_porcelain": git_output(repo_root, "status", "--porcelain"),
        "host": {
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "assets": collect_files(repo_root, DEFAULT_ASSETS),
        "parameter_bundle": collect_parameter_bundle(repo_root),
    }

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print(output_path)


if __name__ == "__main__":
    main()

