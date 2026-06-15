#!/usr/bin/env python3
"""Software model of the binary APU boundary used by final tests 02 and 05."""

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F


@dataclass(frozen=True)
class Layer:
    name: str
    weight_file: str
    bn_file: str
    in_channels: int
    out_channels: int
    stride: int = 1
    residual: bool = False


LAYERS = (
    Layer("layer1.0.conv1", "layer1.0.conv1.txt", "layer1.0.bn1_combined.txt", 64, 64),
    Layer("layer1.0.conv2", "layer1.0.conv2.txt", "layer1.0.bn3_combined.txt", 64, 64),
    Layer("layer1.1.conv1", "layer1.1.conv1.txt", "layer1.1.bn1_combined.txt", 64, 64),
    Layer("layer1.1.conv2", "layer1.1.conv2.txt", "layer1.1.bn3_combined.txt", 64, 64),
    Layer("layer2.0.conv1", "layer2.0.conv1.txt", "layer2.0.bn1_combined.txt", 64, 128, 2),
    Layer("layer2.0.conv2", "layer2.0.conv2_combined.txt", "layer2.0.bn3_combined.txt", 128, 128, 1, True),
    Layer("layer2.1.conv1", "layer2.1.conv1.txt", "layer2.1.bn1_combined.txt", 128, 128),
    Layer("layer2.1.conv2", "layer2.1.conv2.txt", "layer2.1.bn3_combined.txt", 128, 128),
    Layer("layer3.0.conv1", "layer3.0.conv1.txt", "layer3.0.bn1_combined.txt", 128, 256, 2),
    Layer("layer3.0.conv2", "layer3.0.conv2_combined.txt", "layer3.0.bn3_combined.txt", 256, 256, 1, True),
    Layer("layer3.1.conv1", "layer3.1.conv1.txt", "layer3.1.bn1_combined.txt", 256, 256),
    Layer("layer3.1.conv2", "layer3.1.conv2.txt", "layer3.1.bn3_combined.txt", 256, 256),
)


def _tokens(path):
    values = []
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            values.extend(line.split())
    return values


def load_binary_words(path):
    return np.asarray([int(token, 2) for token in _tokens(path)], dtype=np.uint32)


def packed_text_to_nchw(path, channels, height, width, reverse_bits=False):
    bits = []
    with open(path, "r", encoding="utf-8") as stream:
        for line_number, raw_line in enumerate(stream, 1):
            line = "".join(raw_line.split())
            if not line:
                continue
            if len(line) != 32 or set(line) - {"0", "1"}:
                raise ValueError(
                    "Expected one normalized 32-bit line in %s:%d" % (path, line_number)
                )
            line = line[::-1] if reverse_bits else line
            bits.extend(int(value) for value in line)
    expected = channels * height * width
    if len(bits) != expected:
        raise ValueError("%s has %d bits, expected %d" % (path, len(bits), expected))
    nhwc = np.asarray(bits, dtype=np.uint8).reshape(height, width, channels)
    return torch.from_numpy(nhwc.transpose(2, 0, 1).copy()).unsqueeze(0)


def nchw_to_packed_lines(tensor, reverse_bits=False):
    array = np.asarray(tensor.detach().cpu(), dtype=np.uint8)
    bits = array.transpose(0, 2, 3, 1).reshape(-1)
    lines = []
    for offset in range(0, bits.size, 32):
        block = bits[offset : offset + 32]
        if reverse_bits:
            block = block[::-1]
        lines.append("".join(str(int(value)) for value in block))
    return lines


