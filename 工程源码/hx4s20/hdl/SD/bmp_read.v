`timescale 1ns/1ps
module bmp_read #(
    parameter integer COUNT_BITS=4
)(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [COUNT_BITS-1:0]     scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [COUNT_BITS-1:0] scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    output reg                  load_failed, // invalid header or incomplete sector, cancel pending frame
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg [15:0]           src_w,       // 实际图片宽度（从BMP头读取）
    output reg [15:0]           src_h,       // 实际图片高度（从BMP头读取）

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    input                       bmp_data_ready, // hold valid/data until scaler accepts the pixel
    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    // ===== 调试输出 =====
    output reg [3:0]            debug_state,
    output reg [3:0]            debug_rd_cnt,
    output reg [7:0]            debug_byte0,
    output reg [7:0]            debug_byte1,
    output reg                   debug_data_valid
);

localparam ST_IDLE=4'd0, ST_SCAN=4'd1, ST_LOAD_HDR=4'd2,
           ST_LOAD_WAIT=4'd3, ST_LOAD_DATA=4'd4, ST_SCAN_DECIDE=4'd5,
           ST_DRAIN_FETCH=4'd6, ST_DRAIN_BYTE=4'd7, ST_LOAD_FINISH=4'd8;

reg [3:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;
reg [31:0] dib_size;
reg [15:0] planes;

reg [31:0] scan_sector;
reg        scan_match_r;
reg [31:0] scan_next_match_r;
reg [31:0] scan_next_miss_r;
reg        scan_next_match_overflow_r;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [12:0] row_byte_cnt;
// A sector cannot be paused once SPI starts. Store all 512 bytes first, then
// drain at the scaler's pace; never request another sector until it is empty.
// This covers both rows spanning sectors and many short rows in one sector.
reg [7:0] sector_ram [0:511];
reg [9:0] sector_fill_count;
reg [8:0] drain_addr;
reg [7:0] sector_byte;
wire drain_accept = (state==ST_DRAIN_BYTE) &&
                    (!bmp_data_wr_en || bmp_data_ready);

wire header_match;
wire bmp_data_valid;
reg [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;
wire [32:0] next_scan_sector_wide;
// Pipeline header arithmetic: a multiply, file-size add, and full-width
// comparisons must not form one 100 MHz path. All header fields finish at
// byte 33; even the minimum 54-byte header leaves time for every stage below.
// The full 32-bit dimensions are checked separately. These intermediate
// widths also cover every low-11-bit value, including rejected dimensions:
// 2047 * 3 = 6141; aligned stride <= 6144; 6144 * 2047 < 2^24.
reg [12:0] pixel_bytes_per_row;
reg [12:0] row_stride_bytes;
reg [12:0] row_last_byte;
reg [31:0] last_pixel_byte;
reg end_at_current;
reg [23:0] image_data_bytes;
reg [32:0] required_file_size;
reg [32:0] dib_end_offset;
reg header_format_ok;
reg header_extent_ok;
wire [31:0] pixel_data_end = required_file_size[31:0];

assign ready = (state == ST_IDLE);
// Positive-height 24-bit uncompressed BMP, 1..1024 pixels on either axis.
// Pixels are delivered bottom-up; the scaler accounts for display inversion.
assign header_match = header_format_ok && header_extent_ok && (rd_cnt >= 10'd54);
assign bmp_data_valid = drain_accept &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt < pixel_data_end);
// BMP 每行按4字节对齐。只把有效的 BGR 三元组送给后级，跳过行尾填充，
// 否则非4字节对齐宽度的图片会从第二行开始逐行错位。
wire bmp_pixel_byte_valid = bmp_data_valid && (row_byte_cnt < pixel_bytes_per_row);
// Round up in a separate stage before adding the scan address. The length
// finishes at header byte 5, well before the earliest byte-54 decision.
// Do not form file_len+511, which would wrap at the 32-bit boundary.
assign next_scan_sector_wide = {1'b0,scan_sector} + {1'b0,file_sector_count};
assign next_scan_sector_if_match = next_scan_sector_wide[31:0];
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pixel_bytes_per_row <= 13'd0;
        row_stride_bytes <= 13'd0;
        row_last_byte <= 13'd0;last_pixel_byte<=0;end_at_current<=0;
        image_data_bytes <= 24'd0;
        required_file_size <= 33'd0;
        dib_end_offset <= 33'd0;
        header_format_ok <= 1'b0;
        header_extent_ok <= 1'b0;
        file_sector_count <= 32'd1;
    end else begin
        file_sector_count <= (file_len == 32'd0) ? 32'd1 :
            ((file_len >> 9) + ((|file_len[8:0]) ? 32'd1 : 32'd0));
        pixel_bytes_per_row <= {2'd0,width[10:0]} + {1'd0,width[10:0],1'b0};
        row_stride_bytes <= (pixel_bytes_per_row + 13'd3) & 13'h1ffc;
        // Header constants settle before pixel drain; keep subtraction off the counter path.
        row_last_byte <= row_stride_bytes - 13'd1;
        last_pixel_byte<=pixel_data_end-32'd1;end_at_current<=bmp_len_cnt>=last_pixel_byte;
        image_data_bytes <= row_stride_bytes * height[10:0];
        required_file_size <= {1'b0,pixel_offset} + {9'd0,image_data_bytes};
        dib_end_offset <= {1'b0,dib_size} + 33'd14;
        header_format_ok <= (header_0 == "B") && (header_1 == "M") &&
                            (bit_count == 16'd24) && (compression == 32'd0) &&
                            (dib_size >= 32'd40) && (planes == 16'd1) &&
                            (width >= 32'd1) && (width <= 32'd1024) &&
                            (height >= 32'd1) && (height <= 32'd1024);
        header_extent_ok <= ({1'b0,pixel_offset} >= dib_end_offset) &&
                            !required_file_size[32] &&
                            (file_len >= required_file_size[31:0]);
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
        dib_size     <= 32'd0;
        planes       <= 16'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd14: dib_size[7:0] <= sd_sec_read_data;
            10'd15: dib_size[15:8] <= sd_sec_read_data;
            10'd16: dib_size[23:16] <= sd_sec_read_data;
            10'd17: dib_size[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;
            10'd26: planes[7:0] <= sd_sec_read_data;
            10'd27: planes[15:8] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

// Synchronous RAM read/write ports. Fetch and consume are separate states,
// so a paused byte cannot read the wrong address when scaling resumes.
always @(posedge clk) begin
    if (state==ST_LOAD_DATA && sd_sec_read_data_valid && sector_fill_count<512)
        sector_ram[sector_fill_count[8:0]] <= sd_sec_read_data;
    if (state==ST_DRAIN_FETCH)
        sector_byte <= sector_ram[drain_addr];
end
always @(posedge clk or posedge rst) begin
    if (rst) sector_fill_count<=0;
    else if (!sd_init_done || state!=ST_LOAD_DATA) sector_fill_count<=0;
    else if (sd_sec_read_data_valid && sector_fill_count<512)
        sector_fill_count<=sector_fill_count+1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt<=0; row_byte_cnt<=0; bmp_byte_idx<=0;
        bmp_data_wr_en<=0; bmp_data<=0;
    end else if (!sd_init_done) begin
        bmp_len_cnt<=0; row_byte_cnt<=0; bmp_byte_idx<=0;
        bmp_data_wr_en<=0; bmp_data<=0;
    end else begin
        if (bmp_data_wr_en && bmp_data_ready) bmp_data_wr_en<=0;
        if (state==ST_LOAD_WAIT) begin
            bmp_len_cnt<=0; row_byte_cnt<=0; bmp_byte_idx<=0;
            bmp_data_wr_en<=0;
        end else if (drain_accept) begin
            bmp_len_cnt<=bmp_len_cnt+1'b1;
            if (bmp_len_cnt>=pixel_offset && bmp_len_cnt<pixel_data_end) begin
                if (row_byte_cnt==row_last_byte) row_byte_cnt<=0;
                else row_byte_cnt<=row_byte_cnt+1'b1;
            end
            if (bmp_pixel_byte_valid) begin
                case(bmp_byte_idx)
                    0: bmp_data[7:0]<=sector_byte;
                    1: bmp_data[15:8]<=sector_byte;
                    2: begin bmp_data[23:16]<=sector_byte; bmp_data_wr_en<=1; end
                endcase
                bmp_byte_idx <= (bmp_byte_idx==2) ? 0 : bmp_byte_idx+1'b1;
            end
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        load_failed       <= 1'b0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 4'd0;
        scan_sector       <= 32'd0;
        scan_match_r      <= 1'b0;
        scan_next_match_r <= 32'd0;
        scan_next_miss_r  <= 32'd0;
        scan_next_match_overflow_r <= 1'b0;
        load_sector_latched <= 32'd0;
        drain_addr        <= 9'd0;
        src_w             <= 16'd640;
        src_h             <= 16'd480;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        load_failed       <= 1'b0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 4'd0;
        scan_sector       <= 32'd0;
        scan_match_r      <= 1'b0;
        scan_next_match_r <= 32'd0;
        scan_next_miss_r  <= 32'd0;
        scan_next_match_overflow_r <= 1'b0;
        load_sector_latched <= 32'd0;
        drain_addr        <= 9'd0;
        src_w             <= 16'd640;
        src_h             <= 16'd480;
    end else begin
        scan_found_valid <= 1'b0;
        load_failed <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 4'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    // Capture the header decision and address arithmetic at
                    // the sector boundary, then consume it in the following
                    // state. This removes the file_len->ceil->scan_limit
                    // chain from the SD read-end critical path.
                    scan_match_r <= header_match;
                    scan_next_match_r <= next_scan_sector_if_match;
                    scan_next_miss_r <= next_scan_sector_if_miss;
                    scan_next_match_overflow_r <= next_scan_sector_wide[32];
                    state <= ST_SCAN_DECIDE;
                end
            end

            ST_SCAN_DECIDE: begin
                state_code <= 4'd2;
                if (scan_match_r) begin
                    scan_found_valid  <= 1'b1;
                    scan_found_sector <= scan_sector;
                    scan_found_total  <= scan_found_total + 1'b1;
                    if (({1'b0,scan_found_total} + 1'b1 >= scan_target_count) ||
                        scan_next_match_overflow_r || (scan_next_match_r > scan_max_sector)) begin
                        scan_done        <= 1'b1;
                        state            <= ST_IDLE;
                        sd_sec_read_addr <= scan_next_match_r;
                        scan_sector      <= scan_next_match_r;
                    end else begin
                        sd_sec_read_addr <= scan_next_match_r;
                        scan_sector      <= scan_next_match_r;
                        state            <= ST_SCAN;
                    end
                end else if (scan_sector >= scan_max_sector || scan_next_miss_r <= scan_sector) begin
                    scan_done <= 1'b1;
                    state     <= ST_IDLE;
                end else begin
                    sd_sec_read_addr <= scan_next_miss_r;
                    scan_sector      <= scan_next_miss_r;
                    state            <= ST_SCAN;
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        src_w            <= width[15:0];   // 锁存实际宽度
                        src_h            <= height[15:0];  // 锁存实际高度
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        load_failed <= 1'b1;
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code<=4'd4;
                sd_sec_read<=1'b1;
                if (sd_sec_read_end) begin
                    sd_sec_read<=1'b0;
                    if (sector_fill_count + (sd_sec_read_data_valid ? 10'd1 : 10'd0) != 10'd512) begin
                        load_failed<=1'b1; state<=ST_IDLE;
                    end else begin
                        drain_addr<=0; state<=ST_DRAIN_FETCH;
                    end
                end
            end
            ST_DRAIN_FETCH: begin
                state_code<=4'd4; sd_sec_read<=0; state<=ST_DRAIN_BYTE;
            end
            ST_DRAIN_BYTE: begin
                state_code<=4'd4; sd_sec_read<=0;
                if (drain_accept) begin
                    if (end_at_current) state<=ST_LOAD_FINISH;
                    else if (drain_addr==9'd511) begin
                        sd_sec_read_addr<=sd_sec_read_addr+1'b1;
                        state<=ST_LOAD_DATA;
                    end else begin
                        drain_addr<=drain_addr+1'b1; state<=ST_DRAIN_FETCH;
                    end
                end
            end
            ST_LOAD_FINISH: begin
                state_code<=4'd4; sd_sec_read<=0;
                if (!bmp_data_wr_en) state<=ST_IDLE;
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

// ===== 调试信号 =====
always @(posedge clk or posedge rst) begin
    if (rst) begin
        debug_state <= 4'd0; debug_rd_cnt <= 4'd0;
        debug_byte0 <= 8'd0; debug_byte1 <= 8'd0; debug_data_valid <= 1'b0;
    end else begin
        debug_state <= state;
        debug_rd_cnt <= rd_cnt[3:0];
        debug_data_valid <= sd_sec_read_data_valid;
        if ((state == ST_SCAN || state == ST_LOAD_HDR) && sd_sec_read_data_valid) begin
            if (rd_cnt == 10'd0) debug_byte0 <= sd_sec_read_data;
            if (rd_cnt == 10'd1) debug_byte1 <= sd_sec_read_data;
        end
    end
end

endmodule
