
module top(
    input                       clk,
    input wire link_rx, output wire link_tx,
    output wire music_bclk,music_lrck,music_out,input wire music_return,
    input                       key1,           // K1=A2 功能键1（模式相关）
    input                       key2,           // K2=B2 功能键2（模式相关）
    input                       key3,           // K3=B1 功能键3（模式相关）
    input                       key4,           // K4=C1 模式切换键（短按循环：图片→亮度→对比度）
    input                       sw1,            // ON=音调变化请求下一张图片
    input                       sw2,            // ON=八频点柱，OFF=原幅值柱
    input                       sw3,            // 测试图模式（ON=彩条测试图）
    input                       sw4,            // OSD使能开关

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // LED状态指示
    output                      led1,           // 心跳指示灯（约1Hz闪烁）
    output                      led2            // SD卡工作状态指示
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [ADDR_BITS-1:0] FRAME_PIXELS = 307200;   // 640*480, memory word address width
parameter [ADDR_BITS-1:0] BUF0_ADDR = 0;
parameter [ADDR_BITS-1:0] BUF1_ADDR = FRAME_PIXELS;
parameter integer SWITCH_DEBOUNCE_CYCLES = 1_000_000; // 50MHz下20ms
// Hardware cap chosen to keep the SD pipeline within the device resources while
// supporting substantially more images than the original 8-image design.
parameter integer SD_IMAGE_COUNT = 32;
parameter integer SD_SPI_HIGH_SPEED_DIV = 0; // 62.5 MHz / (2 * (0 + 2)) = 15.625 MHz
parameter integer SD_READ_RELEASE_CYCLES = 4; // Three idle clocks cover the pipelined WAV header checks.
parameter integer TRANSITION_FRAME_STEP = 4; // ~0.33s cover+reveal at 60Hz
localparam integer IMAGE_INDEX_BITS=(SD_IMAGE_COUNT>1 ? $clog2(SD_IMAGE_COUNT) : 1);
// Separate demo build uses synthesized BMP sectors through the real pipeline.
parameter integer BUILTIN_DEMO = 0;
parameter integer USER_IMAGE_TEST = 0;
parameter integer MANUAL_ONLY = 0; // historical ROM-only wrapper may lock manual mode
parameter integer USER_BMP_TEST = 0;
parameter integer AUTO_INTERVAL_SECONDS = 10;
parameter integer KEY_LONG_CYCLES = 25_000_000;
// Declare cross-module nets before first use; TD otherwise creates implicit nets.
wire video_clk, rst_all, transition_frame_start;
reg [1:0] disp_buf_sync0, disp_buf_sync1, disp_buf_sync2;
reg [3:0] sd_error_code_sync0, sd_error_code_sync1;
reg [5:0] sd_last_cmd_sync0, sd_last_cmd_sync1;
reg [7:0] sd_last_r1_sync0, sd_last_r1_sync1;
reg [1:0] playback_mode; // 0 manual, 1 automatic, 2 audio
reg playback_paused;
reg [1:0] playback_video0, playback_video1;
reg [1:0] pause_video_sync;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin playback_video0<=0;playback_video1<=0;pause_video_sync<=0;end
    else begin
        playback_video0<=playback_mode;playback_video1<=playback_video0;
        pause_video_sync<={pause_video_sync[0],playback_paused};
    end
end

wire remote_online,remote_command_valid,remote_status_valid;
wire music_return_present;
wire [3:0] music_return_state;
reg [1:0] return_video_sync;
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)return_video_sync<=0;
 else return_video_sync<={return_video_sync[0],music_return_present};
end
wire remote_music_valid;wire [7:0] remote_music_command;
reg music_next_toggle,music_prev_toggle;
always @(posedge clk or posedge rst_all)begin
 if(rst_all)begin music_next_toggle<=0;music_prev_toggle<=0;end
 else if(remote_music_valid && !voice_active)begin
  if(remote_music_command==4)music_next_toggle<=~music_next_toggle;
  if(remote_music_command==5)music_prev_toggle<=~music_prev_toggle;
 end
end
wire [1:0] remote_command;wire [255:0] remote_status;wire [15:0] remote_crc_errors;
wire voice_active=remote_online && remote_status[15];
reg voice_next_toggle,voice_prev_toggle;
always @(posedge clk or posedge rst_all)begin
 if(rst_all)begin voice_next_toggle<=0;voice_prev_toggle<=0;end
 else if(voice_active && remote_command_valid)begin
  if(remote_command==1)voice_next_toggle<=~voice_next_toggle;
  if(remote_command==2)voice_prev_toggle<=~voice_prev_toggle;
 end
end
link_host #(.PRESCALE(54)) u_remote(.clk(clk),.rst(rst_all),.rx(link_rx),.tx(link_tx),
 .music_valid(remote_music_valid),.music_command(remote_music_command),.voice_allow(voice_active),.online(remote_online),.command_valid(remote_command_valid),.command(remote_command),
 .status_valid(remote_status_valid),.status(remote_status),.crc_errors(remote_crc_errors));
reg remote_next_toggle;
always @(posedge clk or posedge rst_all)begin
 if(rst_all)remote_next_toggle<=0;
 else if(remote_command_valid && remote_command==1 && !voice_active)remote_next_toggle<=~remote_next_toggle;
end
reg [1:0] remote_next_sync;reg remote_next_seen,remote_next_pending;
wire [256:0] remote_video;
// Refresh connection status even when no status frame arrives. The CDC
// mailbox holds its source data until a video frame has consumed it.
reg [19:0] remote_poll;
always @(posedge clk or posedge rst_all)begin
 if(rst_all)remote_poll<=0;
 else remote_poll<=remote_poll==999999?0:remote_poll+1'b1;
end
link_snapshot_cdc u_remote_cdc(.source_clk(clk),.dest_clk(video_clk),.rst(rst_all),
 .source_valid(remote_poll==999999),.source_data({remote_online,remote_status}),
 .frame_start(transition_frame_start),.dest_data(remote_video));
wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire hdmi_5x_clk;
wire sys_pll_lock, video_pll_lock;
wire rst_mem;
wire rst_sd;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [3:0]  sd_status_code;
wire        sd_error;
wire [3:0]  sd_error_code;
wire [5:0]  sd_last_cmd;
wire [7:0]  sd_last_r1;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_req_ack_mem;
reg [1:0]   video_ack_sync;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire        sd_card_write_data_ready;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
// 输入尺寸由 BMP 头锁存；基础赛题格式固定为640x480。
wire [15:0] src_w;
wire [15:0] src_h;
wire [15:0] display_src_w;
wire [15:0] display_src_h;
wire        frame_write_req_ack;
wire        frame_write_req_ack_mem;
reg [1:0]   write_ack_sync;
wire        frame_write_finish;
reg         frame_write_toggle_mem;
wire        read_buffer_toggle_mem;
wire [1:0]  read_buffer_index_mem;

// 帧控制器的应答来自mem域，保持到请求撤销，双触发同步后回到请求域。
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) video_ack_sync <= 2'b00;
    else video_ack_sync <= {video_ack_sync[0], video_read_req_ack_mem};
end
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) write_ack_sync <= 2'b00;
    else write_ack_sync <= {write_ack_sync[0], frame_write_req_ack_mem};
end
assign video_read_req_ack = video_ack_sync[1];
assign frame_write_req_ack = write_ack_sync[1];

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire [IMAGE_INDEX_BITS-1:0] current_pic_idx;
wire [3:0]  debug_state;
wire [3:0]  debug_rd_cnt;
wire [7:0]  debug_byte0;
wire [7:0]  debug_byte1;
wire        debug_data_valid;
wire [6:0]  seg_dbg_state, seg_dbg_rdcnt, seg_dbg_b0, seg_dbg_b1;
wire        trans_start;
wire [4:0]  trans_alpha;
wire        trans_active;
wire [23:0] vout_data_fx;
reg  [1:0]  disp_buf_idx_d0;