def _decode_normal_weights(path, in_channels, out_channels):
    words32 = load_binary_words(path)
    in_groups = in_channels // 64
    out_groups = out_channels // 64
    lines_per_bank_group = 2 * 9 * in_groups
    expected = out_groups * 64 * lines_per_bank_group
    if words32.size != expected:
        raise ValueError("%s has %d words, expected %d" % (path, words32.size, expected))
    result = np.zeros((out_channels, in_channels, 3, 3), dtype=np.float32)
    for output_group in range(out_groups):
        for lane in range(64):
            output_channel = output_group * 64 + lane
            start = (output_group * 64 + lane) * lines_per_bank_group
            words64 = np.ascontiguousarray(
                words32[start : start + lines_per_bank_group]
            ).view(np.uint64)
            for kernel_index in range(9):
                for input_group in range(in_groups):
                    word = int(words64[kernel_index * in_groups + input_group])
                    for bit in range(64):
                        input_channel = input_group * 64 + bit
                        result[output_channel, input_channel, kernel_index // 3, kernel_index % 3] = (word >> bit) & 1
    return torch.from_numpy(result)


def _decode_residual_weights(path, in_channels, out_channels):
    words32 = load_binary_words(path)
    in_groups = in_channels // 64
    shortcut_groups = in_groups // 2
    out_groups = out_channels // 64
    lines_per_bank_group = (2 * 9 + 1) * in_groups
    expected = out_groups * 64 * lines_per_bank_group
    if words32.size != expected:
        raise ValueError("%s has %d words, expected %d" % (path, words32.size, expected))
    main = np.zeros((out_channels, in_channels, 3, 3), dtype=np.float32)
    shortcut = np.zeros((out_channels, in_channels // 2, 1, 1), dtype=np.float32)
    for output_group in range(out_groups):
        for lane in range(64):
            output_channel = output_group * 64 + lane
            start = (output_group * 64 + lane) * lines_per_bank_group
            words64 = np.ascontiguousarray(
                words32[start : start + lines_per_bank_group]
            ).view(np.uint64)
            for kernel_index in range(9):
                for input_group in range(in_groups):
                    word = int(words64[kernel_index * in_groups + input_group])
                    for bit in range(64):
                        main[output_channel, input_group * 64 + bit, kernel_index // 3, kernel_index % 3] = (word >> bit) & 1
            base = 9 * in_groups
            for input_group in range(shortcut_groups):
                word = int(words64[base + input_group])
                for bit in range(64):
                    shortcut[output_channel, input_group * 64 + bit, 0, 0] = (word >> bit) & 1
    return torch.from_numpy(main), torch.from_numpy(shortcut)


def _xor_popcount(input_bits, weight_bits, stride, padding):
    input_float = input_bits.float()
    weight_float = weight_bits.float()
    input_sum = F.conv2d(
        input_float,
        torch.ones_like(weight_float),
        stride=stride,
        padding=padding,
    )
    weight_sum = weight_float.sum(dim=(1, 2, 3)).view(1, -1, 1, 1)
    both_one = F.conv2d(input_float, weight_float, stride=stride, padding=padding)
    return input_sum + weight_sum - 2.0 * both_one


def _threshold(accumulator, path):
    values = load_binary_words(path)
    channels = accumulator.shape[1]
    if values.size != channels:
        raise ValueError("%s has %d values, expected %d" % (path, values.size, channels))
    direction = torch.from_numpy(((values >> 12) & 1).astype(np.bool_)).view(1, -1, 1, 1)
    threshold = torch.from_numpy((values & 0xFFF).astype(np.float32)).view(1, -1, 1, 1)
    return torch.where(direction, accumulator > threshold, accumulator < threshold).to(torch.uint8)


class ApuBinaryReference:
    def __init__(self, param_dir):
        self.param_dir = Path(param_dir)
        self.decoded = {}
        for layer in LAYERS:
            weight_path = self.param_dir / layer.weight_file
            if layer.residual:
                weights = _decode_residual_weights(weight_path, layer.in_channels, layer.out_channels)
            else:
                weights = _decode_normal_weights(weight_path, layer.in_channels, layer.out_channels)
            self.decoded[layer.name] = weights

    def execute(self, input_bits, capture=False):
        if tuple(input_bits.shape) != (1, 64, 32, 32):
            raise ValueError("Expected input shape (1,64,32,32)")
        current = input_bits.to(torch.uint8)
        block_input = current
        captured = {}
        for layer in LAYERS:
            if layer.name in ("layer2.0.conv1", "layer3.0.conv1"):
                block_input = current
            if layer.residual:
                main_weight, shortcut_weight = self.decoded[layer.name]
                main = _xor_popcount(current, main_weight, 1, 1)
                shortcut = _xor_popcount(block_input, shortcut_weight, 2, 0)
                accumulator = main + shortcut
            else:
                accumulator = _xor_popcount(current, self.decoded[layer.name], layer.stride, 1)
            current = _threshold(accumulator, self.param_dir / layer.bn_file)
            if capture:
                captured[layer.name + ".accumulator"] = accumulator.clone()
                captured[layer.name] = current.clone()
        return (current, captured) if capture else current


def verify_exported_weights(param_dir, state_dict):
    """Verify that exported APU bits equal ``checkpoint_weight < 0``."""
    model = ApuBinaryReference(param_dir)
    results = {}
    for layer in LAYERS:
        decoded = model.decoded[layer.name]
        main = decoded[0] if isinstance(decoded, tuple) else decoded
        expected = (state_dict[layer.name + ".weight"] < 0).to(torch.float32)
        mismatch = int(torch.count_nonzero(main != expected).item())
        results[layer.name] = mismatch
        if mismatch:
            raise ValueError(
                "%s exported weight mismatch: %d bits" % (layer.name, mismatch)
            )
        if layer.residual:
            shortcut = decoded[1]
            block_name = layer.name.rsplit(".", 1)[0]
            expected_shortcut = (
                state_dict[block_name + ".downsample.0.weight"] < 0
            ).to(torch.float32)
            mismatch = int(torch.count_nonzero(shortcut != expected_shortcut).item())
            results[block_name + ".downsample.0"] = mismatch
            if mismatch:
                raise ValueError(
                    "%s exported shortcut mismatch: %d bits"
                    % (block_name, mismatch)
                )
    return results


def verify_exported_thresholds(param_dir, state_dict):
    """Check exported BN direction/threshold values against the checkpoint."""
    results = {}
    for layer in LAYERS:
        raw = load_binary_words(Path(param_dir) / layer.bn_file)
        direction = (raw >> 12) & 1
        threshold = raw & 0xFFF
        block = layer.name.rsplit(".", 1)[0]
        bn_name = block + (".bn1" if layer.name.endswith("conv1") else ".bn3")
        gamma = state_dict[bn_name + ".weight"].numpy()
        beta = state_dict[bn_name + ".bias"].numpy()
        mean = state_dict[bn_name + ".running_mean"].numpy()
        variance = state_dict[bn_name + ".running_var"].numpy()
        terms = layer.in_channels * 9
        if layer.residual:
            terms += layer.in_channels // 2
        derived = (
            terms - (mean - beta * np.sqrt(variance + 1e-5) / gamma)
        ) / 2.0
        direction_mismatch = int(np.count_nonzero(direction != (gamma > 0)))
        max_threshold_error = float(
            np.max(np.abs(threshold - np.clip(derived, 0, 0xFFF)))
        )
        if direction_mismatch or max_threshold_error >= 1.0:
            raise ValueError(
                "%s threshold export mismatch: direction=%d max_error=%f"
                % (layer.name, direction_mismatch, max_threshold_error)
            )
        results[layer.name] = {
            "direction_mismatch": direction_mismatch,
            "max_threshold_error": max_threshold_error,
        }
    return results
