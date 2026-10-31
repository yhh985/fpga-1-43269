`timescale 1ns/1ps
// Measure actual input-pin transitions, independently of the PCM decoder.
// code: 0 = 32-bit slot (or no recent measurement), 1 = fewer than four
// BCLK rises per LRCK edge, 2 = approximately 64, 3 = another slot length.
// This does not establish pin identity or prove signal integrity.
module aca_music_clock_probe(input clk,rst,bclk,lrck,output reg [1:0] code,
 output reg valid);
 (* async_reg="true" *) reg [2:0] bs,ls;
 reg [7:0] rises;
 reg started;
 reg [1:0] candidate;
 reg [3:0] run;
 reg [19:0] idle;
 wire rise=bs[1]&&!bs[2];
 wire edge_lr=ls[1]!=ls[2];
 wire [8:0] measured={1'b0,rises}+rise;
 wire [1:0] category=measured<4 ? 2'd1 :
    measured>=31 && measured<=33 ? 2'd0 :
    measured>=63 && measured<=65 ? 2'd2 : 2'd3;
 always @(posedge clk or posedge rst)begin
  if(rst)begin bs<=0;ls<=0;rises<=0;started<=0;candidate<=0;run<=0;code<=0;valid<=0;idle<=0;end
  else begin
   bs<={bs[1:0],bclk};ls<={ls[1:0],lrck};
   if(edge_lr)begin
    idle<=0;started<=1;rises<=0;
    if(started)begin
     if(category!=candidate)begin candidate<=category;run<=1;end
     else begin
      if(run<8)run<=run+1'b1;
      if(run>=7)begin code<=category;valid<=1;end
     end
    end
   end else begin
    if(rise && rises!=255)rises<=rises+1'b1;
    if(idle!=20'hfffff)idle<=idle+1'b1;
    else begin code<=0;valid<=0;started<=0;run<=0;rises<=0;end
   end
  end
 end
endmodule

// Both external pins are INPUTS. Recognize the 32:1 clock pair in either
// order; never use DATA as a clock or drive an external pin during recovery.
// An idle code=0 is not evidence of a clock: valid is required for switching.
// CRC validation downstream remains mandatory for every audio sample.
module aca_music_clock_route(input clk,rst,pin_bclk,pin_lrck,
 output selected_bclk,selected_lrck,output reg swapped,
 output reg changed,output [1:0] code);
 wire [1:0] normal_code,reverse_code;
 wire normal_valid,reverse_valid;
 aca_music_clock_probe normal(.clk(clk),.rst(rst),.bclk(pin_bclk),
  .lrck(pin_lrck),.code(normal_code),.valid(normal_valid));
 aca_music_clock_probe reverse(.clk(clk),.rst(rst),.bclk(pin_lrck),
  .lrck(pin_bclk),.code(reverse_code),.valid(reverse_valid));
 assign selected_bclk=swapped?pin_lrck:pin_bclk;
 assign selected_lrck=swapped?pin_bclk:pin_lrck;
 assign code=swapped?reverse_code:normal_code;
 always @(posedge clk or posedge rst)begin
  if(rst)begin swapped<=0;changed<=0;end
  else begin
   changed<=0;
   if(!swapped && normal_valid && normal_code==1 &&
       reverse_valid && reverse_code==0)begin swapped<=1;changed<=1;end
   else if(swapped && normal_valid && normal_code==0 &&
       reverse_valid && reverse_code==1)begin swapped<=0;changed<=1;end
  end
 end
endmodule
