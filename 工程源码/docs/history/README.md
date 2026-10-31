# ACA420 + HX4S20 CRC 音效独立工程（2026-10-21）

当前工程：E:\anlo_project\liantiao\development\audio_crc。

当前现场诊断：`deliverable/voice_capture_20261023`（位于总工程根目录），
见[板上特征与具体拒识原因抓取](docs/板上语音抓取20261023.md)。在下述归一化
模型上增加USB串口特征/分数/原因输出，识别算法保持原值；HX无需更新。

2026-10-23 当前语音候选：[整句语速归一化与噪声增强](docs/语速与噪声鲁棒版20261023.md)。
保留整句、归一化快慢语速，重新训练时间卷积模型；保留音频抗干扰与语音阶段提示。
配套目录 `E:\anlo_project\liantiao\deliverable\voice_robust_20261023`。
ACA更新，HX沿用上一语音反馈码流。合成测试总体和快慢速改善，正常无噪声组退步，
未做真人实板验收，详见报告。实际模型位于 `voice/experiments/robust_normalized/model`，
`voice/model` 为旧版比较基线；旧模型专用回归与同步工具不适用于当前引擎。

2026-10-23 语音现场定位版：[语音状态反馈](docs/语音状态反馈20261023.md)。
基于本日抗干扰版增加语音阶段提示，模型与识别阈值保持原值；
配套发布目录为 `E:\anlo_project\liantiao\deliverable\voice_feedback_20261023`。

2026-10-23：在自动时钟恢复版基础上加入杜邦线抗干扰功能。
当前修改与复测说明见 [杜邦线抗干扰](docs/杜邦线抗干扰20261023.md)，
配套发布目录为 `E:\anlo_project\liantiao\deliverable\audio_antiglitch_20261023`。
下文 FX WAIT 发布记录为历史说明。

当前为 FX WAIT 时序修复版：[定位、已复现缺陷与屏幕诊断](docs/FX_WAIT定位与时序修复.md)。本轮发布目录为 E:\anlo_project\liantiao\deliverable\audio_crc_skewfix_20261021；前一版 audio_crc_20261021 保留追溯。

优先阅读 [音效CRC版验收说明](docs/音效CRC版验收.md)。本版提供原声、约85ms回声、低通、5Hz颤音；两板必须使用同一 CRC 版码流。音效在 ACA 实际计算，HX 接收完整 PCM 帧并送 HDMI。

旧版源码和码流已经单独备份，本目录的旧 deliverable/release_manifest.json 不代表本 CRC 版发布结果。新发布目录由 tools/package_checked_audio.py 生成，必须通过本轮仿真、源码绑定和两板时序检查。

工程入口：aca420/aca420_audio.al、hx4s20/contest_proj.al。

原图像缩放等操作及历史开发说明保存在 docs/README_历史20261020.md；下文是历史版本说明。
