#!/usr/bin/env python3
"""Build the legacy 12-layer APU network as one aggregate DMA job."""

from dataclasses import dataclass
import os

import numpy as np

try:
    from .dma_job import JobBuilder, Target
except ImportError:
    from dma_job import JobBuilder, Target


@dataclass(frozen=True)
class LayerSpec:
    weight_file: str
    bn_file: str
    opcode: int
    kernel_size: int
    log_in_hw: int
    log_in_c: int
    log_out_c: int
    stride1: int
    stride2: int
    weight_address: int
    bn_address: int
    resident: bool = False


STAGES = (
    (
        LayerSpec("layer1.0.conv1.txt", "layer1.0.bn1_combined.txt", 0, 3, 5, 6, 6, 1, 0, 0, 0),
        LayerSpec("layer1.0.conv2.txt", "layer1.0.bn3_combined.txt", 0, 3, 5, 6, 6, 1, 0, 9, 1),
        LayerSpec("layer1.1.conv1.txt", "layer1.1.bn1_combined.txt", 0, 3, 5, 6, 6, 1, 0, 18, 2),
        LayerSpec("layer1.1.conv2.txt", "layer1.1.bn3_combined.txt", 0, 3, 5, 6, 6, 1, 0, 27, 3),
        LayerSpec("layer2.0.conv1.txt", "layer2.0.bn1_combined.txt", 0, 3, 5, 6, 7, 2, 0, 36, 4),
        LayerSpec("layer2.0.conv2_combined.txt", "layer2.0.bn3_combined.txt", 1, 3, 4, 7, 7, 1, 2, 54, 6, True),
        LayerSpec("layer2.1.conv1.txt", "layer2.1.bn1_combined.txt", 0, 3, 4, 7, 7, 1, 0, 92, 10),
        LayerSpec("layer2.1.conv2.txt", "layer2.1.bn3_combined.txt", 0, 3, 4, 7, 7, 1, 0, 128, 14),
    ),
    (LayerSpec("layer3.0.conv1.txt", "layer3.0.bn1_combined.txt", 0, 3, 4, 7, 8, 2, 0, 0, 0),),
    (LayerSpec("layer3.0.conv2_combined.txt", "layer3.0.bn3_combined.txt", 1, 3, 3, 8, 8, 1, 2, 0, 0, True),),
    (LayerSpec("layer3.1.conv1.txt", "layer3.1.bn1_combined.txt", 0, 3, 3, 8, 8, 1, 0, 0, 0),),
    (LayerSpec("layer3.1.conv2.txt", "layer3.1.bn3_combined.txt", 0, 3, 3, 8, 8, 1, 0, 0, 0),),
)


