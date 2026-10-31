`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Dynamic status OSD overlay
//
// Status uses a small 5x7 ASCII font (2x pixel scale).  The bottom caption
// uses a dedicated synchronous 16x16 Chinese gray-level ROM. Input status signals
// must already be synchronized to I_clk by the caller.
//
// Default text (39 cells, 16 pixels per cell), at y=28:
//   IMGnn AUTO PLAY TRAN SCAN Fm MM:SS OK
// A Chinese caption scrolls at y=448, clear of the top parameter/status rows.
// A 4-pixel bar at
// y=64 shows transition progress only, not SD loading or autoplay timing.
// MM:SS is elapsed frame time (FRAME_RATE frames/second), not a real-time clock.
// All state and progress are captured at falling VS to prevent tearing.
//
// I_de/I_vs follow the same raster convention as osd_overlay.v.  O_rgb_out is
// registered by one I_clk and has no combinational path from the input pixel.
// -----------------------------------------------------------------------------
module osd_status_overlay #(
    parameter DATA_WIDTH      = 24,
    parameter FRAME_WIDTH     = 640,
    parameter FRAME_HEIGHT    = 480,
    parameter STATUS_START_X  = 8,
    parameter STATUS_START_Y  = 28,
    parameter STATUS_CHARS    = 39,
    parameter SCROLL_START_Y  = 448,
    parameter PROGRESS_START_Y = 64,
    parameter integer FRAME_RATE = 60,
    parameter integer SCROLL_FRAMES = 1,
    parameter integer SCROLL_STEP = 1,
    parameter integer MUSIC_STATUS = 0,
    parameter integer ZOOM_STATUS = 0,
    parameter integer PLAYBACK_STATUS = 0
)(
    input [1:0] I_zoom_level,
    input [3:0] I_music_status,
    input                       I_clk,
    input                       I_rst,
    input                       I_vs,
    input                       I_hs,
    input                       I_de,
    input      [DATA_WIDTH-1:0] I_rgb,
    input      [6:0]            I_img_idx,
    input      [15:0]           I_src_w,
    input      [15:0]           I_src_h,
    input                       I_src_valid,
    input      [2:0]            I_filter_mode,
    input                       I_auto_play,
    input [1:0]                 I_playback_mode,
    input                       I_paused,
    input                       I_trans_active,
    input      [4:0]            I_trans_alpha,
    input      [3:0]            I_state_code,
    input                       I_sd_error,
    input      [3:0]            I_sd_error_code,
    input      [5:0]            I_sd_last_cmd,
    input      [7:0]            I_sd_last_r1,
    input                       I_osd_en,
    input                       I_test_mode,
    output reg [DATA_WIDTH-1:0] O_rgb_out
);

    reg [1:0] zoom_frame;
    reg [3:0] music_frame;
    reg [9:0] px_x;
    reg [9:0] px_y;
    reg       vs_d0;
    reg       de_d0;
    wire      vs_falling = vs_d0 & ~I_vs;

    reg [6:0] img_idx_frame;
    reg [15:0] src_w_frame, src_h_frame;
    reg src_valid_frame;
    `include "decimal_two_digits.vh"
    reg [7:0] image_digits_frame;
    reg [2:0] filter_frame;
    reg auto_frame, trans_frame, error_frame, osd_frame, test_frame;
    reg [1:0] mode_frame;
    reg paused_frame;
    reg [4:0] alpha_frame;
    reg [3:0] state_frame;
    reg [3:0] error_code_frame;
    reg [5:0] last_cmd_frame;
    reg [7:0] last_r1_frame;
    localparam integer SECOND_COUNT_WIDTH=(FRAME_RATE<2)?1:$clog2(FRAME_RATE);
    localparam integer SCROLL_COUNT_WIDTH=(SCROLL_FRAMES<2)?1:$clog2(SCROLL_FRAMES);
    reg [SECOND_COUNT_WIDTH-1:0] second_frame_count;
    reg [SCROLL_COUNT_WIDTH-1:0] scroll_frame_count;
    reg [3:0] minute_tens, minute_ones, second_tens, second_ones;
    reg [9:0] scroll_offset;
    localparam integer SCROLL_WIDTH = FRAME_WIDTH - 2*STATUS_START_X;
    localparam integer SCROLL_CYCLE = SCROLL_WIDTH + 16*16;
    reg [15:0] scroll_random;
    reg [2:0] scroll_message, scroll_color_index;
    wire [2:0] random_message = scroll_random[2:0];
    wire [2:0] random_color = scroll_random[7:5];
    wire [10:0] scroll_next = {1'b0, scroll_offset} + SCROLL_STEP;

    // Advance continuously so user timing varies the choices. This is a
    // maximal-length pseudo-random sequence, not a source of physical entropy.
    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst) scroll_random<=16'hACE1;
        else scroll_random<={scroll_random[14:0],
            scroll_random[15]^scroll_random[13]^scroll_random[12]^scroll_random[10]};
    end

    // The caller synchronizes CDC signals before these frame registers.  The
    // extra frame boundary also makes every line of text use one snapshot.
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            zoom_frame<=1;music_frame<=0;
            img_idx_frame <= 7'd0;
            src_w_frame <= 16'd0; src_h_frame <= 16'd0; src_valid_frame <= 1'b0;
            image_digits_frame<=0;
            filter_frame <= 3'd0;
            auto_frame <= 1'b0; trans_frame <= 1'b0;mode_frame<=0;paused_frame<=0;
            error_frame <= 1'b0; osd_frame <= 1'b0; test_frame <= 1'b0;
            alpha_frame <= 5'd0; state_frame <= 4'd0;
            error_code_frame <= 4'd0;
            last_cmd_frame <= 6'd0; last_r1_frame <= 8'hff;
            second_frame_count <= 16'd0;
            scroll_frame_count <= 16'd0;
            minute_tens <= 4'd0; minute_ones <= 4'd0;
            second_tens <= 4'd0; second_ones <= 4'd0;
            scroll_offset <= 10'd0;
            scroll_message <= 0; scroll_color_index <= 0;
        end else if (vs_falling) begin
            zoom_frame<=I_zoom_level;music_frame<=I_music_status;
            img_idx_frame <= I_img_idx;
            src_w_frame <= I_src_w; src_h_frame <= I_src_h; src_valid_frame <= I_src_valid;
            image_digits_frame<=decimal_two_digits(I_img_idx);
            filter_frame <= I_filter_mode;
            test_frame <= I_test_mode;
            mode_frame <= PLAYBACK_STATUS ? I_playback_mode : (I_auto_play ? 2'd1 : 2'd0);
            paused_frame <= PLAYBACK_STATUS && I_paused;
            auto_frame <= I_auto_play && !I_test_mode;
            trans_frame <= I_trans_active && !I_test_mode;
            error_frame <= I_sd_error && !I_test_mode; osd_frame <= I_osd_en;
            alpha_frame <= I_test_mode ? 5'd0 : I_trans_alpha;
            state_frame <= I_test_mode ? 4'd7 : I_state_code;
            error_code_frame <= I_test_mode ? 4'd0 : I_sd_error_code;
            last_cmd_frame <= I_sd_last_cmd;
            last_r1_frame <= I_sd_last_r1;

            if (second_frame_count == FRAME_RATE-1) begin
                second_frame_count <= 16'd0;
                if (second_ones == 4'd9) begin
                    second_ones <= 4'd0;
                    if (second_tens == 4'd5) begin
                        second_tens <= 4'd0;
                        if (minute_ones == 4'd9) begin
                            minute_ones <= 4'd0;
                            minute_tens <= (minute_tens == 4'd9) ? 4'd0 : minute_tens + 1'b1;
                        end else minute_ones <= minute_ones + 1'b1;
                    end else second_tens <= second_tens + 1'b1;
                end else second_ones <= second_ones + 1'b1;
            end else second_frame_count <= second_frame_count + 1'b1;

            if (scroll_frame_count == SCROLL_FRAMES-1) begin
                scroll_frame_count <= 16'd0;
                if (scroll_next >= SCROLL_CYCLE) begin
                    // Both ends are blank here. A whole caption and color are
                    // kept together until the old caption has exited fully.
                    scroll_offset <= 0;
                    scroll_message <= (random_message==scroll_message)?
                        random_message+3'd1:random_message;
                    scroll_color_index <= (random_color==scroll_color_index)?
                        random_color+3'd1:random_color;
                end else scroll_offset <= scroll_next[9:0];
            end else scroll_frame_count <= scroll_frame_count + 1'b1;
        end
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            px_x  <= 10'd0;
            px_y  <= 10'd0;
            vs_d0 <= 1'b0;
            de_d0 <= 1'b0;
        end else begin
            vs_d0 <= I_vs;
            de_d0 <= I_de;
            if (I_de) begin
                if (px_x < FRAME_WIDTH-1)
                    px_x <= px_x + 1'b1;
                else
                    px_x <= 10'd0;
            end else begin
                px_x <= 10'd0;
            end
            if (vs_falling)
                px_y <= 10'd0;
            else if (de_d0 && !I_de && px_y < FRAME_HEIGHT-1)
                px_y <= px_y + 1'b1;
        end
    end

    wire in_status_x = (px_x >= STATUS_START_X) &&
                       (px_x < STATUS_START_X + STATUS_CHARS*16);
    wire in_status_y = (px_y >= STATUS_START_Y) &&
                       (px_y < STATUS_START_Y + 14);
    wire in_status = in_status_x && in_status_y && I_de && osd_frame;
    wire in_scroll = (px_x >= STATUS_START_X) &&
                     (px_x < FRAME_WIDTH - STATUS_START_X) &&
                     (px_y >= SCROLL_START_Y) && (px_y < SCROLL_START_Y+16) &&
                     I_de && osd_frame;
    wire in_progress = (px_x >= STATUS_START_X) &&
                       (px_x < STATUS_START_X + STATUS_CHARS*16) &&
                       (px_y >= PROGRESS_START_Y) && (px_y < PROGRESS_START_Y+4) &&
                       I_de && osd_frame && trans_frame && !test_frame && !I_test_mode;

    wire [9:0] status_offset_x = px_x - STATUS_START_X;
    wire [9:0] status_offset_y = px_y - STATUS_START_Y;
    wire [5:0] status_char_idx = status_offset_x[9:4];
    wire [3:0] status_char_x   = status_offset_x[3:0];
    wire [2:0] status_char_y   = status_offset_y[3:1];
    // On an SD failure show the actual reason, command and R1 response below
    // the status row, for example SD E6 C17 R00 (missing data token).
    wire in_diagnostic = error_frame && (error_code_frame != 4'd0) &&
                         !test_frame && !I_test_mode && osd_frame && I_de &&
                         (px_x >= STATUS_START_X) && (px_x < STATUS_START_X+13*16) &&
                         (px_y >= 10'd48) && (px_y < 10'd62);
    wire [9:0] diagnostic_offset_y = px_y - 10'd48;
    wire [2:0] diagnostic_char_y = diagnostic_offset_y[3:1];
    function [7:0] hex_char;
        input [3:0] value;
        begin hex_char = (value < 4'd10) ? 8'h30+value : 8'h41+(value-4'd10); end
    endfunction
    reg [7:0] diagnostic_char;
    always @(*) begin
        case (status_char_idx)
            0: diagnostic_char="S";
            1: diagnostic_char="D";
            3: diagnostic_char="E";
            4: diagnostic_char=hex_char(error_code_frame);
            6: diagnostic_char="C";
            7: diagnostic_char=8'h30+(last_cmd_frame/10);
            8: diagnostic_char=8'h30+(last_cmd_frame%10);
            10: diagnostic_char="R";
            11: diagnostic_char=hex_char(last_r1_frame[7:4]);
            12: diagnostic_char=hex_char(last_r1_frame[3:0]);
            default: diagnostic_char=" ";
        endcase
    end
    wire in_resolution = osd_frame && I_de && src_valid_frame &&
                         (px_x >= STATUS_START_X) && (px_x < STATUS_START_X+(ZOOM_STATUS ? 19 : 17)*16) &&
                         (px_y >= 10'd80) && (px_y < 10'd94);
    wire [5:0] resolution_char_idx = (px_x-STATUS_START_X) >> 4;
    wire [3:0] resolution_char_x = (px_x-STATUS_START_X) & 4'hf;
    wire [2:0] resolution_char_y = (px_y-10'd80) >> 1;
    function [15:0] dimension_bcd;
        input [10:0] value;
        reg [15:0] digits;
        integer bit_no, digit_no;
        begin
            digits=0;
            for(bit_no=10;bit_no>=0;bit_no=bit_no-1)begin
                for(digit_no=0;digit_no<4;digit_no=digit_no+1)
                    if(digits[digit_no*4+:4]>=5)
                        digits[digit_no*4+:4]=digits[digit_no*4+:4]+3;
                digits={digits[14:0],value[bit_no]};
            end
            dimension_bcd=digits;
        end
    endfunction
    // Convert dimensions at the same frame boundary as their snapshot.
    // Keeping BCD conversion out of the pixel/font mux shortens video timing.
    reg [15:0] width_digits,height_digits;
    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst) begin width_digits<=0;height_digits<=0;end
        else if(vs_falling) begin
            width_digits<=dimension_bcd(I_src_w[10:0]);
            height_digits<=dimension_bcd(I_src_h[10:0]);
        end
    end
    reg [7:0] resolution_char;
    always @(*) begin
        case (resolution_char_idx)
            0: resolution_char="S"; 1: resolution_char="R"; 2: resolution_char="C";
            4: resolution_char=src_w_frame<1000 ? " " : 8'h30+width_digits[15:12];
            5: resolution_char=src_w_frame<100 ? " " : 8'h30+width_digits[11:8];
            6: resolution_char=src_w_frame<10 ? " " : 8'h30+width_digits[7:4];
            7: resolution_char=8'h30+width_digits[3:0];
            8: resolution_char="X";
            9: resolution_char=src_h_frame<1000 ? " " : 8'h30+height_digits[15:12];
            10: resolution_char=src_h_frame<100 ? " " : 8'h30+height_digits[11:8];
            11: resolution_char=src_h_frame<10 ? " " : 8'h30+height_digits[7:4];
            12: resolution_char=8'h30+height_digits[3:0];
            14: resolution_char=ZOOM_STATUS ? "X" : "F";
            15: resolution_char=ZOOM_STATUS ? (zoom_frame==0 ? "0" : zoom_frame==3 ? "2" : "1") : "I";
            16: resolution_char=ZOOM_STATUS ? "." : "T";
            17: resolution_char=ZOOM_STATUS ? (zoom_frame==0 || zoom_frame==2 ? "5" : "0") : " ";
            default: resolution_char=" ";
        endcase
    end
    wire in_music=MUSIC_STATUS && osd_frame && I_de &&
        px_x>=320 && px_x<320+12*16 && px_y>=80 && px_y<94;
    wire [3:0] music_idx=(px_x-320)>>4;
    wire [3:0] music_x=(px_x-320)&15;
    wire [2:0] music_y=(px_y-80)>>1;
    reg [31:0] music_label;
    always @(*)case(music_frame)
     0:music_label="OFF ";1:music_label="NONE";2:music_label="BUFF";
     3:music_label="PLAY";4:music_label="PAUS";5:music_label="ERR ";
     6:music_label="UNDR";default:music_label="WAIT";
    endcase
    reg [7:0] music_char;
    always @(*)case(music_idx)
     0:music_char="W";1:music_char="A";2:music_char="V";
     4:music_char=music_label[31:24];5:music_char=music_label[23:16];
     6:music_char=music_label[15:8];7:music_char=music_label[7:0];
     default:music_char=" ";
    endcase
    reg [7:0] sd_c0, sd_c1, sd_c2, sd_c3;
    always @(*) begin
        if (error_frame) begin sd_c0="E"; sd_c1="R"; sd_c2="R"; sd_c3=" "; end
        else case(state_frame)
            4'd0: begin sd_c0="I"; sd_c1="N"; sd_c2="I"; sd_c3="T"; end
            4'd1: begin sd_c0="O"; sd_c1="K"; sd_c2=" "; sd_c3=" "; end
            4'd2: begin sd_c0="S"; sd_c1="C"; sd_c2="A"; sd_c3="N"; end
            4'd3: begin sd_c0="W"; sd_c1="A"; sd_c2="I"; sd_c3="T"; end
            4'd4: begin sd_c0="L"; sd_c1="O"; sd_c2="A"; sd_c3="D"; end
            4'd5: begin sd_c0="N"; sd_c1="O"; sd_c2="N"; sd_c3="E"; end
            4'd6: begin sd_c0="S"; sd_c1="Y"; sd_c2="N"; sd_c3="C"; end
            4'd7: begin sd_c0="T"; sd_c1="E"; sd_c2="S"; sd_c3="T"; end
            default: begin sd_c0="?"; sd_c1="?"; sd_c2="?"; sd_c3="?"; end
        endcase
    end
    reg [7:0] status_char;
    always @(*) begin
        case (status_char_idx)
            6'd0: status_char="I";
            6'd1: status_char="M";
            6'd2: status_char="G";
            6'd3: status_char=8'h30+image_digits_frame[7:4];
            6'd4: status_char=8'h30+image_digits_frame[3:0];
            6'd6: status_char=(mode_frame==2) ? "A" : auto_frame ? "A" : "M";
            6'd7: status_char=(mode_frame==2) ? "U" : auto_frame ? "U" : "A";
            6'd8: status_char=(mode_frame==2) ? "D" : auto_frame ? "T" : "N";
            6'd9: status_char=auto_frame ? "O" : " ";
            6'd11: status_char=PLAYBACK_STATUS ? "P" : auto_frame ? "P" : "I";
            6'd12: status_char=PLAYBACK_STATUS ? (paused_frame ? "A" : "L") : auto_frame ? "L" : "D";
            6'd13: status_char=PLAYBACK_STATUS ? (paused_frame ? "U" : "A") : auto_frame ? "A" : "L";
            6'd14: status_char=PLAYBACK_STATUS ? (paused_frame ? "S" : "Y") : auto_frame ? "Y" : "E";
            6'd15: status_char=(PLAYBACK_STATUS && paused_frame) ? "E" : " ";
            6'd16: status_char=trans_frame ? "T" : "I";
            6'd17: status_char=trans_frame ? "R" : "D";
            6'd18: status_char=trans_frame ? "A" : "L";
            6'd19: status_char=trans_frame ? "N" : "E";
            6'd21: status_char=sd_c0;
            6'd22: status_char=sd_c1;
            6'd23: status_char=sd_c2;
            6'd24: status_char=sd_c3;
            6'd26: status_char="F";
            6'd27: status_char=8'h30 + filter_frame;
            6'd29: status_char=8'h30 + minute_tens;
            6'd30: status_char=8'h30 + minute_ones;
            6'd31: status_char=":";
            6'd32: status_char=8'h30 + second_tens;
            6'd33: status_char=8'h30 + second_ones;
            6'd35: status_char=error_frame ? "E" : "O";
            6'd36: status_char=error_frame ? "R" : "K";
            6'd37: status_char=error_frame ? "R" : " ";
            default: status_char=" ";
        endcase
    end

    wire [10:0] scroll_sum = {1'b0,status_offset_x} + {1'b0,scroll_offset};
    wire scroll_text_visible = scroll_sum>=SCROLL_WIDTH && scroll_sum<SCROLL_WIDTH+256;
    wire [9:0] scroll_canvas_x = scroll_sum-SCROLL_WIDTH;
    wire [3:0] scroll_char_idx = scroll_canvas_x[7:4];
    wire [3:0] scroll_char_x = scroll_canvas_x[3:0];
    wire [9:0] scroll_offset_y = px_y - SCROLL_START_Y;
    wire [3:0] rom_char_y = scroll_offset_y[3:0];
    function [5:0] scroll_code;
        input [3:0] idx;
        begin
            case(scroll_message)
`include "scroll_captions.vh"
            endcase
        end
    endfunction

    wire [5:0] rom_char_sel = scroll_text_visible?scroll_code(scroll_char_idx):6'd0;
    (* ram_style = "block" *) reg [31:0] scroll_font [0:1023];
`ifdef __ICARUS__
    initial $readmemh("hdl/scroll_font.mem", scroll_font);
`else
    initial $readmemh("scroll_font.mem", scroll_font);
`endif
    // Synchronous ROM and the background/column registers refer to the same
    // input pixel. Blending their registered outputs retains one-cycle latency.
    reg [31:0] font_row;
    always @(posedge I_clk) font_row<=scroll_font[{rom_char_sel,rom_char_y}];

    // 5-bit rows, top-to-bottom.  Unsupported characters are blank.
    function [4:0] glyph_row;
        input [7:0] c;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (c)
                "0": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10011;3:glyph_row=5'b10101;4:glyph_row=5'b11001;5:glyph_row=5'b10001;6:glyph_row=5'b01110; endcase
                "1": case(row) 0:glyph_row=5'b00100;1:glyph_row=5'b01100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b01110; endcase
                "2": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00001;3:glyph_row=5'b00010;4:glyph_row=5'b00100;5:glyph_row=5'b01000;6:glyph_row=5'b11111; endcase
                "3": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b00001;2:glyph_row=5'b00001;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110; endcase
                "4": case(row) 0:glyph_row=5'b00010;1:glyph_row=5'b00110;2:glyph_row=5'b01010;3:glyph_row=5'b10010;4:glyph_row=5'b11111;5:glyph_row=5'b00010;6:glyph_row=5'b00010; endcase
                "5": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110; endcase
                "6": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110; endcase
                "7": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b01000;5:glyph_row=5'b01000;6:glyph_row=5'b01000; endcase
                "8": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110; endcase
                "9": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b01111;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b01110; endcase
                "A": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001; endcase
                "C": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b01111; endcase
                "D": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110; endcase
                "E": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111; endcase
                "F": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000; endcase
                "G": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10000;3:glyph_row=5'b10111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110; endcase
                "H": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11111;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001; endcase
                "I": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b11111; endcase
                "K": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10010;2:glyph_row=5'b10100;3:glyph_row=5'b11000;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001; endcase
                "L": case(row) 0:glyph_row=5'b10000;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b10000;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b11111; endcase
                "M": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11011;2:glyph_row=5'b10101;3:glyph_row=5'b10101;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001; endcase
                "N": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b11001;2:glyph_row=5'b10101;3:glyph_row=5'b10011;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b10001; endcase
                "O": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110; endcase
                "P": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10000;5:glyph_row=5'b10000;6:glyph_row=5'b10000; endcase
                "R": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10100;5:glyph_row=5'b10010;6:glyph_row=5'b10001; endcase
                "S": case(row) 0:glyph_row=5'b01111;1:glyph_row=5'b10000;2:glyph_row=5'b10000;3:glyph_row=5'b01110;4:glyph_row=5'b00001;5:glyph_row=5'b00001;6:glyph_row=5'b11110; endcase
                "T": case(row) 0:glyph_row=5'b11111;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100; endcase
                "U": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b01110; endcase
                "B": case(row) 0:glyph_row=5'b11110;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b11110;4:glyph_row=5'b10001;5:glyph_row=5'b10001;6:glyph_row=5'b11110; endcase
                "V": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10001;4:glyph_row=5'b10001;5:glyph_row=5'b01010;6:glyph_row=5'b00100; endcase
                "W": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b10001;3:glyph_row=5'b10101;4:glyph_row=5'b10101;5:glyph_row=5'b10101;6:glyph_row=5'b01010; endcase
                "Y": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00100; endcase
                "X": case(row) 0:glyph_row=5'b10001;1:glyph_row=5'b10001;2:glyph_row=5'b01010;3:glyph_row=5'b00100;4:glyph_row=5'b01010;5:glyph_row=5'b10001;6:glyph_row=5'b10001; endcase
                ":": case(row) 0:glyph_row=5'b00000;1:glyph_row=5'b00100;2:glyph_row=5'b00100;3:glyph_row=5'b00000;4:glyph_row=5'b00100;5:glyph_row=5'b00100;6:glyph_row=5'b00000; endcase
                "?": case(row) 0:glyph_row=5'b01110;1:glyph_row=5'b10001;2:glyph_row=5'b00010;3:glyph_row=5'b00100;4:glyph_row=5'b00100;5:glyph_row=5'b00000;6:glyph_row=5'b00100; endcase
                ".": if(row==6) glyph_row=5'b00100;
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    wire [7:0] current_char = status_char;
    wire [3:0] glyph_x = status_char_x;
    wire [2:0] glyph_y = status_char_y;
    wire glyph_x_valid = (glyph_x >= 4'd3) && (glyph_x <= 4'd12);
    wire [3:0] glyph_x_offset = glyph_x - 4'd3;
    wire [2:0] glyph_col = glyph_x_valid ? glyph_x_offset[3:1] : 3'd0;
    wire [3:0] music_x_offset=music_x-3;
    wire glyph_on, diagnostic_on, resolution_on, music_on;
    generate if(STATUS_START_X==8 && STATUS_START_Y==28) begin : g_shared_ascii
        // These four text rectangles do not overlap in the default layout.
        // Select the character first, then share one font decoder. This keeps
        // the same combinational dot and one-clock pixel output latency.
        wire [7:0] selected_char=in_music ? music_char :
            in_resolution ? resolution_char : in_diagnostic ? diagnostic_char : current_char;
        wire [2:0] selected_y=in_music ? music_y :
            in_resolution ? resolution_char_y : in_diagnostic ? diagnostic_char_y : glyph_y;
        wire [2:0] selected_col=in_music ? music_x_offset[3:1] : glyph_col;
        wire selected_x_valid=in_music ? (music_x>=3 && music_x<=12) : glyph_x_valid;
        wire [4:0] selected_row=glyph_row(selected_char,selected_y);
        wire selected_on=selected_x_valid && selected_row[4-selected_col];
        assign glyph_on=in_status && selected_on;
        assign diagnostic_on=in_diagnostic && selected_on;
        assign resolution_on=in_resolution && selected_on;
        assign music_on=in_music && selected_on;
    end else begin : g_separate_ascii
        // Keep the original priority for parameterized layouts that may
        // overlap the fixed music-status rectangle.
        wire [4:0] current_row=glyph_row(current_char,glyph_y);
        wire [4:0] diagnostic_row=glyph_row(diagnostic_char,diagnostic_char_y);
        wire [4:0] resolution_row=glyph_row(resolution_char,resolution_char_y);
        wire [4:0] music_row=glyph_row(music_char,music_y);
        assign glyph_on=in_status && glyph_x_valid && current_row[4-glyph_col];
        assign diagnostic_on=in_diagnostic && glyph_x_valid && diagnostic_row[4-glyph_col];
        assign resolution_on=in_resolution && glyph_x_valid && resolution_row[4-glyph_col];
        assign music_on=in_music && music_x>=3 && music_x<=12 && music_row[4-music_x_offset[3:1]];
    end endgenerate
    // Status colors convey the most useful state at a glance while keeping
    // the underlying image visible through the character cells.
    wire [23:0] glyph_color = error_frame ? 24'hff4040 :
                               trans_frame ? 24'hffdc20 :
                               auto_frame ? 24'h40ffa0 : 24'hffffff;

    wire [7:0] bg_r = I_rgb[23:16] >> 1;
    wire [7:0] bg_g = I_rgb[15:8]  >> 1;
    wire [7:0] bg_b = I_rgb[7:0]   >> 1;

    reg [23:0] scroll_palette;
    reg [2:0] scroll_color_pixel;
    always @(*) begin
        case(scroll_color_pixel)
            0:scroll_palette=24'h70E8FF; 1:scroll_palette=24'h80FFB0;
            2:scroll_palette=24'hFFE080; 3:scroll_palette=24'hFFB0D8;
            4:scroll_palette=24'hC8B0FF; 5:scroll_palette=24'hFFB080;
            6:scroll_palette=24'hB0E0FF; default:scroll_palette=24'hF0F0F0;
        endcase
    end
    reg scroll_pixel;
    reg [3:0] scroll_column;
    reg [23:0] scroll_background;
    reg [DATA_WIDTH-1:0] pixel_base;
    wire [1:0] scroll_gray=font_row[31-{scroll_column,1'b0} -: 2];
    function [7:0] blend_caption;
        input [7:0] background, foreground;
        input [1:0] gray;
        reg [9:0] mix;
        begin
            case(gray)
                0:blend_caption=background;
                1:begin
                    mix={2'b0,background}+{1'b0,background,1'b0}+{2'b0,foreground};
                    blend_caption=mix[9:2];
                end
                2:begin
                    mix={2'b0,background}+{2'b0,foreground};
                    blend_caption=mix[8:1];
                end
                default:blend_caption=foreground;
            endcase
        end
    endfunction
    wire [23:0] scroll_rgb={
        blend_caption(scroll_background[23:16],scroll_palette[23:16],scroll_gray),
        blend_caption(scroll_background[15:8],scroll_palette[15:8],scroll_gray),
        blend_caption(scroll_background[7:0],scroll_palette[7:0],scroll_gray)};
    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst) begin
            scroll_pixel<=0;scroll_column<=0;scroll_background<=0;scroll_color_pixel<=0;
        end else begin
            scroll_pixel<=in_scroll && I_osd_en;
            scroll_column<=scroll_char_x;
            scroll_background<={bg_r,bg_g,bg_b};
            scroll_color_pixel<=scroll_color_index;
        end
    end
    always @(*) O_rgb_out=scroll_pixel?scroll_rgb:pixel_base;

    // alpha=31 is exactly full width, alpha=0 is empty.  Intermediate values
    // use a power-of-two denominator to avoid a pixel-rate hardware divider.
    wire [15:0] alpha_pixels = alpha_frame * (STATUS_CHARS*16);
    wire [9:0] progress_width = (alpha_frame == 5'd31) ? STATUS_CHARS*16 : alpha_pixels[14:5];
    wire progress_filled = in_progress && (status_offset_x < progress_width);

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            pixel_base <= {DATA_WIDTH{1'b0}};
        else if(music_on && I_osd_en && I_de)
            pixel_base <= music_frame==5 || music_frame==6 ? 24'hff4040 : 24'h40ffff;
        else if (!I_de || !I_osd_en)
            pixel_base <= I_rgb;
        else if (glyph_on)
            pixel_base <= glyph_color;
        else if (in_resolution)
            pixel_base <= resolution_on ? 24'h80d8ff : {bg_r, bg_g, bg_b};
        else if (in_diagnostic)
            pixel_base <= diagnostic_on ? 24'hff4040 : {bg_r, bg_g, bg_b};
        else if (in_scroll)
            pixel_base <= {bg_r,bg_g,bg_b};
        else if (in_status)
            pixel_base <= {bg_r, bg_g, bg_b};
        else if (in_progress)
            pixel_base <= progress_filled ? 24'hffdc20 : {bg_r, bg_g, bg_b};
        else
            pixel_base <= I_rgb;
    end

endmodule
