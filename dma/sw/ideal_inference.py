#!/usr/bin/env python3
"""Generate the software golden result for final tests 02 and 05."""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torchvision import transforms

from reference_model import (
    ApuBinaryReference,
    nchw_to_packed_lines,
    verify_exported_thresholds,
    verify_exported_weights,
)


CLASSES = ("plane", "car", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tensor_sha256(tensor):
    array = np.ascontiguousarray(tensor.detach().cpu().numpy())
    return hashlib.sha256(array.tobytes()).hexdigest()


def load_checkpoint(path):
    payload = torch.load(path, map_location="cpu")
    return payload["state_dict"]


def frontend(image_path, state_dict):
    preprocess = transforms.Compose([
        transforms.Resize(32),
        transforms.ToTensor(),
        transforms.Normalize(
            mean=[0.485, 0.456, 0.406],
            std=[0.229, 0.224, 0.225],
        ),
    ])
    image = preprocess(Image.open(image_path).convert("RGB")).unsqueeze(0)
    value = torch.nn.functional.conv2d(image, state_dict["conv1.weight"], padding=1)
    value = torch.nn.functional.batch_norm(
        value,
        state_dict["bn1.running_mean"],
        state_dict["bn1.running_var"],
        state_dict["bn1.weight"],
        state_dict["bn1.bias"],
        training=False,
    )
    value = torch.nn.functional.hardtanh(value, inplace=False)
    return value.sign().add(-1).div(-2).to(torch.uint8)


def backend(apu_bits, state_dict):
    value = apu_bits.to(torch.float32).mul(-2.0).add(1.0)
    value = torch.nn.functional.avg_pool2d(value, 8).flatten(1)
    value = torch.nn.functional.linear(value, state_dict["fc.weight"], state_dict["fc.bias"])
    value = torch.nn.functional.batch_norm(
        value,
        state_dict["bn3.running_mean"],
        state_dict["bn3.running_var"],
        state_dict["bn3.weight"],
        state_dict["bn3.bias"],
        training=False,
    )
    return torch.nn.functional.log_softmax(value, dim=1)


def write_packed(path, tensor):
    path.write_text("\n".join(nchw_to_packed_lines(tensor, reverse_bits=True)) + "\n", encoding="ascii")


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, default=root / "apuYjb/image/cifar10_test_image.jpg")
    parser.add_argument("--checkpoint", type=Path, default=root / "apuYjb/model_best.pth.tar")
    parser.add_argument("--param-dir", type=Path, default=root / "apuYjb/param")
    parser.add_argument("--output-dir", type=Path, default=root / "dma/sw/output")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    state_dict = load_checkpoint(args.checkpoint)
    weight_checks = verify_exported_weights(args.param_dir, state_dict)
    threshold_checks = verify_exported_thresholds(args.param_dir, state_dict)

    with torch.no_grad():
        apu_input = frontend(args.image, state_dict)
        apu_output = ApuBinaryReference(args.param_dir).execute(apu_input)
        logits = backend(apu_output, state_dict)

    np.save(args.output_dir / "ideal_apu_input.npy", apu_input.numpy())
    np.save(args.output_dir / "ideal_apu_output.npy", apu_output.numpy())
    write_packed(args.output_dir / "ideal_apu_input_packed.txt", apu_input)
    write_packed(args.output_dir / "ideal_apu_output_packed.txt", apu_output)

    predicted = int(torch.argmax(logits, dim=1).item())

    def display_path(path):
        resolved = path.resolve()
        try:
            return resolved.relative_to(root).as_posix()
        except ValueError:
            return str(resolved)

    result = {
        "alignment": "dma/final_tests/02_mydesign_inference.py and 05_apu_dma_inference.py",
        "image": display_path(args.image),
        "image_sha256": sha256_file(args.image),
        "checkpoint": display_path(args.checkpoint),
        "checkpoint_sha256": sha256_file(args.checkpoint),
        "param_dir": display_path(args.param_dir),
        "exported_weight_mismatch_bits": weight_checks,
        "exported_threshold_checks": threshold_checks,
        "apu_input_shape": list(apu_input.shape),
        "apu_input_sha256": tensor_sha256(apu_input),
        "apu_output_shape": list(apu_output.shape),
        "apu_output_sha256": tensor_sha256(apu_output),
        "logsoftmax": [float(value) for value in logits[0]],
        "prediction": predicted,
        "class": CLASSES[predicted],
    }
    result_path = args.output_dir / "ideal_inference.json"
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print("Ideal LogSoftmax: %s" % logits)
    print("Ideal prediction: %d (%s)" % (predicted, CLASSES[predicted]))
    print("Ideal APU output SHA256: %s" % result["apu_output_sha256"])
    print("Result: %s" % result_path)


if __name__ == "__main__":
    main()