def load_binary_words(param_dir, filename):
    values = []
    path = os.path.join(param_dir, filename)
    with open(path, "r", encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            for token in line.split():
                try:
                    values.append(int(token, 2))
                except ValueError as error:
                    raise ValueError("Bad binary token in %s:%d" % (path, line_number)) from error
    if not values:
        raise ValueError("Parameter file is empty: " + path)
    return np.asarray(values, dtype=np.uint32)


def pack_instruction(spec):
    return np.uint32(
        ((spec.opcode & 3) << 30)
        | ((spec.kernel_size & 3) << 28)
        | ((spec.log_in_hw & 7) << 25)
        | ((spec.log_in_c & 15) << 21)
        | ((spec.log_out_c & 15) << 17)
        | ((spec.stride1 & 3) << 15)
        | ((spec.stride2 & 3) << 13)
        | ((spec.weight_address & 255) << 5)
        | (spec.bn_address & 31)
    )


def _layer_bank_payloads(param_dir, spec):
    weights = load_binary_words(param_dir, spec.weight_file)
    bn = load_binary_words(param_dir, spec.bn_file)
    input_groups = max(1, (1 << spec.log_in_c) // 64)
    output_groups = (1 << spec.log_out_c) // 64
    words32_per_group = (
        (2 * spec.kernel_size * spec.kernel_size + 1) * input_groups
        if spec.resident
        else 2 * spec.kernel_size * spec.kernel_size * input_groups
    )
    if words32_per_group % 2:
        raise ValueError("Weight group is not 64-bit aligned: " + spec.weight_file)
    expected_weight_words = words32_per_group * output_groups * 64
    if weights.size < expected_weight_words:
        raise ValueError(
            "%s has %d words, expected at least %d"
            % (spec.weight_file, weights.size, expected_weight_words)
        )
    if bn.size < output_groups * 64:
        raise ValueError("BN file is shorter than the output channel count: " + spec.bn_file)

    weight_payloads = []
    bn_payloads = []
    for bank in range(64):
        chunks = []
        for group in range(output_groups):
            start = words32_per_group * bank + group * words32_per_group * 64
            chunks.append(weights[start : start + words32_per_group])
        words32 = np.ascontiguousarray(np.concatenate(chunks), dtype=np.uint32)
        weight_payloads.append(words32.view(np.uint64))
        bn_payloads.append(
            np.ascontiguousarray(
                [bn[bank + group * 64] for group in range(output_groups)],
                dtype=np.uint32,
            )
        )
    return weight_payloads, bn_payloads


def _append_stage(builder, param_dir, stage, timeout_cycles):
    weight_regions = [[] for _ in range(64)]
    bn_regions = [[] for _ in range(64)]
    for spec in stage:
        weight_payloads, bn_payloads = _layer_bank_payloads(param_dir, spec)
        for bank in range(64):
            weight_regions[bank].append((spec.weight_address, weight_payloads[bank]))
            bn_regions[bank].append((spec.bn_address, bn_payloads[bank]))

    for bank, regions in enumerate(weight_regions):
        regions.sort(key=lambda item: item[0])
        run_address = regions[0][0]
        expected = run_address
        payloads = []
        for address, payload in regions:
            if address != expected and payloads:
                builder.load_u64(
                    Target.WEIGHT,
                    address=run_address,
                    payload=np.ascontiguousarray(np.concatenate(payloads), dtype=np.uint64),
                    bank=bank,
                )
                run_address = address
                payloads = []
            payloads.append(payload)
            expected = address + payload.size
        builder.load_u64(
            Target.WEIGHT,
            address=run_address,
            payload=np.ascontiguousarray(np.concatenate(payloads), dtype=np.uint64),
            bank=bank,
        )

    for bank, regions in enumerate(bn_regions):
        regions.sort(key=lambda item: item[0])
        run_address = regions[0][0]
        expected = run_address
        payloads = []
        for address, payload in regions:
            if address != expected and payloads:
                builder.load_u32(
                    Target.BN,
                    address=run_address,
                    payload=np.ascontiguousarray(np.concatenate(payloads), dtype=np.uint32),
                    bank=bank,
                )
                run_address = address
                payloads = []
            payloads.append(payload)
            expected = address + payload.size
        builder.load_u32(
            Target.BN,
            address=run_address,
            payload=np.ascontiguousarray(np.concatenate(payloads), dtype=np.uint32),
            bank=bank,
        )

    instructions = np.asarray([pack_instruction(spec) for spec in stage], dtype=np.uint32)
    builder.load_u32(Target.INSTRUCTION, address=0, payload=instructions)
    builder.run(instruction_count=len(stage), timeout_cycles=timeout_cycles)


def pack_input_nchw(input_tensor):
    if hasattr(input_tensor, "detach"):
        array = input_tensor.detach().cpu().numpy()
    else:
        array = np.asarray(input_tensor)
    if array.shape != (1, 64, 32, 32):
        raise ValueError("APU input must have shape (1, 64, 32, 32)")
    bits = np.asarray(array, dtype=np.uint8).transpose(0, 2, 3, 1).reshape(-1) & 1
    packed = np.packbits(bits, bitorder="little")
    return np.ascontiguousarray(packed).view(np.uint64)


def unpack_output_payload(payload):
    raw = np.asarray(payload, dtype=np.uint8)
    expected_bytes = 256 * 8
    if raw.size != expected_bytes:
        raise ValueError("Expected %d output bytes, got %d" % (expected_bytes, raw.size))
    bits = np.unpackbits(raw, bitorder="little")
    return bits.reshape(1, 8, 8, 256).transpose(0, 3, 1, 2).copy()


def build_full_network_job(
    uint64_buffer,
    param_dir,
    input_words,
    sequence_id=1,
    timeout_cycles=100_000_000,
):
    input_words = np.asarray(input_words)
    if input_words.dtype != np.uint64 or input_words.shape != (1024,):
        raise ValueError("input_words must be 1024 uint64 words")
    builder = JobBuilder(uint64_buffer, sequence_id=sequence_id)
    builder.load_u64(Target.ACT, address=0, payload=input_words)
    for stage in STAGES:
        _append_stage(builder, param_dir, stage, timeout_cycles)
    builder.read_result(Target.ACT, address=0, element_count=256)
    used_bytes = builder.end()
    return builder, used_bytes
