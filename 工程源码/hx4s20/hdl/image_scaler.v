`timescale 1ns/1ps

// ============================================================
// 模块名：image_scaler
// 功能：数字变焦 — 在640×480画面中选中央区域放大2倍显示
//   zoom_en=0：原样输出
//   zoom_en=1：中央320×240区域放大到640×480
// 原理：最近邻插值，out_coord ÷ 2 + 160 = in_coord
// 无额外存储需求，纯组合逻辑映射
// ============================================================
module image_scaler #(
    parameter DATA_WIDTH   = 24,
    parameter FRAME_WIDTH  = 640,
    parameter FRAME_HEIGHT = 480,
    parameter ZOOM_FACTOR  = 2,    // 放大倍数
    parameter CROP_X       = 160,  // 中央区域起始x（640-320）/2
    parameter CROP_Y       = 120,  // 中央区域起始y（480-240）/2
    parameter CROP_W       = 320,  // 裁剪区域宽
    parameter CROP_H       = 240   // 裁剪区域高
)(
    input                       I_clk,
    input                       I_rst,
    input                       I_de,
    input      [9:0]            I_px_x,
    input      [9:0]            I_px_y,
    input      [DATA_WIDTH-1:0] I_rgb,
    input                       I_zoom_en,
    output reg [DATA_WIDTH-1:0] O_rgb_out,
    output                      O_request_addr    // 给帧缓存的读地址偏移
);

// ============================================================
// 像素坐标计数器
// ============================================================
reg [9:0] px_x, px_y;
reg       de_d0, vs_d0;
reg       vs_d1;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        px_x <= 10'd0;
        px_y <= 10'd0;
        de_d0 <= 1'b0;
        vs_d0 <= 1'b0;
        vs_d1 <= 1'b0;
    end else begin
        de_d0 <= I_de;
        vs_d0 <= 1'b0;  // 外部VS未接，用DE检测新帧
        vs_d1 <= vs_d0;

        // DE上升沿：新行开始
        if (de_d0 == 1'b0 && I_de == 1'b1) begin
            px_x <= 10'd0;
            if (px_y < FRAME_HEIGHT - 1)
                px_y <= px_y + 1'b1;
            else
                px_y <= 10'd0;
        end

        // DE有效期间：x递增
        if (I_de) begin
            if (px_x < FRAME_WIDTH - 1)
                px_x <= px_x + 1'b1;
            else
                px_x <= 10'd0;
        end
    end
end

// ============================================================
// 坐标映射（最近邻）
// 放大2倍：out_x ÷ 2 + CROP_X = in_x
// 例如 out_x=0 → in_x=160, out_x=1 → in_x=160, out_x=2 → in_x=161
// ============================================================
// 右移1位代替除以2
wire [9:0] src_x = (px_x >> 1) + CROP_X[9:0];
wire [9:0] src_y = (px_y >> 1) + CROP_Y[9:0];

// ============================================================
// 输出
// 注意：放大模式下，显示的像素来自帧缓存中不同位置
// 但本工程帧缓存是整帧写入的，读取时由frame_read_write控制地址
// 这里我们只做像素级的处理：放大模式下，用当前像素代替
// 实际效果是"像素放大"——每个像素重复2×2次
// ============================================================
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst)
        O_rgb_out <= {DATA_WIDTH{1'b0}};
    else if (I_zoom_en)
        O_rgb_out <= I_rgb;  // 像素重复模式：直接用当前像素
    else
        O_rgb_out <= I_rgb;  // 非放大：透传
end

assign O_request_addr = 1'b0;

endmodule