`timescale 1ns/1ps
// Noise floor, hysteresis and frame-based hangover are informed by
// electronic-circuit/audio_vad.v. This is an independent transient detector,
// not speech recognition or a classifier proving a sound is a hand clap.
module aca_clap_detector #(
    parameter integer WINDOW_BITS=6,
    parameter integer CALIBRATION_FRAMES=200,
    parameter integer QUIET_FRAMES=16,
    parameter integer RELEASE_FRAMES=3,
    parameter integer MAX_ACTIVE_FRAMES=90,
    parameter integer COOLDOWN_FRAMES=110,
    parameter integer MIN_PEAK=1200,
    parameter integer MIN_MEAN=200,
    parameter integer MIN_OFF=150
)(
    input wire clk, input wire rst_n, input wire sample_valid,
    input wire signed [15:0] sample,
    output reg clap, output reg active, output reg calibrated,
    output reg clipped,
    output reg [16:0] frame_peak, noise_floor, threshold,
    output reg [15:0] clap_count
);
    localparam WARMUP=0, ARMED=1, CANDIDATE=2, HOLDOFF=3;
    reg [1:0] state;
    reg signed [31:0] dc_q8;
    wire signed [31:0] sample_q8={ {8{sample[15]}},sample,8'b0 };
    wire signed [31:0] ac_q8=sample_q8-dc_q8;
    wire [31:0] abs_q8=ac_q8[31] ? -ac_q8 : ac_q8;
    wire [16:0] magnitude=abs_q8[24:8];
    reg [WINDOW_BITS-1:0] sample_index;
    reg [17+WINDOW_BITS-1:0] sum;
    reg [16:0] peak;
    reg [WINDOW_BITS:0] loud_samples;
    reg raw_clip;
    reg frame_ready;
    reg [16:0] frame_mean;
    reg [WINDOW_BITS:0] frame_loud;
    wire [17+WINDOW_BITS-1:0] sum_next=sum+magnitude;
    wire [16:0] peak_next=peak>magnitude ? peak:magnitude;
    wire loud=magnitude>=threshold;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            dc_q8<=0; sample_index<=0; sum<=0; peak<=0; loud_samples<=0;
            raw_clip<=0; frame_ready<=0; frame_peak<=0;
            frame_mean<=0; frame_loud<=0; clipped<=0;
        end else begin
            frame_ready<=0;
            if(sample_valid) begin
                dc_q8<=dc_q8+(ac_q8>>>8);
                if(&sample_index) begin
                    frame_peak<=peak_next;
                    frame_mean<=sum_next>>WINDOW_BITS;
                    frame_loud<=loud_samples+loud;
                    clipped<=raw_clip || sample==16'sh7fff || sample==16'sh8000;
                    frame_ready<=1; sample_index<=0; sum<=0;
                    peak<=0; loud_samples<=0; raw_clip<=0;
                end else begin
                    sample_index<=sample_index+1'b1; sum<=sum_next; peak<=peak_next;
                    loud_samples<=loud_samples+loud;
                    if(sample==16'sh7fff || sample==16'sh8000) raw_clip<=1;
                end
            end
        end
    end
    reg [15:0] warmup, quiet, age, release_count, cooldown;
    reg onset_wait;
    wire [20:0] on_calc=({4'd0,noise_floor}<<3)+21'd1000;
    wire [19:0] off_calc=({3'd0,noise_floor}<<1)+20'd64;
    wire [16:0] off_threshold=off_calc>65535 ? 17'd65535 :
        off_calc<MIN_OFF ? MIN_OFF : off_calc[16:0];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WARMUP; noise_floor<=0; threshold<=MIN_PEAK;
            warmup<=0; quiet<=0; age<=0; release_count<=0; cooldown<=0;
            clap<=0; clap_count<=0; active<=0; calibrated<=0;
            onset_wait<=0;
        end else begin
            clap<=0;
            if(frame_ready) begin
                threshold<=on_calc>65535 ? 17'd65535 :
                    on_calc<MIN_PEAK ? MIN_PEAK : on_calc[16:0];
                if(state==WARMUP || (state==ARMED && frame_peak<threshold)) begin
                    if(frame_mean>noise_floor)
                        noise_floor<=noise_floor+((frame_mean-noise_floor)>>5);
                    else noise_floor<=noise_floor-((noise_floor-frame_mean)>>5);
                end
                case(state)
                    WARMUP: begin
                        if(warmup>=CALIBRATION_FRAMES-1) begin
                            calibrated<=1; quiet<=0; state<=ARMED;
                        end else warmup<=warmup+1'b1;
                    end
                    ARMED: begin
                        active<=0;
                        if(frame_mean<off_threshold) begin
                            if(quiet<QUIET_FRAMES) quiet<=quiet+1'b1;
                            onset_wait<=0;
                        end else if(quiet>=QUIET_FRAMES && !onset_wait) begin
                            // An onset may have only one sample in the last
                            // position of a frame. Preserve quiet history for
                            // one frame so the next full frame can qualify it.
                            // A lone spike still cannot meet frame_loud>=2.
                            onset_wait<=1;
                        end else begin quiet<=0; onset_wait<=0; end
                        if(quiet>=QUIET_FRAMES && frame_peak>=threshold &&
                           frame_mean>=MIN_MEAN && frame_loud>=2) begin
                            active<=1; age<=0; release_count<=0;
                            quiet<=0; state<=CANDIDATE;
                        end
                    end
                    CANDIDATE: begin
                        age<=age+1'b1;
                        if(age>=MAX_ACTIVE_FRAMES-1) begin
                            // Reject long speech/tones rather than repeat-triggering.
                            active<=0; cooldown<=0; state<=HOLDOFF;
                        end else if(frame_mean<off_threshold) begin
                            if(release_count>=RELEASE_FRAMES-1) begin
                                clap<=1; clap_count<=clap_count+1'b1;
                                active<=0; cooldown<=0; state<=HOLDOFF;
                            end else release_count<=release_count+1'b1;
                        end else release_count<=0;
                    end
                    HOLDOFF: begin
                        if(cooldown>=COOLDOWN_FRAMES-1) begin
                            quiet<=0; state<=ARMED;
                        end else cooldown<=cooldown+1'b1;
                    end
                    default: state<=WARMUP;
                endcase
            end
        end
    end
endmodule
