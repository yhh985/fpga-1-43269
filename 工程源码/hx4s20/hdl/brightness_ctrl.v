`timescale 1ns/1ps

// ============================================================
// 模块名：brightness_ctrl
// 功能：通过按键 key1/key2 调节画面亮度
//   key1（增）：单击亮度+1，长按(>0.5s)每100ms连续+1
//   key2（减）：单击亮度-1，长按(>0.5s)每100ms连续-1
//   亮度范围 0~31，默认16（中等亮度）
//   RGB三通道等比例缩放
//   内置20ms硬件消抖
// 时钟：I_clk = 50MHz（按键采样域），I_video_clk = 25.175MHz（视频域）
// ============================================================
module brightness_ctrl #(
    parameter DATA_WIDTH  = 24,
    parameter BRIGHT_BITS = 5
)(
    input                       I_clk,
    input                       I_rst,
    input                       I_key_up,       // 亮度+（按键，低有效）
    input                       I_key_down,     // 亮度-（按键，低有效）
    input                       I_video_clk,
    input      [DATA_WIDTH-1:0] I_rgb,
    output [BRIGHT_BITS-1:0]    O_brightness,
    output reg [DATA_WIDTH-1:0] O_rgb_out
);

localparam BRIGHT_MAX = 5'd31;
localparam BRIGHT_DEF = 5'd16;

// ============================================================
// 按键消抖（20ms）
//   50MHz × 20ms = 1,000,000 周期
// ============================================================
localparam [19:0] DEBOUNCE_CNT = 20'd1_000_000;

reg        key_up_db;
reg        key_down_db;
reg [19:0] db_cnt_up;
reg [19:0] db_cnt_down;

// key_up 消抖
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        key_up_db <= 1'b1;
        db_cnt_up <= 20'd0;
    end else if (I_key_up != key_up_db) begin
        if (db_cnt_up == DEBOUNCE_CNT) begin
            key_up_db <= I_key_up;
            db_cnt_up <= 20'd0;
        end else begin
            db_cnt_up <= db_cnt_up + 1'b1;
        end
    end else begin
        db_cnt_up <= 20'd0;
    end
end

// key_down 消抖
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        key_down_db <= 1'b1;
        db_cnt_down <= 20'd0;
    end else if (I_key_down != key_down_db) begin
        if (db_cnt_down == DEBOUNCE_CNT) begin
            key_down_db <= I_key_down;
            db_cnt_down <= 20'd0;
        end else begin
            db_cnt_down <= db_cnt_down + 1'b1;
        end
    end else begin
        db_cnt_down <= 20'd0;
    end
end

// ============================================================
// 按键单击/长按检测 + 亮度计数器
//   单击：按下后松开，且按下时间 < 0.5秒 → 亮度±1
//   长按：按下持续 ≥ 0.5秒 → 立即触发一次，之后每100ms连续触发
// ============================================================
localparam [24:0] LONG_PRESS_CNT  = 25'd25_000_000;  // 0.5秒 @50MHz
localparam [22:0] REPEAT_CNT      = 23'd5_000_000;   // 100ms @50MHz

reg [BRIGHT_BITS-1:0] brightness_r;
reg                   key_up_d0;        // 消抖后打一拍
reg                   key_down_d0;
reg                   up_pressed;       // key_up 是否处于按下状态
reg                   down_pressed;
reg                   up_long_trig;     // key_up 已触发过长按
reg                   down_long_trig;
reg [24:0]            up_hold_cnt;      // key_up 按下持续计时
reg [24:0]            down_hold_cnt;
reg [22:0]            up_repeat_cnt;    // key_up 长按重复间隔计时
reg [22:0]            down_repeat_cnt;
reg                   up_inc_pulse;     // key_up 亮度+脉冲（单拍）
reg                   down_dec_pulse;   // key_down 亮度-脉冲（单拍）

wire up_falling   = key_up_d0   & ~key_up_db;    // 下降沿：按下（1→0）
wire down_falling = key_down_d0 & ~key_down_db;
wire up_rising    = ~key_up_d0  & key_up_db;     // 上升沿：松开（0→1）
wire down_rising  = ~key_down_d0 & key_down_db;

// key_up 处理
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        key_up_d0     <= 1'b1;
        up_pressed    <= 1'b0;
        up_long_trig  <= 1'b0;
        up_hold_cnt   <= 25'd0;
        up_repeat_cnt <= 23'd0;
        up_inc_pulse  <= 1'b0;
    end else begin
        key_up_d0    <= key_up_db;
        up_inc_pulse <= 1'b0;

        if (up_falling) begin
            // 按下：初始化
            up_pressed    <= 1'b1;
            up_long_trig  <= 1'b0;
            up_hold_cnt   <= 25'd0;
            up_repeat_cnt <= 23'd0;
        end
        else if (up_pressed) begin
            if (key_up_db == 1'b0) begin
                // 仍按住
                if (!up_long_trig) begin
                    // 未达到长按阈值：计时
                    if (up_hold_cnt < LONG_PRESS_CNT) begin
                        up_hold_cnt <= up_hold_cnt + 1'b1;
                    end else begin
                        // 达到0.5秒：触发长按第一次
                        up_long_trig  <= 1'b1;
                        up_inc_pulse  <= 1'b1;
                        up_repeat_cnt <= 23'd0;
                    end
                end else begin
                    // 已触发长按：每100ms重复一次
                    if (up_repeat_cnt < REPEAT_CNT) begin
                        up_repeat_cnt <= up_repeat_cnt + 1'b1;
                    end else begin
                        up_repeat_cnt <= 23'd0;
                        up_inc_pulse  <= 1'b1;
                    end
                end
            end else begin
                // 松开
                up_pressed <= 1'b0;
                if (!up_long_trig) begin
                    // 短按松开：触发一次
                    up_inc_pulse <= 1'b1;
                end
            end
        end
    end
end

// key_down 处理（逻辑同上，方向为减）
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        key_down_d0     <= 1'b1;
        down_pressed    <= 1'b0;
        down_long_trig  <= 1'b0;
        down_hold_cnt   <= 25'd0;
        down_repeat_cnt <= 23'd0;
        down_dec_pulse  <= 1'b0;
    end else begin
        key_down_d0    <= key_down_db;
        down_dec_pulse <= 1'b0;

        if (down_falling) begin
            down_pressed    <= 1'b1;
            down_long_trig  <= 1'b0;
            down_hold_cnt   <= 25'd0;
            down_repeat_cnt <= 23'd0;
        end
        else if (down_pressed) begin
            if (key_down_db == 1'b0) begin
                if (!down_long_trig) begin
                    if (down_hold_cnt < LONG_PRESS_CNT) begin
                        down_hold_cnt <= down_hold_cnt + 1'b1;
                    end else begin
                        down_long_trig  <= 1'b1;
                        down_dec_pulse  <= 1'b1;
                        down_repeat_cnt <= 23'd0;
                    end
                end else begin
                    if (down_repeat_cnt < REPEAT_CNT) begin
                        down_repeat_cnt <= down_repeat_cnt + 1'b1;
                    end else begin
                        down_repeat_cnt <= 23'd0;
                        down_dec_pulse  <= 1'b1;
                    end
                end
            end else begin
                down_pressed <= 1'b0;
                if (!down_long_trig) begin
                    down_dec_pulse <= 1'b1;
                end
            end
        end
    end
end

// 亮度计数器
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        brightness_r <= BRIGHT_DEF;
    end else begin
        if (up_inc_pulse && brightness_r < BRIGHT_MAX)
            brightness_r <= brightness_r + 1'b1;
        else if (down_dec_pulse && brightness_r > {BRIGHT_BITS{1'b0}})
            brightness_r <= brightness_r - 1'b1;
    end
end

// ============================================================
// 跨时钟域：brightness 从 I_clk 同步到 I_video_clk
// ============================================================
reg [BRIGHT_BITS-1:0] bright_sync0, bright_sync1, bright_sync2;

always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst) begin
        bright_sync0 <= BRIGHT_DEF;
        bright_sync1 <= BRIGHT_DEF;
        bright_sync2 <= BRIGHT_DEF;
    end else begin
        bright_sync0 <= brightness_r;
        bright_sync1 <= bright_sync0;
        bright_sync2 <= bright_sync1;
    end
end

// ============================================================
// 视频域：亮度缩放  out = in * brightness / 16
// ============================================================
wire [7:0] r_in = I_rgb[23:16];
wire [7:0] g_in = I_rgb[15:8];
wire [7:0] b_in = I_rgb[7:0];

wire [12:0] r_mul = r_in * bright_sync2;
wire [12:0] g_mul = g_in * bright_sync2;
wire [12:0] b_mul = b_in * bright_sync2;

wire [7:0] r_out = (r_mul >= 13'd4080) ? 8'd255 : r_mul[11:4];
wire [7:0] g_out = (g_mul >= 13'd4080) ? 8'd255 : g_mul[11:4];
wire [7:0] b_out = (b_mul >= 13'd4080) ? 8'd255 : b_mul[11:4];

always @(posedge I_video_clk or posedge I_rst) begin
    if (I_rst)
        O_rgb_out <= {DATA_WIDTH{1'b0}};
    else
        O_rgb_out <= {r_out, g_out, b_out};
end

assign O_brightness = bright_sync2;

endmodule
