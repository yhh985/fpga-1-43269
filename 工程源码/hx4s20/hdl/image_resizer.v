`timescale 1ns/1ps

// Flow-controlled nearest-neighbour scaler. One complete source row is held
// in RAM while its destination rows are emitted. The source holds valid and
// data when in_ready is low; the SD parser provides a whole-sector buffer.
// Visible mapping is floor(dst_x*src_w/DST_W), floor(dst_y*src_h/DST_H).
// BMP and SDRAM input rows run bottom-up, so the source row in that stream is
// floor(((bottom_y+1)*src_h-1)/DST_H), the equivalent of top-down nearest.
module image_resizer #(
    parameter DST_W = 16'd640,
    parameter DST_H = 16'd480,
    parameter LINE_BUF_DEPTH = 11'd1024
)(
    input clk,
    input rst,
    input [15:0] src_w,
    input [15:0] src_h,
    input in_write_req,
    output reg in_write_req_ack,
    input in_wr_en,
    input [31:0] in_data,
    output in_ready,
    output reg out_write_req,
    input out_write_req_ack,
    input out_ready,
    // Valid/data remain asserted and unchanged until out_ready accepts them.
    output reg out_wr_en,
    output reg [31:0] out_data,
    output reg out_busy,
    output reg out_done
);
localparam ST_IDLE=4'd0, ST_WAIT_ACK=4'd1, ST_READ_ROW=4'd2,
           ST_PRIME=4'd3, ST_SCALE_ROW=4'd4, ST_NEXT_ROW=4'd5,
           ST_DRAIN=4'd6, ST_DONE=4'd7, ST_ROW_STEP=4'd8,
           ST_ROW_ADVANCE=4'd9, ST_ROW_DECIDE=4'd10;
localparam integer LINE_ADDR_BITS = (LINE_BUF_DEPTH <= 1) ? 1 : $clog2(LINE_BUF_DEPTH);
reg [3:0] state;
(* ram_style = "bram" *) reg [23:0] line_buf [0:LINE_BUF_DEPTH-1];
reg [23:0] rd_data;
reg [10:0] wr_addr, rd_addr, input_y, source_y;
reg [15:0] width_latched, height_latched;
reg [15:0] h_acc, v_acc;
reg [16:0] row_v_sum;
reg [1:0] row_v_step;
reg [15:0] output_x, output_y;
wire [16:0] h_sum = {1'b0,h_acc}+{1'b0,width_latched};
wire [16:0] v_sum = {1'b0,v_acc}+{1'b0,height_latched};
// Source width/height <=1024: horizontal step 0..2, vertical step 0..3.
// Compare/subtract rather than divide on the pixel-rate output path.
wire [1:0] h_step = (h_sum >= 2*DST_W) ? 2'd2 :
                         (h_sum >= DST_W) ? 2'd1 : 2'd0;
wire [1:0] row_v_step_next = (row_v_sum >= 3*DST_H) ? 2'd3 :
                              (row_v_sum >= 2*DST_H) ? 2'd2 :
                              (row_v_sum >= DST_H) ? 2'd1 : 2'd0;
wire [15:0] h_remainder = h_sum - h_step*DST_W;
wire [15:0] row_v_remainder = row_v_sum - row_v_step*DST_H;
wire [10:0] next_rd_addr = rd_addr + h_step;
// The registered output is one elastic slot; rd_data holds the next pixel.
// Freeze both slots and the mapping counters while the memory FIFO is full.
wire output_slot_free = !out_wr_en || out_ready;
wire line_read_en = (state==ST_PRIME) ||
                    (state==ST_SCALE_ROW && output_slot_free && output_x < DST_W-1);
wire [10:0] line_read_addr = (state==ST_PRIME) ? 11'd0 : next_rd_addr;
wire [15:0] first_y_numerator = src_h-1'b1;
wire [1:0] first_source_y = (first_y_numerator >= 2*DST_H) ? 2'd2 :
                                (first_y_numerator >= DST_H) ? 2'd1 : 2'd0;
assign in_ready = (state==ST_READ_ROW || state==ST_DRAIN);

// Separate write port and synchronous read permit block-RAM inference.
always @(posedge clk) begin
    if (state==ST_READ_ROW && in_wr_en && in_ready && input_y==source_y)
        line_buf[wr_addr[LINE_ADDR_BITS-1:0]] <= in_data[23:0];
end
always @(posedge clk) begin
    if (line_read_en)
        rd_data <= line_buf[line_read_addr[LINE_ADDR_BITS-1:0]];
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=ST_IDLE; in_write_req_ack<=0; out_write_req<=0;
        out_wr_en<=0; out_data<=0; out_busy<=0; out_done<=0;
        width_latched<=1; height_latched<=1;
        wr_addr<=0; rd_addr<=0; input_y<=0; source_y<=0;
        h_acc<=0; v_acc<=0; output_x<=0; output_y<=0;
        row_v_sum<=0; row_v_step<=0;
    end else begin
        if(output_slot_free) out_wr_en<=0;
        in_write_req_ack<=0;
        case(state)
            ST_IDLE: begin
                out_write_req<=0; out_busy<=0;
                if(in_write_req) begin
                    width_latched<=src_w; height_latched<=src_h;
                    wr_addr<=0; rd_addr<=0; input_y<=0; source_y<=first_source_y;
                    h_acc<=0; v_acc<=first_y_numerator-first_source_y*DST_H;
                    output_x<=0; output_y<=0;
                    out_done<=0; out_busy<=1; out_write_req<=1;
                    state<=ST_WAIT_ACK;
                end
            end
            ST_WAIT_ACK: if(out_write_req_ack) begin
                out_write_req<=0; in_write_req_ack<=1; state<=ST_READ_ROW;
            end
            ST_READ_ROW: if(in_wr_en && in_ready) begin
                if(wr_addr==width_latched-1) begin
                    wr_addr<=0; input_y<=input_y+1'b1;
                    if(input_y==source_y) begin
                        rd_addr<=0; h_acc<=0; output_x<=0; state<=ST_PRIME;
                    end
                end else wr_addr<=wr_addr+1'b1;
            end
            ST_PRIME: state<=ST_SCALE_ROW;
            ST_SCALE_ROW: if(output_slot_free) begin
                out_wr_en<=1; out_data<={rd_data,8'd0};
                if(output_x==DST_W-1) state<=ST_NEXT_ROW;
                else begin
                    rd_addr<=next_rd_addr; h_acc<=h_remainder;
                    output_x<=output_x+1'b1;
                end
            end
            // The final pixel must leave the elastic slot before a source
            // row is replaced or a completed frame can be reported.
            ST_NEXT_ROW: if(output_slot_free) begin
                if(output_y==DST_H-1) begin
                    // Drain skipped final source rows before reporting done.
                    if(input_y>=height_latched) state<=ST_DONE;
                    else state<=ST_DRAIN;
                end else begin
                    output_y<=output_y+1'b1;
                    row_v_sum<=v_sum; state<=ST_ROW_STEP;
                end
            end
            // Vertical mapping runs once per output row. Split sum, step,
            // source-row advance and the row-reuse decision across clocks
            // so their carry chains do not reach pixel-counter enables.
            ST_ROW_STEP: begin
                row_v_step<=row_v_step_next; state<=ST_ROW_ADVANCE;
            end
            ST_ROW_ADVANCE: begin
                v_acc<=row_v_remainder; source_y<=source_y+row_v_step;
                state<=ST_ROW_DECIDE;
            end
            ST_ROW_DECIDE: begin
                if(source_y<input_y) begin
                    rd_addr<=0; h_acc<=0; output_x<=0; state<=ST_PRIME;
                end else state<=ST_READ_ROW;
            end
            ST_DRAIN: if(in_wr_en && in_ready) begin
                if(wr_addr==width_latched-1) begin
                    wr_addr<=0; input_y<=input_y+1'b1;
                    if(input_y==height_latched-1) state<=ST_DONE;
                end else wr_addr<=wr_addr+1'b1;
            end
            ST_DONE: begin
                out_busy<=0; out_done<=1;
                if(!in_write_req) state<=ST_IDLE;
            end
            default: begin state<=ST_IDLE; out_write_req<=0; out_busy<=0; end
        endcase
    end
end
endmodule
