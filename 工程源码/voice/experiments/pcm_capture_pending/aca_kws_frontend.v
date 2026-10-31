`timescale 1ns/1ps
// Fixed point reference: voice/tools/kws_common.py. Fs=48027.66/6 Hz.
module aca_kws_frontend #(parameter integer ADAPTIVE_VAD=0)(input wire clk,rst,sample_valid,
 input wire signed [15:0] sample,
 output reg feature_valid,output reg [3:0] feature_index,
 output reg signed [7:0] feature_data,output reg frame_done,
 output wire fault,output wire vad_ready,output wire vad_speech,
 output wire debug_pcm_valid,output wire signed [15:0] debug_pcm);
 reg [2:0] div6;reg signed [18:0] box_sum;
 reg dec_valid;reg signed [15:0] dec_sample;
 assign debug_pcm_valid=dec_valid;
 assign debug_pcm=dec_sample;
 wire signed [18:0] box_total=box_sum+{{3{sample[15]}},sample};
 always @(posedge clk)begin
  if(rst)begin div6<=0;box_sum<=0;dec_valid<=0;dec_sample<=0;end
  else begin
   dec_valid<=0;
   if(sample_valid)begin
    if(div6==5)begin div6<=0;box_sum<=0;dec_sample<=box_total>>>3;dec_valid<=1;end
    else begin div6<=div6+1'b1;box_sum<=box_total;end
   end
  end
 end
 wire result,overrun,overflow;wire [31:0] p[0:15];
 kws_goertzel u_bins(.clk(clk),.rst(rst),.sample_valid(dec_valid),.sample_in(dec_sample),
  .sample_overrun(overrun),.result_overflow(overflow),.result_valid(result),
  .power0(p[0]),.power1(p[1]),.power2(p[2]),.power3(p[3]),
  .power4(p[4]),.power5(p[5]),.power6(p[6]),.power7(p[7]),
  .power8(p[8]),.power9(p[9]),.power10(p[10]),.power11(p[11]),
  .power12(p[12]),.power13(p[13]),.power14(p[14]),.power15(p[15]));
 function [7:0] log4;
  input [31:0] v;integer j;reg [31:0] mant;
  begin
   log4=0;mant=0;
   for(j=0;j<32;j=j+1)if(v[j])begin
    if(j>=2)mant=v>>(j-2);else mant=v<<(2-j);
    log4=j*4+mant[1:0];
   end
  end
 endfunction
 reg [1:0] state;reg [3:0] band;reg half;
 reg [7:0] logs[0:15];reg signed [7:0] first[0:15];
 reg [7:0] max_log;reg loud;reg sticky_fault;
 // Estimate the ambient spectral-power floor before admitting an utterance.
 // log4 has four steps per octave: +8 requires 4x background power.
 // Freeze during speech; otherwise quiet background must become ZERO features,
 // just as silence in the trained model, rather than blocking endpoint forever.
 reg [10:0] noise_q;
 reg [10:0] band_noise_q[0:15];
 reg [4:0] speech_bands;
 reg [4:0] calibration;
 reg [7:0] active_run;
 reg speech;
 assign vad_ready=calibration==16;
 assign vad_speech=speech;
 wire [7:0] noise_log=noise_q[10:3];
 wire [8:0] speech_threshold={1'b0,noise_log}+9'd8;
 wire vad_active=loud && {1'b0,max_log}>speech_threshold && speech_bands>=3;
 wire [7:0] floor_log=max_log;
 wire [7:0] current_log=log4(p[band]);
 wire [7:0] difference=max_log-logs[band];
 wire signed [7:0] normalized=(!loud || (ADAPTIVE_VAD && !speech) || difference>=64)?-8'sd64:-$signed(difference);
 wire signed [8:0] pair_sum=$signed(first[band])+$signed(normalized);
 assign fault=overrun|overflow|sticky_fault;
 integer n;
 always @(posedge clk)begin
  if(rst)begin
   state<=0;band<=0;half<=0;max_log<=0;loud<=0;sticky_fault<=0;
   noise_q<=11'd0;calibration<=0;active_run<=0;speech<=0;
   speech_bands<=0;
   for(n=0;n<16;n=n+1)band_noise_q[n]<=0;
   feature_valid<=0;feature_index<=0;feature_data<=0;frame_done<=0;
  end else begin
   feature_valid<=0;frame_done<=0;
   if(result && state!=0)sticky_fault<=1;
   case(state)
    0:if(result)begin band<=0;max_log<=0;loud<=0;speech_bands<=0;state<=1;end
    1:begin
     logs[band]<=current_log;
     if({1'b0,current_log}>{1'b0,band_noise_q[band][10:3]}+9'd8)
       speech_bands<=speech_bands+1'b1;
     if(current_log>max_log)max_log<=current_log;
     if(p[band]>=512)loud<=1;
     if(band==15)begin band<=0;state<=3;end else band<=band+1'b1;
    end
    3:begin
     speech<=calibration==16 && vad_active;
     if(calibration<16)begin
      calibration<=calibration+1'b1;
      // Start at the observed floor, never at an artificial zero floor.
      noise_q<=calibration==0 ? {floor_log,3'd0} : noise_q-(noise_q>>3)+{3'd0,floor_log};
     end else if(!vad_active || active_run==127)begin
      noise_q<=noise_q-(noise_q>>3)+{3'd0,floor_log};
     end
     if(vad_active)begin if(active_run<127)active_run<=active_run+1'b1;end
     else active_run<=0;
     state<=2;
    end
    2:begin
     if(calibration==1)band_noise_q[band]<={logs[band],3'd0};
     else if(calibration<16 || !speech || active_run==127)
       band_noise_q[band]<=band_noise_q[band]-(band_noise_q[band]>>3)+{3'd0,logs[band]};
     if(!half)first[band]<=normalized;
     else begin feature_valid<=1;feature_index<=band;feature_data<=(pair_sum>>>1)+64;end
     if(band==15)begin state<=0;half<=~half;if(half)frame_done<=1;end
     else band<=band+1'b1;
    end
    default:state<=0;
   endcase
  end
 end
endmodule
