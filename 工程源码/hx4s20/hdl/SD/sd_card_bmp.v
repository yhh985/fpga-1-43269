`timescale 1ns/1ps
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer BUILTIN_DEMO      = 0,
    parameter integer USER_BMP_TEST     = 0,
    parameter integer MAIN_SD_FEATURES  = 0, // FAT32 + quality scaler; never enabled by test wrappers
    parameter integer FIT_ASPECT = 0,
    parameter integer PREFETCH_NEXT = 0,
    parameter integer SPI_HIGH_SPEED_DIV = 6,
    parameter integer READ_RELEASE_CYCLES = MAIN_SD_FEATURES ? 4 : 32,
    parameter integer AUTO_INTERVAL_SECONDS = 10,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter integer SCAN_TARGET_COUNT = 8,
    parameter integer IMAGE_INDEX_BITS = (SCAN_TARGET_COUNT>1 ? $clog2(SCAN_TARGET_COUNT) : 1),
    parameter integer IMAGE_COUNT_BITS = $clog2(SCAN_TARGET_COUNT+1)
)(
    input [1:0] zoom_level,output reg [1:0] display_zoom,
    input audio_clk, music_pop,
    input music_next_toggle,music_prev_toggle,
    output [31:0] music_data,output music_valid,music_empty,
    output [12:0] music_used,output music_ok,music_error,music_found,
    output [2:0] music_track,output [3:0] music_tracks,
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       audio_play_enable,
    input                       background_music_enable,
    input                       playback_pause,
    input                       auto_play_enable, // 顶层持有播放状态，高电平启用
    input                       test_mode,        // 高电平：仅暂停新任务，已开始的帧安全完成
    input                       audio_next_toggle, // 音调事件toggle，忙时合并保留一次请求
    input voice_next_toggle,voice_prev_toggle,
    output [3:0]                state_code,
    output [3:0]                status_code,  // display-only diagnostic, parser state is unchanged
    output [3:0]                sd_error_code,
    output [5:0]                sd_last_cmd,
    output [7:0]                sd_last_r1,
    output reg                  sd_error,    // sticky command failure; cleared after success
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output [15:0]               src_w,        // 实际图片宽度
    output [15:0]               src_h,        // 实际图片高度
    output reg [15:0]           display_src_w,
    output reg [15:0]           display_src_h,
    output reg                  display_valid,

    input                       write_finish_toggle,
    input                       read_buffer_toggle, // mem-domain event after reader commits its new base
    input [1:0]                 read_buffer_index,  // held stable until the next reader event
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output [IMAGE_INDEX_BITS-1:0] current_pic_idx, // source index is independent of the two frame buffers
    output [3:0]                debug_state,
    output [3:0]                debug_rd_cnt,
    output [7:0]                debug_byte0,
    output [7:0]                debug_byte1,
    output                      debug_data_valid,

    output                      write_req,
    input                       write_req_ack,
    input                       write_data_ready, // write_clk-domain FIFO capacity
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
// sd_init_done is generated in the SDRAM clock domain.  Do not use its
// asynchronous deassertion as a reset in this SD clock domain: recovery
// timing on the scaler reset path is otherwise timing-critical.
reg [1:0]        sd_init_done_sync;
wire             sd_ready = sd_init_done_sync[1];
wire             sd_error_event;
wire [3:0]       card_sd_error_code;
reg              parser_error;
reg              sd_init_done_d;
reg              resize_hold;
wire             bmp_ready;
reg              scheduler_ready;
wire             raw_ready;
wire             raw_write_req, raw_write_req_ack;
wire             resize_input_ready, resize_busy, resize_done;
wire             scaled_write_req, scaled_write_en;
wire [31:0]      scaled_write_data;
wire             bmp_load_failed;
// Hold the scaler in reset from a register in its own clock domain.  The
// synchronized ready flag may change only on clk edges, so reset release has
// no cross-domain recovery path.
wire             resize_rst = rst || resize_hold || bmp_load_failed;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [IMAGE_COUNT_BITS-1:0] scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              initial_load_failed;
reg [1:0]        auto_play_sync;
wire             auto_play_en = auto_play_sync[1];
reg [1:0]        test_mode_sync;
wire             test_active = test_mode_sync[1];
reg [1:0] audio_play_sync, pause_sync;
reg [1:0] background_music_sync;
reg [1:0] previous_mode;
wire [1:0] selected_mode = auto_play_en ? 2'd1 : audio_play_sync[1] ? 2'd2 : 2'd0;
wire controls_changed = selected_mode != previous_mode;
wire tasks_paused = test_active || pause_sync[1];
reg [2:0]        audio_next_sync;
reg [2:0] voice_next_sync,voice_prev_sync;
reg request_previous,voice_request;
reg [1:0] load_zoom;
wire [1:0] requested_zoom=(^zoom_level === 1'bx) ? 2'd1 : zoom_level;
wire voice_next_event=voice_next_sync[2]^voice_next_sync[1];
wire voice_prev_event=voice_prev_sync[2]^voice_prev_sync[1];
wire [IMAGE_INDEX_BITS-1:0] prev_from_current;
reg [31:0] prev_sector;
wire             audio_next_event = audio_next_sync[2] ^ audio_next_sync[1];
reg [31:0]       auto_cnt;
reg [IMAGE_COUNT_BITS-1:0] img_found_count;
reg [IMAGE_INDEX_BITS-1:0] img_idx;      // 当前真正显示中的图片编号
reg [IMAGE_INDEX_BITS-1:0] load_idx;     // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0] current_sector;
(* ram_style="bram" *) reg [31:0] img_sectors[0:SCAN_TARGET_COUNT-1];
reg [31:0] next_sector;
reg              next_req_pending;
reg              load_busy;
reg prefetch_load,prefetch_valid,prefetch_failed;
reg [15:0] prefetch_w,prefetch_h;
wire prefetch_hit=PREFETCH_NEXT && prefetch_valid &&
    load_idx==(request_previous?prev_from_current:next_from_current) && load_zoom==requested_zoom;

// bmp_ready 表示源读取与缩放都完成；切显示还要等待独立的 SDRAM 写完事件。
reg              source_done_seen;
reg              source_started_seen;
reg              mem_done_seen;
reg              switch_wait; // keep the previous display buffer reserved until real reader confirmation
reg [2:0]        rdbuf_tgl_sync;
reg [1:0]        rdbuf_idx_sync0, rdbuf_idx_sync1;
wire             read_buffer_selected = rdbuf_tgl_sync[2] ^ rdbuf_tgl_sync[1];

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;
wire [IMAGE_INDEX_BITS-1:0] next_from_current;

// The external writer only receives complete 640x480 scaled frames.
// Fatal card loss immediately cancels the partial source/scaler output;
// the scheduler retains the last fully committed display buffer.
assign write_req = scaled_write_req && sd_ready && !bmp_load_failed;
assign write_en = scaled_write_en && sd_ready && !bmp_load_failed;
assign write_data = scaled_write_data;
assign bmp_ready = raw_ready && !resize_busy;
// Register the parser/scaler ready decode before high-fanout scheduler enables.
// In-flight completion still requires the independently latched SDRAM event.
always @(posedge clk or posedge rst) begin
    if(rst)scheduler_ready<=1'b0;
    else scheduler_ready<=bmp_ready;
end
// B identifies a BMP parser/header/sector-length rejection, independently
// of command errors. Never display ERR with a misleading success code E0.
assign sd_error_code = parser_error ? 4'hb : card_sd_error_code;
wire main_auto_tick;
wire [2:0] main_auto_carry;
wire main_auto_run = !tasks_paused && !controls_changed && scan_done && auto_play_en && display_valid && !load_busy && !switch_wait && first_image_committed && (img_found_count > 4'd1);
wire [31:0] main_auto_increment={
 (auto_cnt[31:24]+{7'd0,main_auto_carry[2]}),
 (auto_cnt[23:16]+{7'd0,main_auto_carry[1]}),
 (auto_cnt[15:8]+{7'd0,main_auto_carry[0]}),
 (auto_cnt[7:0]+8'd1)};
// Main-only lookahead removes the 32-bit timer carry and terminal decode
// from the scheduler's high-fanout 100 MHz enable paths. Legacy test unchanged.
generate if(MAIN_SD_FEATURES)begin : g_main_timer
 reg terminal;
 reg [2:0] carry;
 assign main_auto_tick=terminal;
 assign main_auto_carry=carry;
 always @(posedge clk or posedge rst)begin
  if(rst)begin terminal<=0;carry<=0;end
  else begin
   terminal<=main_auto_run && !auto_tick && auto_cnt==(CLK_FREQ_HZ*AUTO_INTERVAL_SECONDS-2);
   carry[0]<=main_auto_run && !auto_tick && auto_cnt[7:0]==8'hfe;
   carry[1]<=main_auto_run && !auto_tick && auto_cnt[15:0]==16'hfffe;
   carry[2]<=main_auto_run && !auto_tick && auto_cnt[23:0]==24'hfffffe;
  end
 end
end else begin : g_legacy_timer
 assign main_auto_tick=0;assign main_auto_carry=0;
end endgenerate
assign auto_tick  = MAIN_SD_FEATURES ? main_auto_tick : (auto_cnt == (CLK_FREQ_HZ * AUTO_INTERVAL_SECONDS - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign prev_from_current = img_idx==0?img_found_count-1'b1:img_idx-1'b1;
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

// A load's completion events are independent of pause/mode/next-image
// scheduling. Keep these three latches out of the dispatch priority mux;
// either source or memory may finish first, including while paused.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        source_started_seen <= 1'b0;
        source_done_seen <= 1'b0;
        mem_done_seen <= 1'b0;
    end else if (!sd_ready || !load_busy || bmp_load_failed ||
                 (source_done_seen && mem_done_seen)) begin
        source_started_seen <= 1'b0;
        source_done_seen <= 1'b0;
        mem_done_seen <= 1'b0;
    end else begin
        if (!scheduler_ready) source_started_seen <= 1'b1;
        if (source_started_seen && scheduler_ready) source_done_seen <= 1'b1;
        if (write_finish_pulse) mem_done_seen <= 1'b1;
    end
end

// Keep diagnostics independent of scheduling and frame-commit handshakes.
// A successful initialization or complete new frame clears an old error;
// an error in the same cycle has priority and remains visible.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sd_error <= 1'b0;
        sd_init_done_d <= 1'b0;
        sd_init_done_sync <= 2'b00;
        resize_hold <= 1'b1;
        parser_error <= 1'b0;
    end else begin
        sd_init_done_sync <= {sd_init_done_sync[0], sd_init_done};
        sd_init_done_d <= sd_ready;
        resize_hold <= !sd_ready;
        if (sd_error_event || bmp_load_failed) begin
            sd_error <= 1'b1;
            parser_error <= bmp_load_failed && !sd_error_event;
        end
        else if ((sd_ready && !sd_init_done_d) ||
                 (load_busy && source_done_seen && mem_done_seen)) begin
            sd_error <= 1'b0;
            parser_error <= 1'b0;
        end
    end
end

// 0=initializing, 1=ready, 2=scan/header, 3=write wait, 4=pixel read,
// 5=no supported image, 6=waiting for the other frame-completion event.
assign status_code = !sd_ready ? 4'd0 :
                     (scan_done && (img_found_count == 4'd0)) ? 4'd5 :
                     (switch_wait || (load_busy && (source_done_seen || mem_done_seen))) ? 4'd6 :
                     state_code;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

// 自动播放是已消抖的状态，不应再次按低有效机械按键解释。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        auto_play_sync <= 2'b00;audio_play_sync<=0;background_music_sync<=0;pause_sync<=0;previous_mode<=0;
        // Fail closed until the video domain has selected its debounced mode.
        test_mode_sync <= 2'b11;
        audio_next_sync <= 3'b000;voice_next_sync<=0;voice_prev_sync<=0;
    end else begin
        auto_play_sync <= {auto_play_sync[0], auto_play_enable};
        audio_play_sync <= {audio_play_sync[0], audio_play_enable};
        background_music_sync <= {background_music_sync[0], background_music_enable === 1'b1};
        pause_sync <= {pause_sync[0], playback_pause};
        previous_mode <= selected_mode;
        test_mode_sync <= {test_mode_sync[0], test_mode};
        // Two destination flops plus event history; consume toggles even
        // while paused/busy so they cannot replay after a later resume.
        audio_next_sync <= {audio_next_sync[1:0], audio_next_toggle};
        voice_next_sync<={voice_next_sync[1:0],voice_next_toggle};
        voice_prev_sync<={voice_prev_sync[1:0],voice_prev_toggle};
    end
end

function [IMAGE_INDEX_BITS-1:0] next_index_limited;
    input [IMAGE_INDEX_BITS-1:0] cur;
    input [IMAGE_COUNT_BITS-1:0] count;
    begin
        if (count<=1 || ({1'b0,cur}+1'b1)>=count)
            next_index_limited=0;
        else next_index_limited=cur+1'b1;
    end
endfunction

function [31:0] sector_lut;
    input [IMAGE_INDEX_BITS-1:0] idx;
    begin
        sector_lut = idx<SCAN_TARGET_COUNT ? img_sectors[idx] : img_sector0;
    end
endfunction

// Synchronous table read avoids a large sector mux as the album grows.
// Commit and reader acknowledgement leave several cycles for the next read.
always @(posedge clk) begin
    if(sd_ready && scan_found_valid && img_found_count<SCAN_TARGET_COUNT)
        img_sectors[img_found_count[IMAGE_INDEX_BITS-1:0]]<=scan_found_sector;
    next_sector<=img_sectors[next_from_current];
    prev_sector<=img_sectors[prev_from_current];
end

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        rdbuf_tgl_sync        <= 3'b000;
        rdbuf_idx_sync0       <= 2'd0;
        rdbuf_idx_sync1       <= 2'd0;
        switch_wait          <= 1'b0;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        initial_load_failed   <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 4'd0;
        img_idx               <= 3'd0;
        display_src_w         <= 16'd0;
        display_src_h         <= 16'd0;
        load_idx              <= 3'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;current_sector<=0;
        next_req_pending      <= 1'b0;request_previous<=0;voice_request<=0;
        load_busy             <= 1'b0;
        prefetch_load<=0;prefetch_valid<=0;prefetch_failed<=0;prefetch_w<=0;prefetch_h<=0;
        display_valid         <= 1'b0;display_zoom<=1;load_zoom<=1;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        // Data has two settling stages; the event has three. The reader
        // holds its index for a full frame, so the event observes one index.
        rdbuf_tgl_sync   <= {rdbuf_tgl_sync[1:0], read_buffer_toggle};
        rdbuf_idx_sync0  <= read_buffer_index;
        rdbuf_idx_sync1  <= rdbuf_idx_sync0;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        // Reader ownership remains meaningful during a test display or SD
        // initialization loss. Do not discard the acknowledgement in either.
        if (switch_wait && read_buffer_selected && rdbuf_idx_sync1 == disp_buf_idx)
            switch_wait <= 1'b0;

        if (!sd_ready) begin
            prefetch_load<=0;prefetch_valid<=0;prefetch_failed<=0;
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            initial_load_failed   <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 4'd0;
            load_idx              <= 3'd0;
            pending_buf_idx       <= 2'd0;
            img_sector0           <= 32'd0;
            next_req_pending      <= 1'b0;request_previous<=0;voice_request<=0;
            load_busy             <= 1'b0;
            // The last complete SDRAM frame is independent of card health.
            // Keep its validity, image number and buffer reservation intact.
        end else begin
            // Cache each supported BMP header up to the configured album limit.
            if (scan_found_valid) begin
                if(img_found_count==0)img_sector0<=scan_found_sector;
                if (img_found_count < SCAN_TARGET_COUNT)
                    img_found_count <= img_found_count + 1'b1;
            end

            // 先观察源模块进入忙状态，避免把发起请求前的 ready 当成完成。
            // 源缩放完成和 SDRAM 提交完成分别锁存，不能把 FIFO 接收当成落盘。
            // 保留两个事件的任意先后顺序支持，避免依赖具体内存流水线延迟。

            if (load_busy && bmp_load_failed) begin
                prefetch_valid<=0;prefetch_load<=0;
                if(prefetch_load)prefetch_failed<=1;
                // Invalid header/short source sector cancels this pending frame.
                // The previous complete display buffer remains untouched.
                load_busy <= 1'b0;
                if(!prefetch_load)begin next_req_pending <= 1'b0;request_previous<=0;voice_request<=0;end
                // Recovery may retain a valid old frame, but its first newly
                // scanned image still needs an explicit retry after rejection.
                if (!first_image_committed)
                    initial_load_failed <= 1'b1;
            end else if (load_busy && source_done_seen && mem_done_seen) begin
                load_busy             <= 1'b0;
                if(prefetch_load)begin
                    prefetch_load<=0;prefetch_valid<=1;
                    prefetch_w<=src_w;prefetch_h<=src_h;
                end else begin
                prefetch_valid<=0;prefetch_failed<=0;
                disp_buf_idx          <= pending_buf_idx;
                switch_wait           <= 1'b1;
                img_idx               <= load_idx;
                display_zoom<=load_zoom;current_sector<=load_sector;
                display_src_w         <= src_w;
                display_src_h         <= src_h;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                initial_load_failed   <= 1'b0;
                end
            end

            // Scan once after initialization; fewer files form a shorter loop.
            if (!tasks_paused && !controls_changed && !scan_kicked && scheduler_ready && !load_busy && !switch_wait) begin
                prefetch_valid<=0;prefetch_failed<=0;
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                initial_load_failed   <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 4'd0;
                load_idx              <= 3'd0;
                pending_buf_idx       <= 2'd0;
                next_req_pending      <= 1'b0;request_previous<=0;voice_request<=0;
                load_busy             <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (controls_changed || (tasks_paused && !voice_request))begin
                    next_req_pending <= 1'b0;request_previous<=0;voice_request<=0;end
                else if (key_next_press && scan_done && (img_found_count > 4'd0)) begin
                    next_req_pending <= 1'b1;request_previous<=0;voice_request<=0;
                    initial_load_failed <= 1'b0; // explicit retry after an invalid first header
                end
                else if (selected_mode == 2 && audio_next_event && scan_done && display_valid &&
                         first_image_committed &&
                         (img_found_count > 4'd1)) begin
                    // Capture even while the next frame is being prefetched.
                    // Launch/commit below still waits for source, memory and reader ownership.
                    // Coalesce to one request; pause/mode change cancels it above.
                    next_req_pending <= 1'b1;request_previous<=0;voice_request<=0;
                end

                if((voice_next_event || voice_prev_event) && scan_done && display_valid && img_found_count>1)begin
                    next_req_pending<=1;request_previous<=voice_prev_event;voice_request<=1;
                end

                // 自动播放 10s（可参数化）计数：只有当前没有写图任务时才计时
                if (!tasks_paused && !controls_changed && scan_done && auto_play_en && display_valid && !load_busy && !switch_wait && first_image_committed && (img_found_count > 4'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= MAIN_SD_FEATURES ? main_auto_increment : auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // Cold first frame uses buffer0. A rescan after card failure
                // loads the opposite buffer, preserving the retained image.
                if (!tasks_paused && !controls_changed && scan_done && !first_image_committed && !initial_load_failed && scheduler_ready && !load_busy && !switch_wait && (img_found_count != 4'd0)) begin
                    load_idx         <= 3'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;load_zoom<=requested_zoom;
                    load_busy        <= 1'b1;
                    next_req_pending <= 1'b0;request_previous<=0;voice_request<=0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (!tasks_paused && !controls_changed && scan_done && scheduler_ready && display_valid && !load_busy && !switch_wait && next_req_pending && (img_found_count != 4'd0)) begin
                    if(prefetch_hit)begin
                        // Both source and SDRAM completion were acknowledged.
                        // Commit the prepared frame without any new SD request.
                        disp_buf_idx<=pending_buf_idx;switch_wait<=1;img_idx<=load_idx;
                        display_zoom<=load_zoom;current_sector<=load_sector;
                        display_src_w<=prefetch_w;display_src_h<=prefetch_h;
                        prefetch_valid<=0;prefetch_failed<=0;
                    end else begin
                    prefetch_valid<=0;prefetch_failed<=0;
                    load_idx         <= request_previous?prev_from_current:next_from_current;
                    load_sector      <= request_previous?prev_sector:next_sector;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;load_zoom<=requested_zoom;
                    load_busy        <= 1'b1;
                    end
                    next_req_pending <= 1'b0;request_previous<=0;voice_request<=0;
                    auto_cnt         <= 32'd0;
                end
                // Zoom redraw is a new complete frame of the SAME file.
                // Keep the old display and reader reservation until commit.
                else if (!tasks_paused && !controls_changed && scan_done && scheduler_ready && display_valid && first_image_committed && !load_busy && !switch_wait && requested_zoom!=display_zoom && MAIN_SD_FEATURES) begin
                    prefetch_valid<=0;prefetch_failed<=0;
                    load_idx<=img_idx;load_sector<=current_sector;
                    pending_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    write_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    load_start_pulse<=1;load_zoom<=requested_zoom;load_busy<=1;auto_cnt<=0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (!tasks_paused && !controls_changed && scan_done && scheduler_ready && display_valid && !load_busy && !switch_wait && auto_play_en && auto_tick && (img_found_count > 4'd1)) begin
                    if(PREFETCH_NEXT && prefetch_valid && load_idx==next_from_current && load_zoom==requested_zoom)begin
                        disp_buf_idx<=pending_buf_idx;switch_wait<=1;img_idx<=load_idx;
                        display_zoom<=load_zoom;current_sector<=load_sector;
                        display_src_w<=prefetch_w;display_src_h<=prefetch_h;
                        prefetch_valid<=0;prefetch_failed<=0;
                    end else begin
                    prefetch_valid<=0;prefetch_failed<=0;
                    load_idx         <= next_from_current;
                    load_sector      <= next_sector;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;load_zoom<=requested_zoom;
                    load_busy        <= 1'b1;
                    end
                    auto_cnt         <= 32'd0;
                end
                else if(PREFETCH_NEXT && !tasks_paused && !controls_changed && scan_done &&
                        scheduler_ready && display_valid && first_image_committed && !load_busy &&
                        !switch_wait && !prefetch_failed && !next_req_pending && img_found_count>1 &&
                        requested_zoom==display_zoom && (!prefetch_valid || load_zoom!=requested_zoom))begin
                    // Never overwrite a frame still reserved by the reader or
                    // a transition. Top-level pause includes transition-active.
                    load_idx<=next_from_current;load_sector<=next_sector;
                    pending_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    write_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    load_start_pulse<=1;load_zoom<=requested_zoom;load_busy<=1;
                    prefetch_load<=1;prefetch_valid<=0;
                end
            end
        end
    end
end

localparam [IMAGE_COUNT_BITS-1:0] SCAN_LIMIT=SCAN_TARGET_COUNT;
wire fs_init_done,fs_error;
wire [IMAGE_COUNT_BITS-1:0] fs_file_count;
wire [31:0] fs_last_sector,fs_native_addr;
wire fs_native_req,fs_data_valid,fs_read_end;
wire [7:0] fs_data;
bmp_read #(.COUNT_BITS(IMAGE_COUNT_BITS)) bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (raw_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (MAIN_SD_FEATURES ? 32'd2048 : SCAN_START_SECTOR),
    .scan_max_sector        (MAIN_SD_FEATURES ? fs_last_sector : SCAN_MAX_SECTOR),
    .scan_target_count      (MAIN_SD_FEATURES && fs_file_count<SCAN_LIMIT ? fs_file_count : SCAN_LIMIT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .load_failed            (bmp_load_failed),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .src_w                  (src_w),
    .src_h                  (src_h),
    .write_req              (raw_write_req),
    .write_req_ack          (raw_write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_ready         (resize_input_ready),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .debug_state            (debug_state),
    .debug_rd_cnt           (debug_rd_cnt),
    .debug_byte0            (debug_byte0),
    .debug_byte1            (debug_byte1),
    .debug_data_valid       (debug_data_valid)
);

wire legacy_ack,legacy_ready,legacy_req,legacy_en,legacy_busy,legacy_done;
wire [31:0] legacy_data;
wire quality_ack,quality_ready,quality_req,quality_en,quality_busy,quality_done;
wire [31:0] quality_data;
assign raw_write_req_ack=MAIN_SD_FEATURES ? quality_ack : legacy_ack;
assign resize_input_ready=MAIN_SD_FEATURES ? quality_ready : legacy_ready;
assign scaled_write_req=MAIN_SD_FEATURES ? quality_req : legacy_req;
assign scaled_write_en=MAIN_SD_FEATURES ? quality_en : legacy_en;
assign scaled_write_data=MAIN_SD_FEATURES ? quality_data : legacy_data;
assign resize_busy=MAIN_SD_FEATURES ? quality_busy : legacy_busy;
assign resize_done=MAIN_SD_FEATURES ? quality_done : legacy_done;
// Preserve the legacy test instance and its complete data path.
image_resizer u_image_resizer(
    .clk(clk), .rst(resize_rst), .src_w(src_w), .src_h(src_h),
    .in_write_req(MAIN_SD_FEATURES ? 1'b0 : raw_write_req), .in_write_req_ack(legacy_ack),
    .in_wr_en(bmp_data_wr_en), .in_data({8'd0,bmp_data}),
    .in_ready(legacy_ready), .out_write_req(legacy_req),
    .out_write_req_ack(write_req_ack), .out_wr_en(legacy_en),
    .out_ready(write_data_ready && sd_ready && !bmp_load_failed),
    .out_data(legacy_data), .out_busy(legacy_busy), .out_done(legacy_done)
);
generate if(MAIN_SD_FEATURES)begin : g_main_quality
 image_resizer_sd_quality #(.FIT_ASPECT(FIT_ASPECT)) u_scaler(
  .clk(clk),.rst(resize_rst),.src_w(src_w),.src_h(src_h),.zoom_level(load_zoom),
  .in_write_req(raw_write_req),.in_write_req_ack(quality_ack),
  .in_wr_en(bmp_data_wr_en),.in_data({8'd0,bmp_data}),.in_ready(quality_ready),
  .out_write_req(quality_req),.out_write_req_ack(write_req_ack),
  .out_ready(write_data_ready && sd_ready && !bmp_load_failed),
  .out_wr_en(quality_en),.out_data(quality_data),.out_busy(quality_busy),.out_done(quality_done));
end else begin : g_legacy_quality
 assign quality_ack=0;assign quality_ready=0;assign quality_req=0;assign quality_en=0;
 assign quality_data=0;assign quality_busy=0;assign quality_done=0;
end endgenerate

localparam BUILTIN_SOURCE = BUILTIN_DEMO || USER_BMP_TEST;
wire native_init_done, native_error_event;
wire [3:0] native_error_code;
wire [5:0] native_last_cmd;
wire [7:0] native_last_r1, native_data;
wire native_data_valid, native_read_end;
wire native_cs, native_clk, native_mosi;
wire demo_init_done, demo_data_valid, demo_read_end;
wire [7:0] demo_data;
assign sd_init_done = BUILTIN_SOURCE ? demo_init_done : (MAIN_SD_FEATURES ? fs_init_done : native_init_done);
assign sd_error_event = BUILTIN_SOURCE ? 1'b0 : native_error_event | (MAIN_SD_FEATURES && fs_error);
assign card_sd_error_code = BUILTIN_SOURCE ? 4'd0 : (MAIN_SD_FEATURES && fs_error ? 4'hc : native_error_code);
assign sd_last_cmd = BUILTIN_SOURCE ? 6'd0 : native_last_cmd;
assign sd_last_r1 = BUILTIN_SOURCE ? 8'd0 : native_last_r1;
assign sd_sec_read_data = BUILTIN_SOURCE ? demo_data : (MAIN_SD_FEATURES ? fs_data : native_data);
assign sd_sec_read_data_valid = BUILTIN_SOURCE ? demo_data_valid : (MAIN_SD_FEATURES ? fs_data_valid : native_data_valid);
assign sd_sec_read_end = BUILTIN_SOURCE ? demo_read_end : (MAIN_SD_FEATURES ? fs_read_end : native_read_end);
assign SD_nCS = BUILTIN_SOURCE ? 1'b1 : native_cs;
assign SD_DCLK = BUILTIN_SOURCE ? 1'b0 : native_clk;
assign SD_MOSI = BUILTIN_SOURCE ? 1'b1 : native_mosi;
generate if (USER_BMP_TEST) begin : g_user_bmp
    user_bmp_card u_card(
        .clk(clk), .rst(rst), .init_done(demo_init_done),
        .read_req(sd_sec_read), .read_addr(sd_sec_read_addr),
        .read_data(demo_data), .read_valid(demo_data_valid), .read_end(demo_read_end)
    );
end else if (BUILTIN_DEMO) begin : g_demo
    demo_bmp_card u_card(
        .clk(clk), .rst(rst), .init_done(demo_init_done),
        .read_req(sd_sec_read), .read_addr(sd_sec_read_addr),
        .read_data(demo_data), .read_valid(demo_data_valid), .read_end(demo_read_end)
    );
end else begin : g_no_demo
    assign demo_init_done=1'b0;
    assign demo_data=8'd0;
    assign demo_data_valid=1'b0;
    assign demo_read_end=1'b0;
end endgenerate

generate if(MAIN_SD_FEATURES)begin : g_fat32
 reg [2:0] track_index;
 wire [3:0] track_count;
 wire [2:0] active_track;
 assign music_track=active_track;
 assign music_tracks=track_count;
 reg [2:0] next_sync,prev_sync;
 reg [1:0] switch_state;
 reg [4:0] switch_delay;
 reg [2:0] wanted_track;
 wire switch_hold=switch_state!=0;
 always @(posedge clk or posedge rst)begin
  if(rst)begin next_sync<=0;prev_sync<=0;track_index<=0;wanted_track<=0;switch_state<=0;switch_delay<=0;end
  else begin
   next_sync<={next_sync[1:0],music_next_toggle===1'b1};
   prev_sync<={prev_sync[1:0],music_prev_toggle===1'b1};
   if(!fs_init_done)begin track_index<=0;wanted_track<=0;switch_state<=0;end
   else if((next_sync[2]!=next_sync[1] || prev_sync[2]!=prev_sync[1]) && track_count!=0)begin
    if(next_sync[2]!=next_sync[1])wanted_track<=wanted_track+1>=track_count ? 3'd0 : wanted_track+1'b1;
    else wanted_track<=wanted_track==0 ? track_count-1'b1 : wanted_track-1'b1;
    switch_state<=1;switch_delay<=0;
   end else case(switch_state)
    1:if(!wav_req)begin switch_state<=2;switch_delay<=0;end
    2:if(switch_delay==15)begin track_index<=wanted_track;switch_state<=3;switch_delay<=0;end
      else switch_delay<=switch_delay+1'b1;
    // An image/FAT transaction can outlast thousands of clocks. Wait for
    // the filesystem's acknowledgement, never restart on the old WAV header.
    3:if(active_track!=track_index) switch_delay<=0;
      else if(switch_delay==15)begin switch_state<=0;end else switch_delay<=switch_delay+1'b1;
   endcase
  end
 end
 wire media_req,media_valid,media_end,wav_req,wav_valid,wav_end;
 wire [31:0] media_addr,wav_addr;
 wire [7:0] media_data,wav_data;
 wire [31:0] wav_bytes,pcm_frame;
 wire pcm_valid,fifo_full,session_ok;
 wire [12:0] fifo_used;
 reg [7:0] native_data_r;
 reg native_valid_r,native_end_r;
 // Carry the native byte and both strobes through the same stage. The card
 // release interval permits this extra clock, and request remains held
 // until the delayed sector-end strobe is consumed.
 always @(posedge clk or posedge rst)begin
  if(rst)begin native_data_r<=0;native_valid_r<=0;native_end_r<=0;end
  else begin
   native_data_r<=native_data;
   native_valid_r<=native_data_valid && native_init_done;
   native_end_r<=native_read_end && native_init_done;
  end
 end
 reg urgent;
 always @(posedge clk or posedge rst)begin
  if(rst)begin urgent<=1;end
  else begin urgent<=fifo_used<13'd3072;end
 end
 wav_sector_reader u_music_reader(.clk(clk),.rst(rst),.mounted(fs_init_done),
  .found(music_found),.enabled((audio_play_sync[1] || background_music_sync[1])&&!switch_hold),.file_bytes(wav_bytes),
  .fifo_used(fifo_used),.fifo_full(fifo_full),.read_req(wav_req),.read_addr(wav_addr),
  .read_data(wav_data),.read_valid(wav_valid),.read_end(wav_end),
  .pcm_valid(pcm_valid),.pcm_frame(pcm_frame),.stream_ok(session_ok),.error(music_error),.state_code());
 assign music_ok=session_ok&&!switch_hold;
 // The FIFO's asynchronous reset and two-clock local release already block
 // writes outside a session. Avoid repeating the session decode before the
 // write-pointer increment and full comparison.
 audio_pcm_fifo u_music_fifo(.rst(rst||!session_ok),.wclk(clk),.we(pcm_valid),.din(pcm_frame),
  .full(fifo_full),.wused(fifo_used),.rclk(audio_clk),.re(music_pop),
  .dout(music_data),.valid(music_valid),.empty(music_empty),.rused(music_used));
 sd_media_arbiter u_media_arbiter(.clk(clk),.rst(rst),.mounted(fs_init_done),
  .image_req(sd_sec_read),.image_addr(sd_sec_read_addr),.image_data(fs_data),.image_valid(fs_data_valid),.image_end(fs_read_end),
  .audio_req(wav_req),.audio_addr(wav_addr),.audio_urgent(urgent),.audio_data(wav_data),.audio_valid(wav_valid),.audio_end(wav_end),
  .fs_req(media_req),.fs_addr(media_addr),.fs_data(media_data),.fs_valid(media_valid),.fs_end(media_end));
 fat32_bmp_source #(.MAX_FILES(SCAN_TARGET_COUNT)) u_files(
  .clk(clk),.rst(rst),.native_init_done(native_init_done),.init_done(fs_init_done),.fs_error(fs_error),
  .file_count(fs_file_count),.last_sector(fs_last_sector),.wav_found(music_found),.wav_bytes(wav_bytes),.track_index(track_index),.track_count(track_count),.active_track(active_track),
  .read_req(media_req),.read_addr(media_addr),.read_data(media_data),.read_valid(media_valid),.read_end(media_end),
  .native_req(fs_native_req),.native_addr(fs_native_addr),.native_data(native_data_r),.native_valid(native_valid_r),.native_end(native_end_r));
end else begin : g_no_fat32
 assign music_track=0;assign music_tracks=0;
 assign music_data=0;assign music_valid=0;assign music_empty=1;assign music_used=0;
 assign music_ok=0;assign music_error=0;assign music_found=0;
 assign fs_init_done=0;assign fs_error=0;assign fs_file_count=0;assign fs_last_sector=0;
 assign fs_native_req=0;assign fs_native_addr=0;assign fs_data=0;assign fs_data_valid=0;assign fs_read_end=0;
end endgenerate
sd_card_top #(.READ_MAX_RETRIES(MAIN_SD_FEATURES ? 2 : 0),
    .SPI_HIGH_SPEED_DIV(SPI_HIGH_SPEED_DIV),
    .READ_RELEASE_CYCLES(READ_RELEASE_CYCLES),
    .RESOURCE_OPTIMIZED(MAIN_SD_FEATURES)) sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (native_cs),
    .SD_DCLK                (native_clk),
    .SD_MOSI                (native_mosi),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (native_init_done),
    .sd_error_event         (native_error_event),
    .sd_error_code          (native_error_code),
    .sd_last_cmd            (native_last_cmd),
    .sd_last_r1             (native_last_r1),
    .sd_sec_read            (MAIN_SD_FEATURES ? fs_native_req : sd_sec_read),
    .sd_sec_read_addr       (MAIN_SD_FEATURES ? fs_native_addr : sd_sec_read_addr),
    .sd_sec_read_data       (native_data),
    .sd_sec_read_data_valid (native_data_valid),
    .sd_sec_read_end        (native_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

    assign current_pic_idx = img_idx;  // 引出当前图片编号

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
