//====================================================================
// test_pattern_gen.v — 多图测试图发生器（8张图，支持切换）
//
// 8张测试图：
//   0: 8色竖条 + 底部灰度台阶（640x480全屏）
//   1: 纯红色（640x480全屏）
//   2: 纯绿色（640x480全屏）
//   3: 纯蓝色（640x480全屏）
//   4: 彩虹渐变（640x480全屏）
//   5: 棋盘格（640x480全屏）
//   6: 320x240小图居中（模拟低分辨率输入，周围黑边）
//   7: 同心圆图案（640x480全屏，复杂图案）
//
// 输出 img_width/img_height 表示当前图的"有效分辨率"，
// 供后续分辨率自适应模块使用（当前版本直接输出全屏）。
//====================================================================
module test_pattern_gen #(
    parameter FRAME_WIDTH  = 640,
    parameter FRAME_HEIGHT = 480
)(
    input  wire        I_clk,      // video_clk（25.175MHz）
    input  wire        I_rst,      // 高有效复位
    input  wire        I_de,       // 数据有效（与 vout_data 同拍）
    input  wire [2:0]  I_img_idx,  // 图片索引 0~7
    output reg  [23:0] O_rgb,      // 测试图 RGB（与 I_de 同拍）
    output reg  [15:0] O_img_width,  // 当前图有效宽度
    output reg  [15:0] O_img_height  // 当前图有效高度
);

    // 行内像素计数 0~639，行计数 0~479
    reg [9:0] pix_cnt;
    reg [9:0] line_cnt;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            pix_cnt  <= 10'd0;
            line_cnt <= 10'd0;
        end else if (I_de) begin
            if (pix_cnt == FRAME_WIDTH - 1) begin
                pix_cnt <= 10'd0;
                if (line_cnt == FRAME_HEIGHT - 1)
                    line_cnt <= 10'd0;
                else
                    line_cnt <= line_cnt + 1'b1;
            end else begin
                pix_cnt <= pix_cnt + 1'b1;
            end
        end
    end

    // ============ 图0：8色竖条 + 底部灰度台阶 ============
    reg [23:0] img0_rgb;
    always @(*) begin
        if (line_cnt >= 10'd400) begin
            // 底部灰度台阶
            case (pix_cnt[9:6])
                4'd0:    img0_rgb = 24'h000000;
                4'd1:    img0_rgb = 24'h242424;
                4'd2:    img0_rgb = 24'h484848;
                4'd3:    img0_rgb = 24'h6C6C6C;
                4'd4:    img0_rgb = 24'h909090;
                4'd5:    img0_rgb = 24'hB4B4B4;
                4'd6:    img0_rgb = 24'hD8D8D8;
                default: img0_rgb = 24'hFCFCFC;
            endcase
        end else begin
            // 8色竖条
            if      (pix_cnt < 10'd80)   img0_rgb = 24'hFFFFFF; // 白
            else if (pix_cnt < 10'd160)  img0_rgb = 24'hFFFF00; // 黄
            else if (pix_cnt < 10'd240)  img0_rgb = 24'h00FFFF; // 青
            else if (pix_cnt < 10'd320)  img0_rgb = 24'h00FF00; // 绿
            else if (pix_cnt < 10'd400)  img0_rgb = 24'hFF00FF; // 品红
            else if (pix_cnt < 10'd480)  img0_rgb = 24'hFF0000; // 红
            else if (pix_cnt < 10'd560)  img0_rgb = 24'h0000FF; // 蓝
            else                         img0_rgb = 24'h000000; // 黑
        end
    end

    // ============ 图4：彩虹渐变（水平方向色相变化） ============
    reg [23:0] img4_rgb;
    always @(*) begin
        // 640像素分成6段，每段约107像素，RGB通道阶梯变化
        if (pix_cnt < 10'd107) begin
            // 红→黄：R=255, G=0→255, B=0
            img4_rgb = {8'd255, pix_cnt[7:0], 8'd0};
        end else if (pix_cnt < 10'd214) begin
            // 黄→绿：R=255→0, G=255, B=0
            img4_rgb = {8'd255 - pix_cnt[7:0], 8'd255, 8'd0};
        end else if (pix_cnt < 10'd321) begin
            // 绿→青：R=0, G=255, B=0→255
            img4_rgb = {8'd0, 8'd255, pix_cnt[7:0]};
        end else if (pix_cnt < 10'd428) begin
            // 青→蓝：R=0, G=255→0, B=255
            img4_rgb = {8'd0, 8'd255 - pix_cnt[7:0], 8'd255};
        end else if (pix_cnt < 10'd535) begin
            // 蓝→品红：R=0→255, G=0, B=255
            img4_rgb = {pix_cnt[7:0], 8'd0, 8'd255};
        end else begin
            // 品红→红：R=255, G=0, B=255→0
            img4_rgb = {8'd255, 8'd0, 8'd255 - pix_cnt[7:0]};
        end
    end

    // ============ 图5：棋盘格（40x40像素方块） ============
    reg [23:0] img5_rgb;
    always @(*) begin
        if (((pix_cnt / 10'd40) + (line_cnt / 10'd40)) % 2 == 0)
            img5_rgb = 24'hFFFFFF;
        else
            img5_rgb = 24'h000000;
    end

    // ============ 图6：320x240小图居中（模拟低分辨率） ============
    // 有效区域：x=160~479, y=120~359，内部是彩条，外部黑边
    reg [23:0] img6_rgb;
    always @(*) begin
        if (pix_cnt >= 10'd160 && pix_cnt < 10'd480 &&
            line_cnt >= 10'd120 && line_cnt < 10'd360) begin
            // 320x240内部彩条（40像素一条，共8色）
            case ((pix_cnt - 10'd160) / 10'd40)
                3'd0: img6_rgb = 24'hFFFFFF;
                3'd1: img6_rgb = 24'hFFFF00;
                3'd2: img6_rgb = 24'h00FFFF;
                3'd3: img6_rgb = 24'h00FF00;
                3'd4: img6_rgb = 24'hFF00FF;
                3'd5: img6_rgb = 24'hFF0000;
                3'd6: img6_rgb = 24'h0000FF;
                default: img6_rgb = 24'h000000;
            endcase
        end else begin
            img6_rgb = 24'h000000; // 黑边
        end
    end

    // ============ 图7：同心圆图案（复杂图案） ============
    // 以中心(320,240)为圆心，距离决定颜色，形成彩虹环
    reg [23:0] img7_rgb;
    reg [9:0] dx7, dy7;
    reg [10:0] dist7;
    always @(*) begin
        dx7 = (pix_cnt > 10'd320) ? (pix_cnt - 10'd320) : (10'd320 - pix_cnt);
        dy7 = (line_cnt > 10'd240) ? (line_cnt - 10'd240) : (10'd240 - line_cnt);
        dist7 = dx7 + dy7; // 曼哈顿距离
        // 每32像素换一种颜色，共8色循环
        case (dist7[7:5])
            3'd0: img7_rgb = 24'hFF0000; // 红
            3'd1: img7_rgb = 24'hFF8000; // 橙
            3'd2: img7_rgb = 24'hFFFF00; // 黄
            3'd3: img7_rgb = 24'h00FF00; // 绿
            3'd4: img7_rgb = 24'h00FFFF; // 青
            3'd5: img7_rgb = 24'h0000FF; // 蓝
            3'd6: img7_rgb = 24'h8000FF; // 紫
            default: img7_rgb = 24'hFF00FF; // 品红
        endcase
    end

    // ============ 输出选择 ============
    always @(*) begin
        case (I_img_idx)
            3'd0:    O_rgb = img0_rgb;       // 彩条+灰度
            3'd1:    O_rgb = 24'hFF0000;     // 纯红
            3'd2:    O_rgb = 24'h00FF00;     // 纯绿
            3'd3:    O_rgb = 24'h0000FF;     // 纯蓝
            3'd4:    O_rgb = img4_rgb;       // 彩虹渐变
            3'd5:    O_rgb = img5_rgb;       // 棋盘格
            3'd6:    O_rgb = img6_rgb;       // 320x240小图
            default: O_rgb = img7_rgb;       // 同心圆
        endcase
    end

    // 输出当前图的有效分辨率（供分辨率自适应模块使用）
    always @(*) begin
        case (I_img_idx)
            3'd6: begin
                O_img_width  = 16'd320;  // 小图有效分辨率320x240
                O_img_height = 16'd240;
            end
            default: begin
                O_img_width  = 16'd640;  // 其他都是全屏640x480
                O_img_height = 16'd480;
            end
        endcase
    end

endmodule
