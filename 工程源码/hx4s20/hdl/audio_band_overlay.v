`timescale 1ns/1ps

// Four or eight measured Goertzel frequency bars. Each power is magnitude
// squared, not amplitude/dB. A simple logarithmic display maps bit 12 to height
// 4, bit 13 to height 8, etc. NOISE_GATE suppresses tiny powers. For default
// Goertzel coefficients the bars represent about 262/330/392/523 Hz.
// Result signals must be synchronous to I_video_clk. They are held as a pending
// snapshot then displayed at the next falling VS edge to avoid frame tearing.
// Pixel output latency is exactly one I_video_clk. I_de=0 always passes I_rgb.
module audio_band_overlay #(
    parameter integer BAND_COUNT=4,
    parameter integer INDEX_WIDTH=(BAND_COUNT==8)?3:2,
    parameter integer FRAME_WIDTH=640,
    parameter integer FRAME_HEIGHT=480,
    parameter integer BOX_X=32,
    parameter integer BOX_Y=380,
    parameter integer BOX_WIDTH=576,
    parameter integer BAR_HEIGHT=80,
    parameter integer BAR_GAP=12,
    parameter integer DECAY_STEP=2,
    parameter integer PEAK_HOLD_FRAMES=12,
    parameter integer POWER_BASE_BIT=11,
    parameter [31:0] NOISE_GATE=32'd4096
)(
    input wire I_video_clk,
    input wire I_rst,
    input wire I_vs,
    input wire I_de,
    input wire [23:0] I_rgb,
    input wire I_enable,
    input wire I_result_valid,
    input wire [INDEX_WIDTH-1:0] I_peak_index,
    input wire [31:0] I_power0,
    input wire [31:0] I_power1,
    input wire [31:0] I_power2,
    input wire [31:0] I_power3,
    input wire [31:0] I_power4,
    input wire [31:0] I_power5,
    input wire [31:0] I_power6,
    input wire [31:0] I_power7,
    output reg [23:0] O_rgb_out
);
    localparam integer BAR_WIDTH=BOX_WIDTH/BAND_COUNT;
    localparam integer HEIGHT_WIDTH=$clog2(BAR_HEIGHT+1);
    localparam integer HOLD_WIDTH=(PEAK_HOLD_FRAMES<2)?1:$clog2(PEAK_HOLD_FRAMES+1);
    reg vs_d, de_d;
    localparam integer X_WIDTH=(FRAME_WIDTH<2)?1:$clog2(FRAME_WIDTH);
    localparam integer Y_WIDTH=(FRAME_HEIGHT<2)?1:$clog2(FRAME_HEIGHT);
    reg [X_WIDTH-1:0] px_x;
    reg [Y_WIDTH-1:0] px_y;
    wire frame_start=vs_d && !I_vs;
    reg [HEIGHT_WIDTH-1:0] pending_h [0:BAND_COUNT-1];
    reg [HEIGHT_WIDTH-1:0] active_h [0:BAND_COUNT-1];
    reg [HEIGHT_WIDTH-1:0] peak_h [0:BAND_COUNT-1];
    reg [HOLD_WIDTH-1:0] peak_hold [0:BAND_COUNT-1];
    wire [31:0] powers [0:7];
    assign powers[0]=I_power0; assign powers[1]=I_power1;
    assign powers[2]=I_power2; assign powers[3]=I_power3;
    assign powers[4]=I_power4; assign powers[5]=I_power5;
    assign powers[6]=I_power6; assign powers[7]=I_power7;
    wire [HEIGHT_WIDTH-1:0] target_h [0:BAND_COUNT-1];
    wire [HEIGHT_WIDTH-1:0] next_h [0:BAND_COUNT-1];
    genvar g;
    generate for(g=0;g<BAND_COUNT;g=g+1) begin : envelope
        assign target_h[g]=I_result_valid?power_height(powers[g]):pending_h[g];
        assign next_h[g]=(target_h[g]>=active_h[g])?target_h[g]:
            ((active_h[g]-target_h[g]<=DECAY_STEP)?target_h[g]:active_h[g]-DECAY_STEP);
    end endgenerate
    integer r;
    function [HEIGHT_WIDTH-1:0] power_height;
        input [31:0] p;
        integer bit_index;
        begin
            if(p==0 || p<NOISE_GATE) power_height=0;
            else begin
                power_height=1;
                // Constant heights map the highest set bit directly. This
                // avoids eight replicated signed subtract/compare datapaths.
                for(bit_index=0;bit_index<32;bit_index=bit_index+1)
                    if(p[bit_index]) begin
                        if(bit_index<=POWER_BASE_BIT) power_height=1;
                        else if((bit_index-POWER_BASE_BIT)*4>BAR_HEIGHT) power_height=BAR_HEIGHT;
                        else power_height=(bit_index-POWER_BASE_BIT)*4;
                    end
            end
        end
    endfunction
    always @(posedge I_video_clk or posedge I_rst) begin
        if(I_rst) begin
            vs_d<=0; de_d<=0; px_x<=0; px_y<=0;
            for(r=0;r<BAND_COUNT;r=r+1) begin
                pending_h[r]<=0; active_h[r]<=0; peak_h[r]<=0; peak_hold[r]<=0;
            end
        end else begin
            vs_d<=I_vs; de_d<=I_de;
            if(frame_start) px_y<=0;
            else if(de_d && !I_de && px_y<FRAME_HEIGHT-1) px_y<=px_y+1'b1;
            if(I_de) begin
                if(px_x<FRAME_WIDTH-1) px_x<=px_x+1'b1;
                else px_x<=0;
            end else px_x<=0;
            if(I_result_valid) begin
                for(r=0;r<BAND_COUNT;r=r+1) pending_h[r]<=power_height(powers[r]);
            end
            if(frame_start) begin
                // A result arriving on this same edge also belongs to this frame.
                for(r=0;r<BAND_COUNT;r=r+1) begin
                    active_h[r]<=next_h[r];
                    if(next_h[r]>=peak_h[r]) begin
                        peak_h[r]<=next_h[r]; peak_hold[r]<=PEAK_HOLD_FRAMES;
                    end else if(peak_hold[r]!=0) peak_hold[r]<=peak_hold[r]-1'b1;
                    else if(peak_h[r]>next_h[r]) peak_h[r]<=peak_h[r]-1'b1;
                end
            end
        end
    end
    reg [INDEX_WIDTH-1:0] bar_index;
    reg [23:0] bar_color;
    integer m;
    always @(*) begin
        bar_index=0;
        for(m=1;m<BAND_COUNT;m=m+1)
            if(px_x>=BOX_X+m*BAR_WIDTH) bar_index=m;
        case(bar_index)
            0: bar_color=24'h40C8FF;
            1: bar_color=24'h40FFE0;
            2: bar_color=24'h70FF80;
            3: bar_color=24'hE0FF60;
            4: bar_color=24'hFFD060;
            5: bar_color=24'hFF9060;
            6: bar_color=24'hFF70C0;
            default: bar_color=24'hB090FF;
        endcase
    end
    wire in_box=I_de && I_enable && px_x>=BOX_X && px_x<BOX_X+BOX_WIDTH
        && px_y>=BOX_Y && px_y<BOX_Y+BAR_HEIGHT;
    wire [11:0] bar_x=px_x-BOX_X-bar_index*BAR_WIDTH;
    wire [11:0] from_bottom=BOX_Y+BAR_HEIGHT-1-px_y;
    wire in_body=bar_x>=BAR_GAP/2 && bar_x<BAR_WIDTH-BAR_GAP/2;
    wire in_bar=in_body && from_bottom<active_h[bar_index];
    wire peak_cap=in_body && peak_h[bar_index]!=0
        && from_bottom+1==peak_h[bar_index];
    wire [23:0] dim_rgb={1'b0,I_rgb[23:17],1'b0,I_rgb[15:9],1'b0,I_rgb[7:1]};
    always @(posedge I_video_clk or posedge I_rst) begin
        if(I_rst) O_rgb_out<=0;
        else if(in_box) begin
            if(peak_cap) O_rgb_out<=24'hFFFFFF;
            else if(in_bar) O_rgb_out<=bar_color;
            else O_rgb_out<=dim_rgb;
        end else O_rgb_out<=I_rgb;
    end
endmodule
