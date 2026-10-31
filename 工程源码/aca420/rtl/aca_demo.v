`timescale 1ns/1ps
// Synthetic 750 Hz PCM and four-tap gestures, independent of ADC availability.
// Three patterns correspond to NEXT / PAUSE / FX. No recognition is bypassed.
module aca_demo #(parameter integer SAMPLE_CYCLES=1041,MS_CYCLES=50000)(
 input wire clk,rst,enable,input wire [1:0] slot,
 output reg sample_valid,output reg signed [15:0] sample,output reg tap
);
 reg [15:0] sample_div;reg [5:0] phase;reg [31:0] ms_div;reg [12:0] elapsed;reg previous_enable;
 wire hit=elapsed==100 || (slot==0 && (elapsed==400 || elapsed==700 || elapsed==1000)) ||
 (slot==1 && (elapsed==300 || elapsed==500 || elapsed==1100)) ||
 (slot==2 && (elapsed==300 || elapsed==900 || elapsed==1100));
 always @(posedge clk)begin
  if(rst)begin sample_div<=0;phase<=0;sample_valid<=0;sample<=0;ms_div<=0;elapsed<=0;tap<=0;previous_enable<=0;end
  else begin
   sample_valid<=0;tap<=0;previous_enable<=enable;
   if(!enable || !previous_enable)begin elapsed<=0;ms_div<=0;sample_div<=0;phase<=0;sample<=0;end
   else begin
    if(sample_div>=SAMPLE_CYCLES-1)begin sample_div<=0;sample_valid<=1;phase<=phase+1'b1;sample<=phase[5]?-16'sd6000:16'sd6000;end else sample_div<=sample_div+1'b1;
    if(ms_div>=MS_CYCLES-1)begin ms_div<=0;elapsed<=elapsed==5999?0:elapsed+1'b1;if(hit)tap<=1;end else ms_div<=ms_div+1'b1;
   end
  end
 end
endmodule
