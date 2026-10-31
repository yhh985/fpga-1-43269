# 语音反馈及响应修正（2026-10-23）

适用工程：`E:/anlo_project/liantiao/development/audio_crc`。本版基于当前语音特征抓取版继续修改。

## 本版行为

- NEXT/PREV 仅在收到 HX 的匹配命令确认包后显示；这表示 HX 已接收命令，不表示 HDMI 已切换图片。
- 开始新一句话、拒识、命令发送失败或提示超过一秒，清除旧 NEXT/PREV，避免残留结果被误认为新的识别。
- 命令丢包重试间隔从 100ms 缩短到 50ms；保留 CRC、序号和 HX 去重，重传不会重复翻页。
- 现有特征提取、权重及拒识阈值保持当前经过验证的版本。

## 使用

将发布目录内 `aca420_voice_response.bit` 下载至 ACA420，将 `hx4s20_voice_response.bit` 下载至 HX4S20。短按 ACA S4，确认 VOICE READY。以正常音量说“下一张”或“上一张”。观察这一次新出现的 NEXT/PREV 及图片编号，而不是上一轮的结果。

## 已测范围与两秒目标

50MHz 的整数 RTL 仿真中，三次推理及归一化最长 4.455ms；端点等待为 192ms，前端仿真在语音停止后不超过 224ms 结束检测。这里的语音停止指 VAD 判定结束，持续噪声可能延后端点。上述时间不包含人说话本身的时长。

真实双板顶层 UART 仿真通过：确认包丢失重试、去重、HX 接收后再显示 NEXT、新一句清除、提示过期、语音模式握手。该测试中的存储和 PLL 使用替身。

另以真实 SD 调度模块测试：NEXT 缓存命中不重新读卡，预读中收到的语音请求不丢失，PREV 缓存未命中正确重新读取，显示缓冲区等待内存写完及读端确认，转场期间保留缓冲区。这个测试替代了实际卡及 SDRAM 完成事件，不是 SD 卡性能测试。

缓存未准备好时，NEXT 要等当前读取完成；PREV 还可能先等 NEXT 预读再读上一张。图片大小、卡速、持续噪声和接线错误均可能使实际响应超过两秒。本版不能宣称已解决所有长延迟，需用上板说完口令到新图可见的实际时间确认。

## 算法检索与试验

查阅了以下公开实现/论文：

- [ARM DS-CNN 小型关键词识别](https://github.com/ARM-software/ML-KWS-for-MCU)
- [对应 FPGA HLS 工程](https://github.com/zYeoman/ML-KWS-for-FPGA)：Xilinx/Vivado 工程，不能直接在安路下载；英文权重也不能直接识别中文命令。
- [TC-ResNet 时序卷积](https://github.com/hyperconnect/TC-ResNet)
- [PCEN 远场抗噪前端](https://arxiv.org/abs/1607.05666)
- [TensorFlow 定点频带降噪](https://github.com/tensorflow/tensorflow/blob/master/tensorflow/lite/experimental/microfrontend/lib/noise_reduction.c) 及 [PCAN 增益控制](https://github.com/tensorflow/tensorflow/blob/master/tensorflow/lite/experimental/microfrontend/lib/pcan_gain_control.c)

当前独立实现的 DTW 试验使用训练集模板，在相同 2290 个合成验证候选上比较：

| 方法 | 正确命令 / 649 | 反方向 | 背景误触发 / 1641 |
| --- | ---: | ---: | ---: |
| 当前 MLP | 375 | 13 | 8 |
| DTW 试验 | 22 | 1 | 7 |

这是候选片段级合成验证，不是人的实测识别率。DTW 没有改善，不部署。结果及脚本在 `voice/experiments/dtw_pilot/validation_report.json`、`voice/tools/evaluate_dtw_candidate.py`。

更有依据的后续方向是频带噪声估计/PCEN 配合中文双命令时序网络重新训练。目前串口保存的是归一化且被 VAD 置零的特征，不能恢复原始频带能量；不能直接把 PCEN 公式套到现有特征上并声称提高成功率。用户确认过整批口令，但噪声产生的每个候选没有逐段标签，暂不拿整批候选冒充带标签语音训练。
