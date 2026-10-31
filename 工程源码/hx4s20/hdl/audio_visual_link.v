`timescale 1ns/1ps
// Request the next image after a stable dominant selected frequency changes.
// The legacy transition_start output is consumed by the SD request path.
// This is a tone-change detector, not a musical beat/tempo estimator.
// All inputs are synchronous to clk. Three result windows reject peak jitter;
// a frame-based refractory period prevents repeated starts during one effect.
module audio_visual_link #(
    parameter integer INDEX_WIDTH = 2,
    parameter integer COOLDOWN_FRAMES = 40,
    parameter [31:0] MIN_POWER = 32'd4096
)(
    input wire clk,
    input wire rst,
    input wire enable,
    input wire frame_start,
    input wire result_valid,
    input wire result_overflow,
    input wire [INDEX_WIDTH-1:0] peak_index,
    input wire [31:0] peak_power,
    output reg transition_start
);
reg [INDEX_WIDTH-1:0] candidate, active_peak;
reg [1:0] stable_count;
reg have_peak;
reg [7:0] cooldown;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        candidate<=0;stable_count<=0;active_peak<=0;have_peak<=0;
        cooldown<=0;transition_start<=0;
    end else begin
        transition_start<=0;
        if(!enable) begin
            stable_count<=0;have_peak<=0;cooldown<=0;
        end else begin
            if(frame_start && cooldown!=0) cooldown<=cooldown-1'b1;
            if(result_valid) begin
                if(result_overflow || peak_power<MIN_POWER) stable_count<=0;
                else if(stable_count==0 || peak_index!=candidate) begin
                    candidate<=peak_index;stable_count<=1;
                end else if(stable_count<2) stable_count<=stable_count+1'b1;
                else if(!have_peak) begin
                    // 首次稳定音调只建立基准，开关/无卡恢复不能触发切图。
                    active_peak<=candidate;have_peak<=1;
                end else if(candidate!=active_peak && cooldown==0) begin
                    transition_start<=1;
                    active_peak<=candidate;have_peak<=1;
                    cooldown<=COOLDOWN_FRAMES;
                end
            end
        end
    end
end
endmodule

// Compact frequency-band estimator: count positive hysteretic crossings in
// 1024 accepted samples. +/-8 PCM12 deadband rejects small zero-point jitter.
// Frequency bands <300, <600, <1200 and >=1200 Hz at nominal 48kHz.
// This is waveform crossing density, not FFT/dominant spectral frequency.
module music_frequency_probe(input clk,rst,sample_valid,input signed [11:0] sample_in,
 output reg result_valid,output wire result_overflow,output reg [1:0] peak_index,
 output reg [31:0] peak_power);
 reg [9:0] count;reg [4:0] crossings;reg armed;reg loud;
 wire crossing=armed && sample_in>12'sd8;
 // Only the <7/<13/<26 decisions are used; saturate instead of counting
 // beyond the highest band. The consumer needs a silence gate, not power.
 wire [4:0] total_crossings=crossings==5'd26 ? crossings : crossings+crossing;
 wire loud_now=loud || sample_in>=12'sd32 || sample_in<=-12'sd32;
 assign result_overflow=1'b0;
 always @(posedge clk or posedge rst)begin
  if(rst)begin count<=0;crossings<=0;armed<=0;loud<=0;result_valid<=0;peak_index<=0;peak_power<=0;end
  else begin
   result_valid<=0;
   if(sample_valid)begin
    if(sample_in< -12'sd8)armed<=1;else if(crossing)armed<=0;
    if(count==1023)begin
     peak_index<=total_crossings<7?0:total_crossings<13?1:total_crossings<26?2:3;
     peak_power<=loud_now ? 32'd8192 : 32'd0;
     result_valid<=1;count<=0;crossings<=0;loud<=0;
    end else begin count<=count+1'b1;crossings<=total_crossings;loud<=loud_now;end
   end
  end
 end
endmodule
