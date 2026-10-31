`timescale 1ns/1ps
// Full-content 64x48 RGB444 storage, aspect-correct bilinear 640x480 display.
module user_image_rom #(
    // TD resolves readmemh paths relative to this HDL source directory.
    parameter ROM_FILE = "user_images_rgb444.mem"
)(
    input wire clk, input wire rst,
    input wire hs, input wire vs, input wire de,
    input wire [2:0] image_index,
    output reg hs_out, output reg vs_out, output reg de_out,
    output wire [23:0] rgb
);
(* ram_style = "block" *) reg [11:0] pixels [0:32767];
initial $readmemh(ROM_FILE, pixels);
// One ROM port fills two row caches in 130 clocks of the 160-clock horizontal
// blank. Replicating the full picture ROM would exceed the device's 64 BRAMs.
(* ram_style = "distributed" *) reg [11:0] row0 [0:63];
(* ram_style = "distributed" *) reg [11:0] row1 [0:63];
reg [11:0] pixel;
reg loading, read_valid, cache_ready;
reg [6:0] load_count, read_count;
reg [5:0] cache_y;
reg [2:0] cache_image;
wire [5:0] load_y = load_count[6] && cache_y != 47 ? cache_y + 1'b1 : cache_y;
wire [14:0] image_base = ({12'd0, cache_image} << 11) + ({12'd0, cache_image} << 10);
wire [14:0] address = image_base + {3'd0, load_y, load_count[5:0]};
// Keep this register unreset to infer initialized synchronous BRAM.
always @(posedge clk) pixel <= pixels[address];

reg [9:0] x;
reg [8:0] y;
reg [21:0] x_phase, y_phase;
reg vs_d, de_d;
function [41:0] geometry;
    input [2:0] index;
    reg [9:0] left_edge,right_edge;
    reg [21:0] x_step;
    begin
    left_edge=10'd150; right_edge=10'd490; x_step=22'd12179;
    case(index)
`include "user_image_geometry.vh"
    endcase
    geometry={left_edge,right_edge,x_step};
    end
endfunction
wire [9:0] left_edge,right_edge;
wire [21:0] x_step;
assign {left_edge,right_edge,x_step}=geometry(image_index);
wire frame_reset = (vs_d && !vs) || image_index != cache_image;
wire line_end = de_d && !de;
wire [21:0] next_y_phase = y == 478 ? (22'd47 << 16) : y_phase + 22'd6430;
wire row_change = line_end && y < 479 && next_y_phase[21:16] != cache_y;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        x<=0; y<=0; x_phase<=0; y_phase<=0; vs_d<=0; de_d<=0;
        loading<=0;read_valid<=0;cache_ready<=0;load_count<=0;read_count<=0;
        cache_y<=0;cache_image<=0;
    end else begin
        vs_d<=vs; de_d<=de;
        if(frame_reset) begin
            x<=0; y<=0; x_phase<=0; y_phase<=0;
        end else begin
            if(de) begin
                x <= x == 639 ? 10'd0 : x + 1'b1;
                if(x >= left_edge && x < right_edge - 1'b1) x_phase<=x_phase+x_step;
            end else begin x<=0; x_phase<=0; end
            if(line_end && y < 479) begin y<=y+1'b1; y_phase<=next_y_phase; end
        end
        if(frame_reset || row_change) begin
            cache_y<=frame_reset ? 6'd0 : next_y_phase[21:16];
            cache_image<=image_index;
            load_count<=0;loading<=1;read_valid<=0;cache_ready<=0;
        end else begin
            read_valid<=loading; read_count<=load_count;
            if(loading) begin
                if(load_count==127) loading<=0;
                else load_count<=load_count+1'b1;
            end
            if(read_valid) begin
                if(read_count[6]) row1[read_count[5:0]]<=pixel;
                else row0[read_count[5:0]]<=pixel;
                if(read_count==127) cache_ready<=1;
            end
        end
    end
end

wire in_picture = de && x >= left_edge && x < right_edge && cache_ready;
wire [21:0] sample_phase = x == right_edge - 1'b1 || x_phase > (22'd63 << 16) ? (22'd63 << 16) : x_phase;
wire [5:0] sample_x = sample_phase[21:16];
wire [5:0] sample_x1 = sample_x == 63 ? 6'd63 : sample_x + 1'b1;
wire [7:0] xf = sample_phase[15:8];
wire [11:0] p00=row0[sample_x],p01=row0[sample_x1];
wire [11:0] p10=row1[sample_x],p11=row1[sample_x1];

function [7:0] lerp8;
    input [7:0] a,b,f;
    reg signed [8:0] delta,weight;
    reg signed [17:0] product;
    reg signed [18:0] result;
    begin
        delta=$signed({1'b0,b})-$signed({1'b0,a});
        weight=$signed({1'b0,f});
        product=delta*weight;
        result=$signed({1'b0,a})+(($signed(product)+19'sd128) >>> 8);
        lerp8=result[7:0];
    end
endfunction

// Separate horizontal and vertical stages keep interpolation timing short.
// HS/VS/DE have the same two-clock latency, including the black margins.
reg [23:0] upper,lower,rgb_out;
reg [7:0] yf;
reg hs_stage,vs_stage,de_stage,picture_stage;
assign rgb = de_out ? rgb_out : 24'd0;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        upper<=0;lower<=0;rgb_out<=0;yf<=0;
        hs_stage<=0;vs_stage<=0;de_stage<=0;picture_stage<=0;
        hs_out<=0;vs_out<=0;de_out<=0;
    end else begin
        hs_stage<=hs;vs_stage<=vs;de_stage<=de;picture_stage<=in_picture;
        hs_out<=hs_stage;vs_out<=vs_stage;de_out<=de_stage;
        yf<=y_phase[15:8];
        upper<={lerp8({p00[11:8],p00[11:8]},{p01[11:8],p01[11:8]},xf),
                lerp8({p00[7:4],p00[7:4]},{p01[7:4],p01[7:4]},xf),
                lerp8({p00[3:0],p00[3:0]},{p01[3:0],p01[3:0]},xf)};
        lower<={lerp8({p10[11:8],p10[11:8]},{p11[11:8],p11[11:8]},xf),
                lerp8({p10[7:4],p10[7:4]},{p11[7:4],p11[7:4]},xf),
                lerp8({p10[3:0],p10[3:0]},{p11[3:0],p11[3:0]},xf)};
        rgb_out<=picture_stage ? {lerp8(upper[23:16],lower[23:16],yf),
                                 lerp8(upper[15:8],lower[15:8],yf),
                                 lerp8(upper[7:0],lower[7:0],yf)} : 24'd0;
    end
end
endmodule
