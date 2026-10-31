# 语音输入及命令跟踪版

本版基于 `voice_response_20261023`，工程在 `E:/anlo_project/liantiao/development/audio_crc`。识别权重、前端数学运算及拒识门限未改变；本版没有实测识别率提升或两秒端到端保证。

## 下载与可见变化

将本目录内 ACA 和 HX 两个码流分别下载到对应板。短按 ACA S4 进入 VOICE READY。

- SEND：本地识别通过，等待 HX 命令确认。正常链路很快确认，可能看不到短暂 SEND。
- NEXT/PREV：已收到 HX 命令确认，尚不代表图片已经显示。
- FAIL：板间命令发送失败或事件队列溢出。
- 确认提示至少保留 200ms，之后新语音或拒识可清除；最大保留一秒。短杂音不再立即擦掉刚收到确认的结果。
- 同时输出语音检测前的 8kHz 识别输入 PCM、原有特征/分数、接受次数及确认次数。PCM 是经过现有六抽一处理的输入，不是未处理的 48kHz ADC；满幅标记仍监测 ADC 原样本。

## 抓取和分析

进入 VOICE READY 后，语音抓取串口速率改为 460800。非语音模式的旧状态串口仍为 115200。

```powershell
./tools/capture_voice.ps1 -Port COM3 -Seconds 30 -Baud 460800
python tools/decode_voice_pcm.py verification/voice_capture_时间.bin
python tools/replay_voice_capture.py verification/voice_capture_时间.feature.bin
```

只在无 CRC 错误、无帧缺口、无采样数量或溢出故障时导出连续 WAV，避免把丢包拼成假声音。输出 `.pcm.json` 含命令跟踪，`.wav` 可回听，`.feature.bin` 可用原工具精确重放分类。抓取后按实际听到的内容逐段标注上一张、下一张及杂音，不能按一整批口令把全部候选自动标为下一张。

## 协议及边界

596 字节、opcode 0x55；bytes 0..71 保留原特征布局，版本 byte70 为 0x25，byte71 bit0 为溢出、bit1 为采样数量异常。bytes72..73 为样本数256，74..585 为256个 PCM16 小端样本，586..593 为命令跟踪，594..595 为前594字节的 CRC16-CCITT。

跟踪字段依次为：最后接受的识别候选序号16位、接受次数16位、HX确认次数16位、状态8位、最后接受的命令8位。状态bit0在线、bit1语音运行、bit2等待确认、bit3发送失败、bit4队列溢出、bits6:5屏幕命令码。计数仅在语音运行期间有效，退出语音后清零。确认计数是命令收到确认的记录，不是 SD 或 HDMI 完成记录。

## 本轮参考资料及取舍

- [TensorFlow micro_speech](https://github.com/tensorflow/tflite-micro/tree/main/tensorflow/lite/micro/examples/micro_speech)：参考前处理明确采用频带谱减、PCAN增益控制、再取对数。可借鉴定点实现，但改变特征后要配套训练，不能直接搭配当前权重宣称提高识别率。
- [PCEN 抗噪关键词前端论文](https://arxiv.org/abs/1607.05666)：评估频带自适应归一化的方向。已有串口特征经过归一化/VAD置零，无法还原 PCEN 所需的原始能量。
- [ARM 小型关键词识别](https://github.com/ARM-software/ML-KWS-for-MCU) 及 [FPGA HLS 工程](https://github.com/zYeoman/ML-KWS-for-FPGA)：可参考架构，不能直接把英文权重或 Xilinx 码流用于安路中文命令。
- [MAX4466 模块说明](https://learn.adafruit.com/adafruit-microphone-amplifier-breakout/measuring-sound-levels)：该参考模块增益25～125倍可调，不等于已确认用户实物型号/当前增益。
- [Espressif ES8388 参考驱动](https://github.com/espressif/esp-adf/blob/v2.7/components/audio_hal/driver/es8388/es8388.c)：PGA通过ADCCONTROL1设置。当前工程寄存器0x09已写0x00，即PGA0dB，没有据此继续任意降低寄存器增益。

检索到的其他板 ES8388 失真、VAD截断讨论不能证明本板具有相同原因。当前实证仍以151059抓取及 `docs/voice_failure_analysis_20261023_151059.md` 为准。本轮 DTW 试验未优于当前模型，未部署。

## 已做验证

- PCM UART的有符号样本、大小端、双缓冲隔离、末样本与末频带对齐、不可变命令记录快照、CRC、残帧故障标记。
- 真实降采样及频谱前端按板上节拍连续三帧，768个PCM样本逐个匹配，帧计数256，无丢样或溢出。
- 主机解码拒绝CRC损坏与帧缺口；可还原模拟输入音频及命令记录。
- 双板顶层实际UART的确认丢失重传、去重、SEND等待、短杂音后的最短可见时间、过期清除和语音握手。
- 新SEND/FAIL文字及现有音乐诊断显示、噪声端点和SD预读回归。

这些是数字仿真验证；麦克风模拟质量及人的实际口令识别率仍需上板数据，不能以仿真PASS代替。
