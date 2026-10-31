`timescale 1ns/1ps

// ============================================================
// 模块名：osd_overlay（中文灰度字模版 + 右上角模式提示）
// 功能：
//   1. 画面顶部叠加中文状态（微软雅黑16×16，4级灰度抗锯齿）
//      显示格式："图03 原色 亮16"（10字符）
//   2. K4切换模式时，右上角显示"图片模式"/"亮度模式"/"对比模式"
//      持续约1秒后自动消失（I_mode_change由顶层计时）
// 时钟：video_clk (25.175MHz)
// ============================================================
module osd_overlay #(
    parameter DATA_WIDTH   = 24,
    parameter FRAME_WIDTH  = 640,
    parameter FRAME_HEIGHT = 480,
    parameter OSD_START_X  = 240,
    parameter OSD_START_Y  = 8
)(
    input                       I_clk,
    input                       I_rst,
    input                       I_vs,
    input                       I_hs,
    input                       I_de,
    input      [DATA_WIDTH-1:0] I_rgb,
    input      [6:0]            I_img_idx,
    input      [2:0]            I_filter_mode,
    input      [4:0]            I_brightness,
    input      [4:0]            I_contrast,
    input      [1:0]            I_op_mode,
    input                       I_mode_change,
    input                       I_osd_en,
    output reg [DATA_WIDTH-1:0] O_rgb_out
);

reg [9:0] px_x;
reg [9:0] px_y;
reg       vs_d0, de_d0;
wire vs_falling = vs_d0 & ~I_vs;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin px_x<=0; px_y<=0; vs_d0<=0; de_d0<=0; end
    else begin
        vs_d0<=I_vs; de_d0<=I_de;
        // 输出 always 在时钟沿读取当前坐标；首像素/首行均从0开始。
        if (I_de) begin if(px_x<FRAME_WIDTH-1) px_x<=px_x+1; else px_x<=0; end
        else px_x<=0;
        if (vs_falling) px_y<=0;
        else if (de_d0 && !I_de && px_y<FRAME_HEIGHT-1) px_y<=px_y+1;
    end
end

// ============= 主OSD区域（顶部中间） =============
wire in_osd_x = (px_x>=OSD_START_X) && (px_x<OSD_START_X+160);
wire in_osd_y = (px_y>=OSD_START_Y) && (px_y<OSD_START_Y+16);
wire in_osd   = in_osd_x && in_osd_y && I_osd_en;

wire [7:0] offset_x = px_x - OSD_START_X;
wire [3:0] char_idx = offset_x[7:4];
wire [3:0] char_x   = offset_x[3:0];
wire [9:0] offset_y = px_y - OSD_START_Y;
wire [3:0] char_y   = offset_y[3:0];

// ============= 右上角模式提示区域 =============
localparam MODE_START_X = 10'd544;
localparam MODE_START_Y = 10'd8;
wire in_mode_x = (px_x>=MODE_START_X) && (px_x<MODE_START_X+64);
wire in_mode_y = (px_y>=MODE_START_Y) && (px_y<MODE_START_Y+16);
wire in_mode   = in_mode_x && in_mode_y && I_mode_change;

wire [7:0] mode_offset_x = px_x - MODE_START_X;
wire [3:0] mode_char_idx = mode_offset_x[5:4];
wire [3:0] mode_char_x   = mode_offset_x[3:0];
wire [9:0] mode_offset_y = px_y - MODE_START_Y;
wire [3:0] mode_char_y   = mode_offset_y[3:0];

// 模式→4个中文字符索引
// 0=图 4=度 12=亮 24=片 25=模 26=式 27=对 28=比
reg [4:0] mode_c0, mode_c1, mode_c2, mode_c3;
always @(*) begin
    case(I_op_mode)
        2'd0: begin mode_c0=0;  mode_c1=24; mode_c2=25; mode_c3=26; end
        2'd1: begin mode_c0=12; mode_c1=4;  mode_c2=25; mode_c3=26; end
        2'd2: begin mode_c0=27; mode_c1=28; mode_c2=25; mode_c3=26; end
        default: begin mode_c0=0; mode_c1=24; mode_c2=25; mode_c3=26; end
    endcase
end

reg [4:0] mode_char_sel;
always @(*) begin
    case(mode_char_idx)
        4'd0: mode_char_sel = mode_c0;
        4'd1: mode_char_sel = mode_c1;
        4'd2: mode_char_sel = mode_c2;
        4'd3: mode_char_sel = mode_c3;
        default: mode_char_sel = 5'd31;
    endcase
end

// ============= 主OSD字符映射 =============
reg [4:0] img_tens, img_ones;
`include "decimal_two_digits.vh"
wire [7:0] image_digits=decimal_two_digits(I_img_idx);
always @(*) begin
    img_tens=5'd14+image_digits[7:4];
    img_ones=5'd14+image_digits[3:0];
end

