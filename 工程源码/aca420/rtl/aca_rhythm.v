`timescale 1ns/1ps
// Three volatile learned four-tap templates. Compare normalized intervals
// by cross products; uniform tempo changes cancel. Reject ambiguous match_count.
module aca_rhythm #(parameter integer MS_CYCLES=50000,MIN_GAP=120,MAX_GAP=1800,
 parameter integer COOLDOWN_MS=1000)(
 input wire clk,rst,tap,learn,clear,input wire [1:0] slot,
 output reg learning,output reg [2:0] learned,output reg [2:0] progress,
 output reg event_valid,output reg [1:0] event_command,
 output reg [7:0] confidence,output reg rejected,output reg learned_pulse
);
 reg [31:0] divider;reg [15:0] gap,cooldown;wire ms=divider>=MS_CYCLES-1;
 reg [15:0] intervals[0:1];reg [15:0] templates[0:8];reg [15:0] totals[0:2];
 reg [15:0] captured[0:2];reg [15:0] total;reg [1:0] learn_slot;
 reg checking;reg [1:0] check_slot,check_interval;reg candidate;
 reg [1:0] match_count,matched_slot;integer i;
 wire [31:0] a=captured[check_interval]*totals[check_slot];
 wire [31:0] b=templates[check_slot*3+check_interval]*total;
 wire [31:0] base=totals[check_slot]*total;
 wire [31:0] diff=a>b?a-b:b-a;
 wire interval_ok=diff<=(base>>3);
 always @(posedge clk)begin
  if(rst)begin
   divider<=0;gap<=0;cooldown<=0;learning<=0;learned<=0;progress<=0;event_valid<=0;event_command<=0;confidence<=0;rejected<=0;learned_pulse<=0;
   checking<=0;check_slot<=0;check_interval<=0;candidate<=1;match_count<=0;matched_slot<=0;total<=0;learn_slot<=0;
   for(i=0;i<9;i=i+1)templates[i]<=0;
   for(i=0;i<3;i=i+1)begin totals[i]<=0;captured[i]<=0;end
   intervals[0]<=0;intervals[1]<=0;
  end else begin
   event_valid<=0;rejected<=0;learned_pulse<=0;
   if(ms)begin divider<=0;if(gap<MAX_GAP+1)gap<=gap+1'b1;if(cooldown!=0)cooldown<=cooldown-1'b1;end
   else divider<=divider+1'b1;
   if(clear)begin learned[slot]<=0;progress<=0;learning<=0;checking<=0;end
   else if(learn)begin learning<=~learning;learn_slot<=slot;progress<=0;gap<=0;checking<=0;confidence<=0;end
   else if(checking)begin
    if(check_interval==2)begin
     if(candidate && interval_ok && learned[check_slot])begin match_count<=match_count+1'b1;matched_slot<=check_slot;end
     if(check_slot==2)begin
      checking<=0;cooldown<=COOLDOWN_MS;
      if((match_count==1 && !(candidate && interval_ok && learned[2])) || (match_count==0 && candidate && interval_ok && learned[2]))begin
       event_valid<=1;event_command<=match_count==0?3:matched_slot+1'b1;confidence<=100;
      end else begin rejected<=1;confidence<=0;end
     end else begin check_slot<=check_slot+1'b1;check_interval<=0;candidate<=1;end
    end else begin candidate<=candidate && interval_ok;check_interval<=check_interval+1'b1;end
   end else if(progress!=0 && gap>MAX_GAP)begin progress<=0;rejected<=1;end
   else if(tap && (learning || cooldown==0))begin
    if(progress==0)begin progress<=1;gap<=0;end
    else if(gap>=MIN_GAP && gap<=MAX_GAP)begin
     gap<=0;
     if(progress==3)begin
      progress<=0;
      if(learning)begin
       templates[learn_slot*3]<=intervals[0];templates[learn_slot*3+1]<=intervals[1];templates[learn_slot*3+2]<=gap;
       totals[learn_slot]<=intervals[0]+intervals[1]+gap;learned[learn_slot]<=1;learning<=0;learned_pulse<=1;confidence<=100;
      end else begin
       captured[0]<=intervals[0];captured[1]<=intervals[1];captured[2]<=gap;total<=intervals[0]+intervals[1]+gap;
       checking<=1;check_slot<=0;check_interval<=0;candidate<=1;match_count<=0;
      end
     end else begin intervals[progress-1]<=gap;progress<=progress+1'b1;end
    end // Very close echoes are ignored, not treated as a new rhythm.
   end
  end
 end
endmodule
