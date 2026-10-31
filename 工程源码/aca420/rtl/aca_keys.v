`timescale 1ns/1ps
module aca_keys #(parameter integer DEBOUNCE=1000000, LONG=50000000)(
 input wire clk,rst,input wire [2:0] keys_n,
 output reg [2:0] short_press,long_press
);
 reg [2:0] sync0,sync1,stable,long_seen;
 reg [19:0] db[0:2];reg [25:0] held[0:2];integer i;
 always @(posedge clk)begin
  if(rst)begin sync0<=7;sync1<=7;stable<=7;long_seen<=0;short_press<=0;long_press<=0;for(i=0;i<3;i=i+1)begin db[i]<=0;held[i]<=0;end end
  else begin
   sync0<=keys_n;sync1<=sync0;short_press<=0;long_press<=0;
   for(i=0;i<3;i=i+1)begin
    if(sync1[i]==stable[i])db[i]<=0;
    else if(db[i]>=DEBOUNCE-1)begin
     db[i]<=0;stable[i]<=sync1[i];
     if(sync1[i])begin if(!long_seen[i])short_press[i]<=1;held[i]<=0;long_seen[i]<=0;end
    end else db[i]<=db[i]+1'b1;
    if(!stable[i] && !long_seen[i])begin
     if(held[i]>=LONG-1)begin long_seen[i]<=1;long_press[i]<=1;end else held[i]<=held[i]+1'b1;
    end
   end
  end
 end
endmodule
