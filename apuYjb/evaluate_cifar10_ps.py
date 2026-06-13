# -*- coding: utf-8 -*-
import torch
import torchvision
import torchvision.transforms as transforms
from torch.utils.data import DataLoader
import os
import time
from resnet_binary_ps import resnet_binary_cifar10_hybrid # 工厂函数

RUN_ON_PC_FOR_DEBUG = False
SAVE_DEBUG_FILES_DURING_EVALUATION = False

# --- 配置 ---
CIFAR10_DATASET_ROOT = "./CIFAR10/" # CIFAR-10 数据集下载/存放路径
PARAM_FILE_DIR_CONFIG = "./param/"
MODEL_WEIGHTS_PATH_CONFIG = "./model_best.pth.tar"

DEBUG_DIR_REAL_CONFIG = "./debug_outputs_real/"  # 真实APU的调试输出 (如果启用)
DEBUG_DIR_MOCK_CONFIG = "./debug_outputs_mock/" # 模拟APU的调试输出 (如果启用)

# PYNQ 特定配置 (仅在 RUN_ON_PC_FOR_DEBUG = False 时使用)
BITSTREAM_FILE_CONFIG = None
AXI_APU_IP_NAME_CONFIG = None

if RUN_ON_PC_FOR_DEBUG:
    print("正在PC上运行CIFAR-10评估 (使用模拟APU驱动)...")
    print("警告: 使用模拟APU进行评估可能无法准确反映真实硬件性能。")
    if SAVE_DEBUG_FILES_DURING_EVALUATION:
        print("注意: 将为评估过程生成调试文件，这会非常缓慢。")
else: # PYNQ 特定设置
    print("正在PYNQ上运行CIFAR-10评估 (使用真实APU驱动)...")
    if SAVE_DEBUG_FILES_DURING_EVALUATION:
        print("注意: 将为评估过程生成调试文件，这会非常缓慢。")
    BITSTREAM_FILE_CONFIG = "./myDesign.bit" 
    AXI_APU_IP_NAME_CONFIG = "APU_0"   
    try:
        from pynq import Overlay 
    except ImportError:
        print("错误: PYNQ库未找到。如果不在PYNQ板上运行，请设置 RUN_ON_PC_FOR_DEBUG = True")
        exit()

