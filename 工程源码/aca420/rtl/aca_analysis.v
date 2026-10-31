`timescale 1ns/1ps
// Eight measured DFT bins, logarithmic magnitude, bar decay, 16 triggered waveform
// samples (every 4 samples); no claim of a contiguous broadband FFT.
module aca_analysis(input wire clk,rst,sample_valid,input wire signed [15:0] sample,
output reg [63:0] bars,output reg [127:0] waveform,
 output wire overrun,overflow);
 wire result;wire [31:0] power[0:7];wire [2:0] peak_index;
 audio_goertzel #(.BAND_COUNT(8),.POWER_SHIFT(25),.POWER_WIDTH(24),
 .COEFF0(131033),.COEFF1(130914),.COEFF2(130441),.COEFF3(128553),
 .FREQUENCY0(188),.FREQUENCY1(375),.FREQUENCY2(750),.FREQUENCY3(1500)) u_bins(
 .clk(clk),.rst(rst),.sample_valid(sample_valid),.sample_in(sample),.sample_ready(),
 .sample_overrun(overrun),.result_valid(result),.result_overflow(overflow),
 .event_pulse(),.peak_index(peak_index),.peak_frequency(),.peak_power(),
 .power0(power[0]),.power1(power[1]),.power2(power[2]),.power3(power[3]),
 .power4(power[4]),.power5(power[5]),.power6(power[6]),.power7(power[7]),.sample_count());
 function [7:0] log_height;input [31:0] p;integer k;reg [7:0] v;
 begin v=0;for(k=4;k<24;k=k+1)if(p[k])v=(k-3)*6;log_height=v;end endfunction
 reg [1:0] wave_div;reg previous_negative,capturing;reg [3:0] wave_count;
 reg [11:0] trigger_age;reg [127:0] wave_capture;integer i;reg [7:0] height;
 always @(posedge clk)begin
  if(rst)begin bars<=0;waveform<={16{8'd128}};wave_div<=0;previous_negative<=1;capturing<=0;wave_count<=0;trigger_age<=0;wave_capture<=0;end
  else begin
   if(sample_valid)begin
    previous_negative<=sample[15];
    // Capture 16 points after a rising zero crossing. DC/silence gets a
    // timeout capture; the published waveform never contains half a capture.
    if(!capturing)begin
     if((previous_negative && !sample[15]) || trigger_age==4095)begin
      capturing<=1;wave_capture<={120'b0,(sample[15:8]^8'h80)};
      wave_count<=1;wave_div<=0;trigger_age<=0;
     end else trigger_age<=trigger_age+1'b1;
    end else begin
     wave_div<=wave_div+1'b1;
     if(wave_div==3)begin
      wave_capture<={wave_capture[119:0],(sample[15:8]^8'h80)};
      if(wave_count==15)begin
       waveform<={wave_capture[119:0],(sample[15:8]^8'h80)};capturing<=0;
      end else wave_count<=wave_count+1'b1;
     end
    end
   end
   if(result)for(i=0;i<8;i=i+1)begin
    height=log_height(power[i]);
    if(height>=bars[i*8+:8])bars[i*8+:8]<=height;
    else bars[i*8+:8]<=bars[i*8+:8]-height>2?bars[i*8+:8]-2:height;
   end
  end
 end
endmodule