// Keep automatic no-frame fallback separate from the debounced SW3 mode.
// SW3 is low-active per the board pull-up constraint; only that physical
// mode may mask SD diagnostics in the OSD.
wire        video_fallback;
wire        video_test_active;
wire [2:0]  test_img_idx = 3'd0;
wire        test_img_changed = 1'b0;
reg [2:0]   user_image_idx;
reg [2:0]   trans_mode_r;

// 图像增强信号
wire [4:0]  brightness;
wire [4:0]  contrast;
wire [23:0] vout_data_enhance;

// OSD字幕叠加信号
wire [23:0] vout_data_osd;
wire [6:0] img_index; // human-readable 01..99 on both HDMI overlays

// 音频可视化信号
wire [23:0] vout_data_spectrum;
wire [23:0] vout_data_bands;
wire [23:0] vout_data_status;
wire        audio_link_start;
reg         audio_next_toggle;
reg audio_change_pending;
reg [1:0]   test_switch_sync;
reg [19:0]  test_switch_count;
reg         test_switch_candidate;
reg         test_switch_ready;
reg         test_mode_db;
reg [1:0]   test_mode_sync;
reg         test_mode;

// Stable level must persist 20ms; all OSD layers share one frame-latched enable.
(* async_reg="true" *) reg [1:0] osd_pin_sync,tone_pin_sync;
reg osd_db,tone_db;
reg [19:0] osd_db_count,tone_db_count;
reg [1:0] osd_video_sync,tone_video_sync,music_enable_video,music_playing_video;
reg osd_frame_enable,tone_frame_enable;
always @(posedge clk or posedge rst_all)begin
 if(rst_all)begin
  osd_pin_sync<=0;tone_pin_sync<=0;osd_db<=0;tone_db<=0;
  osd_db_count<=0;tone_db_count<=0;
 end else begin
  osd_pin_sync<={osd_pin_sync[0],~sw4};tone_pin_sync<={tone_pin_sync[0],~sw1};
  if(osd_pin_sync[1]==osd_db)osd_db_count<=0;
  else if(osd_db_count>=SWITCH_DEBOUNCE_CYCLES-1)begin osd_db<=osd_pin_sync[1];osd_db_count<=0;end
  else osd_db_count<=osd_db_count+1'b1;
  if(tone_pin_sync[1]==tone_db)tone_db_count<=0;
  else if(tone_db_count>=SWITCH_DEBOUNCE_CYCLES-1)begin tone_db<=tone_pin_sync[1];tone_db_count<=0;end
  else tone_db_count<=tone_db_count+1'b1;
 end
end
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)begin osd_video_sync<=0;tone_video_sync<=0;osd_frame_enable<=0;tone_frame_enable<=0;music_enable_video<=0;music_playing_video<=0;end
 else begin
  osd_video_sync<={osd_video_sync[0],osd_db};tone_video_sync<={tone_video_sync[0],tone_db};
  music_enable_video<={music_enable_video[0],music_enable};music_playing_video<={music_playing_video[0],music_playing};
  if(transition_frame_start)begin osd_frame_enable<=osd_video_sync[1];tone_frame_enable<=tone_video_sync[1];end
 end
end

// SW3机械抖动只在系统域消抖，图源只在视频帧边界切换。
always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        test_switch_sync <= 2'b00;
        test_switch_count <= 20'd0;
        test_switch_candidate <= 1'b0;
        test_switch_ready <= 1'b0;
        test_mode_db <= 1'b0;
    end else begin
        test_switch_sync <= {test_switch_sync[0], ~sw3};
        if (test_switch_sync[1] != test_switch_candidate) begin
            test_switch_candidate <= test_switch_sync[1];
            test_switch_count <= 20'd0;
        end else if (test_switch_count == SWITCH_DEBOUNCE_CYCLES - 1) begin
            test_mode_db <= test_switch_candidate;
            test_switch_ready <= 1'b1;
        end else
            test_switch_count <= test_switch_count + 1'b1;
    end
end
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        test_mode_sync <= 2'b00;
        test_mode <= 1'b0;
        audio_next_toggle <= 1'b0;audio_change_pending<=0;
        remote_next_sync<=0;remote_next_seen<=0;remote_next_pending<=0;
    end else begin
        test_mode_sync <= USER_IMAGE_TEST ? 2'b00 : {test_mode_sync[0], test_mode_db};
        if (transition_frame_start) test_mode <= test_mode_sync[1];
        if(!music_tone_enable)audio_change_pending<=0;
        else if(audio_link_start)audio_change_pending<=1;
        remote_next_sync<={remote_next_sync[0],remote_next_toggle};
        if(remote_next_sync[1]!=remote_next_seen)begin remote_next_seen<=remote_next_sync[1];remote_next_pending<=1;end
        if (!pause_video_sync[1] && !test_mode && !test_mode_sync[1] && !trans_active &&
            ((music_tone_enable && (audio_link_start || audio_change_pending)) || remote_next_pending))begin
            audio_next_toggle<=~audio_next_toggle;remote_next_pending<=0;audio_change_pending<=0;
        end
    end
end

// 色彩滤镜信号
wire [23:0] vout_data_filtered;
wire [2:0]  filter_mode;
wire        spectrum_en;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// 像素链：转场1、增强4、滤镜1、参数OSD1、幅值柱1、频点柱1、状态1，共10拍。
// 同步信号必须经过相同延迟，否则画面边界会与像素数据错位。
reg [9:0] hs_pipe;
reg [9:0] vs_pipe;
reg [9:0] de_pipe;

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        hs_pipe <= 10'd0;
        vs_pipe <= 10'd0;
        de_pipe <= 10'd0;
    end else begin
        hs_pipe <= {hs_pipe[8:0], hs};
        vs_pipe <= {vs_pipe[8:0], vs};
        de_pipe <= {de_pipe[8:0], de};
    end
end

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire [31:0] music_data;
wire [12:0] music_used;
wire music_valid,music_empty,music_pop,music_ok,music_error,music_found;
wire [2:0] music_track;wire [3:0] music_tracks;
wire music_playing,music_underflow;
wire [15:0] music_underruns;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// ============================================================
// 内部上电复位（POR）：替代外部 rst_n 引脚
// 配置完成后前255个时钟周期保持复位，之后释放
// ============================================================
reg [7:0] por_cnt;
reg       por_rst;
// 全部PLL锁定后才释放POR，避免SDRAM/视频时钟尚未稳定就启动。
wire all_pll_locked = sys_pll_lock & video_pll_lock;
always @(posedge clk or negedge all_pll_locked) begin
    if (!all_pll_locked) begin
        por_cnt <= 8'd0;
        por_rst <= 1'b1;
    end else if (por_cnt < 8'd255) begin
        por_cnt <= por_cnt + 1'b1;
        por_rst <= 1'b1;
    end else begin
        por_rst <= 1'b0;
    end
end

// 统一复位：POR + 任一PLL失锁
assign rst_all = por_rst | ~all_pll_locked;
// SDRAM owns its POR delay: 216 + 3 destination clocks = 5.256 us.
// Do not feed the 50 MHz por_rst into this domain's reset/release D muxes.
// PLL loss of lock asserts immediately; the local counter restarts on recovery.
reset_release #(.HOLD_CYCLES(216)) u_mem_reset (
    .I_clk(ext_mem_clk), .I_async_rst(~all_pll_locked), .O_rst(rst_mem)
);
// SD also owns its POR: 320 + 3 clocks at 62.5 MHz = 5.168 us.
// Local release avoids a 4 ns recovery budget from the 50 MHz POR domain.
reset_release #(.HOLD_CYCLES(320)) u_sd_reset (
    .I_clk(sd_card_clk), .I_async_rst(~all_pll_locked), .O_rst(rst_sd)
);

