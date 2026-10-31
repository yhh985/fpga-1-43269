# 2026-10-21 音效 CRC 版

当前为 FX WAIT 时序修复版，发布目录为 `deliverable/audio_crc_skewfix_20261021`。已复现的独立线延迟缺陷及新版诊断文字见 `FX_WAIT定位与时序修复.md`；前一版本实板反馈未通过。

本版本在独立工程 `E:\anlo_project\liantiao\development\audio_crc` 开发。旧版快照位于主目录 `archive/20261021_pre_crc_baseline`；早期 CRC 快照位于 `archive/20261021_crc_audio_experiment`，均不覆盖。

## 本版实现

HX 从 SD 读 PCM16 WAV，以 32 位/声道传给 ACA；每个槽包含 PCM16、CRC15 和填充位。ACA 校验输入后完成效果计算，再重新计算 CRC 返回 HX。HX 在完整 PCM 帧处选择本地或返回音频，将有效采样送入 HDMI。该格式是双 FPGA 私有协议，不能直接连接外部 I2S 编解码器。

两块板必须更新到同一 CRC 版。旧版与本版音频帧格式不兼容。UART 协议及接线没有修改。

ACA S3 长按约 1 秒依次切换：

| 档位 | 效果 | 实现与听感 |
|---|---|---|
| 0 | 原声 | HX 本地 PCM，统一衰减约 12 dB |
| 1 | 回声 | 4096 帧约 85 ms 延迟；左右声道平均作为单声道湿声，与各自原声各混一半，再统一衰减；短音停下后可听见尾声 |
| 2 | 低通 | 两声道独立一阶滤波，Q4 状态，约 1 kHz 截止；高频明显变暗 |
| 3 | 颤音 | 约 5 Hz 的高低音量交替，低档为高档的四分之一；左右声道在同一帧切换 |

回声缓存保存最近的有效音乐，所以切入回声时可以听到切换前约 85 ms 的音乐。它是一次延迟混音，没有持续反馈。CRC 失败后清除缓存有效计数，填满前不会读出旧缓存作为湿声。

原声及所有音效的输出均预留约 12 dB 余量，不使用四倍饱和失真。原声与效果之间不再存在统一衰减造成的 12 dB 跳变。切换尚未加入淡入淡出，不能承诺没有轻微点击。

屏幕显示 `FX ECHO`、`FX LOWPASS`、`FX TREMOLO`。返回帧未验证可用时，屏幕给出去程/回程具体诊断，详见 `FX_WAIT定位与时序修复.md`；此时音效输出静音，不用原声冒充效果。CRC 只负责识别坏帧，效果正确性由下面的独立数值检查证明。

## 上板测试

1. 先关小音箱音量，以音箱短时试听；本轮曾有刺耳杂音，首次复测不要佩戴耳机。
2. 给 ACA、HX 同时下载本次发布目录里成对的新码流。不要混用主目录旧版码流。
3. FAT32 卡根目录放至少两个 PCM1、16 位、48 kHz WAV。可先复制 `card_test` 的三份测试音来区分曲目。MP3 和 44.1 kHz 不支持；若只有一首，上一首/下一首都会回到这一首。
4. 保持 ACA 音乐模式，S4 进入语音模式会停止音乐。HX 图片操作页短按 K2，手动→自动→音乐循环；K4 长按暂停/恢复。
5. S2 短按下一首，S3 短按上一首。S3 长按约 1 秒进入回声，再次长按进入低通，再次进入颤音，再次回原声。每次查看屏幕的效果名称。
6. 用有停顿、鼓点或人声的音乐判断回声；用含高频的音乐判断低通；颤音应每秒明显起伏约 5 次。纯低频持续音不适合判断低通或回声。
7. 若一直无声或仍出现杂音，记录两板码流文件名、完整诊断文字和接线，不能将“仿真通过”等同为实板验收通过。

## 接线沿用原版

两板分别供电，只有信号和共地互连，不互接供电针。

| 信号 | HX 接头 / FPGA 管脚 | ACA 接头 / FPGA 管脚 |
|---|---|---|
| ACA TX → HX RX | J2-1 / P4 | P4-1 / E15 |
| HX TX → ACA RX | J2-2 / N4 | P4-2 / F13 |
| GND | J2-12 | P4-12 |
| BCLK，HX → ACA | J1-1 / D14 | P4-3 / F14 |
| LRCK，HX → ACA | J1-2 / G11 | P4-4 / D16 |
| 音频数据，HX → ACA | J1-3 / G12 | P4-5 / D14 |
| 返回数据，ACA → HX | J1-4 / F13 | P4-6 / E13 |

这里的 P4-12 是接头脚号，不是 FPGA 封装管脚名。它和 P4-11 电源脚不能混淆。

## 验证范围与复现

在本工程目录运行，Python 可使用本机 Codex runtime 的 python.exe：

```
python sim/run_checked_audio.py
python sim/run_dual_board_music.py
python sim/run_audio_skew.py
python sim/run_music_diagnostics.py
python sim/render_effect_audio.py
python tools/build_verified.py aca420
python tools/build_verified.py hx4s20
python tools/package_checked_audio.py
```

- `run_checked_audio.py`：30 组相位/延迟矩阵，加一组完整 5 Hz 颤音和实际回声串行往返检查；记录全部测试源码 SHA256，并拒绝测试中途变更源码。
- `run_dual_board_music.py`：实际两板顶层、物理按键输入、UART 协议和 HX HDMI PCM 输入；覆盖立体声、原声/效果切换、错误静音和恢复。SD、PLL 和加密 HDMI 内核使用测试桩，不是实体 HDMI 发送验证。
- `render_effect_audio.py`：用实际 HDL DSP 处理两秒原创测试信号，四档共 768000 个样本与独立整数参考逐一对照，导出 `verification/effect_audio` 下的 WAV。此试听证明 DSP 数值变化，不能证明杜邦线和实体 HDMI 声音质量。
- `tb_music_echo.v`：20501 帧的精确回声延迟、边界、错误清空和未初始化 RAM 检查。
- 两板 `verified_build_inputs.json` 将码流绑定到本轮源码、模型、约束和构建脚本。Setup/Hold 裕量以本轮 `final_timing_status.txt` 为准。

内部时序报告不覆盖跨板接线的实测延迟与信号质量。完整合格结论仍须两板实际播放验证。语音沿用原生产模型；本版音效验收不宣称解决真人语音识别问题。

## 网上项目参考

- https://github.com/Muzhou-exe/FPGA-Based-Guitar-Digital-Multi-effect-pedal ：MIT 许可，参考其 I2S 收发和定点低通实现方法。该项目是 Basys3 单板系统，不能作为本工程双板链路的测试结果。本版一阶低通及 CRC/回声代码为本工程实现，并未直接套用其二阶滤波系数。
- https://github.com/MatiasE2004/FPGA-ZYBO-Z7-10-AUDIOEFFECTSREALTIME ：作为实时 FPGA 音效的相关实现参考，未将其验证结果当作本板结果。

本目录复制的 10 月 20 日旧说明、旧 release manifest 和旧音效回归仅作历史记录；本 CRC 版当前证据以 `verification/checked_audio.json`、`dual_board_music.json`、`effect_render.json` 及专用发布清单为准。
