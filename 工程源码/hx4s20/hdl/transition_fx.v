`timescale 1ns/1ps
// Cover OLD frame, hold black for memory-reader swap, reveal NEW frame.
// Frame-paced coordinate masks inspired by Project F animated-shapes.
module transition_fx #(
    parameter DATA_WIDTH=24, ALPHA_BITS=5,
    parameter FRAME_WIDTH=640, FRAME_HEIGHT=480, WAIT_FOR_READER=0,
    parameter integer FRAME_STEP=1
)(
    input I_clk,I_rst,I_vs,I_de,I_trans_start,
    input [2:0] I_mode,
    input [DATA_WIDTH-1:0] I_rgb,
    input [9:0] I_px_x,I_px_y,
    input I_reveal,
    output [ALPHA_BITS-1:0] O_alpha,
    output O_active,O_black,
    output reg [DATA_WIDTH-1:0] O_rgb_out
);
localparam IDLE=0,CLOSE=1,BLACK=2,OPEN=3;
reg [1:0] phase;
reg [4:0] step;
reg [2:0] cur_mode_r;
reg vs_d0,vs_d1;
wire vs_falling=vs_d1 & ~vs_d0;
// Saturation preserves a full black frame even when the increment skips 31.
wire [4:0] next_step=step>=31-FRAME_STEP ? 5'd31 : step+FRAME_STEP;
always @(posedge I_clk or posedge I_rst) begin
    if(I_rst)begin vs_d0<=0;vs_d1<=0;end
    else begin vs_d0<=I_vs;vs_d1<=vs_d0;end
end
always @(posedge I_clk or posedge I_rst) begin
    if(I_rst)begin phase<=IDLE;step<=0;cur_mode_r<=0;end
    else if(I_trans_start && phase==IDLE)begin
        phase<=CLOSE;step<=0;cur_mode_r<=I_mode;
    end else if(vs_falling)begin
        case(phase)
            CLOSE: if(step==31)begin phase<=BLACK;step<=0;end else step<=next_step;
            BLACK: if(!WAIT_FOR_READER || I_reveal)begin phase<=OPEN;step<=0;end
            OPEN: if(step==31)begin phase<=IDLE;end else step<=next_step;
            default: ;
        endcase
    end
end
wire [4:0] p=(phase==OPEN) ? (5'd31-step) : step;
wire [5:0] gain={1'b0,5'd31-p}+1'b1;
wire [13:0] rm=I_rgb[23:16]*gain;
wire [13:0] gm=I_rgb[15:8]*gain;
wire [13:0] bm=I_rgb[7:0]*gain;
wire [9:0] wipe=p*10'd20;
wire [9:0] curtain=p*10'd10;
wire [10:0] diagonal={1'b0,I_px_x}+{1'b0,I_px_y};
wire [10:0] diagonal_edge=p*11'd36;
wire [9:0] dx=I_px_x<FRAME_WIDTH/2 ? FRAME_WIDTH/2-I_px_x : I_px_x-FRAME_WIDTH/2;
wire [9:0] dy=I_px_y<FRAME_HEIGHT/2 ? FRAME_HEIGHT/2-I_px_y : I_px_y-FRAME_HEIGHT/2;
wire [10:0] diamond={1'b0,dx}+{1'b0,dy};
wire [10:0] diamond_edge=p*11'd18;
// 32x32 squares: odd rows invert parity. All squares of one parity grow
// simultaneously over the whole frame; complementary squares follow.
wire parity=I_px_x[5]^I_px_y[5];
wire [4:0] local_dx=I_px_x[4:0]<16 ? 5'd15-I_px_x[4:0] : I_px_x[4:0]-5'd16;
wire [4:0] local_dy=I_px_y[4:0]<16 ? 5'd15-I_px_y[4:0] : I_px_y[4:0]-5'd16;
wire [4:0] square_radius={1'b0,p[3:0]};
wire square_inside=(local_dx<square_radius)&&(local_dy<square_radius);
wire checker_cover=(!parity && (p[4] || square_inside)) || (parity && p[4] && square_inside);
reg covered;
always @(*)begin
    case(cur_mode_r)
        1:covered=I_px_x<wipe;
        2:covered=I_px_y[4:0]<p;
        3:covered=checker_cover;
        4:covered=diamond<diamond_edge;
        5:covered=(I_px_x<curtain)||(I_px_x>=FRAME_WIDTH-curtain);
        6:covered=diagonal<diagonal_edge;
        default:covered=0;
    endcase
    if(p==0)covered=0;
    if(p==31)covered=1;
end
always @(posedge I_clk or posedge I_rst)begin
    if(I_rst)O_rgb_out<=0;
    else if(phase==BLACK)O_rgb_out<=0;
    else if(phase==IDLE)O_rgb_out<=I_rgb;
    else if(cur_mode_r==0)O_rgb_out<=p==31 ? 24'd0 : {rm[12:5],gm[12:5],bm[12:5]};
    else O_rgb_out<=covered ? 24'd0 : I_rgb;
end
assign O_active=phase!=IDLE;
assign O_black=phase==BLACK;
assign O_alpha=phase==CLOSE ? {1'b0,step[4:1]} :
               phase==BLACK ? 5'd16 : phase==OPEN ? {1'b1,step[4:1]} :
               step==31 ? 5'd31 : 5'd0;
endmodule
