# 从头复审与公开源码对照（2026-10-18）

工程根目录：`E:\anlo_project\liantiao`。复审对象包括HX缩放、BMP/FAT32/SD调度、双帧显存切换、跨时钟传递、按键和OSD，ACA语音许可及数字音效，以及两板构建和交付校验。

## 发现与处理

1. **构建与源码缺少直接绑定。** 旧版本在打包时记录当前源码哈希，但不能单凭该记录证明已有bit由当前源码生成。新增 `tools/build_verified.py`：构建前记录TD声明源文件及HDL/include/ROM/模型/约束依赖，构建后再次核对输入、全新完成标记、码流时间与建立/保持时序，保存 `verified_build_inputs.json`；TD保存的最终工程配置也计入输出锁定。打包和最终校验均核对输入与输出哈希。两板使用此流程重新构建。
2. **失败的专项仿真可能遗留旧总报告。** 缩放及音乐运行脚本现在先撤销旧通过清单，全部用例成功才写入新清单；打包同时检查精确用例集合、逐项日志与汇总一致性，并统一Windows CRLF与Python读取后的换行表示，避免新生成的合法报告因换行差异被拒绝。音乐 `-Focused` 仍按设计保留未重跑的长用例结果，完整复审使用全量运行。
3. **原缩放像素测试逐帧复位，缺少连续使用证据。** 新增16帧不复位的倍率/尺寸切换、延迟目的端确认、输入请求保持、处理中改变实时倍率检查。原40组边界和640×480逐像素参考测试保留。
4. **原调度测试未覆盖错误确认和控制碰撞。** 补充错误缓冲区ACK不能放行写入、缩放与手动NEXT/语音PREV同时排队时的目标图片、扇区、倍率、优先级和重复加载次数检查。

本轮未更换功能RTL。逐段检查了定点坐标及余数累加、有符号插值位宽、两行缓存读写顺序、裁切后源数据排空、valid停顿保持、源/显存双完成事件和读帧所有权。新增测试用于检查尚未覆盖的运行场景，未发现需要改变这些功能的可复现错误。

## 网上源码参考及取舍

| 实际读取的公开实现 | 用于对照的设计 | 本工程处理 |
|---|---|---|
| [OpenCores Video Stream Scaler](https://github.com/freecores/video_stream_scaler/blob/master/rtl/verilog/scaler.v)，David Kronstein，LGPL-2.1-or-later | 双线性/最近邻、定点坐标、行缓存、裁切偏移；源码还披露系数量化误差 | 复核本工程Q8坐标、分步插值、边界和舍入，保留独立逐像素整数参考；未直接移植该模块 |
| [Project F linebuffer_simple](https://github.com/projf/projf-explore/blob/main/lib/display/linebuffer_simple.sv)，Will Green，MIT | 行缓冲与按输出使能推进缩放计数 | 对照缓存地址推进和行边界；该例是整数重复采样，本工程需0.5/1.5倍双线性，保留现有两行结构 |
| [verilog-axis axis_register](https://github.com/alexforencich/verilog-axis/blob/master/rtl/axis_register.v)，Alex Forencich，MIT | simple register/skid buffer，valid/ready停顿时保留数据 | 借鉴握手核查方式，补充目的端确认延迟、请求保持和连续帧检查；本工程SD输入速率允许现有带空拍单槽，不增加完整skid流水线 |

已读取的源码快照、下载URL和SHA256保存在 `research/zoom_review_20261018/` 与其中的 `sources.json`，版权头和许可证一并保留。外部代码仅作为研究参考，不在两板TD综合源文件中。较新的bilinear-image-scaler-axistream项目仅阅读了README作架构背景，未据其演示结果认定本工程可上板通过。

HX当前LUT和BRAM占用已较高。本次借鉴集中在坐标/缓存/握手的设计检查与验证，保留串行复用乘法器及双帧显存；完整移植多通道并行流水线会改变资源、延迟、接口及约束，缺少本板收益依据。

## 验证清单

- 缩放7项专项：40组尺寸/倍率、640×480输出8帧共2457600像素、非等比例兼容、连续16帧、调度边界、OSD倍率和小数点、显示运算983040像素等价。
- 音乐12项：播放列表/上限8首、分散簇WAV、首尾与NEXT/PREV、真实串行音频音效及6组跨板相位/延迟；SD集成含12146个立体声帧和270次原生读事务。
- 通用11项、ACA5项、HX实际顶层按键和视频流水线2项；语音调度单独复核。
- 语音整数对照：Mel能量、65184个PCM样本/672个特征、200组MLP三路logit、652帧连续端点行为；重新导出ACA综合网表并审计37008字节权重、40个物理权重RAM。
- 构建来源7项正/负向检查：未改动通过；修改HDL、ROM、声明源清单、工程配置选项、码流及丢失完成标记均拒绝。
- 两板从综合到布局布线、时序和码流重新生成；对应结果以 `deliverable/release_manifest.json`、各板 `verified_build_inputs.json` 为准。

复现：`./voice/run_voice.ps1 -Build`。构建包装器可单板运行：`python tools/build_verified.py aca420` 或 `python tools/build_verified.py hx4s20`；随后执行 `tools/package_music_release.py` 和 `verification/check_final_delivery.py` 完成交付核对。

## 使用边界

本报告属于代码、仿真和FPGA内部实现审查。未进行实体板、真实SD卡、杜邦线时序、HDMI显示器或真人独立语音测试，不能作实板验收。语音模型保持原样，既有92.5%为开发期留出合成语音结果，不代表真人泛化正确率。缩放会重新从卡读取当前BMP，不能承诺连续视频帧率、无等待的动画缩放或任意大图支持；BMP尺寸限制仍为每边1至1024像素。缩小采用双线性插值，尚无额外抗混叠滤波，细密纹理可能出现摩尔纹。