def main():
    required_paths = [PARAM_FILE_DIR_CONFIG, MODEL_WEIGHTS_PATH_CONFIG, CIFAR10_DATASET_ROOT]
    if not RUN_ON_PC_FOR_DEBUG:
        if BITSTREAM_FILE_CONFIG is None:
             print(f"错误: PYNQ模式下比特流文件路径 (BITSTREAM_FILE_CONFIG) 未配置。")
             return
        required_paths.append(BITSTREAM_FILE_CONFIG)

    for item_path in required_paths:
        if not os.path.exists(item_path) and item_path != CIFAR10_DATASET_ROOT : 
             print(f"错误: 必需的文件或目录未找到: {item_path}")
             return
    if not os.path.exists(CIFAR10_DATASET_ROOT):
        os.makedirs(CIFAR10_DATASET_ROOT)
        print(f"创建CIFAR-10数据集目录: {CIFAR10_DATASET_ROOT}")


    print("初始化混合ResNet模型进行评估...")
    model_kwargs = {
        'num_classes': 10,
        'bitstream_path': BITSTREAM_FILE_CONFIG,
        'apu_ip_name': AXI_APU_IP_NAME_CONFIG,
        'param_file_dir': PARAM_FILE_DIR_CONFIG,
        'model_weights_path': MODEL_WEIGHTS_PATH_CONFIG,
        'debug_dir_real': DEBUG_DIR_REAL_CONFIG,
        'debug_dir_mock': DEBUG_DIR_MOCK_CONFIG,
        'use_mock_apu_flag': RUN_ON_PC_FOR_DEBUG
    }

    try:
        model = resnet_binary_cifar10_hybrid(**model_kwargs)
    except Exception as e:
        print(f"模型初始化失败: {e}")
        import traceback
        traceback.print_exc()
        return

    model.eval() # 设置为评估模式

    # CIFAR-10 数据集加载与预处理
    print(f"加载CIFAR-10验证集从 '{CIFAR10_DATASET_ROOT}'...")
    transform_val = transforms.Compose([
        transforms.ToTensor(), 
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])
    val_dataset = torchvision.datasets.CIFAR10(
        root=CIFAR10_DATASET_ROOT,
        train=False, 
        download=True,
        transform=transform_val
    )
    # Batch size 必须为 1
    val_loader = DataLoader(val_dataset, batch_size=1, shuffle=False, num_workers=2)
    print(f"CIFAR-10验证集包含 {len(val_dataset)} 张图片。")

    print(f"开始在CIFAR-10验证集上评估 (模式: {'模拟' if RUN_ON_PC_FOR_DEBUG else '真实'})...")
    top1_correct = 0
    top5_correct = 0
    total_samples = 0
    inference_times = []

    try:
        with torch.no_grad(): # 评估时不需要计算梯度
            for i, (images, labels) in enumerate(val_loader):
                # images: [1, C, H, W], labels: [1]
                start_time_sample = time.time()

                forward_kwargs = {
                    'save_input_debug_file': SAVE_DEBUG_FILES_DURING_EVALUATION,
                    # 为调试文件使用不同的名称，以防覆盖单张图片测试的文件
                    'input_debug_filename': f"eval_sample_{i}_ps_packed_input.txt"
                }
                if RUN_ON_PC_FOR_DEBUG:
                    # 评估时，mock不应依赖golden file，它应模拟APU的通用行为（或输出占位符）
                    forward_kwargs['golden_apu_output_filepath_for_mock'] = None
                else: # PYNQ 上的真实 APU
                    forward_kwargs['save_output_debug_files_for_real'] = SAVE_DEBUG_FILES_DURING_EVALUATION
                    forward_kwargs['output_raw_filename_for_real'] = f"eval_sample_{i}_pynq_apu_raw.txt"
                    forward_kwargs['output_unpacked_filename_for_real'] = f"eval_sample_{i}_pynq_apu_unpacked.txt"

                outputs = model(images, **forward_kwargs) 
                
                end_time_sample = time.time()
                inference_times.append(end_time_sample - start_time_sample)

                # Top-1 准确率
                _, predicted_top1 = torch.max(outputs.data, 1)
                top1_correct += (predicted_top1 == labels).sum().item()

                # Top-5 准确率
                _, predicted_top5 = outputs.topk(5, 1, True, True) # [1, 5]
                predicted_top5 = predicted_top5.t() # [5, 1]
                correct_top5 = predicted_top5.eq(labels.view(1, -1).expand_as(predicted_top5))
                top5_correct += correct_top5[:5].reshape(-1).float().sum(0, keepdim=True).item()
                
                total_samples += labels.size(0) # 应该是1

                if (i + 1) % 100 == 0: # 每100张图片打印一次进度
                    avg_time_ms = (sum(inference_times[-100:]) / 100) * 1000 if inference_times else 0
                    print(f"已处理 [{i+1}/{len(val_loader)}] 张图片. "
                          f"当前Top-1: {100 * top1_correct / total_samples:.2f}%, "
                          f"当前Top-5: {100 * top5_correct / total_samples:.2f}%. "
                          f"最近100张平均耗时: {avg_time_ms:.2f} ms/图片")

        top1_accuracy = 100 * top1_correct / total_samples
        top5_accuracy = 100 * top5_correct / total_samples
        avg_total_inference_time_ms = (sum(inference_times) / total_samples) * 1000 if total_samples > 0 else 0

        print("\n--- CIFAR-10 验证集评估结果 ---")
        print(f"总样本数: {total_samples}")
        print(f"Top-1 正确数: {top1_correct}")
        print(f"Top-5 正确数: {top5_correct}")
        print(f"Top-1 准确率: {top1_accuracy:.2f}%")
        print(f"Top-5 准确率: {top5_accuracy:.2f}%")
        print(f"平均单张图片推理时间: {avg_total_inference_time_ms:.3f} ms")

    except Exception as e:
        print(f"评估过程中发生错误: {e}");
        import traceback; traceback.print_exc()
    finally:
        if hasattr(model, 'apu_driver') and model.apu_driver is not None and hasattr(model.apu_driver, 'cleanup'):
            model.apu_driver.cleanup()
        print("CIFAR-10评估脚本执行完毕。")

if __name__ == "__main__":
    main()