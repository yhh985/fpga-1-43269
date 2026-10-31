`timescale 1ns/1ps

// ============================================================
// 模块名：image_enhance
// 功能：图像增强统一管道 —— 对比度调节 + 亮度调节
//   对比度：out = (in - 128) × gain + 128  (gain=0x~1.9375x)
//   亮度：  out = in + offset                 (offset=-128~+120)
//   4级流水线：中心化→乘法→对比度饱和→亮度偏移+饱和
//   I_rst_bright=1 脉冲：亮度恢复默认16
//   I_rst_contrast=1 脉冲：对比度恢复默认16
// 参考：Hardware Accelerated Image Processing Toolkit
//       (mummanajagadeesh.github.io) 线性变换公式
// ============================================================
module image_enhance #(
    parameter DATA_WIDTH = 24
)(
    input                       I_clk,          // 系统时钟50MHz（按键域）
    input                       I_rst,          // 高有效复位
    input                       I_video_clk,    // 视频时钟25.175MHz（像素域）
    input      [DATA_WIDTH-1:0] I_rgb,          // 输入RGB
    input      [4:0]            I_brightness,   // 亮度 0~31（16=默认）
    input      [4:0]            I_contrast,     // 对比度 0~31（16=默认）
    input                       I_rst_bright,   // 脉冲：亮度恢复默认
    input                       I_rst_contrast, // 脉冲：对比度恢复默认
    output reg [DATA_WIDTH-1:0] O_rgb_out       // 输出RGB
);

// ============================================================
// 亮度/对比度参数寄存器（clk域，按键消抖后写入）
// ============================================================
reg [4:0] brightness_r;
reg [4:0] contrast_r;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        brightness_r <= 5'd16;
        contrast_r   <= 5'd16;
    end else begin
        brightness_r <= I_rst_bright ? 5'd16 : I_brightness;
        contrast_r   <= I_rst_contrast ? 5'd16 : I_contrast;
    end
end

// ============================================================
// 参数同步到 video_clk 域（3级打拍，避免亚稳态）
// ============================================================
reg [4:0] bright_sync0, bright_sync1, bright_sync2;
reg [4:0] contr_sync0,  contr_sync1,  contr_sync2;

always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        bright_sync0 <= 5'd16; bright_sync1 <= 5'd16; bright_sync2 <= 5'd16;
        contr_sync0  <= 5'd16; contr_sync1  <= 5'd16; contr_sync2  <= 5'd16;
    end else begin
        bright_sync0 <= brightness_r;
        bright_sync1 <= bright_sync0;
        bright_sync2 <= bright_sync1;
        contr_sync0  <= contrast_r;
        contr_sync1  <= contr_sync0;
        contr_sync2  <= contr_sync1;
    end
end

// ============================================================
// 对比度增益查找表（Q1.7定点数，128=1.0x）
//   修正：contrast=16 → 128（1.0x，无变化）
//   contrast=0  → 0   (0x，全灰128)
//   contrast=31 → 248 (~1.94x)
//   公式：gain = 128 + (contrast - 16) × 8
// ============================================================
reg [7:0] contrast_gain;
always @(*) begin
    case (contr_sync2)
        5'd0:  contrast_gain = 8'd0;
        5'd1:  contrast_gain = 8'd8;
        5'd2:  contrast_gain = 8'd16;
        5'd3:  contrast_gain = 8'd24;
        5'd4:  contrast_gain = 8'd32;
        5'd5:  contrast_gain = 8'd40;
        5'd6:  contrast_gain = 8'd48;
        5'd7:  contrast_gain = 8'd56;
        5'd8:  contrast_gain = 8'd64;
        5'd9:  contrast_gain = 8'd72;
        5'd10: contrast_gain = 8'd80;
        5'd11: contrast_gain = 8'd88;
        5'd12: contrast_gain = 8'd96;
        5'd13: contrast_gain = 8'd104;
        5'd14: contrast_gain = 8'd112;
        5'd15: contrast_gain = 8'd120;
        5'd16: contrast_gain = 8'd128;
        5'd17: contrast_gain = 8'd136;
        5'd18: contrast_gain = 8'd144;
        5'd19: contrast_gain = 8'd152;
        5'd20: contrast_gain = 8'd160;
        5'd21: contrast_gain = 8'd168;
        5'd22: contrast_gain = 8'd176;
        5'd23: contrast_gain = 8'd184;
        5'd24: contrast_gain = 8'd192;
        5'd25: contrast_gain = 8'd200;
        5'd26: contrast_gain = 8'd208;
        5'd27: contrast_gain = 8'd216;
        5'd28: contrast_gain = 8'd224;
        5'd29: contrast_gain = 8'd232;
        5'd30: contrast_gain = 8'd240;
        5'd31: contrast_gain = 8'd248;
        default: contrast_gain = 8'd128;
    endcase
end

// ============================================================
// 亮度偏移量：brightness=16 → offset=0
//   brightness=0  → -128
//   brightness=31 → +120
//   offset = (brightness - 16) × 8
// ============================================================
wire signed [9:0] bright_offset = $signed({1'b0, bright_sync2} - 5'd16) * $signed(7'd8);

// ============================================================
// 4级流水线：中心化 → 乘法 → 对比度饱和 → 亮度偏移+饱和
// ============================================================

// ---- 第1级：像素值 - 128（中心化）----
reg signed [8:0] cent_r, cent_g, cent_b;  // 有符号：-128 ~ +127

always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        cent_r <= 9'sd0; cent_g <= 9'sd0; cent_b <= 9'sd0;
    end else begin
        cent_r <= $signed({1'b0, I_rgb[23:16]}) - $signed(9'd128);
        cent_g <= $signed({1'b0, I_rgb[15:8]})  - $signed(9'd128);
        cent_b <= $signed({1'b0, I_rgb[7:0]})   - $signed(9'd128);
    end
end

// ---- 第2级：× contrast_gain (Q1.7定点) ----
reg signed [16:0] mul_r, mul_g, mul_b;  // 9bit × 8bit = 17bit有符号

always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        mul_r <= 17'sd0; mul_g <= 17'sd0; mul_b <= 17'sd0;
    end else begin
        mul_r <= cent_r * $signed({1'b0, contrast_gain});
        mul_g <= cent_g * $signed({1'b0, contrast_gain});
        mul_b <= cent_b * $signed({1'b0, contrast_gain});
    end
end

// ---- 第3级：>>7 + 128，对比度结果饱和截断到 0~255 ----
reg [7:0] contr_r_sat, contr_g_sat, contr_b_sat;
wire signed [9:0] contr_r_raw = (mul_r >>> 7) + $signed(9'd128);
wire signed [9:0] contr_g_raw = (mul_g >>> 7) + $signed(9'd128);
wire signed [9:0] contr_b_raw = (mul_b >>> 7) + $signed(9'd128);

always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        contr_r_sat <= 8'd0; contr_g_sat <= 8'd0; contr_b_sat <= 8'd0;
    end else begin
        contr_r_sat <= (contr_r_raw > $signed(9'd255)) ? 8'd255 :
                        (contr_r_raw < $signed(9'd0))   ? 8'd0   : contr_r_raw[7:0];
        contr_g_sat <= (contr_g_raw > $signed(9'd255)) ? 8'd255 :
                        (contr_g_raw < $signed(9'd0))   ? 8'd0   : contr_g_raw[7:0];
        contr_b_sat <= (contr_b_raw > $signed(9'd255)) ? 8'd255 :
                        (contr_b_raw < $signed(9'd0))   ? 8'd0   : contr_b_raw[7:0];
    end
end

// ---- 第4级：+ 亮度偏移，最终饱和截断到 0~255 ----
reg [7:0] out_r, out_g, out_b;
wire signed [9:0] final_r = $signed({1'b0, contr_r_sat}) + bright_offset;
wire signed [9:0] final_g = $signed({1'b0, contr_g_sat}) + bright_offset;
wire signed [9:0] final_b = $signed({1'b0, contr_b_sat}) + bright_offset;

always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        out_r <= 8'd0; out_g <= 8'd0; out_b <= 8'd0;
    end else begin
        out_r <= (final_r > $signed(9'd255)) ? 8'd255 :
                 (final_r < $signed(9'd0))   ? 8'd0   : final_r[7:0];
        out_g <= (final_g > $signed(9'd255)) ? 8'd255 :
                 (final_g < $signed(9'd0))   ? 8'd0   : final_g[7:0];
        out_b <= (final_b > $signed(9'd255)) ? 8'd255 :
                 (final_b < $signed(9'd0))   ? 8'd0   : final_b[7:0];
    end
end

always @(*) O_rgb_out = {out_r, out_g, out_b};

endmodule
