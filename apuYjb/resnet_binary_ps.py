# -*- coding: utf-8 -*-
# --- START OF FILE resnet_binary_ps.py ---
import torch
import torch.nn as nn
import math
import os

# 我们不再在模块级别确定 SelectedAPUDriver，而是在构造函数中

# --- 用户配置 (默认值) ---
BITSTREAM_FILE_DEFAULT = "./myDesign.bit"
AXI_APU_IP_NAME_DEFAULT = "APU_0"
PARAM_FILE_DIR_DEFAULT = "./param/"
DEBUG_OUTPUT_DIR_REAL_DEFAULT = "./debug_outputs_real/"
DEBUG_OUTPUT_DIR_MOCK_DEFAULT = "./debug_outputs_mock/"
DEFAULT_MODEL_WEIGHTS_PATH = "./model_best.pth.tar"
# ---

__all__ = ['ResNet_cifar10_hybrid', 'resnet_binary_cifar10_hybrid']

# 打印tensor的函数 (调试用，评估时一般不调用)
# import numpy as np
# def reverse_bit_list_to_string(bit_list_32):
#     if len(bit_list_32) != 32: raise ValueError("输入列表长度必须为32")
#     return "".join(map(str, bit_list_32[::-1]))
# def print_tensor_in_reversed_bhwc_format(tensor_nchw, num_lines_to_print=16):
#     # ... (代码与之前相同) ...
#     pass

class BasicBlock(nn.Module):
    expansion=1
    def __init__(self,i,p,s=1,d=None):super(BasicBlock,self).__init__();self.conv1=nn.Conv2d(i,p,3,s,1,bias=False);self.bn1=nn.BatchNorm2d(p);self.tanh1=nn.Hardtanh(True);self.conv2=nn.Conv2d(p,p,3,1,1,bias=False);self.bn2=nn.BatchNorm2d(p);self.tanh2=nn.Hardtanh(True);self.downsample=d;self.stride=s
    def forward(self,x):r=x;o=self.conv1(x);o=self.bn1(o);o=self.tanh1(o);o=self.conv2(o);o=self.bn2(o);r=(self.downsample(x))if self.downsample else r;o+=r;o=self.tanh2(o);return o

def init_model0(m): # 随机初始化
    for i in m.modules():
        if isinstance(i,nn.Conv2d): i.weight.data.normal_(0,math.sqrt(2./(i.kernel_size[0]*i.kernel_size[1]*i.out_channels)))
        elif isinstance(i,(nn.BatchNorm2d,nn.BatchNorm1d)): i.weight.data.fill_(1); i.bias.data.zero_()

def init_model1(m,p): # 从文件加载权重
    try:
        m.load_state_dict(torch.load(p,map_location=torch.device('cpu'))['state_dict'],strict=False)
        print(f"成功加载模型权重: {p}")
    except FileNotFoundError:
        print(f"警告: 未找到模型权重文件 {p}，将使用随机初始化。")
        init_model0(m)
    except Exception as e:
        print(f"加载模型权重 {p} 出错: {e}，将使用随机初始化。")
        init_model0(m)


class ResNet(nn.Module):
    def __init__(self):
        super(ResNet, self).__init__()
        self.apu_driver = None # 会在子类中被正确设置

    def forward(self, x,
                save_input_debug_file=False,      # 控制是否保存APU输入调试文件
                input_debug_filename="default_packed_input.txt",
                golden_apu_output_filepath_for_mock=None, # 仅用于mock driver
                save_output_debug_files_for_real=False, # 控制是否保存真实APU输出调试文件
                output_raw_filename_for_real="apu_output_raw.txt",
                output_unpacked_filename_for_real="apu_output_unpacked_verified.txt"):
        # PS端预处理
        x = self.conv1(x); x = self.maxpool1(x); x = self.bn1(x); x = self.tanh1(x)
        x_binary_01 = x.sign().add(-1).div(-2).int().float() # 确保其值为 0.0 或 1.0

        apu_driver_kwargs = {
            'input_tensor_ps_01': x_binary_01.clone(),
            'save_input_debug_file': save_input_debug_file, # 传递标志
            'input_debug_filename': input_debug_filename
        }

        APUDriverMock, APUDriver = None, None
        try: from apu_driver_mock import APUDriverMock
        except ImportError: pass # 允许在没有mock时运行
        try: from apu_driver import APUDriver
        except ImportError: pass # 允许在没有真实驱动时运行 (例如，在PC上只用mock)


        if APUDriverMock and isinstance(self.apu_driver, APUDriverMock):
             apu_driver_kwargs['golden_apu_output_filepath'] = golden_apu_output_filepath_for_mock
        elif APUDriver and isinstance(self.apu_driver, APUDriver):
            apu_driver_kwargs['save_output_debug_files'] = save_output_debug_files_for_real # 传递标志
            apu_driver_kwargs['output_raw_filename'] = output_raw_filename_for_real
            apu_driver_kwargs['output_unpacked_filename'] = output_unpacked_filename_for_real
        elif self.apu_driver is None:
             raise RuntimeError("apu_driver 为 None。它应该在 ResNet_cifar10_hybrid 构造函数中被初始化。")
        # else:
            # print(f"警告: apu_driver 类型非预期: {type(self.apu_driver)}。") # 评估时可注释

        x_from_apu_01 = self.apu_driver.execute_apu_network(**apu_driver_kwargs) # 应返回 0/1 的 uint8 张量

        # 将从 APU 得到的 0/1 uint8 张量转换为 -1.0/1.0 的浮点张量，用于后续层
        x = (x_from_apu_01.float() * (-2.0)) + 1.0
        # PS端后处理
        x = self.avgpool(x)
        x = x.view(x.size(0), -1); x = self.fc(x)
        x = self.bn3(x); x = self.logsoftmax(x)
        return x

