`timescale 1ns/1ps
// Combinational RGB layer adds no pixel latency. DE coordinates belong to
// the same existing stage as RGB, VS resets them. Fixed 640x480 geometry.
module mic_overlay(input wire clk,rst,vs,de,enable,online,
 input wire fx_requested,fx_return_ok,
 input wire [3:0] fx_return_state,
 input wire music_mode,input wire [2:0] music_track,input wire [3:0] music_tracks,
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
 reg [71:0] track_text;
 wire [7:0] track_ascii=music_tracks==0 ? 8'd48 : 8'd49+{5'd0,music_track};
 wire [7:0] count_ascii=8'd48+{4'd0,music_tracks};
 reg [34:0] glyph;reg [7:0] ch,text_x;
 reg [3:0] column,ci;reg [2:0] row;
 function [34:0] font;
  input [7:0] c;
  begin case(c)
   "A":font=35'b01110_10001_10001_11111_10001_10001_10001;
   "B":font=35'b11110_10001_10001_11110_10001_10001_11110;
   "C":font=35'b01111_10000_10000_10000_10000_10000_01111;
   "D":font=35'b11110_10001_10001_10001_10001_10001_11110;
   "E":font=35'b11111_10000_10000_11110_10000_10000_11111;
   "F":font=35'b11111_10000_10000_11110_10000_10000_10000;
   "G":font=35'b01110_10001_10000_10111_10001_10001_01110;
   "Q":font=35'b01110_10001_10001_10001_10101_10010_01101;
   "I":font=35'b11111_00100_00100_00100_00100_00100_11111;
   "H":font=35'b10001_10001_10001_11111_10001_10001_10001;
   "L":font=35'b10000_10000_10000_10000_10000_10000_11111;
   "K":font=35'b10001_10010_10100_11000_10100_10010_10001;
   "0":font=35'b01110_10001_10011_10101_11001_10001_01110;
   "1":font=35'b00100_01100_00100_00100_00100_00100_01110;
   "2":font=35'b01110_10001_00001_00010_00100_01000_11111;
   "3":font=35'b11110_00001_00001_01110_00001_00001_11110;
   "4":font=35'b00010_00110_01010_10010_11111_00010_00010;
   "5":font=35'b11111_10000_10000_11110_00001_00001_11110;
   "6":font=35'b01110_10000_10000_11110_10001_10001_01110;
   "7":font=35'b11111_00001_00010_00100_01000_01000_01000;
   "8":font=35'b01110_10001_10001_01110_10001_10001_01110;
   "/":font=35'b00001_00010_00010_00100_01000_01000_10000;
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
  if(status[15] && status[14] && status[9:8]==3)begin
   case(status[12:10])
    1:mode_text="VOICE CAL  ";
    2:mode_text="VOICE HEAR ";
    3:mode_text="VOICE THINK";
    4:mode_text="VOICE AGAIN";
    5:mode_text="MIC NO PCM ";
    6:mode_text="VOICE ERROR";
    7:mode_text="VOICE QUIET";
    default:mode_text="VOICE READY";
   endcase
  end
  if(!status[15] && fx_requested===1'b1)begin
   if(!fx_return_ok)begin
    if(!status[13])mode_text="FX OLD ACA ";
    else if(!status[31])mode_text="FX NO BCLK ";
    else if(!status[30])mode_text="FX NO LRCK ";
    else if(status[22:21]==1)mode_text="FX CLK LOW ";
    else if(status[22:21]==2)mode_text="FX SLOT 64 ";
    else if(status[22:21]==3)mode_text="FX SLOT ERR";
    else if(!status[29])mode_text="FX NO DATA ";
    else if(!status[28])mode_text="FX IN CRC  ";
    else if(!fx_return_state[1])mode_text="FX NO RET  ";
    else mode_text="FX OUT CRC ";
   end
   else case(status[20:19])
    1:mode_text="FX ECHO    ";
    2:mode_text="FX LOWPASS ";
    3:mode_text="FX TREMOLO ";
    default:mode_text="MUSIC MODE ";
   endcase
  end
  command_text=(!status[15] && status[26])?"SWAP":
    (status[15] && flags[6])?"FAIL":
    status[25:24]==1?"NEXT":status[25:24]==2?"PREV":
    (status[15] && status[25:24]==3)?"SEND":"----";
  track_text={"TRACK ",track_ascii,"/",count_ascii};
  glyph=0;ch=0;column=0;row=0;ci=0;text_x=0;
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
      text_x=x-10'd16;ci=text_x/8'd12;column=(text_x%8'd12)>>1;
      ch=mode_text[7'd87-{ci,3'b000}-:8];
     end else if(x>=176)begin
      text_x=x-10'd176;ci=text_x/8'd12;column=(text_x%8'd12)>>1;
      ch=command_text[5'd31-{ci[1:0],3'b000}-:8];
     end
     glyph=font(ch);
     if(column<5 && glyph[6'd34-({3'd0,row}<<2)-{3'd0,row}-{2'd0,column}])out_rgb=status[15]?24'h20d0c0:24'h4080ff;
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
   if(music_mode===1'b1 && x>=16 && x<124 && y>=390 && y<404)begin
    out_rgb=24'h102028;row=(y-390)>>1;
    text_x=x-16;ci=text_x/12;column=(text_x%12)>>1;
    ch=track_text[71-{ci,3'b000}-:8];glyph=font(ch);
    if(column<5 && glyph[34-row*5-column])out_rgb=music_tracks<2?24'hf0b020:24'h20d0c0;
   end
   end
  end
 end
endmodule
