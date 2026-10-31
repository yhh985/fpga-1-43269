`timescale 1ns/1ps
// Main SD path only: two-row RGB888 bilinear scaler with exact endpoints.
// Rational coordinate increments are calculated once/frame by a serial
// divider. Pixel blending reuses two DSPs across R/G/B; no pixel divider.
// The 640x480 identity path copies RGB bytes directly through an elastic slot.
module image_resizer_sd_quality #(
    parameter integer DST_W=640,DST_H=480,LINE_BUF_DEPTH=1024,
    parameter integer FIT_ASPECT=0 // legacy stretch oracle remains selectable
)(
    input clk,rst, input [15:0] src_w,src_h,
    input [1:0] zoom_level, // 0=0.5x, 1=1x, 2=1.5x, 3=2x relative to aspect fit
    input in_write_req,output reg in_write_req_ack,
    input in_wr_en,input [31:0] in_data,output in_ready,
    output reg out_write_req,input out_write_req_ack,out_ready,
    output reg out_wr_en,output reg [31:0] out_data,
    output reg out_busy,out_done,
    output reg [15:0] fit_w,fit_h
);
localparam IDLE=0,DIVIDE=1,ACK=2,ROWS=3,CHECK_ROWS=4,
    FETCH0=5,LEFT=6,FETCH1=7,RIGHT=8,H0=9,H0_MUL=10,H0_ADD=11,
    H1=12,H1_MUL=13,H1_ADD=14,V0=15,V_MUL=16,V_ADD=17,
    OUTPUT=18,ADVANCE=19,DONE=20,IDENTITY=21,FINAL=22,
    GEOMETRY=23,SETUP_X=24,ROUTE=25,DRAIN=26,ROUTE_SETUP=27,START=28,ZOOM_SHAPE=29,SKIP_X=30,SKIP_Y=31;
// TD does not extract this FSM when a transition assigns a ternary state
// expression. Keep transitions as branches so one-hot encoding removes the
// wide binary next-state mux from the 100 MHz pixel-input path.
(* fsm_encoding = "one_hot" *) reg [4:0] state;
reg active_pixel,identity_frame;
reg [1:0] zoom_r;
wire [1:0] zoom_input=(^zoom_level === 1'bx) ? 2'd1 : zoom_level;
reg [10:0] skip_x,skip_y;
reg [17:0] x_origin;
reg [15:0] x_origin_error;
function [15:0] zoom_dimension;
 input [15:0] size;input [1:0] level;
 begin case(level)
  0:zoom_dimension=size>1 ? size>>1 : 16'd1;
  2:zoom_dimension=size+(size>>1);
  3:zoom_dimension=size<<1;
  default:zoom_dimension=size;
 endcase end
endfunction
reg [15:0] width_r,height_r;
reg [15:0] width_last,height_last,right_last,top_last;
reg [10:0] needed_row;
reg [10:0] input_y;
reg [9:0] write_x;
reg [15:0] output_x,output_y;
reg [17:0] x_fp,y_fp,x_step,y_step;
reg [15:0] x_error,y_error,x_rem,y_rem;
reg [25:0] div_numer,div_quot;
reg [15:0] div_rem,div_den;
reg [4:0] div_count;
reg [1:0] div_phase; // 0=aspect fit, 1=x increment, 2=y increment
reg [25:0] aspect_w,aspect_h;
reg width_limited;
reg [15:0] left_pad,bottom_pad,right_edge,top_edge;
reg [15:0] x_den,y_den;

wire [16:0] trial={div_rem,div_numer[25]};
wire div_bit=trial>={1'b0,div_den};
wire [16:0] remainder_next=div_bit ? trial-div_den : trial;
wire [25:0] quotient_next={div_quot[24:0],div_bit};
wire [16:0] x_error_sum={1'b0,x_error}+x_rem;
wire [16:0] y_error_sum={1'b0,y_error}+y_rem;
wire x_carry=x_error_sum>=x_den;
wire y_carry=y_error_sum>=y_den;
wire [9:0] sx=x_fp[17:8],sy=y_fp[17:8];
wire [9:0] sx1=sx<width_last ? sx+1'b1 : sx;
always @(posedge clk)begin
 active_pixel<=output_x>=left_pad && output_x<right_edge && output_y>=bottom_pad && output_y<top_edge;
 width_last<=width_r-1'b1;height_last<=height_r-1'b1;
 right_last<=right_edge-1'b1;top_last<=top_edge-1'b1;
 needed_row<=sy<height_last ? {1'b0,sy}+1'b1 : {1'b0,sy};
end
wire slot_free=!out_wr_en || out_ready;
// Identity input acceptance depends only on a registered output vacancy.
// This breaks the FIFO-full -> parser ready -> pixel counter timing chain;
// alternate-cycle throughput still exceeds the conservative SPI byte rate.
assign in_ready=state==ROWS || state==DRAIN ||
                (state==IDENTITY && !out_wr_en);
(* ram_style="bram" *) reg [23:0] row_even[0:LINE_BUF_DEPTH-1];
(* ram_style="bram" *) reg [23:0] row_odd[0:LINE_BUF_DEPTH-1];
reg [23:0] even_out,odd_out;
wire [9:0] read_x=state==FETCH1 ? sx1 : sx;
always @(posedge clk)begin
 if(state==ROWS && in_wr_en)begin
  if(input_y[0])row_odd[write_x]<=in_data[23:0];
  else row_even[write_x]<=in_data[23:0];
 end
 if(state==FETCH0 || state==FETCH1)begin even_out<=row_even[read_x];odd_out<=row_odd[read_x];end
end
reg [23:0] samples[0:3];
reg last_source_row;
reg [1:0] channel;
reg [7:0] a,b,c,d,h_left;
reg signed [8:0] h_delta;
reg signed [17:0] h_product;
reg [15:0] horizontal0,horizontal1,v_upper;
reg signed [16:0] v_delta;
reg signed [25:0] v_product;
reg [23:0] result;
wire signed [17:0] h_sum=$signed({2'b0,h_left,8'd0})+h_product;
wire signed [25:0] v_sum=$signed({2'b0,v_upper,8'd0})+v_product;
wire signed [25:0] v_rounded=v_sum+26'sd32768;
always @(*)begin
 case(channel)
  0:begin a=samples[0][7:0];b=samples[1][7:0];c=samples[2][7:0];d=samples[3][7:0];end
  1:begin a=samples[0][15:8];b=samples[1][15:8];c=samples[2][15:8];d=samples[3][15:8];end
  default:begin a=samples[0][23:16];b=samples[1][23:16];c=samples[2][23:16];d=samples[3][23:16];end
 endcase
end
integer k;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=IDLE;in_write_req_ack<=0;out_write_req<=0;out_wr_en<=0;out_data<=0;out_busy<=0;out_done<=0;
  zoom_r<=1;skip_x<=0;skip_y<=0;x_origin<=0;x_origin_error<=0;
  identity_frame<=0;width_r<=1;height_r<=1;input_y<=0;write_x<=0;output_x<=0;output_y<=0;
  x_fp<=0;y_fp<=0;x_step<=0;y_step<=0;x_error<=0;y_error<=0;x_rem<=0;y_rem<=0;
  div_numer<=0;div_quot<=0;div_rem<=0;div_den<=1;div_count<=0;div_phase<=0;
  fit_w<=DST_W;fit_h<=DST_H;left_pad<=0;bottom_pad<=0;right_edge<=DST_W;top_edge<=DST_H;
  x_den<=1;y_den<=1;
  aspect_w<=0;aspect_h<=0;width_limited<=0;
  channel<=0;h_left<=0;h_delta<=0;h_product<=0;horizontal0<=0;horizontal1<=0;
  last_source_row<=0;
  v_upper<=0;v_delta<=0;v_product<=0;result<=0;
  for(k=0;k<4;k=k+1)samples[k]<=0;
 end else begin
  if(slot_free)out_wr_en<=0;
  in_write_req_ack<=0;
  case(state)
   IDLE:if(in_write_req)begin
    width_r<=src_w;height_r<=src_h;input_y<=0;write_x<=0;output_x<=0;output_y<=0;
    x_fp<=0;y_fp<=0;x_error<=0;y_error<=0;out_done<=0;out_busy<=1;
    fit_w<=DST_W;fit_h<=DST_H;left_pad<=0;bottom_pad<=0;right_edge<=DST_W;top_edge<=DST_H;
    aspect_w<=src_w*DST_H;aspect_h<=src_h*DST_W;
    zoom_r<=zoom_input;identity_frame<=src_w==DST_W && src_h==DST_H && zoom_input==1;state<=START;
   end
   START:begin
    if(identity_frame)begin out_write_req<=1;state<=ACK;end
    else if(FIT_ASPECT)state<=GEOMETRY;
    else state<=ZOOM_SHAPE;
   end
   GEOMETRY:begin
    // Cross products choose the limiting axis without division or rounding.
    width_limited<=aspect_w>=aspect_h;
    div_numer<=aspect_w>=aspect_h ? aspect_h : aspect_w;
    div_den<=aspect_w>=aspect_h ? width_r : height_r;
    div_quot<=0;div_rem<=0;div_count<=25;div_phase<=0;state<=DIVIDE;
   end
   ZOOM_SHAPE:begin
    fit_w<=zoom_dimension(fit_w,zoom_r);fit_h<=zoom_dimension(fit_h,zoom_r);state<=SETUP_X;
   end
   SETUP_X:begin
    // Frame constants are registered before division and pixel stepping.
    x_den<=fit_w>1 ? fit_w-1'b1 : 16'd1;
    y_den<=fit_h>1 ? fit_h-1'b1 : 16'd1;
    left_pad<=fit_w<DST_W ? (DST_W-fit_w)>>1 : 16'd0;
    bottom_pad<=fit_h<DST_H ? (DST_H-fit_h)>>1 : 16'd0;
    right_edge<=fit_w<DST_W ? ((DST_W-fit_w)>>1)+fit_w : DST_W;
    top_edge<=fit_h<DST_H ? ((DST_H-fit_h)>>1)+fit_h : DST_H;
    skip_x<=fit_w>DST_W ? (fit_w-DST_W)>>1 : 11'd0;
    skip_y<=fit_h>DST_H ? (fit_h-DST_H)>>1 : 11'd0;
    // A one-pixel result samples the source center, and drains the unused
    // source rows after output. Never divide by (1-1).
    x_fp<=fit_w==1 ? ({2'd0,width_r}-18'd1)<<7 : 18'd0;
    y_fp<=fit_h==1 ? ({2'd0,height_r}-18'd1)<<7 : 18'd0;
    div_numer<=({10'd0,width_r}-26'd1)<<8;
    div_den<=fit_w>1 ? fit_w-1'b1 : 16'd1;
    div_quot<=0;div_rem<=0;div_count<=25;div_phase<=1;state<=DIVIDE;
   end
   DIVIDE:begin
    div_numer<={div_numer[24:0],1'b0};div_quot<=quotient_next;div_rem<=remainder_next[15:0];
    if(div_count!=0)div_count<=div_count-1'b1;
    else if(div_phase==0)begin
     if(width_limited)fit_h<=quotient_next==0 ? 16'd1 : quotient_next[15:0];
     else fit_w<=quotient_next==0 ? 16'd1 : quotient_next[15:0];
     state<=ZOOM_SHAPE;
    end else if(div_phase==1)begin
     x_step<=quotient_next[17:0];x_rem<=remainder_next[15:0];
     div_phase<=2;div_numer<=({10'd0,height_r}-26'd1)<<8;div_quot<=0;div_rem<=0;
     div_den<=y_den;div_count<=25;
    end else begin y_step<=quotient_next[17:0];y_rem<=remainder_next[15:0];state<=SKIP_X;end
   end
   // Advance over the off-screen virtual pixels once per frame, sharing
   // the exact rational accumulators. No new multiplier, divider or RAM.
   SKIP_X:if(skip_x!=0)begin
    x_fp<=x_fp+x_step+x_carry;x_error<=x_carry ? x_error_sum-x_den : x_error_sum;skip_x<=skip_x-1'b1;
   end else begin x_origin<=x_fp;x_origin_error<=x_error;state<=SKIP_Y;end
   SKIP_Y:if(skip_y!=0)begin
    y_fp<=y_fp+y_step+y_carry;y_error<=y_carry ? y_error_sum-y_den : y_error_sum;skip_y<=skip_y-1'b1;
   end else begin out_write_req<=1;state<=ACK;end
   ACK:if(out_write_req_ack)begin
    out_write_req<=0;in_write_req_ack<=1;
    if(identity_frame)state<=IDENTITY;
    else state<=ROUTE_SETUP;
   end
   ROUTE_SETUP:state<=ROUTE;
   ROUTE:if(active_pixel)state<=CHECK_ROWS;
         else if(slot_free)begin out_wr_en<=1;out_data<=0;state<=ADVANCE;end
   CHECK_ROWS:if(input_y>needed_row)state<=FETCH0;else state<=ROWS;
   ROWS:if(in_wr_en)begin
    if(write_x==width_last)begin write_x<=0;input_y<=input_y+1'b1;if(input_y==needed_row)state<=FETCH0;end
    else write_x<=write_x+1'b1;
   end
   FETCH0:begin last_source_row<=sy==height_last;state<=LEFT;end
   LEFT:begin
    samples[0]<=sy[0] ? odd_out : even_out;
    samples[2]<=last_source_row ? (sy[0]?odd_out:even_out) : (sy[0]?even_out:odd_out);
    state<=FETCH1;
   end
   FETCH1:state<=RIGHT;
   RIGHT:begin
    samples[1]<=sy[0] ? odd_out : even_out;
    samples[3]<=last_source_row ? (sy[0]?odd_out:even_out) : (sy[0]?even_out:odd_out);
    channel<=0;state<=H0;
   end
   H0:begin h_left<=a;h_delta<=$signed({1'b0,b})-$signed({1'b0,a});state<=H0_MUL;end
   H0_MUL:begin h_product<=h_delta*$signed({1'b0,x_fp[7:0]});state<=H0_ADD;end
   H0_ADD:begin horizontal0<=h_sum[15:0];state<=H1;end
   H1:begin h_left<=c;h_delta<=$signed({1'b0,d})-$signed({1'b0,c});state<=H1_MUL;end
   H1_MUL:begin h_product<=h_delta*$signed({1'b0,x_fp[7:0]});state<=H1_ADD;end
   H1_ADD:begin horizontal1<=h_sum[15:0];state<=V0;end
   V0:begin v_upper<=horizontal0;v_delta<=$signed({1'b0,horizontal1})-$signed({1'b0,horizontal0});state<=V_MUL;end
   V_MUL:begin v_product<=v_delta*$signed({1'b0,y_fp[7:0]});state<=V_ADD;end
   V_ADD:begin
    case(channel)
     0:result[7:0]<=v_rounded[23:16];1:result[15:8]<=v_rounded[23:16];2:result[23:16]<=v_rounded[23:16];
    endcase
    if(channel==2)state<=OUTPUT;else begin channel<=channel+1'b1;state<=H0;end
   end
   OUTPUT:if(slot_free)begin out_wr_en<=1;out_data<={result,8'd0};state<=ADVANCE;end
   ADVANCE:if(slot_free)begin
    if(output_x<DST_W-1)begin
     output_x<=output_x+1'b1;
     if(active_pixel && output_x<right_last)begin
      x_fp<=x_fp+x_step+x_carry;x_error<=x_carry ? x_error_sum-x_den : x_error_sum;
     end
     state<=ROUTE_SETUP;
    end else if(output_y<DST_H-1)begin
     output_y<=output_y+1'b1;
     if(output_y>=bottom_pad && output_y<top_last)begin
      y_fp<=y_fp+y_step+y_carry;y_error<=y_carry ? y_error_sum-y_den : y_error_sum;
     end
     output_x<=0;x_fp<=x_origin;
     x_error<=x_origin_error;state<=ROUTE_SETUP;
    end else if(input_y>=height_r)state<=DONE;
    else state<=DRAIN;
   end
   IDENTITY:if(in_wr_en && !out_wr_en)begin
    out_wr_en<=1;out_data<={in_data[23:0],8'd0};
    if(output_x==DST_W-1)begin
     output_x<=0;if(output_y==DST_H-1)state<=FINAL;else output_y<=output_y+1'b1;
    end else output_x<=output_x+1'b1;
   end
   FINAL:if(slot_free)state<=DONE;
   DRAIN:begin
    if(in_wr_en)begin
     if(write_x==width_last)begin
      write_x<=0;input_y<=input_y+1'b1;
      if(input_y==height_last)state<=DONE;
     end
     else write_x<=write_x+1'b1;
    end
   end
   DONE:begin out_busy<=0;out_done<=1;if(!in_write_req)state<=IDLE;end
   default:begin state<=IDLE;out_busy<=0;out_write_req<=0;end
  endcase
 end
end
endmodule