class ResNet_cifar10_hybrid(ResNet):
    def __init__(self, num_classes=10,
                 bitstream_path=BITSTREAM_FILE_DEFAULT,
                 apu_ip_name=AXI_APU_IP_NAME_DEFAULT,
                 param_file_dir=PARAM_FILE_DIR_DEFAULT,
                 model_weights_path=DEFAULT_MODEL_WEIGHTS_PATH,
                 debug_dir_real=DEBUG_OUTPUT_DIR_REAL_DEFAULT,
                 debug_dir_mock=DEBUG_OUTPUT_DIR_MOCK_DEFAULT,
                 use_mock_apu_flag=False):
        super(ResNet_cifar10_hybrid, self).__init__()
        self.inflate = 4; self.inplanes = 16 * self.inflate
        self.conv1 = nn.Conv2d(3, self.inplanes, 3, 1, 1, bias=False)
        self.maxpool1 = lambda x: x # 无操作
        self.bn1 = nn.BatchNorm2d(self.inplanes, track_running_stats=True)
        self.tanh1 = nn.Hardtanh(inplace=True)

        if use_mock_apu_flag:
            from apu_driver_mock import APUDriverMock
            print("ResNet_cifar10_hybrid: 初始化模拟APU驱动 (APUDriverMock)...")
            self.apu_driver = APUDriverMock(
                param_file_dir=param_file_dir,
                output_debug_dir=debug_dir_mock
            )
        else: # 真实驱动
            try:
                from apu_driver import APUDriver
                print("ResNet_cifar10_hybrid: 初始化真实APU驱动 (APUDriver)...")
                if not bitstream_path or not apu_ip_name:
                    raise ValueError("真实APU驱动需要bitstream_path和apu_ip_name。")
                self.apu_driver = APUDriver(
                    bitstream_file=bitstream_path,
                    axi_apu_ip_name=apu_ip_name,
                    param_file_dir=param_file_dir,
                    output_debug_dir=debug_dir_real
                )
            except ImportError:
                raise ImportError("真实APU驱动 (apu_driver.py) 未找到或其依赖 (PYNQ) 未满足。")
            except Exception as e:
                print(f"初始化真实APU驱动失败: {e}")
                raise

        self.avgpool = nn.AvgPool2d(8)
        self.fc = nn.Linear(self.inplanes * 4, num_classes) # 256 -> num_classes
        self.bn3 = nn.BatchNorm1d(num_classes, track_running_stats=True)
        self.logsoftmax = nn.LogSoftmax(dim=1)

        current_model_weights_path = model_weights_path
        if not current_model_weights_path or not os.path.isfile(current_model_weights_path):
            print(f"提供的模型权重路径 '{current_model_weights_path}' 无效，尝试默认路径 '{DEFAULT_MODEL_WEIGHTS_PATH}'")
            current_model_weights_path = DEFAULT_MODEL_WEIGHTS_PATH

        init_model1(self, current_model_weights_path)
        self.regime = {0: {'optimizer': 'Adam', 'lr': 5e-3}} # 可能用于训练，推理时忽略

def resnet_binary_cifar10_hybrid(**kwargs):
    use_mock = kwargs.get('use_mock_apu_flag')
    if use_mock is None:
        print("警告: use_mock_apu_flag 未在kwargs中提供，将根据环境变量决定。")
        use_mock = os.getenv("USE_MOCK_APU", "false").lower() == "true"

    num_classes_val = kwargs.get('num_classes', 10)

    return ResNet_cifar10_hybrid(
        num_classes=num_classes_val,
        bitstream_path=kwargs.get('bitstream_file', BITSTREAM_FILE_DEFAULT),
        apu_ip_name=kwargs.get('apu_ip_name', AXI_APU_IP_NAME_DEFAULT),
        param_file_dir=kwargs.get('param_file_dir', PARAM_FILE_DIR_DEFAULT),
        model_weights_path=kwargs.get('model_weights_path', DEFAULT_MODEL_WEIGHTS_PATH),
        debug_dir_real=kwargs.get('debug_dir_real', DEBUG_OUTPUT_DIR_REAL_DEFAULT),
        debug_dir_mock=kwargs.get('debug_dir_mock', DEBUG_OUTPUT_DIR_MOCK_DEFAULT),
        use_mock_apu_flag=use_mock
    )
# --- END OF FILE resnet_binary_ps.py ---