reg [4:0] bright_tens, bright_ones;
wire [4:0] display_parameter = (I_op_mode == 2'd2) ? I_contrast : I_brightness;
always @(*) begin
    case(display_parameter)
        5'd0:  begin bright_tens=14; bright_ones=14; end
        5'd1:  begin bright_tens=14; bright_ones=15; end
        5'd2:  begin bright_tens=14; bright_ones=16; end
        5'd3:  begin bright_tens=14; bright_ones=17; end
        5'd4:  begin bright_tens=14; bright_ones=18; end
        5'd5:  begin bright_tens=14; bright_ones=19; end
        5'd6:  begin bright_tens=14; bright_ones=20; end
        5'd7:  begin bright_tens=14; bright_ones=21; end
        5'd8:  begin bright_tens=14; bright_ones=22; end
        5'd9:  begin bright_tens=14; bright_ones=23; end
        5'd10: begin bright_tens=15; bright_ones=14; end
        5'd11: begin bright_tens=15; bright_ones=15; end
        5'd12: begin bright_tens=15; bright_ones=16; end
        5'd13: begin bright_tens=15; bright_ones=17; end
        5'd14: begin bright_tens=15; bright_ones=18; end
        5'd15: begin bright_tens=15; bright_ones=19; end
        5'd16: begin bright_tens=15; bright_ones=20; end
        5'd17: begin bright_tens=15; bright_ones=21; end
        5'd18: begin bright_tens=15; bright_ones=22; end
        5'd19: begin bright_tens=15; bright_ones=23; end
        5'd20: begin bright_tens=16; bright_ones=14; end
        5'd21: begin bright_tens=16; bright_ones=15; end
        5'd22: begin bright_tens=16; bright_ones=16; end
        5'd23: begin bright_tens=16; bright_ones=17; end
        5'd24: begin bright_tens=16; bright_ones=18; end
        5'd25: begin bright_tens=16; bright_ones=19; end
        5'd26: begin bright_tens=16; bright_ones=20; end
        5'd27: begin bright_tens=16; bright_ones=21; end
        5'd28: begin bright_tens=16; bright_ones=22; end
        5'd29: begin bright_tens=16; bright_ones=23; end
        5'd30: begin bright_tens=17; bright_ones=14; end
        5'd31: begin bright_tens=17; bright_ones=15; end
        default: begin bright_tens=14; bright_ones=14; end
    endcase
end

reg [4:0] filter_c0, filter_c1;
always @(*) begin
    case(I_filter_mode)
        3'd0: begin filter_c0=1;  filter_c1=2;  end
        3'd1: begin filter_c0=3;  filter_c1=4;  end
        3'd2: begin filter_c0=5;  filter_c1=2;  end
        3'd3: begin filter_c0=6;  filter_c1=7;  end
        3'd4: begin filter_c0=8;  filter_c1=2;  end
        3'd5: begin filter_c0=9;  filter_c1=2;  end
        3'd6: begin filter_c0=10; filter_c1=11; end
        default: begin filter_c0=1; filter_c1=2; end
    endcase
end

reg [4:0] char_sel;
always @(*) begin
    case(char_idx)
        4'd0: char_sel=0;
        4'd1: char_sel=img_tens;
        4'd2: char_sel=img_ones;
        4'd3: char_sel=31;
        4'd4: char_sel=filter_c0;
        4'd5: char_sel=filter_c1;
        4'd6: char_sel=31;
        4'd7: char_sel=(I_op_mode == 2'd2) ? 27 : 12;
        4'd8: char_sel=bright_tens;
        4'd9: char_sel=bright_ones;
        default: char_sel=31;
    endcase
end

// ============= 字模ROM（主OSD和模式提示共用） =============
reg [4:0] rom_char_sel;
reg [3:0] rom_char_y;
reg [3:0] rom_char_x;
always @(*) begin
    if (in_mode) begin
        rom_char_sel = mode_char_sel;
        rom_char_y   = mode_char_y;
        rom_char_x   = mode_char_x;
    end else begin
        rom_char_sel = char_sel;
        rom_char_y   = char_y;
        rom_char_x   = char_x;
    end
end

reg [31:0] font_row;
always @(*) begin
    case(rom_char_sel)
`include "cn_font_rom_body.vh"
    endcase
end

wire [1:0] gray_level = font_row[31 - {rom_char_x, 1'b0} -: 2];

wire [7:0] bg_r = I_rgb[23:16] >> 1;
wire [7:0] bg_g = I_rgb[15:8]  >> 1;
wire [7:0] bg_b = I_rgb[7:0]   >> 1;

reg [7:0] mix_r, mix_g, mix_b;
always @(*) begin
    case(gray_level)
        2'd0: begin mix_r=bg_r; mix_g=bg_g; mix_b=bg_b; end
        2'd1: begin mix_r=bg_r-(bg_r>>2)+8'd64; mix_g=bg_g-(bg_g>>2)+8'd64; mix_b=bg_b-(bg_b>>2)+8'd64; end
        2'd2: begin mix_r=(bg_r>>1)+8'd128; mix_g=(bg_g>>1)+8'd128; mix_b=(bg_b>>1)+8'd128; end
        2'd3: begin mix_r=8'd255; mix_g=8'd255; mix_b=8'd255; end
    endcase
end

wire in_any_osd = in_mode | in_osd;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) O_rgb_out <= 0;
    else if (in_any_osd) O_rgb_out <= {mix_r, mix_g, mix_b};
    else O_rgb_out <= I_rgb;
end

endmodule
