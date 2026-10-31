`timescale 1ns/1ps

// ============================================================
// 模块名：audio_spectrum
// 功能：16柱分级音频幅值可视化（不执行 FFT，不代表频率分量）
//   - 16根柱子，每根40像素宽（38柱+2间隙），最大高度80像素
//   - 在 audio_valid 有效时累计帧内峰值，避免单拍 PCM 样本被漏采
//   - 峰值保持：每根柱顶白色峰值点，每帧衰减1级
//   - 半透明黑底：频谱区域背景亮度减半，不遮挡主画面
//   - 颜色渐变：底部绿→中部黄→顶部红
//   - 柱子高度 5bit(0~31)，零幅值对应零高度
// 时钟：video_clk (25.175MHz)
// ============================================================
module audio_spectrum #(
    parameter DATA_WIDTH  = 24,
    parameter FRAME_WIDTH = 640,
    parameter FRAME_HEIGHT= 480,
    parameter BAR_COUNT   = 16,
    parameter BAR_MAX_H   = 80,
    parameter BAR_START_X = 0,
    parameter BAR_START_Y = 400
)(
    input                       I_video_clk,
    input                       I_rst,
    input                       I_vs,
    input                       I_de,
    input      [DATA_WIDTH-1:0] I_rgb,
    input                       I_audio_valid,
    input      [23:0]           I_audio_left,
    input      [23:0]           I_audio_right,
    input                       I_spectrum_en,
    output reg [DATA_WIDTH-1:0] O_rgb_out
);

// ============================================================
// 音频幅值提取（左右声道平均，24bit 有符号 PCM 映射到 0~31）
// ============================================================
wire [23:0] left_abs  = I_audio_left[23]  ? (~I_audio_left  + 1'b1) : I_audio_left;
wire [23:0] right_abs = I_audio_right[23] ? (~I_audio_right + 1'b1) : I_audio_right;
wire [24:0] audio_sum = {1'b0, left_abs} + {1'b0, right_abs};
wire [23:0] audio_mag = audio_sum[24:1];
wire [4:0] audio_lvl = audio_mag[23] ? 5'd31 : audio_mag[22:18];

// ============================================================
// 帧同步（vs下降沿 = 新一帧开始）
// ============================================================
reg vs_d0;
always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) vs_d0 <= 1'b0;
    else       vs_d0 <= I_vs;
end
wire vs_falling = vs_d0 & ~I_vs;

// ============================================================
// 16根柱子高度寄存器 + 峰值保持寄存器
// 同一个幅值用不同门限展示，不能将这些柱子解读为 FFT 频谱。
// ============================================================
reg [4:0] bar_h [0:15];    // 16根柱子当前高度
reg [4:0] bar_peak [0:15]; // 16根柱子峰值
reg [4:0] frame_peak_lvl;
wire [4:0] frame_level = (I_audio_valid && (audio_lvl > frame_peak_lvl))
                        ? audio_lvl : frame_peak_lvl;

// 每根柱子采用不同幅值门限，所有柱子每帧同时更新。
wire [4:0] bar_target [0:15];
genvar gi;
generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : gen_bar_target
        assign bar_target[gi] = (frame_level > gi) ? (frame_level - gi) : 5'd0;
    end
endgenerate

// 包络在整帧中收集有效音频样本；帧边界采样并清空下一帧的累计器。
// 边界同拍的有效样本也计入当前帧。
always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        frame_peak_lvl <= 5'd0;
    end else if (vs_falling) begin
        frame_peak_lvl <= 5'd0;
    end else if (I_audio_valid && (audio_lvl > frame_peak_lvl)) begin
        frame_peak_lvl <= audio_lvl;
    end
end

// 柱子高度 + 峰值更新：快速上升、逐帧平滑下降。
integer bi;
always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        bar_h[0]<=5'd0; bar_h[1]<=5'd0; bar_h[2]<=5'd0; bar_h[3]<=5'd0;
        bar_h[4]<=5'd0; bar_h[5]<=5'd0; bar_h[6]<=5'd0; bar_h[7]<=5'd0;
        bar_h[8]<=5'd0; bar_h[9]<=5'd0; bar_h[10]<=5'd0; bar_h[11]<=5'd0;
        bar_h[12]<=5'd0; bar_h[13]<=5'd0; bar_h[14]<=5'd0; bar_h[15]<=5'd0;
        bar_peak[0]<=5'd0; bar_peak[1]<=5'd0; bar_peak[2]<=5'd0; bar_peak[3]<=5'd0;
        bar_peak[4]<=5'd0; bar_peak[5]<=5'd0; bar_peak[6]<=5'd0; bar_peak[7]<=5'd0;
        bar_peak[8]<=5'd0; bar_peak[9]<=5'd0; bar_peak[10]<=5'd0; bar_peak[11]<=5'd0;
        bar_peak[12]<=5'd0; bar_peak[13]<=5'd0; bar_peak[14]<=5'd0; bar_peak[15]<=5'd0;
    end else if (vs_falling) begin
        for (bi = 0; bi < 16; bi = bi + 1) begin
            if (bar_target[bi] >= bar_h[bi])
                bar_h[bi] <= bar_target[bi];
            else if (bar_h[bi] > 5'd0)
                bar_h[bi] <= bar_h[bi] - 1'b1;

            if (bar_target[bi] >= bar_peak[bi])
                bar_peak[bi] <= bar_target[bi];
            else if (bar_peak[bi] > 5'd0)
                bar_peak[bi] <= bar_peak[bi] - 1'b1;
        end
    end
end

// ============================================================
// 内部像素坐标计数器（由 I_de 驱动）
// ============================================================
reg [9:0] px_x;
reg [9:0] px_y;
reg       de_d0;

always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        px_x <= 10'd0; px_y <= 10'd0; de_d0 <= 1'b0;
    end else begin
        de_d0 <= I_de;
        if (vs_falling) px_y <= 10'd0;
        else if (de_d0 && !I_de && (px_y < FRAME_HEIGHT - 1))
            px_y <= px_y + 1'b1;
        if (I_de) begin
            if (px_x < FRAME_WIDTH - 1) px_x <= px_x + 1'b1;
            else px_x <= 10'd0;
        end else px_x <= 10'd0;
    end
end

// ============================================================
// 像素坐标 → 柱子映射
//   16根柱，每根40像素宽（38柱体+2间隙）
//   柱高映射：level(0~31) → 像素高(0~62)：height = level*2
// ============================================================
wire in_spectrum_y = (px_y >= BAR_START_Y) && (px_y < (BAR_START_Y + BAR_MAX_H));
localparam integer BAR_WIDTH = FRAME_WIDTH / BAR_COUNT;
wire in_spectrum_x = (px_x >= BAR_START_X) && (px_x < BAR_START_X + FRAME_WIDTH);
wire in_spectrum = I_de && in_spectrum_x && in_spectrum_y && I_spectrum_en;

reg [3:0] bar_idx;
integer map_idx;
always @(*) begin
    bar_idx = 4'd0;
    for (map_idx = 1; map_idx < BAR_COUNT; map_idx = map_idx + 1)
        if (px_x >= BAR_START_X + map_idx * BAR_WIDTH)
            bar_idx = map_idx;
end
wire [9:0] bar_x_off = px_x - BAR_START_X - bar_idx * BAR_WIDTH;
wire in_bar_body = (bar_x_off >= 10'd1) && (bar_x_off < BAR_WIDTH - 1);

// 当前柱子高度和峰值（level 0~31）
wire [4:0] cur_h = bar_h[bar_idx];
wire [4:0] cur_peak = bar_peak[bar_idx];

// 零幅值不绘制最小柱，避免静音时仍显示固定的 8 像素高度。
wire [6:0] cur_h_px = {cur_h, 1'b0};
wire [6:0] cur_peak_px = {cur_peak, 1'b0};

// 从底部往上的偏移量
wire [9:0] bar_bottom = BAR_START_Y + BAR_MAX_H - 1;
wire [6:0] bar_offset = bar_bottom - px_y;  // 0~79

// 当前像素是否在柱体内、峰值点内
wire in_bar = in_bar_body && (bar_offset < cur_h_px);
wire in_peak = in_bar_body && (bar_offset == cur_peak_px) && (cur_peak > 5'd0);

// ============================================================
// 柱子颜色渐变（底部绿→中部黄→顶部红）
//   bar_offset 0~79，分3段：
//   0~26: 绿(00FF00)→黄(FFFF00)  27~53: 黄→红  54~79: 红
// ============================================================
reg [23:0] bar_color;
always @(*) begin
    if (bar_offset < 7'd27)
        bar_color = 24'h00FF00;        // 绿
    else if (bar_offset < 7'd54)
        bar_color = 24'hFFFF00;        // 黄
    else
        bar_color = 24'hFF0000;        // 红
end

// 峰值点颜色：白色
wire [23:0] peak_color = 24'hFFFFFF;

// ============================================================
// 半透明黑底：频谱区域背景亮度减半
// ============================================================
wire [7:0] bg_r = I_rgb[23:16] >> 1;
wire [7:0] bg_g = I_rgb[15:8]  >> 1;
wire [7:0] bg_b = I_rgb[7:0]   >> 1;
wire [23:0] bg_dim = {bg_r, bg_g, bg_b};

// ============================================================
// 输出混合
//   优先级：峰值点 > 柱体 > 半透明黑底 > 原图
// ============================================================
always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst)
        O_rgb_out <= {DATA_WIDTH{1'b0}};
    else if (in_spectrum) begin
        if (in_peak)
            O_rgb_out <= peak_color;       // 峰值白点（最高优先级）
        else if (in_bar)
            O_rgb_out <= bar_color;        // 柱体
        else
            O_rgb_out <= bg_dim;           // 半透明黑底
    end else
        O_rgb_out <= I_rgb;               // 频谱区域外：原图
end

endmodule
