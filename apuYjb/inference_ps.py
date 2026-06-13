# -*- coding: utf-8 -*-
import torch
import os
import time
from torchvision import transforms
from PIL import Image
from resnet_binary_ps import resnet_binary_cifar10_hybrid

RUN_ON_PC_FOR_DEBUG = False 
SAVE_ALL_DEBUG_FILES = False 


PARAM_FILE_DIR_CONFIG = "./param/"
MODEL_WEIGHTS_PATH_CONFIG = "./model_best.pth.tar"
IMAGE_PATH_CONFIG = "./image/cifar10_test_image.jpg" 

GOLDEN_APU_OUTPUT_FILE_CONFIG = "./data_flow/layer3.1_bn3_output.txt"

DEBUG_DIR_REAL_CONFIG = "./debug_outputs_real/"
DEBUG_DIR_MOCK_CONFIG = "./debug_outputs_mock/"


BITSTREAM_FILE_CONFIG = None
AXI_APU_IP_NAME_CONFIG = None

if RUN_ON_PC_FOR_DEBUG:
    print("正在PC上运行以进行调试 (使用模拟APU驱动)...")
    if not SAVE_ALL_DEBUG_FILES:
        print("注意: 调试文件生成已禁用。")
    elif GOLDEN_APU_OUTPUT_FILE_CONFIG and not os.path.isfile(GOLDEN_APU_OUTPUT_FILE_CONFIG):
        print(f"警告: 黄金参考APU输出文件 '{GOLDEN_APU_OUTPUT_FILE_CONFIG}' 未找到。模拟驱动将使用全零输出。")
else: 
    print("正在PYNQ上运行 (使用真实APU驱动)...")
    if not SAVE_ALL_DEBUG_FILES:
        print("注意: 调试文件生成已禁用。")
    BITSTREAM_FILE_CONFIG = "./myDesign.bit"
    AXI_APU_IP_NAME_CONFIG = "APU_0"
    try:
        from pynq import Overlay 
    except ImportError:
        print("错误: PYNQ库未找到。如果不在PYNQ板上运行，请设置 RUN_ON_PC_FOR_DEBUG = True")
        exit()


def main():
    required_paths = [PARAM_FILE_DIR_CONFIG, MODEL_WEIGHTS_PATH_CONFIG, IMAGE_PATH_CONFIG]
    if not RUN_ON_PC_FOR_DEBUG:
        if BITSTREAM_FILE_CONFIG is None:
             print(f"错误: PYNQ模式下比特流文件路径 (BITSTREAM_FILE_CONFIG) 未配置。")
             return
        required_paths.append(BITSTREAM_FILE_CONFIG)

    for item_path in required_paths:
        if not os.path.exists(item_path):
            print(f"错误: 必需的文件或目录未找到: {item_path}")
            return


    if SAVE_ALL_DEBUG_FILES:
        target_debug_dir = DEBUG_DIR_MOCK_CONFIG if RUN_ON_PC_FOR_DEBUG else DEBUG_DIR_REAL_CONFIG
        if not os.path.exists(target_debug_dir):
            try:
                os.makedirs(target_debug_dir)
                print(f"信息: 调试输出目录 '{target_debug_dir}' 将被创建（如果尚不存在）。")
            except OSError as e:
                print(f"创建调试目录 '{target_debug_dir}' 失败: {e}"); return


    print("初始化混合ResNet模型...")
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

    model.eval()

    print(f"加载图像: {IMAGE_PATH_CONFIG}");
    try:
        image = Image.open(IMAGE_PATH_CONFIG).convert('RGB')
    except FileNotFoundError:
        print(f"错误: 图像文件 '{IMAGE_PATH_CONFIG}' 未找到.")
        return

    preprocess = transforms.Compose([
        transforms.Resize(32),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])
    print("预处理图像...");
    input_tensor = preprocess(image);
    input_batch = input_tensor.unsqueeze(0)

    print(f"运行推理 (模式: {'模拟' if RUN_ON_PC_FOR_DEBUG else '真实'})...")
    try:
        with torch.no_grad():
            start_time = time.time()

            forward_kwargs = {
                'save_input_debug_file': SAVE_ALL_DEBUG_FILES, 
                'input_debug_filename': "single_img_ps_packed_input_to_apu.txt"
            }
            if RUN_ON_PC_FOR_DEBUG:
                if SAVE_ALL_DEBUG_FILES and GOLDEN_APU_OUTPUT_FILE_CONFIG and os.path.isfile(GOLDEN_APU_OUTPUT_FILE_CONFIG):
                    forward_kwargs['golden_apu_output_filepath_for_mock'] = GOLDEN_APU_OUTPUT_FILE_CONFIG
                else:
                    forward_kwargs['golden_apu_output_filepath_for_mock'] = None 
            else: 
                forward_kwargs['save_output_debug_files_for_real'] = SAVE_ALL_DEBUG_FILES 
                forward_kwargs['output_raw_filename_for_real'] = "single_img_pynq_apu_output_raw.txt"
                forward_kwargs['output_unpacked_filename_for_real'] = "single_img_pynq_apu_output_unpacked.txt"

            output = model(input_batch, **forward_kwargs)

            end_time = time.time()
            elapsed_time_ms = (end_time - start_time) * 1000
            print(f"推理时间: {elapsed_time_ms:.3f} ms")

        _, predicted_idx = torch.max(output, 1)
        classes = ('plane', 'car', 'bird', 'cat', 'deer', 'dog', 'frog', 'horse', 'ship', 'truck')
        predicted_class = classes[predicted_idx.item()] if 0 <= predicted_idx.item() < len(classes) else "Unknown"

        print(f"原始输出 (LogSoftmax): {output}")
        print(f"预测类别索引: {predicted_idx.item()} (类别: {predicted_class})")

    except Exception as e:
        print(f"推理过程中发生错误: {e}");
        import traceback; traceback.print_exc()
    finally:
        if hasattr(model, 'apu_driver') and model.apu_driver is not None and hasattr(model.apu_driver, 'cleanup'):
            model.apu_driver.cleanup()
        print("单张图片推理脚本执行完毕。")

if __name__ == "__main__":
    main()