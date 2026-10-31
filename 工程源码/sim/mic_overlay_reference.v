`timescale 1ns/1ps
// Combinational RGB layer adds no pixel latency. DE coordinates belong to
// the same existing stage as RGB, VS resets them. Fixed 640x480 geometry.
module mic_overlay_reference(input wire clk,rst,vs,de,enable,online,
 input wire [255:0] status,input wire [23:0] rgb,
 output reg [23:0] out_rgb);
 reg [9:0] x,y;reg prev_de,prev_vs;
 always @(posedge clk)begin
  if(rst)begin x<=0;y<=0;prev_de<=0;prev_vs<=1;end
  else begin
   prev_de<=de;prev_vs<=vs;
   if(prev_vs && !vs)begin x<=0;y<=0;end
   else if(de)x<=x+1'b1;
   else if(prev_de)begin x<=0;y<=y+1'b1;end
  end
 end
 wire [7:0] flags=status[7:0];wire [1:0] slot=status[9:8];
 wire [2:0] progress=status[12:10],learned=status[18:16];
 wire [63:0] bars=status[95:32];wire [127:0] wave=status[223:96];
 reg [2:0] band;reg [3:0] wi;reg [7:0] height,w;
 reg [9:0] wave_y;reg [23:0] color;integer k;
 // KWS status marker keeps legacy diagnostic frames readable.
 wire kws=status[23];
 reg [87:0] mode_text;reg [31:0] command_text;
 reg [34:0] glyph;reg [7:0] ch;integer column,row,ci;
 function [34:0] font;
  input [7:0] c;
  begin case(c)
   "A":font=35'b01110_10001_10001_11111_10001_10001_10001;
   "C":font=35'b01111_10000_10000_10000_10000_10000_01111;
   "D":font=35'b11110_10001_10001_10001_10001_10001_11110;
   "E":font=35'b11111_10000_10000_11110_10000_10000_11111;
   "I":font=35'b11111_00100_00100_00100_00100_00100_11111;
   "M":font=35'b10001_11011_10101_10101_10001_10001_10001;
   "N":font=35'b10001_11001_11001_10101_10011_10011_10001;
   "O":font=35'b01110_10001_10001_10001_10001_10001_01110;
   "P":font=35'b11110_10001_10001_11110_10000_10000_10000;
   "R":font=35'b11110_10001_10001_11110_10100_10010_10001;
   "S":font=35'b01111_10000_10000_01110_00001_00001_11110;
   "T":font=35'b11111_00100_00100_00100_00100_00100_00100;
   "U":font=35'b10001_10001_10001_10001_10001_10001_01110;
   "V":font=35'b10001_10001_10001_10001_10001_01010_00100;
   "W":font=35'b10001_10001_10001_10101_10101_10101_01010;
   "X":font=35'b10001_10001_01010_00100_01010_10001_10001;
   "Y":font=35'b10001_10001_01010_00100_00100_00100_00100;
   "-":font=35'b00000_00000_00000_11111_00000_00000_00000;
   default:font=0;
  endcase end
 endfunction
 always @*begin
  out_rgb=rgb;band=0;wi=0;height=0;w=128;wave_y=264;color=24'h20d0c0;
  mode_text=status[15]?(status[14]?"VOICE READY":"VOICE WAIT "):"MUSIC MODE ";
  command_text=status[25:24]==1?"NEXT":status[25:24]==2?"PREV":"----";
  glyph=0;ch=0;column=0;row=0;ci=0;
  if(enable && de)begin
   // Thin connection indicator: red means timeout; cyan means microphone;
   // amber means synthetic input, magenta means clipping/config/DSP errors.
   if(x>=16 && x<176 && y>=144 && y<150)
    out_rgb=!online?24'hc03030:(flags[7] || flags[6] || flags[5] || flags[3])?24'hff20d0:flags[0]?24'hf0b020:24'h20d0c0;
   if(online)begin
    if(!kws && x>=16 && x<176 && y>=156 && y<164)begin
     out_rgb=24'h102028;
     for(k=0;k<3;k=k+1)if(x>=16+k*52 && x<60+k*52)
      out_rgb=slot==k?(flags[1]?24'hf0b020:24'h20d0c0):(learned[k]?24'h208040:24'h303030);
    end
    if(!kws && x>=16 && x<176 && y>=168 && y<172)out_rgb=x<16+progress*40?24'hffffff:24'h202020;
    if(kws && y>=156 && y<170 && x>=16 && x<224)begin
     row=(y-156)>>1;out_rgb=24'h102028;
     if(x<148)begin
      ci=(x-16)/12;column=((x-16)%12)>>1;ch=mode_text[87-ci*8-:8];
     end else if(x>=176)begin
      ci=(x-176)/12;column=((x-176)%12)>>1;ch=command_text[31-ci*8-:8];
     end
     glyph=font(ch);
     if(column<5 && glyph[34-row*5-column])out_rgb=status[15]?24'h20d0c0:24'h4080ff;
    end
   if(x>=16 && x<144 && y>=180 && y<302)begin
     out_rgb=24'h101820;band=(x-16)>>4;
     height=bars[band*8+:8];
     if(height>120)height=120;
     case(band)0,1:color=24'h4080ff;2,3:color=24'h20d0c0;4,5:color=24'hd0d020;default:color=24'hf06030;endcase
     if((x-16)%16<12 && y>=300-height && y<300)out_rgb=color;
    end
   if(x>=16 && x<144 && y>=312 && y<378)begin
     wi=(x-16)>>3;w=wave[wi*8+:8];wave_y=312+{2'b0,w[7:2]};
     out_rgb=(y==344)?24'h304050:24'h101820;
     if(y==wave_y || y==wave_y+1)out_rgb=24'hf0f0f0;
    end
   end
  end
 end
endmodule

