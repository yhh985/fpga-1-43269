`timescale 1ns/1ps

// ============================================================
// 模块名：color_filter
// 功能：7种色彩滤镜
//   mode=000:原图(ORIG)  001:灰度(GRY)  010:反色(INV)  011:怀旧(SEPIA)
//   mode=100:冷色(COOL)  101:暖色(WARM)  110:二值(BIN)
// 原理：逐像素组合逻辑处理，寄存器流水1拍
//   灰度: Y=(76*R+150*G+30*B)>>8 (BT.601)
//   反色: out=~in
//   Sepia: R'=(101R+199G+49B)>>8, G'=(90R+176G+43B)>>8, B'=(70R+137G+34B)>>8
//   冷色: R*0.8, G*0.9, B*1.2(饱和)
//   暖色: R*1.2(饱和), G*1.0, B*0.8
//   二值: Y>128 ? 白 : 黑
// ============================================================
module color_filter #(
    parameter DATA_WIDTH = 24
)(
    input                       I_clk,
    input                       I_rst,
    input      [2:0]            I_mode,         // 3位模式选择(0~6)
    input      [DATA_WIDTH-1:0] I_rgb,           // 输入RGB
    output reg [DATA_WIDTH-1:0] O_rgb_out        // 输出RGB
);

// 输入通道分离
wire [7:0] r_in = I_rgb[23:16];
wire [7:0] g_in = I_rgb[15:8];
wire [7:0] b_in = I_rgb[7:0];

// ============================================================
// 灰度计算: Y = (76*R + 150*G + 30*B) >> 8
// ============================================================
wire [15:0] gray_r = 8'd76  * r_in;
wire [15:0] gray_g = 8'd150 * g_in;
wire [15:0] gray_b = 8'd30  * b_in;
wire [17:0] gray_sum = {2'b0, gray_r} + {2'b0, gray_g} + {2'b0, gray_b};
wire [7:0] gray_val = gray_sum[15:8];

// ============================================================
// 反色计算: out = ~in
// ============================================================
wire [7:0] inv_r = ~r_in;
wire [7:0] inv_g = ~g_in;
wire [7:0] inv_b = ~b_in;

// ============================================================
// Sepia计算(标准怀旧矩阵)
// ============================================================
wire [15:0] sep_r_r = 8'd101 * r_in;
wire [15:0] sep_r_g = 8'd199 * g_in;
wire [15:0] sep_r_b = 8'd49  * b_in;
wire [17:0] sep_r_sum = {2'b0, sep_r_r} + {2'b0, sep_r_g} + {2'b0, sep_r_b};
wire [7:0] sep_r = (sep_r_sum > 18'd65535) ? 8'd255 : sep_r_sum[15:8];

wire [15:0] sep_g_r = 8'd90  * r_in;
wire [15:0] sep_g_g = 8'd176 * g_in;
wire [15:0] sep_g_b = 8'd43  * b_in;
wire [17:0] sep_g_sum = {2'b0, sep_g_r} + {2'b0, sep_g_g} + {2'b0, sep_g_b};
wire [7:0] sep_g = (sep_g_sum > 18'd65535) ? 8'd255 : sep_g_sum[15:8];

wire [15:0] sep_b_r = 8'd70  * r_in;
wire [15:0] sep_b_g = 8'd137 * g_in;
wire [15:0] sep_b_b = 8'd34  * b_in;
wire [17:0] sep_b_sum = {2'b0, sep_b_r} + {2'b0, sep_b_g} + {2'b0, sep_b_b};
wire [7:0] sep_b = (sep_b_sum > 18'd65535) ? 8'd255 : sep_b_sum[15:8];

// ============================================================
// 冷色(COOL): R*0.8, G*0.9, B*1.2(饱和到255)
//   0.8=204/256, 0.9=230/256, 1.2=307/256
// ============================================================
wire [15:0] cool_r_mult = 8'd204 * r_in;
wire [15:0] cool_g_mult = 8'd230 * g_in;
// 1.2x 系数307需要9位；最大乘积255*307=78285需要17位。
wire [16:0] cool_b_mult = 9'd307 * b_in;
wire [7:0] cool_r = cool_r_mult[15:8];
wire [7:0] cool_g = cool_g_mult[15:8];
wire [7:0] cool_b = (cool_b_mult > 17'd65280) ? 8'd255 : cool_b_mult[15:8];

// ============================================================
// 暖色(WARM): R*1.2(饱和), G*1.0, B*0.8
// ============================================================
wire [16:0] warm_r_mult = 9'd307 * r_in;
wire [15:0] warm_b_mult = 8'd204 * b_in;
wire [7:0] warm_r = (warm_r_mult > 17'd65280) ? 8'd255 : warm_r_mult[15:8];
wire [7:0] warm_g = g_in;
wire [7:0] warm_b = warm_b_mult[15:8];

// ============================================================
// 二值(BIN): 灰度值 > 128 ? 白(255) : 黑(0)
// ============================================================
wire [7:0] bin_val = (gray_val > 8'd128) ? 8'd255 : 8'd0;

// ============================================================
// 模式选择输出(7种 + 默认原图)
// ============================================================
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst)
        O_rgb_out <= {DATA_WIDTH{1'b0}};
    else begin
        case (I_mode)
            3'd0: O_rgb_out <= I_rgb;                              // 000 原色
            3'd1: O_rgb_out <= {gray_val, gray_val, gray_val};     // 001 灰度
            3'd2: O_rgb_out <= {inv_r, inv_g, inv_b};              // 010 反色
            3'd3: O_rgb_out <= {sep_r, sep_g, sep_b};              // 011 怀旧
            3'd4: O_rgb_out <= {cool_r, cool_g, cool_b};           // 100 冷色
            3'd5: O_rgb_out <= {warm_r, warm_g, warm_b};           // 101 暖色
            3'd6: O_rgb_out <= {bin_val, bin_val, bin_val};        // 110 二值
            default: O_rgb_out <= I_rgb;                             // 111 原图(兜底)
        endcase
    end
end

endmodule
