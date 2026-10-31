# 2026-10-21 FX WAIT 时序修复版

用户实板反馈：原声有声音，CRC 版一切音效都持续 FX WAIT；两块板均已更新，沿用之前的音频接线。该反馈意味着前一个发布版本尚未通过实板验收。

## 已复现的代码缺陷

旧代码仅在检测到 BCLK 下降沿时处理 LRCK 换声道。如果 LRCK 经独立管脚、布线或采样后晚于这个判断时刻，代码要再等一个 BCLK 周期才重置位计数，导致漏掉有效位，持续 CRC 失败。

加入 LRCK 相对 BCLK 晚 35 ns 的独立线延迟后，旧 HDL 可复现 `no valid checked return, errors=80`。证据保存在 `verification/skew_before_failure.json` 和 `.log`。这是已证明的软件脆弱点；没有测量实体两板波形，不能断言用户板上延迟恰好是 35 ns。

接收端改为每个系统时钟都检测同步后的 LRCK 变化，及时进入新声道的 dummy 位。ACA 返回发送端也在 dummy 位内装载字，并根据 BCLK 高低区分“LRCK 先到”和“LRCK 后到”，防止提前发送 MSB。保持原有 32 位槽、PCM16、CRC15、每帧校验和 48 kHz 采样格式，没有降低校验标准，也没有用原声代替效果。

## 屏幕诊断

原有单一 FX WAIT 改为分段诊断。ACA 的接收状态通过已有 UART 的保留位传给 HX，无需增加线。

| 显示 | 含义 |
|---|---|
| FX OLD ACA | ACA 没有新版诊断标记，可能仍烧着旧码流 |
| FX NO BCLK | ACA 最近没有观察到音频位时钟跳变 |
| FX NO LRCK | ACA 有 BCLK，但没有观察到帧时钟跳变 |
| FX NO DATA | ACA 有时钟，但没有观察到去程 DATA 跳变 |
| FX IN CRC | ACA 有时钟和 DATA，但没有收到通过校验的完整立体声帧 |
| FX NO RET | ACA 已收到有效立体声，HX 没有观察到返回 DATA 跳变 |
| FX OUT CRC | ACA 去程有效、HX 返回 DATA 有跳变，但返回帧未稳定通过校验 |
| FX ECHO / FX LOWPASS / FX TREMOLO | 返回帧已稳定通过校验，分别选择回声/低通/颤音 |

诊断按约 10～20 ms 窗口更新，另加已有 UART 状态报告时间。刚开播时提示可能短暂变化。原声仍在 HX 本地播放，因此原声正常本身不能证明两板往返音频有效。DATA 有跳变也不能证明位序和 CRC 正确。

## 回归及构建

新增 `python sim/run_audio_skew.py`：27 组独立延迟组合，覆盖帧时钟落后 0/15/25/35/60/90 ns、提前 15 ns、不同 ACA/HX 采样相位、不同 DATA 延迟及往返线延迟。它是数字延迟模型，不代替信号完整性测量。

新增 `python sim/run_music_diagnostics.py`：验证无时钟、DATA 跳变但 CRC 错、有效立体声、活动过期以及全部十种屏幕文字。

实际两板顶层的 `run_dual_board_music.py` 也加入独立 BCLK/LRCK/DATA/返回延迟，并核对诊断位经过真实 UART 发送到 HX。SD、PLL 和加密 HDMI 内核仍使用测试桩。

保留原有 31 组校验音效回归、精确回声测试及 768000 个 DSP 样本比较。发布脚本检查测试源码哈希、码流构建输入和 Setup/Hold 报告后才允许发布。

## 使用本次文件

仅使用 `E:\anlo_project\liantiao\deliverable\audio_crc_skewfix_20261021` 的两份成对码流；前一个 `audio_crc_20261021` 目录保留用于追溯。接线和 S3 长按切音效操作不变。先关小音箱音量，首次不用耳机。

若仍无声音，等状态稳定约 1 秒后记录屏幕的完整诊断文字，就能区分去程或回程问题。仍需实板确认，此说明不宣称仿真等于硬件验收。

改动前源码、原版成对码流及输入哈希已保存到 `E:\anlo_project\liantiao\archive\20261021_crc_wait_baseline`。