// TF=62.5MHz；SDRAM=41.667MHz/0°与180°；视频=25MHz。
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .extlock    (sys_pll_lock),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .extlock    (video_pll_lock),
    .reset      (1'b0)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// ============================================================
// 操作模式寄存器（K4短按循环切换）
//   0=图片模式  1=亮度模式  2=对比度模式
// ============================================================
reg [1:0] op_mode;
reg [1:0] zoom_level;
wire [256:0] zoom_sd_mailbox,zoom_video_mailbox;
wire [1:0] display_zoom_sd;
link_snapshot_cdc u_zoom_request(.source_clk(clk),.dest_clk(sd_card_clk),.rst(rst_all),
 .source_valid(1'b1),.source_data({255'd0,zoom_level}),.frame_start(1'b1),.dest_data(zoom_sd_mailbox));
link_snapshot_cdc u_zoom_display(.source_clk(sd_card_clk),.dest_clk(video_clk),.rst(rst_all),
 .source_valid(1'b1),.source_data({255'd0,display_zoom_sd}),.frame_start(transition_frame_start),.dest_data(zoom_video_mailbox));
reg       mode_change_pulse;  // 模式切换提示（高电平持续1秒，送OSD右上角显示）
reg [25:0] mode_change_cnt;   // 提示持续计时

// ============================================================
// K4 消抖 + 短按检测（模式切换 + 触发提示）
// ============================================================
reg [19:0] key4_dbnc_cnt;
reg        key4_d0, key4_d1;
reg        key4_stable;
reg        key4_prev;
reg key4_short_pulse, key4_long_pulse, key4_long_seen;
reg [25:0] key4_hold_count;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        key4_dbnc_cnt <= 20'd0;
        key4_d0 <= 1'b1; key4_d1 <= 1'b1;
        key4_stable <= 1'b1; key4_prev <= 1'b1;
        key4_short_pulse<=0;key4_long_pulse<=0;key4_long_seen<=0;key4_hold_count<=0;
        op_mode <= 2'd0;
        mode_change_pulse <= 1'b0;
        mode_change_cnt <= 26'd0;
    end else begin
        key4_d0 <= key4;
        key4_d1 <= key4_d0;
        key4_prev <= key4_stable;
        key4_short_pulse<=0;key4_long_pulse<=0;
        if (!key4_stable) begin
            if (!key4_long_seen) begin
                if (key4_hold_count == KEY_LONG_CYCLES-1) begin
                    key4_long_pulse<=1;key4_long_seen<=1;
                end else key4_hold_count<=key4_hold_count+1'b1;
            end
        end else begin
            if (!key4_prev && !key4_long_seen) key4_short_pulse<=1;
            key4_hold_count<=0;key4_long_seen<=0;
        end

        if (key4_d1 != key4_stable) begin
            if (key4_dbnc_cnt < SWITCH_DEBOUNCE_CYCLES)
                key4_dbnc_cnt <= key4_dbnc_cnt + 1'b1;
            else begin key4_stable <= key4_d1; key4_dbnc_cnt <= 20'd0; end
        end else key4_dbnc_cnt <= 20'd0;

        if (key4_short_pulse) begin
            op_mode <= op_mode + 1'b1;
            mode_change_pulse <= 1'b1;
            mode_change_cnt <= 26'd50_000_000;  // 提示持续1秒
        end else if (mode_change_cnt > 26'd0) begin
            mode_change_cnt <= mode_change_cnt - 1'b1;
        end else begin
            mode_change_pulse <= 1'b0;
        end
    end
end

// ============================================================
// K1 消抖 + 单击/长按连续检测
//   单击（<0.5秒松开）→ key1_short_pulse + key1_inc_pulse
//   长按（≥0.5秒）→ 立即+1，之后每100ms连续+1（key1_inc_pulse）
//   图片模式用 key1_short_pulse（下一张）
//   亮度/对比度模式用 key1_inc_pulse（连续+）
// ============================================================
reg [19:0] key1_dbnc_cnt;
reg        key1_d0, key1_d1;
reg        key1_stable;
reg        key1_prev;
reg        key1_pressed;
reg        key1_long_trig;
reg [24:0] key1_hold_cnt;
reg [22:0] key1_repeat_cnt;
reg        key1_short_pulse;
reg        key1_inc_pulse;

wire key1_falling = key1_prev & ~key1_stable;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        key1_dbnc_cnt <= 20'd0; key1_d0 <= 1'b1; key1_d1 <= 1'b1;
        key1_stable <= 1'b1; key1_prev <= 1'b1;
        key1_pressed <= 1'b0; key1_long_trig <= 1'b0;
        key1_hold_cnt <= 25'd0; key1_repeat_cnt <= 23'd0;
        key1_short_pulse <= 1'b0; key1_inc_pulse <= 1'b0;
    end else begin
        key1_d0 <= key1; key1_d1 <= key1_d0; key1_prev <= key1_stable;
        if (key1_d1 != key1_stable) begin
            if (key1_dbnc_cnt < SWITCH_DEBOUNCE_CYCLES) key1_dbnc_cnt <= key1_dbnc_cnt + 1'b1;
            else begin key1_stable <= key1_d1; key1_dbnc_cnt <= 20'd0; end
        end else key1_dbnc_cnt <= 20'd0;

        key1_short_pulse <= 1'b0; key1_inc_pulse <= 1'b0;

        if (key1_falling) begin
            key1_pressed <= 1'b1; key1_long_trig <= 1'b0;
            key1_hold_cnt <= 25'd0; key1_repeat_cnt <= 23'd0;
        end else if (key1_pressed) begin
            if (key1_stable == 1'b0) begin
                if (!key1_long_trig) begin
                    if (key1_hold_cnt < KEY_LONG_CYCLES) key1_hold_cnt <= key1_hold_cnt + 1'b1;
                    else begin key1_long_trig <= 1'b1; key1_inc_pulse <= 1'b1; key1_repeat_cnt <= 23'd0; end
                end else begin
                    if (key1_repeat_cnt < 23'd5_000_000) key1_repeat_cnt <= key1_repeat_cnt + 1'b1;
                    else begin key1_repeat_cnt <= 23'd0; key1_inc_pulse <= 1'b1; end
                end
            end else begin
                key1_pressed <= 1'b0;
                if (!key1_long_trig) begin key1_short_pulse <= 1'b1; key1_inc_pulse <= 1'b1; end
            end
        end
    end
end

// ============================================================
// K2 消抖 + 单击/长按连续检测（方向为减，逻辑同K1）
// ============================================================
reg [19:0] key2_dbnc_cnt;
reg        key2_d0, key2_d1;
reg        key2_stable;
reg        key2_prev;
reg        key2_pressed;
reg        key2_long_trig;
reg        key2_long_pulse;
reg [24:0] key2_hold_cnt;
reg [22:0] key2_repeat_cnt;
reg        key2_short_pulse;
reg        key2_dec_pulse;

wire key2_falling = key2_prev & ~key2_stable;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        key2_dbnc_cnt <= 20'd0; key2_d0 <= 1'b1; key2_d1 <= 1'b1;
        key2_stable <= 1'b1; key2_prev <= 1'b1;
        key2_pressed <= 1'b0; key2_long_trig <= 1'b0;
        key2_hold_cnt <= 25'd0; key2_repeat_cnt <= 23'd0;
        key2_short_pulse <= 1'b0; key2_dec_pulse <= 1'b0;
        key2_long_pulse  <= 1'b0;
    end else begin
        key2_d0 <= key2; key2_d1 <= key2_d0; key2_prev <= key2_stable;
        if (key2_d1 != key2_stable) begin
            if (key2_dbnc_cnt < SWITCH_DEBOUNCE_CYCLES) key2_dbnc_cnt <= key2_dbnc_cnt + 1'b1;
            else begin key2_stable <= key2_d1; key2_dbnc_cnt <= 20'd0; end
        end else key2_dbnc_cnt <= 20'd0;

        key2_short_pulse <= 1'b0; key2_dec_pulse <= 1'b0;
        key2_long_pulse  <= 1'b0;

        if (key2_falling) begin
            key2_pressed <= 1'b1; key2_long_trig <= 1'b0;
            key2_hold_cnt <= 25'd0; key2_repeat_cnt <= 23'd0;
        end else if (key2_pressed) begin
            if (key2_stable == 1'b0) begin
                if (!key2_long_trig) begin
                    if (key2_hold_cnt < KEY_LONG_CYCLES) key2_hold_cnt <= key2_hold_cnt + 1'b1;
                    else begin
                        key2_long_trig <= 1'b1;
                        key2_long_pulse <= 1'b1;
                        key2_dec_pulse <= 1'b1;
                        key2_repeat_cnt <= 23'd0;
                    end
                end else begin
                    if (key2_repeat_cnt < 23'd5_000_000) key2_repeat_cnt <= key2_repeat_cnt + 1'b1;
                    else begin key2_repeat_cnt <= 23'd0; key2_dec_pulse <= 1'b1; end
                end
            end else begin
                key2_pressed <= 1'b0;
                if (!key2_long_trig) begin key2_short_pulse <= 1'b1; key2_dec_pulse <= 1'b1; end
            end
        end
    end
end

// ============================================================
// K3 消抖 + 长短按分离（模式相关）
//   图片模式：短按=切滤镜，长按=切频谱
//   亮度模式：短按=恢复默认亮度
//   对比度模式：短按=恢复默认对比度
// ============================================================
reg [27:0] key3_hold_cnt;
reg        key3_d0, key3_d1;
reg [19:0] key3_dbnc_cnt;
reg        key3_stable, key3_prev;
reg        key3_pressed;
reg [2:0]  filter_mode_r;
reg        spectrum_en_r;
reg        key3_long_done;
reg        key3_short_pulse;   // K3短按脉冲（松开时产生，仅短按）
reg        key3_long_pulse;    // K3长按脉冲（1秒到达时产生）

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        key3_hold_cnt  <= 28'd0;
        key3_d0        <= 1'b1;
        key3_d1        <= 1'b1;
        key3_dbnc_cnt  <= 20'd0;
        key3_stable    <= 1'b1;
        key3_prev      <= 1'b1;
        key3_pressed   <= 1'b0;
        filter_mode_r  <= 3'd0;
        spectrum_en_r  <= 1'b0;
        key3_long_done <= 1'b0;
        key3_short_pulse <= 1'b0;
        key3_long_pulse  <= 1'b0;
    end else begin
        key3_d0 <= key3;
        key3_d1 <= key3_d0;
        key3_prev <= key3_stable;
        if (key3_d1 != key3_stable) begin
            if (key3_dbnc_cnt < SWITCH_DEBOUNCE_CYCLES)
                key3_dbnc_cnt <= key3_dbnc_cnt + 1'b1;
            else begin key3_stable<=key3_d1; key3_dbnc_cnt<=20'd0; end
        end else key3_dbnc_cnt<=20'd0;
        key3_short_pulse <= 1'b0;
        key3_long_pulse  <= 1'b0;

        if (key3_prev && !key3_stable) begin
            key3_pressed  <= 1'b1;
            key3_long_done <= 1'b0;
            key3_hold_cnt <= 28'd0;
        end

        if (key3_pressed) begin
            if (key3_stable == 1'b0) begin
                if (key3_hold_cnt < 28'd50_000_000) begin
                    key3_hold_cnt <= key3_hold_cnt + 1'b1;
                    if (key3_hold_cnt == 28'd50_000_000 - 1) begin
                        // 长按1秒
                        key3_long_pulse <= 1'b1;
                        key3_long_done <= 1'b1;
                        // 仅图片模式下长按切频谱
                        if (op_mode == 2'd0)
                            spectrum_en_r <= ~spectrum_en_r;
                    end
                end
            end else begin
                key3_pressed <= 1'b0;
                if (!key3_long_done) begin
                    // 短按松开
                    key3_short_pulse <= 1'b1;
                    // 图片模式下短按切滤镜
                    if (op_mode == 2'd0) begin
                        if (filter_mode_r == 3'd6)
                            filter_mode_r <= 3'd0;
                        else
                            filter_mode_r <= filter_mode_r + 1'b1;
                    end
                end
            end
        end
    end
end

assign filter_mode = filter_mode_r;
assign spectrum_en = spectrum_en_r;

// ============================================================
// 亮度/对比度寄存器（clk域，根据模式和K1/K2单击更新）
// ============================================================
reg [4:0] brightness_r;
reg [4:0] contrast_r;
reg       rst_bright_pulse;   // 恢复默认亮度脉冲
reg       rst_contrast_pulse; // 恢复默认对比度脉冲

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        brightness_r <= 5'd16;
        contrast_r   <= 5'd16;
        rst_bright_pulse   <= 1'b0;
        rst_contrast_pulse <= 1'b0;
    end else begin
        rst_bright_pulse   <= 1'b0;
        rst_contrast_pulse <= 1'b0;

        case (op_mode)
            2'd1: begin  // 亮度模式：K1长按连续+，K2长按连续-
                if (key1_inc_pulse && brightness_r < 5'd31)
                    brightness_r <= brightness_r + 1'b1;
                if (key2_dec_pulse && brightness_r > 5'd0)
                    brightness_r <= brightness_r - 1'b1;
                if (key3_short_pulse) begin
                    brightness_r <= 5'd16;
                    rst_bright_pulse <= 1'b1;
                end
            end
            2'd2: begin  // 对比度模式：K1长按连续+，K2长按连续-
                if (key1_inc_pulse && contrast_r < 5'd31)
                    contrast_r <= contrast_r + 1'b1;
                if (key2_dec_pulse && contrast_r > 5'd0)
                    contrast_r <= contrast_r - 1'b1;
                if (key3_short_pulse) begin
                    contrast_r <= 5'd16;
                    rst_contrast_pulse <= 1'b1;
                end
            end
            default: ;
        endcase
    end
end

assign brightness = brightness_r;
assign contrast   = contrast_r;

// ============================================================
// 自动播放开关（图片模式下K2单击切换）
// ============================================================
always @(posedge clk or posedge rst_all)begin
 if(rst_all)zoom_level<=1;
 else if(op_mode==3)begin
  if(key3_short_pulse)zoom_level<=1;
  else if(key1_short_pulse && zoom_level<3)zoom_level<=zoom_level+1'b1;
  else if(key2_short_pulse && zoom_level>0)zoom_level<=zoom_level-1'b1;
 end
end
wire auto_play_en = playback_mode == 2'd1 && !voice_active;
wire audio_play_en = playback_mode == 2'd2 && !voice_active;
// Absolute background state arrives in each CRC-protected ACA snapshot.
// Legacy status has demo_enable=0; disconnected ACA fails closed.
wire background_music_en = remote_online && remote_status[13] && remote_status[0];
wire music_enable = !voice_active && (playback_mode==2'd2 || background_music_en);
always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin playback_mode<=0;playback_paused<=0;end
    else begin
        if (!MANUAL_ONLY && op_mode == 0 && key2_short_pulse)
            playback_mode <= playback_mode == 2 ? 0 : playback_mode+1'b1;
        if (key4_long_pulse || (remote_command_valid && remote_command==2 && !voice_active)) playback_paused<=~playback_paused;
    end
end

// ============================================================
// K1单击展宽（图片模式下=下一张，适配sd_card_bmp内部消抖）
// ============================================================
reg [24:0] key1_wide_cnt;
reg        key1_wide;
wire       key1_next_wide = (op_mode == 2'd0) ? key1_wide : 1'b1;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        key1_wide_cnt <= 25'd0;
        key1_wide     <= 1'b1;
    end else begin
        if (op_mode == 2'd0 && key1_short_pulse) begin
            key1_wide     <= 1'b0;
            key1_wide_cnt <= 25'd2_500_000;
        end else if (key1_wide_cnt > 25'd0) begin
            key1_wide_cnt <= key1_wide_cnt - 1'b1;
        end else begin
            key1_wide <= 1'b1;
        end
    end
end

// mem_clk 域把 write_finish 单拍转成 toggle
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
generate if (!USER_IMAGE_TEST) begin : g_card_source
sd_card_bmp #(
    .PREFETCH_NEXT(1),
    .CLK_FREQ_HZ       (62_500_000),
    .BUILTIN_DEMO     (BUILTIN_DEMO),
    .USER_BMP_TEST    (USER_BMP_TEST),
    .MAIN_SD_FEATURES (!USER_BMP_TEST && !BUILTIN_DEMO),
    .FIT_ASPECT       (1),
    .SPI_HIGH_SPEED_DIV (SD_SPI_HIGH_SPEED_DIV),
    .READ_RELEASE_CYCLES (SD_READ_RELEASE_CYCLES),
    .AUTO_INTERVAL_SECONDS(AUTO_INTERVAL_SECONDS),
    .SCAN_START_SECTOR ((BUILTIN_DEMO || USER_BMP_TEST) ? 32'd2048 : 32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (SD_IMAGE_COUNT)
) sd_card_bmp_m0(
    .zoom_level(zoom_sd_mailbox[1:0]),.display_zoom(display_zoom_sd),
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .key_next          (key1_next_wide),   // 图片模式K1=下一张
    .auto_play_enable  (auto_play_en),
    .audio_play_enable (audio_play_en),
    .background_music_enable(background_music_en && !voice_active),
    .music_next_toggle(music_next_toggle),.music_prev_toggle(music_prev_toggle),
    .audio_clk(audio_mclk),.music_pop(music_pop),.music_data(music_data),
    .music_valid(music_valid),.music_empty(music_empty),.music_used(music_used),
    .music_ok(music_ok),.music_error(music_error),.music_found(music_found),
    .music_track(music_track),.music_tracks(music_tracks),
    .playback_pause    ((playback_paused && !voice_active) | trans_active), // reserve frames throughout cover/swap/reveal
    .test_mode         (~test_switch_ready | test_mode_db | test_mode),
    .voice_next_toggle(voice_next_toggle),.voice_prev_toggle(voice_prev_toggle),
    .audio_next_toggle (audio_next_toggle), // 音频事件跨域，实际加载完成才触发转场
    .state_code        (state_code),
    .status_code       (sd_status_code),
    .sd_error          (sd_error),
    .sd_error_code     (sd_error_code),
    .sd_last_cmd       (sd_last_cmd),
    .sd_last_r1        (sd_last_r1),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .src_w             (src_w),
    .src_h             (src_h),
    .display_src_w     (display_src_w),
    .display_src_h     (display_src_h),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .read_buffer_toggle(read_buffer_toggle_mem),
    .read_buffer_index (read_buffer_index_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .current_pic_idx   (current_pic_idx),
    .debug_state        (debug_state),
    .debug_rd_cnt       (debug_rd_cnt),
    .debug_byte0        (debug_byte0),
    .debug_byte1        (debug_byte1),
    .debug_data_valid   (debug_data_valid),

    .write_req         (sd_card_write_req),
    .write_req_ack     (frame_write_req_ack),
    .write_data_ready  (sd_card_write_data_ready),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

end else begin : g_user_source
    assign music_data=0;assign music_valid=0;assign music_empty=1;assign music_used=0;
    assign music_ok=0;assign music_error=0;assign music_found=0;
    assign music_track=0;assign music_tracks=0;
    assign state_code=4'd1;
    assign sd_status_code=4'd1;
    assign sd_error=1'b0;
    assign sd_error_code=4'd0;
    assign sd_last_cmd=6'd0;
    assign sd_last_r1=8'd0;
    assign display_zoom_sd=2'd1;
    assign src_w=16'd64;
    assign src_h=16'd48;
    assign display_src_w=16'd64;
    assign display_src_h=16'd48;
    assign display_valid=1'b1;
    assign write_buf_idx=2'd0;
    assign disp_buf_idx=2'd0;
    assign current_pic_idx=user_image_idx;
    assign debug_state=4'd0;
    assign debug_rd_cnt=4'd0;
    assign debug_byte0=8'd0;
    assign debug_byte1=8'd0;
    assign debug_data_valid=1'b0;
    assign sd_card_write_req=1'b0;
    assign sd_card_write_en=1'b0;
    assign sd_card_write_data=32'd0;
    assign sd_ncs=1'b1;
    assign sd_dclk=1'b0;
    assign sd_mosi=1'b1;
end endgenerate
seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

// 诊断：显示 SD 卡错误码和最后发送的命令
wire [6:0] seg_data_err;
wire [6:0] seg_data_cmd;
wire [6:0] seg_data_r1;
reg  [3:0] sd_err_sync;
reg  [3:0] sd_cmd_sync;
reg  [3:0] sd_r1_sync;
always @(posedge clk) begin
    sd_err_sync  <= sd_error_code_sync1;
    sd_cmd_sync  <= sd_last_cmd_sync1[3:0];
    sd_r1_sync   <= sd_last_r1_sync1[3:0];
end
seg_decoder seg_decoder_err(.bin_data(sd_err_sync),  .seg_data(seg_data_err));
seg_decoder seg_decoder_cmd(.bin_data(sd_cmd_sync),  .seg_data(seg_data_cmd));
seg_decoder seg_decoder_r1(.bin_data(sd_r1_sync),   .seg_data(seg_data_r1));

// 调试：SD卡读取状态信号
seg_decoder seg_dbg_state_m(.bin_data(debug_state),     .seg_data(seg_dbg_state));
seg_decoder seg_dbg_rdcnt_m(.bin_data(debug_rd_cnt),     .seg_data(seg_dbg_rdcnt));
seg_decoder seg_dbg_b0_m(.bin_data(debug_byte0[3:0]), .seg_data(seg_dbg_b0));
seg_decoder seg_dbg_b1_m(.bin_data(debug_byte1[3:0]), .seg_data(seg_dbg_b1));
// The two previously blank digits show the committed image number 01..99.
// The existing playback / operation / transition digits retain their positions.
// Playback 0=manual, 1=automatic, 2=audio; DP on playback marks pause.
// Use the committed source image index for both card and no-card BMP paths.
wire [6:0] seg_zoom_level;
seg_decoder seg_zoom_m(.bin_data({2'd0,zoom_level}),.seg_data(seg_zoom_level));
wire [6:0] seg_playback_mode, seg_image_tens, seg_image_ones, seg_op_mode, seg_trans_mode;
image_number_2digit #(.INDEX_BITS(IMAGE_INDEX_BITS)) u_image_number(
    .clk(clk),.rst(rst_all),.image_index(current_pic_idx),.display_valid(display_valid),
    .seg_tens(seg_image_tens),.seg_ones(seg_image_ones));
seg_decoder seg_playback_mode_m(.bin_data({2'd0,playback_mode}), .seg_data(seg_playback_mode));
seg_decoder seg_op_mode_m(.bin_data({2'd0,op_mode}), .seg_data(seg_op_mode));
seg_decoder seg_trans_mode_m(.bin_data({1'b0,trans_mode_r}), .seg_data(seg_trans_mode));

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (~rst_all),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,seg_image_tens}),
    .seg_data_1        ({1'b1,seg_image_ones}),
    .seg_data_2        ({~playback_paused,seg_playback_mode}),
    .seg_data_3        ({1'b1,seg_op_mode}),
    .seg_data_4        ({1'b1,op_mode==3 ? seg_zoom_level : seg_trans_mode}),
    .seg_data_5        (8'hff)
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

wire hs_memory, vs_memory, de_memory;
wire [23:0] memory_rgb;
video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs_memory),
    .vs_r              (vs_memory),
    .de_r              (de_memory),
    .vout_data         (memory_rgb)
);
generate if (USER_IMAGE_TEST) begin : g_user_video
user_image_rom u_rom(
    .clk(video_clk),.rst(rst_all),.hs(hs_0),.vs(vs_0),.de(de_0),
    .image_index(user_image_idx),.hs_out(hs),.vs_out(vs),.de_out(de),.rgb(vout_data_raw)
);
end else begin : g_memory_video
    assign hs=hs_memory;
    assign vs=vs_memory;
    assign de=de_memory;
    assign vout_data_raw=memory_rgb;
end endgenerate

// ============= 无TF卡测试图模式（sw3 拨到 ON=低电平 进入） =============
wire [23:0] test_rgb;

test_pattern_gen #(
    .FRAME_WIDTH  (640),
    .FRAME_HEIGHT (480)
) u_test_pattern_gen (
    .I_clk  (video_clk),
    .I_rst  (rst_all),
    .I_de   (de),
    .I_img_idx (test_img_idx),
    .O_rgb  (test_rgb)
);

reg [1:0] display_valid_sync;
reg display_valid_sampled;
reg display_valid_frame;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        display_valid_sync <= 2'b00;
        display_valid_sampled <= 1'b0;
        display_valid_frame <= 1'b0;
    end else begin
        display_valid_sync <= {display_valid_sync[0], display_valid};
        if (transition_frame_start) begin
            // 原始VS已先启动读FIFO预取；首图连续两个延迟VS边界有效后
            // 才放行，确保展示的是写完之后启动的完整读帧。
            display_valid_sampled <= display_valid_sync[1];
            if (display_valid_sampled && display_valid_sync[1])
                display_valid_frame <= 1'b1;
        end
    end
end
assign video_fallback = USER_IMAGE_TEST ? 1'b0 : ~display_valid_frame;
assign video_test_active = test_mode | video_fallback;
assign vout_data = video_test_active ? test_rgb : vout_data_raw;

// ============= 像素坐标计数器（供转场特效模块用） =============
reg [9:0] spec_px_x, spec_px_y;
reg       spec_vs_d0, spec_de_d0;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        spec_px_x <= 10'd0; spec_px_y <= 10'd0;
        spec_vs_d0 <= 1'b0; spec_de_d0 <= 1'b0;
    end else begin
        spec_vs_d0 <= vs; spec_de_d0 <= de;
        if (de) begin
            if (spec_px_x < 10'd639) spec_px_x <= spec_px_x + 1'b1;
            else spec_px_x <= 10'd0;
        end else spec_px_x <= 10'd0;
        if (spec_vs_d0 & ~vs) spec_px_y <= 10'd0;
        else if (spec_de_d0 && !de && spec_px_y < 10'd479)
            spec_px_y <= spec_px_y + 1'b1;
    end
end

// ============= 转场特效模块（7种模式） =============
// 转场模式由 KEY2 长按切换（仅图片模式下）；KEY3 长按只控制频谱。
reg [2:0] trans_mode_sync0, trans_mode_sync1;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin trans_mode_sync0<=0; trans_mode_sync1<=0; end
    else begin trans_mode_sync0<=trans_mode_r; trans_mode_sync1<=trans_mode_sync0; end
end
always @(posedge clk or posedge rst_all) begin
    if (rst_all)
        trans_mode_r <= 3'd0;
    else if ((remote_command_valid && remote_command==3) || (op_mode == 2'd0 && (key2_long_pulse || (MANUAL_ONLY && key2_short_pulse))))
        trans_mode_r <= (trans_mode_r == 3'd6) ? 3'd0 : trans_mode_r + 1'b1;
end

wire [23:0] transition_rgb;
wire transition_black;
reg [1:0] visible_buf_idx;
reg [1:0] reader_idx_sync0,reader_idx_sync1;
reg [1:0] black_settle_frames;
// Keep OLD buffer during CLOSE; switch only under black and await reader.
always @(posedge video_clk or posedge rst_all) begin
    if(rst_all)begin
        visible_buf_idx<=0;reader_idx_sync0<=0;reader_idx_sync1<=0;black_settle_frames<=0;
    end else begin
        reader_idx_sync0<=read_buffer_index_mem;reader_idx_sync1<=reader_idx_sync0;
        if(!display_valid_frame || video_test_active || transition_black)visible_buf_idx<=disp_buf_sync2;
        if(!transition_black || reader_idx_sync1!=visible_buf_idx)black_settle_frames<=0;
        else if(transition_frame_start && black_settle_frames!=3)black_settle_frames<=black_settle_frames+1'b1;
    end
end
reg [23:0] transition_bypass_rgb;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) transition_bypass_rgb <= 24'd0;
    else transition_bypass_rgb <= vout_data;
end
// 测试图绕过黑底转场，仍保留原有一拍像素延迟。
assign vout_data_fx = video_test_active ? transition_bypass_rgb : transition_rgb;
transition_fx #(
    .DATA_WIDTH    (24),
    .ALPHA_BITS    (5),
    .FRAME_WIDTH   (640),
    .FRAME_HEIGHT  (480),
    .WAIT_FOR_READER(1),
    .FRAME_STEP(TRANSITION_FRAME_STEP)
) u_transition_fx (
    .I_clk          (video_clk),
    .I_rst          (rst_all | video_test_active),
    .I_vs           (vs),
    .I_de           (de),
    .I_trans_start  (trans_start),
    .I_mode         (trans_mode_sync1),
    .I_rgb          (vout_data),
    .I_px_x         (spec_px_x),
    .I_px_y         (spec_px_y),
    .I_reveal       (USER_IMAGE_TEST || black_settle_frames>=2),
    .O_black        (transition_black),
    .O_alpha        (trans_alpha),
    .O_active       (trans_active),
    .O_rgb_out      (transition_rgb)
);

// ============= 图像增强模块（亮度+对比度统一管道） =============
image_enhance #(
    .DATA_WIDTH    (24)
) u_image_enhance (
    .I_clk          (clk),
    .I_rst          (rst_all),
    .I_video_clk    (video_clk),
    .I_rgb          (vout_data_fx),
    .I_brightness   (brightness_r),
    .I_contrast     (contrast_r),
    .I_rst_bright   (rst_bright_pulse),
    .I_rst_contrast (rst_contrast_pulse),
    .O_rgb_out      (vout_data_enhance)
);

// ============= 转场触发：检测disp_buf_idx变化 =============
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        disp_buf_sync0 <= 2'b0; disp_buf_sync1 <= 2'b0; disp_buf_sync2 <= 2'b0;
        disp_buf_idx_d0 <= 2'b0;
    end else begin
        disp_buf_sync0 <= disp_buf_idx;
        disp_buf_sync1 <= disp_buf_sync0;
        disp_buf_sync2 <= disp_buf_sync1;
        disp_buf_idx_d0  <= disp_buf_sync2;
    end
end
// 只有已提交的新图片触发转场。音频事件经SD请求真正的下一张，
// 不再直接把当前静图变黑。转场期间的事件不能重置渐变进度。
wire transition_allowed = !video_test_active && !test_mode_sync[1] &&
                          (USER_IMAGE_TEST || display_valid_frame) && !trans_active;
wire transition_request = (disp_buf_sync2 != disp_buf_idx_d0) && transition_allowed;
reg user_next_toggle;
reg [2:0] user_next_sync;
reg user_next_pending;
wire user_next_event = user_next_sync[2] ^ user_next_sync[1];
always @(posedge clk or posedge rst_all) begin
    if(rst_all) user_next_toggle<=0;
    else if(op_mode==0 && key1_short_pulse) user_next_toggle<=~user_next_toggle;
end
always @(posedge video_clk or posedge rst_all) begin
    if(rst_all) begin user_next_sync<=0;user_next_pending<=0;user_image_idx<=0;end
    else begin
        user_next_sync<={user_next_sync[1:0],user_next_toggle};
        if(user_next_event) user_next_pending<=1'b1;
        if(USER_IMAGE_TEST && transition_black && user_next_pending) begin
            user_image_idx<=user_image_idx+1'b1;
            user_next_pending<=1'b0;
        end
    end
end
assign transition_frame_start = spec_vs_d0 & ~vs;
reg transition_pending;
always @(posedge video_clk or posedge rst_all) begin
    if(rst_all) transition_pending<=1'b0;
    else if(!transition_allowed || transition_frame_start) transition_pending<=1'b0;
    else if(transition_request) transition_pending<=1'b1;
end
assign trans_start = transition_allowed && transition_frame_start &&
                     (USER_IMAGE_TEST ? (user_next_pending | user_next_event) :
                                        (transition_pending | transition_request));

// ============= 图片编号同步 =============
reg [IMAGE_INDEX_BITS-1:0] pic_idx_sync0, pic_idx_sync1, pic_idx_sync2;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        pic_idx_sync0 <= 3'd0; pic_idx_sync1 <= 3'd0; pic_idx_sync2 <= 3'd0;
    end else begin
        pic_idx_sync0 <= current_pic_idx;
        pic_idx_sync1 <= pic_idx_sync0;
        pic_idx_sync2 <= pic_idx_sync1;
    end
end
assign img_index = USER_IMAGE_TEST ? {4'd0,user_image_idx}+7'd1 :
                   video_test_active ? {4'd0,test_img_idx} :
                   display_valid_frame ? pic_idx_sync2+7'd1 : 7'd0;

// ============= 模式提示同步到 video_clk 域 =============
reg [1:0] op_mode_sync0, op_mode_sync1;
reg       mode_chg_sync0, mode_chg_sync1;
reg [2:0] filter_sync0, filter_sync1;
reg [4:0] bright_osd_sync0, bright_osd_sync1;
reg [4:0] contr_osd_sync0, contr_osd_sync1;
reg       spectrum_sync0, spectrum_sync1;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        op_mode_sync0 <= 2'd0; op_mode_sync1 <= 2'd0;
        mode_chg_sync0 <= 1'b0; mode_chg_sync1 <= 1'b0;
        filter_sync0<=0; filter_sync1<=0;
        bright_osd_sync0<=16; bright_osd_sync1<=16;
        contr_osd_sync0<=16; contr_osd_sync1<=16;
        spectrum_sync0<=0; spectrum_sync1<=0;
    end else begin
        op_mode_sync0 <= op_mode; op_mode_sync1 <= op_mode_sync0;
        mode_chg_sync0 <= mode_change_pulse; mode_chg_sync1 <= mode_chg_sync0;
        filter_sync0<=filter_mode; filter_sync1<=filter_sync0;
        bright_osd_sync0<=brightness; bright_osd_sync1<=bright_osd_sync0;
        contr_osd_sync0<=contrast; contr_osd_sync1<=contr_osd_sync0;
        spectrum_sync0<=spectrum_en; spectrum_sync1<=spectrum_sync0;
    end
end

// 滤镜只处理图片，保留字幕和可视化的颜色与可读性。
color_filter #(.DATA_WIDTH(24)) u_color_filter (
    .I_clk(video_clk), .I_rst(rst_all), .I_mode(filter_sync1),
    .I_rgb(vout_data_enhance), .O_rgb_out(vout_data_filtered)
);

// ============= OSD字幕叠加模块 =============
osd_overlay #(
    .DATA_WIDTH    (24),
    .FRAME_WIDTH   (640),
    .FRAME_HEIGHT  (480),
    .OSD_START_X   (240),
    .OSD_START_Y   (8)
) u_osd_overlay (
    .I_clk          (video_clk),
    .I_rst          (rst_all),
    // 转场1拍+增强4拍+滤镜1拍，同步累计延迟6拍。
    .I_vs           (vs_pipe[5]),
    .I_hs           (hs_pipe[5]),
    .I_de           (de_pipe[5]),
    .I_rgb          (vout_data_filtered),
    .I_img_idx      (img_index),
    .I_filter_mode  (filter_sync1),
    .I_brightness   (bright_osd_sync1),
    .I_contrast     (contr_osd_sync1),
    .I_op_mode      (op_mode_sync1),
    .I_mode_change  (mode_chg_sync1 && op_mode_sync1!=3),
    // SW4 使用上拉输入，拨到 ON 时为低电平。
    .I_osd_en       (osd_frame_enable),
    .O_rgb_out      (vout_data_osd)
);

// ============= 音频可视化模块 =============
audio_spectrum #(
    .DATA_WIDTH    (24),
    .FRAME_WIDTH   (640),
    .FRAME_HEIGHT  (480),
    .BAR_COUNT     (16),
    .BAR_MAX_H     (80),
    .BAR_START_X   (0),
    .BAR_START_Y   (400)
) u_audio_spectrum (
    .I_video_clk     (video_clk),
    .I_rst           (rst_all),
    // OSD再延迟1拍，坐标使用7拍延迟后的同步。
    .I_vs            (vs_pipe[6]),
    .I_de            (de_pipe[6]),
    .I_rgb           (vout_data_osd),
    .I_audio_valid   (audio_valid),
    .I_audio_left    (audio_left_data),
    .I_audio_right   (audio_right_data),
    .I_spectrum_en   (spectrum_sync1),
    .O_rgb_out       (vout_data_spectrum)
);

// ACA420 supplies the measured spectrum. Keep the original overlay-stage
// pixel delay so status RGB remains aligned with vs_pipe/de_pipe[8].
reg [23:0] remote_stage_rgb;
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)remote_stage_rgb<=0;else remote_stage_rgb<=vout_data_spectrum;
end
assign vout_data_bands=remote_stage_rgb;
// Analyze the actual SD music PCM, never the microphone or amplitude bars.
wire music_tone_enable=playback_video1==2 && music_enable_video[1] && music_playing_video[1] &&
 tone_frame_enable && !pause_video_sync[1] && !test_mode && !test_mode_sync[1];
wire tone_result,tone_overflow,tone_ready;
wire [1:0] tone_peak_index;
wire [31:0] tone_peak_power;
// Hysteretic zero-crossing frequency bands; no extra multiplier on dense HX.
wire signed [11:0] tone_sample=local_left[23:12];
music_frequency_probe u_music_tone(
 .clk(video_clk),.rst(rst_all || !music_tone_enable),.sample_valid(audio_valid && music_tone_enable),
 .sample_in(tone_sample),.result_valid(tone_result),
 .result_overflow(tone_overflow),.peak_index(tone_peak_index),.peak_power(tone_peak_power));
audio_visual_link #(.INDEX_WIDTH(2),.COOLDOWN_FRAMES(120)) u_music_visual_link(
 .clk(video_clk),.rst(rst_all),.enable(music_tone_enable),.frame_start(transition_frame_start),
 .result_valid(tone_result),.result_overflow(tone_overflow),.peak_index(tone_peak_index),
 .peak_power(tone_peak_power),.transition_start(audio_link_start));
reg [1:0] band_mode_sync;
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)band_mode_sync<=0;else band_mode_sync<={band_mode_sync[0],~sw2};
end

// Diagnostic controls are synchronized before the status layer samples them
// at a frame boundary.  They never feed the frame writer or buffer handshake.
reg [1:0] auto_status_sync;
reg [1:0] sd_error_sync;
reg [3:0] sd_status_sync0, sd_status_sync1;
reg [15:0] src_w_video_sync0, src_w_video_sync1;
reg [15:0] src_h_video_sync0, src_h_video_sync1;
reg [1:0] src_valid_video_sync;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        auto_status_sync <= 2'b00;
        sd_error_sync <= 2'b00;
        sd_status_sync0 <= 4'd0;
        sd_status_sync1 <= 4'd0;
        sd_error_code_sync0 <= 4'd0; sd_error_code_sync1 <= 4'd0;
        sd_last_cmd_sync0 <= 6'd0; sd_last_cmd_sync1 <= 6'd0;
        sd_last_r1_sync0 <= 8'hff; sd_last_r1_sync1 <= 8'hff;
        src_w_video_sync0 <= 16'd0; src_w_video_sync1 <= 16'd0;
        src_h_video_sync0 <= 16'd0; src_h_video_sync1 <= 16'd0;
        src_valid_video_sync <= 2'b00;
    end else begin
        auto_status_sync <= {auto_status_sync[0], auto_play_en};
        sd_error_sync <= {sd_error_sync[0], sd_error};
        sd_status_sync0 <= sd_status_code;
        sd_status_sync1 <= sd_status_sync0;
        sd_error_code_sync0 <= sd_error_code;
        sd_error_code_sync1 <= sd_error_code_sync0;
        sd_last_cmd_sync0 <= sd_last_cmd;
        sd_last_cmd_sync1 <= sd_last_cmd_sync0;
        sd_last_r1_sync0 <= sd_last_r1;
        sd_last_r1_sync1 <= sd_last_r1_sync0;
        src_w_video_sync0 <= display_src_w; src_w_video_sync1 <= src_w_video_sync0;
        src_h_video_sync0 <= display_src_h; src_h_video_sync1 <= src_h_video_sync0;
        src_valid_video_sync <= {src_valid_video_sync[0], display_valid};
    end
end

reg [4:0] music_flags0,music_flags1;
reg [6:0] track_video0,track_video1;
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)begin track_video0<=0;track_video1<=0;end
 else begin track_video0<={music_tracks,music_track};track_video1<=track_video0;end
end
reg [3:0] music_status;
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)begin music_flags0<=0;music_flags1<=0;music_status<=0;end
 else begin
  music_flags0<={music_error,music_found,music_playing,music_underflow,music_ok};
  music_flags1<=music_flags0;
  if(!music_enable_video[1])music_status<=0;
  else if(music_flags1[4])music_status<=5;
  else if(!music_flags1[3])music_status<=1;
  else if(pause_video_sync[1])music_status<=4;
  else if(music_flags1[2])music_status<=3;
  else if(music_flags1[1])music_status<=6;
  else music_status<=2;
 end
end

osd_status_overlay #(
    .DATA_WIDTH(24), .FRAME_WIDTH(640), .FRAME_HEIGHT(480), .PLAYBACK_STATUS(1), .MUSIC_STATUS(1), .ZOOM_STATUS(1)
) u_osd_status_overlay (
    .I_zoom_level(zoom_video_mailbox[1:0]),.I_music_status(music_status),.I_clk(video_clk), .I_rst(rst_all),
    .I_vs(vs_pipe[8]), .I_hs(hs_pipe[8]), .I_de(de_pipe[8]),
    .I_rgb(vout_data_bands), .I_img_idx(img_index),
    .I_src_w(src_w_video_sync1), .I_src_h(src_h_video_sync1),
    .I_src_valid(src_valid_video_sync[1]),
    .I_filter_mode(filter_sync1), .I_auto_play(auto_status_sync[1]),
    .I_playback_mode(playback_video1), .I_paused(pause_video_sync[1]),
    .I_test_mode(test_mode),
    .I_trans_active(trans_active & ~video_test_active),
    .I_trans_alpha(video_test_active ? 5'd0 : trans_alpha),
    .I_state_code(USER_IMAGE_TEST ? 4'd1 : sd_status_sync1), .I_sd_error(USER_IMAGE_TEST ? 1'b0 : sd_error_sync[1]),
    .I_sd_error_code(sd_error_code_sync1),
    .I_sd_last_cmd(sd_last_cmd_sync1), .I_sd_last_r1(sd_last_r1_sync1),
    .I_osd_en(osd_frame_enable), .O_rgb_out(vout_data_status)
);

wire [23:0] vout_data_mic;
mic_overlay u_mic_overlay(.clk(video_clk),.rst(rst_all),.vs(vs_pipe[9]),.de(de_pipe[9]),
 .fx_return_state(music_return_state),.music_mode(music_enable_video[1]),.music_track(track_video1[2:0]),.music_tracks(track_video1[6:3]),
 .fx_requested(remote_video[20:19]!=0 && !remote_video[15]),.fx_return_ok(return_video_sync[1]),
 .enable(osd_frame_enable),.online(remote_video[256]),.status(remote_video[255:0]),
 .rgb(vout_data_status),.out_rgb(vout_data_mic));
// ============= LED状态指示 =============
reg [24:0] led_cnt;
reg        led_heartbeat;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        led_cnt <= 25'd0;
        led_heartbeat <= 1'b0;
    end else begin
        if (led_cnt == 25'd25_000_000) begin
            led_cnt <= 25'd0;
            led_heartbeat <= ~led_heartbeat;
        end else
            led_cnt <= led_cnt + 1'b1;
    end
end

assign led1 = led_heartbeat;
assign led2 = USER_IMAGE_TEST ? trans_active : (state_code != 4'd1);

generate if (!USER_IMAGE_TEST) begin : g_memory_store
frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack_mem),
    .read_buffer_toggle(read_buffer_toggle_mem),
    .read_buffer_index (read_buffer_index_mem),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       ({ADDR_BITS{1'b0}}),
    .read_addr_3       ({ADDR_BITS{1'b0}}),
    .read_addr_index   (visible_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    // sd_card_bmp buffers each sector and scales the source image to one
    // complete 640x480 stream before writing the inactive frame buffer.
    .write_req         (sd_card_write_req),
    .write_req_ack     (frame_write_req_ack_mem),
    .write_data_ready  (sd_card_write_data_ready),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      ({ADDR_BITS{1'b0}}),
    .write_addr_3      ({ADDR_BITS{1'b0}}),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);
end else begin : g_no_memory_store
    assign video_read_req_ack_mem=1'b1;
    assign read_buffer_toggle_mem=1'b0;
    assign read_buffer_index_mem=2'd0;
    assign video_read_data=32'd0;
    assign frame_write_req_ack_mem=1'b0;
    assign frame_write_finish=1'b0;
    assign sd_card_write_data_ready=1'b0;
    assign Sdr_init_done=1'b0;
    assign Sdr_init_ref_vld=1'b0;
    assign Sdr_busy=1'b0;
    assign Sdr_rd_en=1'b0;
    assign Sdr_rd_dout=32'd0;
end endgenerate

// ===================== SD PCM WAV -> HDMI audio =====================
// 32 bits/channel keeps 48kHz PCM while halving external BCLK to 3.072MHz.
// ACA's synchronized return then has a full 162ns half-bit propagation budget.
audio_wav_i2s #(.SLOT_BITS(32),.CHECKSUM(1)) u_music_i2s(
 .mclk(audio_mclk),.rst(rst_all),.enable(music_enable),.paused(playback_paused),.stream_ok(music_ok),
 .fifo_used(music_used),.fifo_empty(music_empty),.fifo_valid(music_valid),.fifo_data(music_data),.fifo_re(music_pop),
 .bclk(audio_i2s_bclk),.lrck(audio_i2s_lrck),.dout(audio_i2s_dout),
 .playing(music_playing),.underflow(music_underflow),.underruns(music_underruns));

assign music_bclk=audio_i2s_bclk;
assign music_lrck=audio_i2s_lrck;
assign music_out=audio_i2s_dout;
// Switch at stereo-frame boundaries; returning data remains in the video
// receiver's normal oversampled input path. Mode 0 needs no added wires.
reg [1:0] effect_sync;
wire effect_route;
always @(posedge audio_mclk or posedge rst_all)begin
 if(rst_all)begin effect_sync<=0;end
 else begin
  effect_sync<={effect_sync[0],remote_online && music_enable && remote_status[20:19]!=0};
 end
end
wire [23:0] checked_left,checked_right,local_left,local_right;
wire [15:0] return_errors;
wire checked_present;
reg [1:0] effect_video;
reg effect_frame;
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)begin effect_video<=0;effect_frame<=0;end
 else begin
  effect_video<={effect_video[0],effect_sync[1]};
  if(audio_valid)effect_frame<=effect_video[1];
 end
end
assign effect_route=effect_frame;
music_checked_stereo u_return_checked(.clk(video_clk),.rst(rst_all),.bclk(audio_i2s_bclk),
 .lrck(audio_i2s_lrck),.din(music_return),.left(checked_left),.right(checked_right),
 .present(checked_present),.errors(return_errors),.link_state(music_return_state));
assign music_return_present=checked_present;
// Select complete PCM words, never multiplex asynchronous serial DATA.
// Invalid return is silent and shown as unavailable, not substituted original.
// Use the same -12dB headroom for bypass and effects so volume alone does not
// masquerade as an effect and switching back to bypass cannot jump by 12dB.
wire signed [15:0] local_left_safe=$signed(local_left[23:8])>>>2;
wire signed [15:0] local_right_safe=$signed(local_right[23:8])>>>2;
assign audio_left_data=effect_frame ? checked_left : {local_left_safe,8'd0};
assign audio_right_data=effect_frame ? checked_right : {local_right_safe,8'd0};
I2S_receiver #(.DATA_DELAY(2),.SLOT_BITS(32)) u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (rst_all),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (local_left),
    .O_audio_right_data (local_right)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    // 四频点和状态层各再延迟1拍，最终像素与同步累计延迟10拍。
    .I_vs          (vs_pipe[9]),
    .I_de          (de_pipe[9]),
    .I_rgb         (vout_data_mic),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
